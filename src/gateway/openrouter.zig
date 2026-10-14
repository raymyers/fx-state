//! OpenRouter as a built-in provider. It speaks the shared chat completions
//! protocol against a fixed base URL, authorized by an OpenRouter key.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const endpoints = @import("../core/config/openrouter_endpoints.zig");
const types = @import("../core/shared/types.zig");
const http_pool = @import("../core/shared/http_pool.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

/// A cheap, tool-capable model for session titles and permission reviews, so
/// those side calls never bill the user's chosen model. Revisit each release.
pub const side_model = "openai/gpt-5-nano";
/// The side model rejects "none", so titles ask for the least reasoning it allows.
pub const side_model_effort: types.ReasoningEffort = .literal("minimal");

/// The fixed connection the chat completions bundle borrows for the process lifetime.
pub const definition = definitions.Definition{
    .id = "openrouter",
    .protocol = .@"openai-chat-completions",
    .base_url = endpoints.api_base_url,
    .auth = .{ .bearer = "OPENROUTER_API_KEY" },
    // Some upstream providers ignore tools unless tool_choice is explicit.
    .tool_choice_mode = .send,
    .reviewer_model = side_model,
    .builtin = .openrouter,
};

/// Replaces the body of a 402, which only says the key lacks credits.
pub const credits_exhausted_message = "OpenRouter credits exhausted. Add credits at https://openrouter.ai/credits, then try again.";

/// Replaces the body of a 503 when fx restricted routing, since the cause is
/// likely the user's own provider_order. Caller owns the message.
pub fn routingUnavailableMessage(alloc: Allocator, order: []const []const u8, strict: bool) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll("OpenRouter has no available provider for this model among provider_order (") catch return error.OutOfMemory;
    for (order, 0..) |slug, index| {
        if (index != 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(slug) catch return error.OutOfMemory;
    }
    out.writer.writeAll(if (strict)
        "), and provider_strict stops it from trying others. Change provider_order or turn off provider_strict."
    else
        "). Change provider_order.") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

test "OpenRouter names the routing settings behind a 503" {
    const alloc = std.testing.allocator;
    const strict = try routingUnavailableMessage(alloc, &.{ "anthropic", "google-vertex" }, true);
    defer alloc.free(strict);
    try std.testing.expectEqualStrings("OpenRouter has no available provider for this model among provider_order (anthropic, google-vertex), and provider_strict stops it from trying others. Change provider_order or turn off provider_strict.", strict);
    const loose = try routingUnavailableMessage(alloc, &.{"anthropic"}, false);
    defer alloc.free(loose);
    try std.testing.expectEqualStrings("OpenRouter has no available provider for this model among provider_order (anthropic). Change provider_order.", loose);
}

/// App attribution OpenRouter shows in its rankings and the user's activity page.
pub const attribution_headers = [_]std.http.Header{
    .{ .name = "HTTP-Referer", .value = "https://fx.sh" },
    .{ .name = "X-OpenRouter-Title", .value = "fx" },
};

var pool_mutex: std.Io.Mutex = .init;
var pool_ready = false;
var pool_storage: http_pool.HttpPool = undefined;

/// The process-lifetime connection pool for OpenRouter's chat requests, so
/// turns after the first skip the TLS handshake. Never freed.
pub fn pool() *http_pool.HttpPool {
    pool_mutex.lockUncancelable(io_mod.getIo());
    defer pool_mutex.unlock(io_mod.getIo());
    if (!pool_ready) {
        pool_storage = .init(std.heap.c_allocator);
        pool_ready = true;
    }
    return &pool_storage;
}

/// Caller owns the returned URL.
pub fn chat_url(alloc: Allocator) ![]u8 {
    return endpoints.apiUrl(alloc, "/chat/completions");
}

test "OpenRouter chat URL defaults to the public API" {
    const url = try chat_url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", url);
}
