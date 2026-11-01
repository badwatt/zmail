//! The browser round trip: PKCE, a local listener, and the token exchange.
//!
//! `amail --oauth <provider>` runs this; the TUI's account form calls it through
//! the accounts port. When there is no browser, the URL is printed as a QR code
//! (via `qrencode` if installed) so a phone can scan it.

const std = @import("std");
const core = @import("core");
const https = @import("https.zig");
const Transport = @import("tls.zig").TlsTransport;

pub const Error = error{ Unavailable, Cancelled };

pub const Options = struct {
    provider: core.oauth.Provider = .microsoft,
    client_id: []const u8 = "",
    /// Where to print the URL/QR (the terminal).
    write: *const fn (context: *anyopaque, bytes: []const u8) void = noop,
    /// Reads one line (the pasted redirect URL).
    read: *const fn (context: *anyopaque, out: []u8) Error!usize = read_none,
    context: *anyopaque = undefined,
};

fn noop(_: *anyopaque, _: []const u8) void {}

fn read_none(_: *anyopaque, _: []u8) Error!usize {
    return error.Unavailable;
}

/// Runs the flow and returns a token. Blocking: the user is in the browser.
pub fn run(gpa: std.mem.Allocator, io: std.Io, options: Options, out: *core.oauth.Token) Error!void {
    if (options.client_id.len == 0) return error.Unavailable;

    // 1. PKCE and a fixed loopback redirect. No listener: the provider sends
    // the browser to 127.0.0.1, which fails to load, and the user pastes that
    // URL back. It works headless, over SSH, and from a phone via the QR.
    var random: [32]u8 = undefined;
    io.random(&random);
    const pkce = core.oauth.make_pkce(random);
    var state_random: [8]u8 = undefined;
    io.random(&state_random);
    var state_buffer: [16]u8 = undefined;
    // Use the encoder's slice, not the whole array: the rest is uninitialised.
    const state = std.base64.url_safe_no_pad.Encoder.encode(&state_buffer, &state_random);

    // No listener: this Zig's network streams cannot be read here yet, so the
    // redirect is pasted back. Headless and phone (QR) friendly.
    var redirect_buffer: [64]u8 = undefined;
    const redirect = std.fmt.bufPrint(&redirect_buffer, "http://127.0.0.1:8123/", .{}) catch
        return error.Unavailable;

    var url_buffer: [2048]u8 = undefined;
    const url = core.oauth.auth_url(
        &url_buffer,
        options.provider,
        options.client_id,
        redirect,
        state,
        pkce.verifier_slice(),
    );
    if (url.len == 0) return error.Unavailable;

    // 2. Show it: browser if there is one, QR for a headless terminal.
    show_url(io, options, url);
    options.write(options.context, "\nFinish in the browser; if nothing happens, paste the URL here:\n\n");

    // 3. Read the pasted URL.
    var pasted: [2048]u8 = undefined;
    const length = options.read(options.context, &pasted) catch return error.Unavailable;
    const auth_code = core.oauth.parse_redirect(pasted[0..length]) orelse return error.Cancelled;

    // 5. Exchange the code for a token.
    var body_buffer: [2048]u8 = undefined;
    const body = core.oauth.code_body(&body_buffer, options.provider, options.client_id, auth_code, redirect, pkce.verifier_slice());
    var response_buffer: [https.max_response]u8 = undefined;

    const e = core.oauth.endpoints(options.provider);
    const host = host_of(e.token_url);
    const path = path_of(e.token_url);
    const response = https.post(gpa, io, host, path, "application/x-www-form-urlencoded", body, &response_buffer) catch
        return error.Unavailable;
    if (response.status != 200) return error.Unavailable;

    core.oauth.parse_token(response.body, now(io), out) catch return error.Unavailable;
}

/// Exchanges a refresh token for a fresh access token, in place. No browser,
/// no prompt: this runs on a normal refresh when the stored token expired.
pub fn refresh(
    gpa: std.mem.Allocator,
    io: std.Io,
    provider: core.oauth.Provider,
    client_id: []const u8,
    token: *core.oauth.Token,
) bool {
    if (client_id.len == 0 or token.refresh.is_empty()) return false;

    var body_buffer: [1024]u8 = undefined;
    const body = core.oauth.refresh_body(&body_buffer, provider, client_id, token.refresh.slice());
    if (body.len == 0) return false;

    const endpoint = core.oauth.endpoints(provider).token_url;
    if (endpoint.len == 0) return false;

    var response_buffer: [8192]u8 = undefined;
    const response = https.post(
        gpa,
        io,
        host_of(endpoint),
        path_of(endpoint),
        "application/x-www-form-urlencoded",
        body,
        &response_buffer,
    ) catch return false;

    if (response.status != 200) return false;
    var refreshed: core.oauth.Token = .{};
    core.oauth.parse_token(response.body, now(io), &refreshed) catch return false;
    // Providers often omit the refresh token on refresh: keep the old one.
    if (refreshed.refresh.is_empty()) refreshed.refresh = token.refresh;
    token.* = refreshed;
    return true;
}

fn show_url(io: std.Io, options: Options, url: []const u8) void {
    // The URL always goes out first: it is the only thing that works
    // everywhere, and a browser that fails to open must not hide it.
    options.write(options.context, "\nOpen this URL to sign in:\n\n");
    options.write(options.context, url);
    options.write(options.context, "\n\n");

    // Then try to save the copying: whatever opener this machine has.
    const openers = [_][]const []const u8{
        &.{ "xdg-open", url },
        &.{ "gio", "open", url },
        &.{ "sensible-browser", url },
        &.{ "open", url },
        &.{ "wslview", url },
    };
    for (openers) |argv| {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        _ = child.wait(io) catch null;
        break;
    }

    // QR fallback: `qrencode` printing to the terminal.
    var qr = std.process.spawn(io, .{
        .argv = &.{ "qrencode", "-t", "ansiutf8", "-o", "-", url },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch null;
    if (qr) |*process| {
        if (process.stdout) |stdout| {
            var buffer: [4096]u8 = undefined;
            const read = stdout.readPositionalAll(io, &buffer, 0) catch 0;
            if (read > 0) options.write(options.context, buffer[0..read]);
        }
        _ = process.wait(io) catch null;
    }
}

fn host_of(url: []const u8) []const u8 {
    const scheme = "https://";
    const start = if (std.mem.startsWith(u8, url, scheme)) scheme.len else 0;
    const rest = url[start..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return rest[0..end];
}

fn path_of(url: []const u8) []const u8 {
    const scheme = "https://";
    const start = if (std.mem.startsWith(u8, url, scheme)) scheme.len else 0;
    const rest = url[start..];
    const at = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
    return rest[at..];
}

fn now(io: std.Io) i64 {
    const stamp = std.Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(stamp.nanoseconds, std.time.ns_per_s));
}

test "a refresh needs a client id and a refresh token" {
    var token: core.oauth.Token = .{};
    token.access.set("old");
    // No client id: nothing to send.
    try std.testing.expect(!refresh(std.testing.allocator, undefined, .microsoft, "", &token));
    // A client id but no refresh token: nothing to exchange.
    try std.testing.expect(!refresh(std.testing.allocator, undefined, .microsoft, "client", &token));
    // A custom provider has no endpoint: refused before any I/O.
    token.refresh.set("refresh");
    try std.testing.expect(!refresh(std.testing.allocator, undefined, .custom, "client", &token));
}
