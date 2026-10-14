//! Sign-in to OpenRouter through its OAuth PKCE flow. Unlike other providers,
//! the exchange returns a long-lived API key instead of an access token, so
//! there is no refresh or expiry handling: the key is validated once and
//! saved as the `openrouter_login` credential.
const std = @import("std");
const browser_callback = @import("browser_callback.zig");
const credentials = @import("credentials.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const endpoints = @import("../config/openrouter_endpoints.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const openrouter_session = @import("openrouter_session.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

/// Authorization codes expire ten minutes after issue, so waiting longer is pointless.
const sign_in_timeout_seconds: i64 = 10 * 60;
const key_label = "fx";

pub const Mode = enum {
    /// A loopback callback receives the code; a pasted code also works.
    browser,
    /// No callback: OpenRouter shows the code and the user pastes it.
    headless,
};

const Callback = struct {
    code: []u8,

    fn deinit(self: *Callback, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.code);
        self.* = undefined;
    }
};

const Context = struct {
    mode: Mode,
    listener: ?std.Io.net.Server,
    code_verifier: []u8,
    /// Null in headless mode, where OpenRouter does not return state.
    state: ?[]u8,
    transport: oauth_transport.Provider,
    manual_code_mutex: std.Io.Mutex = .init,
    manual_code: ?[]u8 = null,
    pending_callback: ?browser_callback.Accepted(Callback) = null,

    fn deinit(self: *Context, alloc: Allocator) void {
        self.finishCallback(alloc, false);
        if (self.listener) |*listener| listener.deinit(io_mod.getIo());
        secret.zeroAndFree(alloc, self.code_verifier);
        if (self.state) |state| secret.zeroAndFree(alloc, state);
        if (self.manual_code) |code| secret.zeroAndFree(alloc, code);
        self.* = undefined;
    }

    fn finishCallback(self: *Context, alloc: Allocator, saved: bool) void {
        var callback = self.pending_callback orelse return;
        self.pending_callback = null;
        defer callback.deinit();
        defer callback.callback.deinit(alloc);
        callback.respond(if (saved) .ok else .failed) catch |err| {
            debug_trace.logf("auth", "OpenRouter completion response failed err={s}", .{@errorName(err)});
        };
    }

    fn submitManualCode(self: *Context, alloc: Allocator, input: []const u8) !void {
        const code = std.mem.trim(u8, input, " \t\r\n");
        if (!validCode(code)) return error.InvalidOpenRouterAuthorizationCode;
        const owned = try alloc.dupe(u8, code);
        errdefer secret.zeroAndFree(alloc, owned);
        self.manual_code_mutex.lockUncancelable(io_mod.getIo());
        defer self.manual_code_mutex.unlock(io_mod.getIo());
        if (self.manual_code) |pending| secret.zeroAndFree(alloc, pending);
        self.manual_code = owned;
    }

    fn takeManualCode(self: *Context) ?[]u8 {
        self.manual_code_mutex.lockUncancelable(io_mod.getIo());
        defer self.manual_code_mutex.unlock(io_mod.getIo());
        const code = self.manual_code;
        self.manual_code = null;
        return code;
    }
};

fn validCode(code: []const u8) bool {
    if (code.len == 0 or code.len > login_flow.max_manual_code_bytes) return false;
    for (code) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

/// Starts a sign-in on `runtime`. Returns false when one is already running.
pub fn startSignIn(
    runtime: *login_flow.SignInRuntime,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mode: Mode,
) !bool {
    if (comptime host_target.is_wasm) return error.OpenRouterSignInUnavailable;
    try credentials.requireSignInStorage(.openrouter_login);
    const page_url = try endpoints.authPageUrl(alloc);
    defer alloc.free(page_url);
    const keys_url = try endpoints.apiUrl(alloc, "/auth/keys");
    var keys_url_owned = true;
    errdefer if (keys_url_owned) alloc.free(keys_url);

    var listener: ?std.Io.net.Server = null;
    errdefer if (listener) |*server| server.deinit(io_mod.getIo());
    var callback_url: ?[]u8 = null;
    defer if (callback_url) |url| alloc.free(url);
    var state: ?[]u8 = null;
    errdefer if (state) |value| secret.zeroAndFree(alloc, value);
    if (mode == .browser) {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        listener = try address.listen(io_mod.getIo(), .{ .reuse_address = true });
        // OpenRouter documents localhost callbacks on any port.
        callback_url = try alloc.print("http://localhost:{d}/callback", .{listener.?.socket.address.getPort()});
        state = try oauth.randomUrlSafeSecret(alloc);
    }
    const code_verifier = try oauth.randomUrlSafeSecret(alloc);
    errdefer secret.zeroAndFree(alloc, code_verifier);
    const code_challenge = try oauth.pkceChallengeAlloc(alloc, code_verifier);
    defer alloc.free(code_challenge);
    const authorization_url = try buildAuthorizationUrl(alloc, page_url, callback_url, code_challenge, state);
    var authorization_url_owned = true;
    errdefer if (authorization_url_owned) alloc.free(authorization_url);

    var prepared = try login_flow.prepareBrowserLogin(alloc, .{
        .issuer = page_url,
        .authorization_endpoint_suffix = "",
        .token_endpoint = keys_url,
        .verification_uri = authorization_url,
        .client_id = "",
        .expires_in = sign_in_timeout_seconds,
    });
    keys_url_owned = false;
    authorization_url_owned = false;
    errdefer prepared.deinit(alloc);

    const context = try alloc.create(Context);
    context.* = .{
        .mode = mode,
        .listener = listener,
        .code_verifier = code_verifier,
        .state = state,
        .transport = transport,
    };
    listener = null;
    state = null;
    return runtime.startPrepared(alloc, prepared, .{
        .ctx = context,
        .deinit_ctx = deinitContext,
        .oauth_transport = transport,
        .poll = .{ .ctx = context, .poll_device_token = pollKey },
        .complete = completeSignIn,
        .save = saveSignIn,
        .finish = finishSignIn,
        .submit_manual_code = submitManualCode,
    });
}

fn deinitContext(raw: ?*anyopaque, alloc: Allocator) void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    context.deinit(alloc);
    alloc.destroy(context);
}

fn submitManualCode(raw: ?*anyopaque, alloc: Allocator, code: []const u8) !void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try context.submitManualCode(alloc, code);
}

/// Caller owns the returned URL.
fn buildAuthorizationUrl(
    alloc: Allocator,
    page_url: []const u8,
    callback_url: ?[]const u8,
    code_challenge: []const u8,
    state: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{s}?", .{page_url});
    var form: oauth.FormBody = .{};
    if (callback_url) |url| try form.append(&out.writer, "callback_url", url);
    try form.append(&out.writer, "code_challenge", code_challenge);
    try form.append(&out.writer, "code_challenge_method", "S256");
    try form.append(&out.writer, "key_label", key_label);
    if (state) |value| try form.append(&out.writer, "state", value);
    return out.toOwnedSlice();
}

fn pollKey(
    raw: ?*anyopaque,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    _: []const u8,
    _: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const manual_code = context.takeManualCode();
    defer if (manual_code) |code| secret.zeroAndFree(alloc, code);
    var accepted: ?browser_callback.Accepted(Callback) = null;
    defer if (accepted) |*callback| {
        callback.callback.deinit(alloc);
        callback.deinit();
    };
    const code = manual_code orelse code: {
        const listener = if (context.listener) |*server| server else return .pending;
        var parser: ParserContext = .{ .expected_state = context.state.? };
        accepted = (browser_callback.await(Callback, classifyCallback, alloc, listener, &parser, cancel_flag, null) catch |err| switch (err) {
            error.OAuthCallbackListenerFailed => return error.OpenRouterCallbackListenerFailed,
            else => return err,
        }) orelse return .pending;
        break :code accepted.?.callback.code;
    };
    const key = exchangeCode(alloc, transport, metadata.token_endpoint, code, context.code_verifier, cancel_flag, deadline) catch |err| {
        if (accepted) |*callback| callback.respond(.failed) catch {};
        return err;
    };
    errdefer secret.zeroAndFree(alloc, key);
    const scope = try alloc.dupe(u8, "");
    const token_type = try alloc.dupe(u8, "Bearer");
    context.pending_callback = accepted;
    accepted = null;
    return .{ .success = .{ .access_token = key, .expires_in = 0, .scope = scope, .token_type = token_type } };
}

const ParserContext = struct {
    expected_state: []const u8,
};

fn classifyCallback(raw: ?*anyopaque, alloc: Allocator, target: []const u8) browser_callback.ParseResult(Callback) {
    const context: *ParserContext = @ptrCast(@alignCast(raw.?));
    const callback = parseCallbackTarget(alloc, target, context.expected_state) catch |err| switch (err) {
        error.InvalidOpenRouterCallback => return .unrelated,
        else => return .{ .failed = err },
    };
    return .{ .accepted = callback };
}

fn parseCallbackTarget(alloc: Allocator, target: []const u8, expected_state: []const u8) !Callback {
    const prefix = "/callback?";
    if (!std.mem.startsWith(u8, target, prefix) or std.mem.findScalar(u8, target, '#') != null) {
        return error.InvalidOpenRouterCallback;
    }
    const query = target[prefix.len..];
    // OpenRouter omits state when the user denies access, so a denial cannot be verified;
    // at worst it ends a sign-in the user can start again.
    if (oauth.queryValueNonEmptyAlloc(alloc, query, "error")) |denial| {
        alloc.free(denial);
        return error.OpenRouterAuthorizationDenied;
    } else |_| {}
    const code = queryValue(alloc, query, "code") catch return error.InvalidOpenRouterCallback;
    errdefer secret.zeroAndFree(alloc, code);
    const state = queryValue(alloc, query, "state") catch return error.OpenRouterStateMismatch;
    defer secret.zeroAndFree(alloc, state);
    if (!std.mem.eql(u8, state, expected_state)) return error.OpenRouterStateMismatch;
    if (!validCode(code)) return error.InvalidOpenRouterCallback;
    return .{ .code = code };
}

fn queryValue(alloc: Allocator, query: []const u8, key: []const u8) ![]u8 {
    return oauth.queryValueNonEmptyAlloc(alloc, query, key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidOpenRouterCallback,
    };
}

/// Trades an authorization code for a key. Caller owns the key.
fn exchangeCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    keys_url: []const u8,
    code: []const u8,
    code_verifier: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(alloc);
    // The body carries the code and verifier.
    defer {
        @memset(body.writer.buffer, 0);
        body.deinit();
    }
    try body.writer.writeAll("{\"code\":");
    try std.json.Stringify.value(code, .{}, &body.writer);
    try body.writer.writeAll(",\"code_verifier\":");
    try std.json.Stringify.value(code_verifier, .{}, &body.writer);
    try body.writer.writeAll(",\"code_challenge_method\":\"S256\"}");
    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = keys_url,
        .payload = body.written(),
        .cancel_flag = cancel_flag,
        .deadline = deadline,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        const status = errorStatus(alloc, response.body);
        debug_trace.logf("auth", "OpenRouter key exchange rejected status={d}", .{status orelse 0});
        return switch (status orelse 0) {
            403 => error.OpenRouterCodeRejected,
            400 => error.OpenRouterChallengeMismatch,
            else => error.OpenRouterKeyExchangeFailed,
        };
    }
    return parseKeyResponse(alloc, response.body);
}

/// The `error.code` OpenRouter puts in a failure body, when it parses.
fn errorStatus(alloc: Allocator, body: []const u8) ?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const failure = parsed.value.object.get("error") orelse return null;
    if (failure != .object) return null;
    const code = failure.object.get("code") orelse return null;
    return if (code == .integer) code.integer else null;
}

fn parseKeyResponse(alloc: Allocator, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.InvalidOpenRouterKeyResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenRouterKeyResponse;
    const key = parsed.value.object.get("key") orelse return error.InvalidOpenRouterKeyResponse;
    if (key != .string or !openrouter_session.validKey(key.string)) return error.InvalidOpenRouterKeyResponse;
    return alloc.dupe(u8, key.string);
}

/// Confirms OpenRouter accepts `key` before fx keeps it.
pub fn validateKey(alloc: Allocator, transport: oauth_transport.Provider, key: []const u8) !void {
    if (!openrouter_session.validKey(key)) return error.InvalidOpenRouterKey;
    const url = try endpoints.apiUrl(alloc, "/key");
    defer alloc.free(url);
    const authorization = try alloc.print("Bearer {s}", .{key});
    defer secret.zeroAndFree(alloc, authorization);
    var response = try transport.execute(alloc, .{ .method = .get, .url = url, .authorization = authorization });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.OpenRouterKeyRejected;
}

fn completeSignIn(raw: ?*anyopaque, alloc: Allocator, _: []const u8, _: []const u8, token: *oauth.TokenSet) !login_flow.SignInCompletion {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try validateKey(alloc, context.transport, token.access_token);
    const key = token.access_token;
    token.access_token = &.{};
    return .{ .openrouter = key };
}

fn saveSignIn(_: ?*anyopaque, alloc: Allocator, completion: login_flow.SignInCompletion) !void {
    const key = switch (completion) {
        .openrouter => |key| key,
        .vercel, .chatgpt, .grok => return error.InvalidSignInCompletion,
    };
    try openrouter_session.save(alloc, key);
}

fn finishSignIn(raw: ?*anyopaque, alloc: Allocator, saved: bool) void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    context.finishCallback(alloc, saved);
}

/// The CLI sign-in. Browser mode falls back to headless when no browser
/// opens, because a callback to this machine cannot work from another one.
pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
    requested: Mode,
) !void {
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var mode = requested;
    if (!try startSignIn(&runtime, alloc, transport, mode)) return error.OpenRouterLoginBusy;
    var authorization_url = (try runtime.browserUrlAlloc(alloc)) orelse return error.OpenRouterAuthorizationUrlMissing;
    defer alloc.free(authorization_url);
    if (mode == .browser and io_mod.getenv("FX_NO_OPEN_BROWSER") == null) {
        const opened = url_opener.open(alloc, authorization_url) catch false;
        if (!opened) {
            debug_trace.logf("auth", "OpenRouter sign-in falling back to headless reason=browser_unavailable", .{});
            _ = runtime.cancel(alloc);
            _ = runtime.pollTransition(alloc);
            mode = .headless;
            if (!try startSignIn(&runtime, alloc, transport, mode)) return error.OpenRouterLoginBusy;
            alloc.free(authorization_url);
            authorization_url = (try runtime.browserUrlAlloc(alloc)) orelse return error.OpenRouterAuthorizationUrlMissing;
        }
    }
    switch (mode) {
        .browser => {
            try writeStdout("Open this URL to sign in with OpenRouter:\n");
            try writeStdout(authorization_url);
            try writeStdout("\n\nWaiting for browser authorization...\n");
        },
        .headless => {
            try writeStdout("Open this URL on any device to sign in with OpenRouter:\n");
            try writeStdout(authorization_url);
            try writeStdout("\n\nPaste the code OpenRouter shows and press enter.\n");
        },
    }

    var stdin_code: login_flow.StdinManualCodeReader = .{};
    defer stdin_code.deinit();
    while (true) {
        if (try stdin_code.poll()) |code| {
            _ = try runtime.submitManualCode(alloc, code);
            stdin_code.clear();
        }
        switch (runtime.pollTransition(alloc)) {
            .none => try io_mod.getIo().sleep(.fromMilliseconds(50), .awake),
            .succeeded => |completion| {
                var owned = completion;
                owned.deinit(alloc);
                return;
            },
            .failed => |err| return err,
            .cancelled => return error.Cancelled,
        }
    }
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

/// Validates and saves a key the user typed.
pub fn saveApiKey(alloc: Allocator, transport: oauth_transport.Provider, input: []const u8) !void {
    const key = std.mem.trim(u8, input, " \t\r\n");
    try credentials.requireSignInStorage(.openrouter_login);
    try validateKey(alloc, transport, key);
    try openrouter_session.save(alloc, key);
}

pub const LogoutResult = openrouter_session.DeleteOutcome;

/// Deletes the saved key. OpenRouter keeps the key active until it is deleted there.
pub fn logout() !LogoutResult {
    return openrouter_session.delete();
}

pub const logout_notice = "The key stays active on OpenRouter until you delete it at https://openrouter.ai/settings/keys.";

test "OpenRouter authorization URL carries PKCE, state, callback, and label" {
    const alloc = std.testing.allocator;
    const browser = try buildAuthorizationUrl(alloc, "https://openrouter.ai/auth", "http://localhost:4567/callback", "challenge", "state-1");
    defer alloc.free(browser);
    try std.testing.expectEqualStrings(
        "https://openrouter.ai/auth?callback_url=http%3A%2F%2Flocalhost%3A4567%2Fcallback&code_challenge=challenge&code_challenge_method=S256&key_label=fx&state=state-1",
        browser,
    );
    const headless = try buildAuthorizationUrl(alloc, "https://openrouter.ai/auth", null, "challenge", null);
    defer alloc.free(headless);
    try std.testing.expectEqualStrings("https://openrouter.ai/auth?code_challenge=challenge&code_challenge_method=S256&key_label=fx", headless);
}

test "OpenRouter callback requires the expected state" {
    const alloc = std.testing.allocator;
    var accepted = try parseCallbackTarget(alloc, "/callback?code=abc123&state=expected", "expected");
    defer accepted.deinit(alloc);
    try std.testing.expectEqualStrings("abc123", accepted.code);
    try std.testing.expectError(error.OpenRouterStateMismatch, parseCallbackTarget(alloc, "/callback?code=abc123&state=forged", "expected"));
    try std.testing.expectError(error.OpenRouterStateMismatch, parseCallbackTarget(alloc, "/callback?code=abc123", "expected"));
    try std.testing.expectError(error.OpenRouterAuthorizationDenied, parseCallbackTarget(alloc, "/callback?error=access_denied", "expected"));
    try std.testing.expectError(error.InvalidOpenRouterCallback, parseCallbackTarget(alloc, "/favicon.ico", "expected"));
    try std.testing.expectError(error.InvalidOpenRouterCallback, parseCallbackTarget(alloc, "/callback?state=expected", "expected"));
}

const FakeTransport = struct {
    status_ok: bool,
    body: []const u8,
    last_url: [256]u8 = undefined,
    last_url_len: usize = 0,
    last_payload: [512]u8 = undefined,
    last_payload_len: usize = 0,

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) anyerror!oauth_transport.Response {
        const self: *FakeTransport = @ptrCast(@alignCast(raw.?));
        @memcpy(self.last_url[0..request.url.len], request.url);
        self.last_url_len = request.url.len;
        const payload = request.payload orelse "";
        @memcpy(self.last_payload[0..payload.len], payload);
        self.last_payload_len = payload.len;
        return .{ .disposition = if (self.status_ok) .accepted else .rejected, .body = try alloc.dupe(u8, self.body) };
    }

    fn provider(self: *FakeTransport) oauth_transport.Provider {
        return .{ .context = self, .execute_fn = execute };
    }
};

test "OpenRouter key exchange sends the verifier and classifies rejected codes" {
    const alloc = std.testing.allocator;
    var ok: FakeTransport = .{ .status_ok = true, .body = "{\"key\":\"sk-or-v1-new\",\"user_id\":\"u\"}" };
    const key = try exchangeCode(alloc, ok.provider(), "https://openrouter.ai/api/v1/auth/keys", "code-1", "verifier-1", null, null);
    defer secret.zeroAndFree(alloc, key);
    try std.testing.expectEqualStrings("sk-or-v1-new", key);
    try std.testing.expectEqualStrings("{\"code\":\"code-1\",\"code_verifier\":\"verifier-1\",\"code_challenge_method\":\"S256\"}", ok.last_payload[0..ok.last_payload_len]);

    for ([_]struct { body: []const u8, err: anyerror }{
        .{ .body = "{\"error\":{\"code\":403,\"message\":\"Invalid code or code_verifier\"}}", .err = error.OpenRouterCodeRejected },
        .{ .body = "{\"error\":{\"code\":403,\"message\":\"Authorization code expired\"}}", .err = error.OpenRouterCodeRejected },
        .{ .body = "{\"error\":{\"code\":400,\"message\":\"Invalid code_challenge_method\"}}", .err = error.OpenRouterChallengeMismatch },
        .{ .body = "<html>gateway</html>", .err = error.OpenRouterKeyExchangeFailed },
    }) |case| {
        var rejected: FakeTransport = .{ .status_ok = false, .body = case.body };
        try std.testing.expectError(case.err, exchangeCode(alloc, rejected.provider(), "https://openrouter.ai/api/v1/auth/keys", "code-1", "verifier-1", null, null));
    }
    var malformed: FakeTransport = .{ .status_ok = true, .body = "{\"key\":\"sk or\"}" };
    try std.testing.expectError(error.InvalidOpenRouterKeyResponse, exchangeCode(alloc, malformed.provider(), "https://openrouter.ai/api/v1/auth/keys", "code-1", "verifier-1", null, null));
}

test "OpenRouter key validation checks the key endpoint" {
    const alloc = std.testing.allocator;
    var ok: FakeTransport = .{ .status_ok = true, .body = "{\"data\":{\"label\":\"fx\"}}" };
    try validateKey(alloc, ok.provider(), "sk-or-v1-valid");
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/key", ok.last_url[0..ok.last_url_len]);
    var rejected: FakeTransport = .{ .status_ok = false, .body = "{\"error\":{\"code\":401}}" };
    try std.testing.expectError(error.OpenRouterKeyRejected, validateKey(alloc, rejected.provider(), "sk-or-v1-revoked"));
    try std.testing.expectError(error.InvalidOpenRouterKey, validateKey(alloc, ok.provider(), "sk or"));
}
