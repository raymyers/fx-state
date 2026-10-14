//! The OpenRouter key saved by `fx login openrouter`. OpenRouter's sign-in
//! returns a long-lived API key rather than an access token, so the file holds
//! only that key: there is nothing to refresh and nothing expires.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");
const session_presence = @import("session_presence.zig");

const Allocator = std.mem.Allocator;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
/// OpenRouter keys are about 70 bytes; the bound keeps a corrupt file out of headers.
const max_key_bytes: usize = 1024;

const auth_file_name = profile_paths.openrouter_auth_file_name;

pub fn presence() host.SecretStorePresence {
    return session_presence.profileFile(auth_file_name, max_auth_file_bytes);
}

/// A key is sent as a bearer token, so it must be printable ASCII without spaces.
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_bytes) return false;
    for (key) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

/// Caller owns the returned key and must release it with secret.zeroAndFree.
pub fn load(alloc: Allocator) !?[]u8 {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.homeDir() orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return null;
        return session_presence.storageError(auth_file_name, err);
    };
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err == error.FileNotFound) return null;
        return session_presence.storageError(auth_file_name, err);
    };
    defer fx_dir.close(io_mod.getIo());

    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return session_presence.storageError(auth_file_name, err),
    };
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch |err| return session_presence.storageError(auth_file_name, err);
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "OpenRouter key load failed step=permissions err=InsecureAuthFile", .{});
        return error.InsecureAuthFile;
    }
    const bytes = io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes) catch |err| return session_presence.storageError(auth_file_name, err);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "OpenRouter key load failed step=parse err={s}", .{@errorName(err)});
            return error.InvalidOpenRouterAuthSession;
        },
    };
}

/// Caller owns the returned key and must release it with secret.zeroAndFree.
pub fn parse(alloc: Allocator, bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenRouterAuthSession;
    const version = parsed.value.object.get("version") orelse return error.InvalidOpenRouterAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidOpenRouterAuthSession;
    const key = parsed.value.object.get("api_key") orelse return error.InvalidOpenRouterAuthSession;
    if (key != .string or !validKey(key.string)) return error.InvalidOpenRouterAuthSession;
    return alloc.dupe(u8, key.string);
}

test "OpenRouter saved key parses only a bounded header-safe key" {
    const alloc = std.testing.allocator;
    const key = try parse(alloc, "{\"version\":1,\"api_key\":\"sk-or-v1-abc\"}");
    defer secret.zeroAndFree(alloc, key);
    try std.testing.expectEqualStrings("sk-or-v1-abc", key);
    for ([_][]const u8{
        "[]",
        "{\"api_key\":\"sk-or-v1-abc\"}",
        "{\"version\":2,\"api_key\":\"sk-or-v1-abc\"}",
        "{\"version\":1,\"api_key\":\"\"}",
        "{\"version\":1,\"api_key\":\"sk-or\\r\\ninjected\"}",
        "{\"version\":1,\"api_key\":\"sk or\"}",
        "{\"version\":1,\"api_key\":7}",
    }) |invalid| try std.testing.expectError(error.InvalidOpenRouterAuthSession, parse(alloc, invalid));
}
