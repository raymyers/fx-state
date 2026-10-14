//! An OpenRouter key's usage as `GET /api/v1/key` reports it: credits spent
//! all time and in the current UTC day, week, and month, and the key's limit
//! and what is left of it. Amounts are US dollars of OpenRouter credit.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const key_path = "/key";
pub const max_body_bytes: usize = 64 * 1024;
const max_label_bytes: usize = 256;
const max_reset_bytes: usize = 32;
/// A billion dollars.
const max_dollars: f64 = 1_000_000_000;

pub const Usage = struct {
    /// The key's label in OpenRouter's settings, e.g. `fx`.
    label: ?[]const u8 = null,
    used: f64 = 0,
    used_daily: ?f64 = null,
    used_weekly: ?f64 = null,
    used_monthly: ?f64 = null,
    /// Null when the key has no limit.
    limit: ?f64 = null,
    limit_remaining: ?f64 = null,
    /// How often the limit resets, e.g. `monthly`; null when it never does.
    limit_reset: ?[]const u8 = null,
    /// True until the account has bought credits.
    free_tier: bool = false,

    /// A deep copy into `alloc`.
    pub fn clone(self: Usage, alloc: Allocator) Allocator.Error!Usage {
        var copy = self;
        if (self.label) |label| copy.label = try alloc.dupe(u8, label);
        if (self.limit_reset) |reset| copy.limit_reset = try alloc.dupe(u8, reset);
        return copy;
    }

    /// Whether every field is in range, for data read back from disk.
    pub fn valid(self: Usage) bool {
        if (!validAmount(self.used)) return false;
        inline for (.{ self.used_daily, self.used_weekly, self.used_monthly, self.limit }) |optional| {
            if (optional) |value| if (!validAmount(value)) return false;
        }
        if (self.limit_remaining) |value| if (!std.math.isFinite(value) or @abs(value) > max_dollars) return false;
        if (self.label) |label| if (label.len > max_label_bytes or !printable(label)) return false;
        if (self.limit_reset) |reset| if (reset.len == 0 or reset.len > max_reset_bytes or !printable(reset)) return false;
        return true;
    }
};

fn validAmount(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= max_dollars;
}

fn printable(text: []const u8) bool {
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    usage: Usage,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{ InvalidResponse, OutOfMemory };

/// Parses a `/key` body. Caller owns the result; it copies every string.
pub fn parseKey(gpa: Allocator, body: []const u8) ParseError!Owned {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    if (parsed != .object) return error.InvalidResponse;
    const data = switch (parsed.object.get("data") orelse return error.InvalidResponse) {
        .object => |object| object,
        else => return error.InvalidResponse,
    };
    var usage: Usage = .{
        .used = try amount(data, "usage") orelse 0,
        .used_daily = try amount(data, "usage_daily"),
        .used_weekly = try amount(data, "usage_weekly"),
        .used_monthly = try amount(data, "usage_monthly"),
        .limit = try amount(data, "limit"),
        .limit_remaining = try signedAmount(data, "limit_remaining"),
        .free_tier = if (data.get("is_free_tier")) |value| value == .bool and value.bool else false,
    };
    if (data.get("label")) |value| if (value == .string and value.string.len != 0) {
        usage.label = try alloc.dupe(u8, value.string[0..@min(value.string.len, max_label_bytes)]);
    };
    if (data.get("limit_reset")) |value| if (value == .string and value.string.len != 0 and value.string.len <= max_reset_bytes) {
        usage.limit_reset = try alloc.dupe(u8, value.string);
    };
    if (!usage.valid()) return error.InvalidResponse;
    return .{ .arena = arena, .usage = usage };
}

fn number(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn amount(object: std.json.ObjectMap, key: []const u8) ParseError!?f64 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    const n = number(value) orelse return error.InvalidResponse;
    if (!validAmount(n)) return error.InvalidResponse;
    return n;
}

/// `limit_remaining` can go below zero when a request overruns the limit.
fn signedAmount(object: std.json.ObjectMap, key: []const u8) ParseError!?f64 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    const n = number(value) orelse return error.InvalidResponse;
    if (!std.math.isFinite(n) or @abs(n) > max_dollars) return error.InvalidResponse;
    return n;
}

const testing = std.testing;

test "an OpenRouter key reports its spend and limit" {
    var owned = try parseKey(testing.allocator,
        \\{"data":{"label":"fx","limit":25,"limit_reset":"monthly","limit_remaining":19.5,"usage":42.25,
        \\"usage_daily":0.5,"usage_weekly":3,"usage_monthly":5.5,"is_free_tier":false,"byok_usage":0,"budgets":[]}}
    );
    defer owned.deinit();
    const u = owned.usage;
    try testing.expectEqualStrings("fx", u.label.?);
    try testing.expectEqual(@as(f64, 42.25), u.used);
    try testing.expectEqual(@as(?f64, 0.5), u.used_daily);
    try testing.expectEqual(@as(?f64, 3), u.used_weekly);
    try testing.expectEqual(@as(?f64, 25), u.limit);
    try testing.expectEqual(@as(?f64, 19.5), u.limit_remaining);
    try testing.expectEqualStrings("monthly", u.limit_reset.?);
    try testing.expect(!u.free_tier);
}

test "an unlimited OpenRouter key has no limit and a malformed body is rejected" {
    var owned = try parseKey(testing.allocator, "{\"data\":{\"label\":\"\",\"limit\":null,\"limit_remaining\":null,\"usage\":0,\"is_free_tier\":true}}");
    defer owned.deinit();
    try testing.expect(owned.usage.limit == null and owned.usage.label == null and owned.usage.free_tier);
    for ([_][]const u8{
        "not json",
        "{}",
        "{\"data\":[]}",
        "{\"data\":{\"usage\":-1}}",
        "{\"data\":{\"usage\":\"5\"}}",
        "{\"data\":{\"usage\":1,\"limit\":1e999}}",
    }) |bad| try testing.expectError(error.InvalidResponse, parseKey(testing.allocator, bad));
}

test "OpenRouter usage clones deeply and validates what it reads back" {
    var owned = try parseKey(testing.allocator, "{\"data\":{\"label\":\"fx\",\"usage\":1,\"limit_reset\":\"daily\"}}");
    defer owned.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const copy = try owned.usage.clone(arena.allocator());
    try testing.expect(copy.label.?.ptr != owned.usage.label.?.ptr);
    try testing.expect(copy.valid());
    var bad = copy;
    bad.used = std.math.nan(f64);
    try testing.expect(!bad.valid());
}
