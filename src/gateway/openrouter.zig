//! OpenRouter as a built-in provider. It speaks the shared chat completions
//! protocol against a fixed base URL, authorized by an OpenRouter key.
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const oauth = @import("../core/auth/oauth.zig");
const model_provider = @import("../core/config/model_provider.zig");

const Allocator = std.mem.Allocator;

pub const default_base_url = "https://openrouter.ai/api/v1";
/// Test seam for the E2E fake server; only loopback URLs are accepted.
const e2e_base_url_env = "FX_E2E_OPENROUTER_BASE_URL";

/// The fixed connection the chat completions bundle borrows for the process lifetime.
pub const definition = definitions.Definition{
    .id = "openrouter",
    .protocol = .@"openai-chat-completions",
    .base_url = default_base_url,
    .auth = .{ .bearer = "OPENROUTER_API_KEY" },
    // Until the live catalog lands, the default model is the only listed entry;
    // its limits stay unknown rather than guessed.
    .model_metadata = &.{.{ .id = model_provider.openrouter_default_model, .supports_tool_use = true }},
    .builtin = .openrouter,
};

/// Caller owns the returned URL.
pub fn chat_url(alloc: Allocator) ![]u8 {
    const base = try oauth.configuredEndpoint(alloc, e2e_base_url_env, default_base_url);
    defer alloc.free(base);
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.mem.concat(alloc, u8, &.{ trimmed, "/chat/completions" });
}

test "OpenRouter chat URL defaults to the public API" {
    const url = try chat_url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", url);
}
