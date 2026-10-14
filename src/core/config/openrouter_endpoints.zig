//! OpenRouter's public endpoints. Tests point them at a loopback fake server
//! through environment variables that refuse any other URL.
const std = @import("std");
const oauth = @import("../auth/oauth.zig");

const Allocator = std.mem.Allocator;

pub const api_base_url = "https://openrouter.ai/api/v1";
pub const auth_page_url = "https://openrouter.ai/auth";
const e2e_api_base_env = "FX_E2E_OPENROUTER_BASE_URL";
const e2e_auth_page_env = "FX_E2E_OPENROUTER_AUTH_URL";

/// `path` starts with a slash. Caller owns the returned URL.
pub fn apiUrl(alloc: Allocator, path: []const u8) ![]u8 {
    const base = try oauth.configuredEndpoint(alloc, e2e_api_base_env, api_base_url);
    defer alloc.free(base);
    return std.mem.concat(alloc, u8, &.{ std.mem.trimEnd(u8, base, "/"), path });
}

/// Caller owns the returned URL.
pub fn authPageUrl(alloc: Allocator) ![]u8 {
    return oauth.configuredEndpoint(alloc, e2e_auth_page_env, auth_page_url);
}

test "OpenRouter endpoints default to the public service" {
    const alloc = std.testing.allocator;
    const keys = try apiUrl(alloc, "/auth/keys");
    defer alloc.free(keys);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/auth/keys", keys);
    const page = try authPageUrl(alloc);
    defer alloc.free(page);
    try std.testing.expectEqualStrings("https://openrouter.ai/auth", page);
}
