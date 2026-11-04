//! The browser round trip: PKCE, a local listener, and the token exchange.
//!
//! `zmail --oauth <provider>` runs this; the TUI's account form calls it through
//! the accounts port. When there is no browser, the URL is printed as a QR code
//! (via `qrencode` if installed) so a phone can scan it.

const std = @import("std");
const core = @import("core");
const https = @import("https.zig");
const Transport = @import("tls.zig").TlsTransport;

pub const Error = error{ Unavailable, Cancelled };

/// What the browser shows when the round trip worked. Built here so the length is
/// the length: it was a hand-written 36 against a 37-byte page, which is a page that
/// never finishes loading. The name comes from the manifest.
const signed_in_body = core.meta.name ++ ": signed in. Close this window.\n";
const signed_in_reply = std.fmt.comptimePrint(
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n" ++
        "Connection: close\r\n\r\n{s}",
    .{ signed_in_body.len, signed_in_body },
);

pub const Options = struct {
    provider: core.oauth.Provider = .microsoft,
    /// Microsoft tenant: `common`, `consumers`, `organizations`, or an id.
    tenant: []const u8 = "common",
    client_id: []const u8 = "",
    /// Where the provider's own refusal lands, when the caller wants it.
    problem: ?*core.text.Text(256) = null,
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

    var random: [32]u8 = undefined;
    io.random(&random);
    const pkce = core.oauth.make_pkce(random);
    var state_random: [8]u8 = undefined;
    io.random(&state_random);
    var state_buffer: [16]u8 = undefined;
    const state = std.base64.url_safe_no_pad.Encoder.encode(&state_buffer, &state_random);

    const address = std.Io.net.IpAddress.parse("127.0.0.1", 8123) catch return error.Unavailable;
    var server: ?std.Io.net.Server = address.listen(io, .{ .reuse_address = true }) catch null;
    defer if (server) |*listening| listening.deinit(io);
    var redirect_buffer: [64]u8 = undefined;
    const redirect = std.fmt.bufPrint(&redirect_buffer, "http://127.0.0.1:8123/", .{}) catch
        return error.Unavailable;

    var url_buffer: [2048]u8 = undefined;
    const url = core.oauth.auth_url(
        &url_buffer,
        options.provider,
        options.tenant,
        options.client_id,
        redirect,
        state,
        pkce.verifier_slice(),
    );
    if (url.len == 0) return error.Unavailable;

    show_url(io, options, url);
    if (server == null) {
        options.write(options.context, "\nPaste the URL your browser ended on:\n\n");
    } else {
        options.write(options.context, "\nWaiting for the browser to come back...\n\n");
    }

    var pasted: [2048]u8 = undefined;
    var code: ?[]const u8 = null;
    if (server) |*listening| {
        if (listening.accept(io)) |client| {
            var stream = client;
            defer stream.close(io);
            var buffer: [4096]u8 = undefined;
            var reader = stream.reader(io, &buffer);
            const request = reader.interface.takeDelimiterExclusive('\n') catch "";
            code = core.oauth.parse_redirect(request);
            if (core.oauth.parse_provider_error(request)) |raw| {
                var decoded: [256]u8 = undefined;
                if (options.problem) |slot| slot.set(core.oauth.url_decode(raw, &decoded));
            }
            var reply_buffer: [256]u8 = undefined;
            var writer = stream.writer(io, &reply_buffer);
            writer.interface.writeAll(signed_in_reply) catch {};
            writer.interface.flush() catch {};
        } else |_| {}
    }
    if (code == null) {
        const length = options.read(options.context, &pasted) catch return error.Unavailable;
        code = core.oauth.parse_redirect(pasted[0..length]);
    }
    const auth_code = code orelse return error.Cancelled;

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
    if (refreshed.refresh.is_empty()) refreshed.refresh = token.refresh;
    token.* = refreshed;
    return true;
}

/// Hands a URL to whatever this machine uses to open one. Best effort: a
/// terminal with no opener simply does nothing.
pub fn open_in_browser(io: std.Io, url: []const u8) void {
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
        return;
    }
}

fn show_url(io: std.Io, options: Options, url: []const u8) void {
    options.write(options.context, "\nOpen this URL to sign in:\n\n");
    options.write(options.context, url);
    options.write(options.context, "\n\n");

    open_in_browser(io, url);

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
    try std.testing.expect(!refresh(std.testing.allocator, undefined, .microsoft, "", &token));
    try std.testing.expect(!refresh(std.testing.allocator, undefined, .microsoft, "client", &token));
    token.refresh.set("refresh");
    try std.testing.expect(!refresh(std.testing.allocator, undefined, .custom, "client", &token));
}

test "the signed-in page says how long it is" {
    const header_end = std.mem.indexOf(u8, signed_in_reply, "\r\n\r\n").?;
    const body = signed_in_reply[header_end + 4 ..];
    var wanted: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&wanted, "Content-Length: {d}", .{body.len});
    try testing.expect(std.mem.indexOf(u8, signed_in_reply, line) != null);
    try testing.expect(std.mem.indexOf(u8, body, core.meta.name) != null);
}

const testing = std.testing;
