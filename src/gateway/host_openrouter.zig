//! OpenRouter through a host transport, for runtimes such as libfx whose
//! network access belongs to the host. Requests, the catalog, and reply
//! parsing are the CLI's own; the host adds the API key at its fetch edge, so
//! the engine never holds it.
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const endpoints = @import("../core/config/openrouter_endpoints.zig");
const chat_completions = @import("chat_completions.zig");
const host_stream = @import("host_stream_provider.zig");
const host_model_catalog = @import("host_model_catalog.zig");
const openrouter = @import("openrouter.zig");
const openrouter_models = @import("openrouter_models.zig");

const Allocator = std.mem.Allocator;

pub const chat_url = endpoints.api_base_url ++ "/chat/completions";
pub const models_url = endpoints.api_base_url ++ "/models?supported_parameters=tools";

pub const Context = struct {
    transport: host_stream.Transport,
};

/// The OpenRouter slot of a host runtime's provider set. Borrows `context`.
pub fn bundle(context: *Context) provider_set.Bundle {
    return .{
        .presentation = provider_catalog.find(.openrouter),
        .auth_strategy = .openrouter,
        .capabilities = .{ .gateway_prompt_caching = true },
        .title_model = openrouter.side_model,
        .fallback_model_capabilities_fn = openrouter_models.capabilitiesFor,
        .agent_stream = .{
            .context = context,
            .stream_fn = stream,
            .build_request_fn = buildRequest,
            .project_replay_fn = chat_completions.project_replay,
        },
        .model_catalog = .{
            .context = context,
            .fetch_fn = fetchCatalog,
            .lookup_capabilities_fn = lookupCapabilities,
            .provider_id = .openrouter,
        },
    };
}

fn buildRequest(_: ?*anyopaque, alloc: Allocator, request: stream_provider.RequestData) anyerror![]u8 {
    return chat_completions.build_for(&openrouter.definition, alloc, request);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    if (host_stream.deadlineExpired(request.deadline)) return error.Timeout;
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    // The engine never holds the key; the host adds it.
    if (request.credential.credentialSource() != .host_managed) {
        return stream_provider.failResult(error.ProviderCredentialRequired);
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const transport = context.transport;
    const payload = request.prepared_request_body orelse
        try chat_completions.build_for(&openrouter.definition, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "text/event-stream" },
    } ++ openrouter.attribution_headers;

    const opened = try host_stream.openPost(alloc, transport, request, chat_url, &headers, payload);
    defer transport.close(opened.handle);
    if (opened.status != .ok) {
        var detail = try host_stream.readErrorBody(alloc, transport, opened.handle, request);
        if (opened.status == .payment_required) {
            alloc.free(detail);
            detail = try alloc.dupe(u8, openrouter.credits_exhausted_message);
        }
        return .{ .failed = .{ .kind = chat_completions.failure_kind(opened.status), .detail = detail, .ownership = .owned } };
    }

    var reader: host_stream.HostStreamReader = undefined;
    reader.init(transport, opened.handle, request.cancel_flag, request.deadline, request.cooperative_pulse);
    const result = chat_completions.consume(alloc, &reader.interface, request) catch |err| switch (err) {
        error.ReadFailed => return host_stream.readFailure(&reader, request.cancel_flag),
        else => return err,
    };
    switch (result) {
        .completed => |completed| host_stream.signalConsumed(transport, opened.handle, request, completed.completion),
        else => {},
    }
    return result;
}

/// The public catalog, read through the host without a key.
fn fetchCatalog(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const headers = [_]std.http.Header{.{ .name = "accept", .value = "application/json" }};
    const body = switch (try host_model_catalog.get(alloc, context.transport, models_url, &headers, input.cancel_flag, openrouter_models.max_catalog_bytes)) {
        .body => |body| body,
        .failure => |failure| return .{ .failure = failure },
    };
    defer alloc.free(body);
    var entries = openrouter_models.parse(alloc, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .{ .category = .malformed_response } },
    };
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    openrouter_models.remember(entries.items);
    return .{ .catalog = entries };
}

fn lookupCapabilities(_: ?*anyopaque, model: []const u8) @import("../core/config/model_capabilities.zig").Capabilities {
    return openrouter_models.capabilitiesFor(model);
}

const FakeTransport = @import("host_transport_testing.zig").FakeTransport;

const reply_sse =
    "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"libfx on OpenRouter\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

test "host OpenRouter posts to OpenRouter's chat URL with attribution and no key" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "anthropic/claude-sonnet-5.5", .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    var result = try bundle(&context).agent_stream.?.stream(alloc, fake.request(.host_managed));
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", fake.urls[0]);
    try std.testing.expect(std.mem.find(u8, fake.headers[0], "authorization") == null);
    try std.testing.expect(std.mem.find(u8, fake.headers[0], "{\"name\":\"HTTP-Referer\",\"value\":\"https://fx.sh\"}") != null);
    try std.testing.expectEqualStrings("libfx on OpenRouter", result.completed.completion.content.?);
    try std.testing.expectEqual(fake.calls, fake.closed);
}

test "host OpenRouter refuses a key held by the engine and explains an empty balance" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "anthropic/claude-sonnet-5.5", .responses = &.{.{ .status = 402, .body = "{\"error\":{\"code\":402}}" }} };
    defer fake.deinit();
    var context = Context{ .transport = fake.transport() };
    const agent_stream = bundle(&context).agent_stream.?;
    const lease: stream_provider.CredentialLease = .{ .direct = .{ .secret_bytes = "sk-or-key", .source = .openrouter_api_key } };
    try std.testing.expectError(error.ProviderCredentialRequired, agent_stream.stream(alloc, fake.request(lease)));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    var result = try agent_stream.stream(alloc, fake.request(.host_managed));
    defer result.deinit(alloc);
    try std.testing.expectEqual(stream_provider.FailureKind.insufficient_credits, result.failed.kind);
    try std.testing.expectEqualStrings(openrouter.credits_exhausted_message, result.failed.detail.?);
}
