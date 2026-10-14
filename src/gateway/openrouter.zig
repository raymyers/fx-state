//! OpenRouter as a built-in provider. It speaks the shared chat completions
//! protocol against a fixed base URL, authorized by an OpenRouter key.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const endpoints = @import("../core/config/openrouter_endpoints.zig");

const Allocator = std.mem.Allocator;

/// The fixed connection the chat completions bundle borrows for the process lifetime.
pub const definition = definitions.Definition{
    .id = "openrouter",
    .protocol = .@"openai-chat-completions",
    .base_url = endpoints.api_base_url,
    .auth = .{ .bearer = "OPENROUTER_API_KEY" },
    // Some upstream providers ignore tools unless tool_choice is explicit.
    .tool_choice_mode = .send,
    .builtin = .openrouter,
};

/// Replaces the body of a 402, which only says the key lacks credits.
pub const credits_exhausted_message = "OpenRouter credits exhausted. Add credits at https://openrouter.ai/credits, then try again.";

/// App attribution OpenRouter shows in its rankings and the user's activity page.
pub const attribution_headers = [_]std.http.Header{
    .{ .name = "HTTP-Referer", .value = "https://fx.sh" },
    .{ .name = "X-OpenRouter-Title", .value = "fx" },
};

/// Caller owns the returned URL.
pub fn chat_url(alloc: Allocator) ![]u8 {
    return endpoints.apiUrl(alloc, "/chat/completions");
}

test "OpenRouter chat URL defaults to the public API" {
    const url = try chat_url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", url);
}
