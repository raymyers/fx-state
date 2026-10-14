//! OpenRouter's live model catalog. The list is public, so no key is sent. It
//! is cached on disk so a slow or failed fetch can fall back to the last copy,
//! and the newest parse stays in memory for capability lookups.
const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const endpoints = @import("../core/config/openrouter_endpoints.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const model_catalog_metadata = @import("../core/gateway/model_catalog_metadata.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;

pub const max_catalog_bytes: usize = 1024 * 1024;
const max_catalog_models: usize = 4096;
const max_model_id_bytes: usize = 256;
const fetch_timeout_ms: i64 = 30_000;
/// A fresh cache skips the network; a stale one is still used when a fetch fails.
const cache_ttl_ms: i64 = 60 * 60 * 1000;
const cache_file_name = "openrouter-models.json";
const cache_header = "fx-openrouter-models-v1 ";

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalog,
    .lookup_capabilities_fn = lookupCapabilities,
    .provider_id = .openrouter,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliCatalog,
};

/// Caller frees with model_catalog.freeModelCatalog. Entries without tool
/// support are dropped, since fx cannot run an agent turn on them.
pub fn parse(alloc: Allocator, bytes: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidOpenRouterCatalog,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenRouterCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenRouterCatalog;
    if (data != .array) return error.InvalidOpenRouterCatalog;
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (data.array.items) |item| {
        if (entries.items.len == max_catalog_models) break;
        if (item != .object) continue;
        const model = item.object;
        const id = stringField(model, "id") orelse continue;
        if (id.len == 0 or id.len > max_model_id_bytes) continue;
        if (!printable(id)) continue;
        const parameters = arrayField(model, "supported_parameters");
        if (!contains(parameters, "tools")) continue;
        const inputs = if (objectField(model, "architecture")) |architecture| arrayField(architecture, "input_modalities") else null;
        const top_provider = objectField(model, "top_provider");
        var entry: model_catalog.ModelCatalogEntry = .{
            .id = try alloc.dupe(u8, id),
            .model_type = undefined,
            .released = integerField(model, "created") orelse 0,
            .has_tool_use = true,
            .has_reasoning = contains(parameters, "reasoning"),
            .has_vision = contains(inputs, "image"),
            .has_file_input = contains(inputs, "file"),
            .context_window = boundedU32(integerField(model, "context_length")),
            .max_tokens = boundedU32(if (top_provider) |provider| integerField(provider, "max_completion_tokens") else null),
        };
        errdefer alloc.free(entry.id);
        entry.model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(entry.model_type);
        if (stringField(model, "name")) |name| {
            const trimmed = std.mem.trim(u8, name, " \t\r\n");
            if (trimmed.len != 0 and printable(trimmed)) entry.name = try alloc.dupe(u8, trimmed);
        }
        errdefer if (entry.name) |name| alloc.free(name);
        if (entry.has_reasoning) try appendEfforts(alloc, &entry, objectField(model, "reasoning"));
        errdefer entry.reasoning_efforts.deinit(alloc);
        try entries.append(alloc, entry);
    }
    return entries;
}

/// The efforts the model lists, in catalog order. A model that always reasons
/// rejects "none", so it is never offered for one.
fn appendEfforts(alloc: Allocator, entry: *model_catalog.ModelCatalogEntry, reasoning: ?std.json.ObjectMap) !void {
    const metadata = reasoning orelse return;
    const mandatory = if (metadata.get("mandatory")) |value| value == .bool and value.bool else false;
    for (arrayField(metadata, "supported_efforts") orelse return) |value| {
        if (entry.reasoning_efforts.items.len == types.ReasoningEffort.max_options) break;
        if (value != .string) continue;
        if (mandatory and std.mem.eql(u8, value.string, "none")) continue;
        const effort = types.ReasoningEffort.parse(value.string) orelse continue;
        if (effort.isDefault()) continue;
        try entry.reasoning_efforts.append(alloc, effort);
    }
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn arrayField(object: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const value = object.get(key) orelse return null;
    return if (value == .array) value.array.items else null;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn contains(values: ?[]const std.json.Value, wanted: []const u8) bool {
    for (values orelse return false) |value| {
        if (value == .string and std.mem.eql(u8, value.string, wanted)) return true;
    }
    return false;
}

fn boundedU32(value: ?i64) u32 {
    const raw = value orelse return 0;
    return std.math.cast(u32, raw) orelse if (raw > 0) std.math.maxInt(u32) else 0;
}

fn printable(text: []const u8) bool {
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn fetchCatalog(_: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const bytes = loadCatalogBytes(alloc, input.cancel_flag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .{ .failure = .{ .category = .cancellation } },
        error.OpenRouterCatalogTooLarge => return .{ .failure = .{ .category = .malformed_response } },
        else => return .{ .failure = .{ .category = .transport, .retryable = true } },
    };
    defer alloc.free(bytes);
    var entries = parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .{ .category = .malformed_response } },
    };
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    remember(entries.items);
    return .{ .catalog = entries };
}

fn fetchCliCatalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const provenance = model_catalog.Provenance{ .access = model_catalog.AccessMetadata.init(input.access) };
    const exhausted: gateway_provider.CliModelCatalogResult = .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
    const result = fetchCatalog(raw, alloc, .{ .access = input.access, .endpoint = input.endpoint, .cancel_flag = input.cancel_flag }) catch return exhausted;
    switch (result) {
        .failure => |failure| return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = failure } },
        .catalog => |value| {
            var entries = value;
            defer model_catalog.freeModelCatalog(alloc, &entries);
            const ids = model_catalog.projectModelIds(alloc, entries.items) catch return exhausted;
            return .{ .loaded = .{ .ids = ids, .provenance = provenance } };
        },
    }
}

/// A fresh disk copy, else the network, else a stale disk copy. Caller owns the bytes.
fn loadCatalogBytes(alloc: Allocator, cancel_flag: ?*std.atomic.Value(bool)) ![]u8 {
    const now_ms = io_mod.milliTimestamp();
    var cached = readCache(alloc, now_ms);
    if (cached) |copy| {
        if (copy.fresh) return copy.bytes;
    }
    defer if (cached) |copy| alloc.free(copy.bytes);
    const fetched = fetchRemote(alloc, cancel_flag) catch |err| {
        if (err == error.OutOfMemory or err == error.Cancelled) return err;
        const stale = cached orelse return err;
        debug_trace.logf("catalog", "OpenRouter catalog fetch failed err={s}; using cached copy", .{@errorName(err)});
        cached = null;
        return stale.bytes;
    };
    writeCache(alloc, fetched, now_ms) catch |err| {
        debug_trace.logf("catalog", "OpenRouter catalog cache write failed err={s}", .{@errorName(err)});
    };
    return fetched;
}

const Body = struct {
    bytes: []u8,

    pub fn deinit(self: *Body, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: Allocator,
    url: []const u8,

    pub fn run(self: *@This()) !Body {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer self.alloc.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{ .user_agent = .{ .override = gateway_client.user_agent }, .accept_encoding = .omit },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            .redirect_behavior = .unhandled,
            .response_writer = &writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OpenRouterCatalogTooLarge,
            else => return err,
        };
        if (result.status != .ok) return error.OpenRouterCatalogRejected;
        const body = writer.buffered();
        if (body.len > max_catalog_bytes) return error.OpenRouterCatalogTooLarge;
        return .{ .bytes = try self.alloc.dupe(u8, body) };
    }
};

fn fetchRemote(alloc: Allocator, cancel_flag: ?*std.atomic.Value(bool)) ![]u8 {
    const url = try endpoints.apiUrl(alloc, "/models?supported_parameters=tools");
    defer alloc.free(url);
    var fallback_cancel = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(fetch_timeout_ms) });
    var operation = FetchOperation{ .alloc = alloc, .url = url };
    const body = try gateway_client.runBoundedHttpOperation(Body, alloc, cancel_flag orelse &fallback_cancel, deadline, &operation);
    return body.bytes;
}

const CachedCatalog = struct {
    bytes: []u8,
    fresh: bool,
};

/// Never fails: an unreadable cache is a missing one.
fn readCache(alloc: Allocator, now_ms: i64) ?CachedCatalog {
    const home = io_mod.homeDir() orelse return null;
    const path = std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, cache_file_name }) catch return null;
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    const text = io_mod.readFileToEnd(alloc, &file, max_catalog_bytes + 64) catch return null;
    return decodeCache(alloc, text, now_ms);
}

/// Takes ownership of `text`.
fn decodeCache(alloc: Allocator, text: []u8, now_ms: i64) ?CachedCatalog {
    const newline = std.mem.findScalar(u8, text, '\n') orelse {
        alloc.free(text);
        return null;
    };
    const header = text[0..newline];
    const written_ms = if (std.mem.startsWith(u8, header, cache_header))
        std.fmt.parseInt(i64, header[cache_header.len..], 10) catch null
    else
        null;
    const stamp = written_ms orelse {
        alloc.free(text);
        return null;
    };
    defer alloc.free(text);
    const bytes = alloc.dupe(u8, text[newline + 1 ..]) catch return null;
    return .{ .bytes = bytes, .fresh = now_ms >= stamp and now_ms - stamp < cache_ttl_ms };
}

fn writeCache(alloc: Allocator, bytes: []const u8, now_ms: i64) !void {
    const home = io_mod.homeDir() orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{}) };
    defer home_dir.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    defer fx_dir.close();
    const text = try alloc.print(cache_header ++ "{d}\n{s}", .{ now_ms, bytes });
    defer alloc.free(text);
    try io_mod.durableReplaceVerified(alloc, &fx_dir, cache_file_name, text);
}

/// The newest catalog's capabilities, for lookups that may not wait or allocate.
const Remembered = struct {
    id: []u8,
    capabilities: model_capabilities.Capabilities,
};

var remembered_mutex: std.Io.Mutex = .init;
var remembered: []Remembered = &.{};

pub fn remember(entries: []const model_catalog.ModelCatalogEntry) void {
    const alloc = std.heap.c_allocator;
    var next = alloc.alloc(Remembered, entries.len) catch return;
    var filled: usize = 0;
    defer if (filled != entries.len) {
        for (next[0..filled]) |item| alloc.free(item.id);
        alloc.free(next);
    };
    for (entries) |entry| {
        next[filled] = .{
            .id = alloc.dupe(u8, entry.id) catch return,
            .capabilities = model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(entry)),
        };
        filled += 1;
    }
    remembered_mutex.lockUncancelable(io_mod.getIo());
    const previous = remembered;
    remembered = next;
    remembered_mutex.unlock(io_mod.getIo());
    for (previous) |item| alloc.free(item.id);
    if (previous.len != 0) alloc.free(previous);
}

/// Unknown (empty) capabilities when the catalog has not loaded or lacks the model.
pub fn capabilitiesFor(model: []const u8) model_capabilities.Capabilities {
    return lookupCapabilities(null, model);
}

fn lookupCapabilities(_: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    remembered_mutex.lockUncancelable(io_mod.getIo());
    defer remembered_mutex.unlock(io_mod.getIo());
    for (remembered) |item| {
        if (std.mem.eql(u8, item.id, model)) return item.capabilities;
    }
    return .{};
}

/// True when a catalog has loaded and does not list `model`.
pub fn catalogOmits(model: []const u8) bool {
    remembered_mutex.lockUncancelable(io_mod.getIo());
    defer remembered_mutex.unlock(io_mod.getIo());
    if (remembered.len == 0) return false;
    for (remembered) |item| {
        if (std.mem.eql(u8, item.id, model)) return false;
    }
    return true;
}

test "OpenRouter catalog parsing maps limits and modalities and drops models without tools" {
    const alloc = std.testing.allocator;
    var entries = try parse(alloc, @embedFile("testdata/openrouter/models.json"));
    defer model_catalog.freeModelCatalog(alloc, &entries);
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    const sonnet = entries.items[0];
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-5.5", sonnet.id);
    try std.testing.expectEqual(@as(u32, 1_000_000), sonnet.context_window);
    try std.testing.expectEqual(@as(u32, 128_000), sonnet.max_tokens);
    try std.testing.expect(sonnet.has_tool_use and sonnet.has_reasoning and sonnet.has_vision and sonnet.has_file_input);
    const pareto = entries.items[1];
    try std.testing.expect(pareto.has_vision and !pareto.has_reasoning and !pareto.has_file_input);
    try std.testing.expectEqual(@as(u32, 131_072), pareto.max_tokens);
}

test "OpenRouter reasoning efforts follow the catalog and never offer none to mandatory models" {
    const alloc = std.testing.allocator;
    var fixture = try parse(alloc, @embedFile("testdata/openrouter/models.json"));
    defer model_catalog.freeModelCatalog(alloc, &fixture);
    try std.testing.expectEqual(@as(usize, 5), fixture.items[0].reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("max", fixture.items[0].reasoning_efforts.items[0].label());
    var entries = try parse(alloc,
        \\{"data":[
        \\{"id":"optional/model","supported_parameters":["tools","reasoning"],"reasoning":{"supported_efforts":["high","none"]}},
        \\{"id":"mandatory/model","supported_parameters":["tools","reasoning"],"reasoning":{"mandatory":true,"supported_efforts":["high","none","bad value",7]}},
        \\{"id":"unlisted/model","supported_parameters":["tools","reasoning"],"reasoning":{"mandatory":true}},
        \\{"id":"plain/model","supported_parameters":["tools"],"reasoning":{"supported_efforts":["high"]}}]}
    );
    defer model_catalog.freeModelCatalog(alloc, &entries);
    const expected = [_][]const []const u8{ &.{ "high", "none" }, &.{"high"}, &.{}, &.{} };
    for (entries.items, expected) |entry, efforts| {
        try std.testing.expectEqual(efforts.len, entry.reasoning_efforts.items.len);
        for (entry.reasoning_efforts.items, efforts) |effort, label| try std.testing.expectEqualStrings(label, effort.label());
    }
    try std.testing.expect(!entries.items[3].has_reasoning);
}

test "OpenRouter catalog parsing tolerates missing fields and rejects malformed roots" {
    const alloc = std.testing.allocator;
    var entries = try parse(alloc,
        \\{"data":[{"id":"bare/model","supported_parameters":["tools"]},{"id":"","supported_parameters":["tools"]},
        \\{"id":"null/limits","context_length":null,"top_provider":null,"architecture":{"input_modalities":null},"supported_parameters":["tools"]},
        \\7,{"supported_parameters":["tools"]},{"id":"huge/limit","context_length":99999999999,"supported_parameters":["tools"]}]}
    );
    defer model_catalog.freeModelCatalog(alloc, &entries);
    try std.testing.expectEqual(@as(usize, 3), entries.items.len);
    try std.testing.expectEqual(@as(u32, 0), entries.items[0].context_window);
    try std.testing.expect(entries.items[0].name == null);
    try std.testing.expectEqual(std.math.maxInt(u32), entries.items[2].context_window);
    for ([_][]const u8{ "[]", "{}", "{\"data\":{}}", "not json" }) |bad| {
        try std.testing.expectError(error.InvalidOpenRouterCatalog, parse(alloc, bad));
    }
}

test "OpenRouter catalog cache honors its time-to-live and rejects unknown headers" {
    const alloc = std.testing.allocator;
    const fresh = decodeCache(alloc, try alloc.dupe(u8, cache_header ++ "1000\n{\"data\":[]}"), 1000 + cache_ttl_ms - 1).?;
    defer alloc.free(fresh.bytes);
    try std.testing.expect(fresh.fresh);
    try std.testing.expectEqualStrings("{\"data\":[]}", fresh.bytes);
    const stale = decodeCache(alloc, try alloc.dupe(u8, cache_header ++ "1000\n{}"), 1000 + cache_ttl_ms).?;
    defer alloc.free(stale.bytes);
    try std.testing.expect(!stale.fresh);
    try std.testing.expect(decodeCache(alloc, try alloc.dupe(u8, "other-header 1000\n{}"), 1000) == null);
    try std.testing.expect(decodeCache(alloc, try alloc.dupe(u8, "no newline"), 1000) == null);
}

test "OpenRouter capability lookup reads the remembered catalog" {
    const alloc = std.testing.allocator;
    var entries = try parse(alloc, @embedFile("testdata/openrouter/models.json"));
    defer model_catalog.freeModelCatalog(alloc, &entries);
    remember(entries.items);
    defer remember(&.{});
    try std.testing.expectEqual(@as(?u32, 1_000_000), lookupCapabilities(null, "anthropic/claude-sonnet-5.5").context_window);
    try std.testing.expect(lookupCapabilities(null, "missing/model").context_window == null);
    try std.testing.expect(catalogOmits("missing/model"));
    try std.testing.expect(!catalogOmits("unbiased/pareto-26.9"));
}
