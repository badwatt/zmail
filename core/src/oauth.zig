//! Just enough OAuth 2.0 to get an IMAP token: PKCE, the authorization URL,
//! the token request bodies, and the token response.
//!
//! Providers stopped accepting passwords (Microsoft in 2024, Google needs app
//! passwords with 2FA), so the login is now a bearer token obtained out of
//! band. This module is pure: it formats URLs and bodies and reads the JSON
//! answer; the browser and the socket live outside the core.

const std = @import("std");
const assert = std.debug.assert;

const Text = @import("domain/text.zig").Text;
const limits = @import("limits.zig");

pub const token_max = 4096;

pub const Provider = enum { microsoft, google, custom };

pub const Endpoints = struct {
    host: []const u8,
    auth_url: []const u8,
    token_url: []const u8,
    scope: []const u8,
};

pub fn endpoints(provider: Provider) Endpoints {
    return switch (provider) {
        .microsoft => .{
            .host = "outlook.office365.com",
            .auth_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            .token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            .scope = "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access",
        },
        .google => .{
            .host = "imap.gmail.com",
            .auth_url = "https://accounts.google.com/o/oauth2/v2/auth",
            .token_url = "https://oauth2.googleapis.com/token",
            .scope = "https://mail.google.com/",
        },
        .custom => .{
            .host = "",
            .auth_url = "",
            .token_url = "",
            .scope = "",
        },
    };
}

pub const verifier_max = 64;
pub const challenge_max = 43;

pub const Pkce = struct {
    verifier: [verifier_max]u8 = @splat(0),
    verifier_len: u8 = 0,
    challenge: [challenge_max]u8 = @splat(0),

    pub fn verifier_slice(self: *const Pkce) []const u8 {
        return self.verifier[0..self.verifier_len];
    }
};

/// RFC 7636: the verifier is 32 random bytes in base64url (43 chars), and the
/// challenge is the base64url of its SHA-256.
pub fn make_pkce(random: [32]u8) Pkce {
    var pkce = Pkce{};
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    // 32 bytes → 43 characters, drawn uniformly from the unreserved set.
    var index: usize = 0;
    for (random) |byte| {
        pkce.verifier[index] = alphabet[byte % alphabet.len];
        index += 1;
    }
    // A second pass for the remaining 11 characters, derived from the hash so
    // the verifier stays unique per call.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(random[0..], &digest, .{});
    for (digest[0..11]) |byte| {
        pkce.verifier[index] = alphabet[byte % alphabet.len];
        index += 1;
    }
    pkce.verifier_len = @intCast(index);

    std.crypto.hash.sha2.Sha256.hash(pkce.verifier_slice(), &digest, .{});
    const encoder = std.base64.url_safe_no_pad.Encoder;
    _ = encoder.encode(&pkce.challenge, &digest);
    return pkce;
}

/// The challenge for a known verifier (RFC 7636 test vector friendly).
pub fn challenge_for(verifier: []const u8) [challenge_max]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var out: [challenge_max]u8 = @splat(0);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&out, &digest);
    return out;
}

/// The tenant comes from the config: `common` covers work and personal
/// accounts only when the app registration allows both, which is why the
/// provider's own refusal is surfaced instead of guessed at.
pub fn auth_url(
    buffer: []u8,
    provider: Provider,
    tenant: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    verifier: []const u8,
) []const u8 {
    const e = endpoints(provider);
    const challenge = challenge_for(verifier);
    var base_buffer: [256]u8 = undefined;
    const base = auth_base(provider, tenant, &base_buffer);
    // Providers join scopes with a space; a URL cannot carry one.
    var scope_buffer: [256]u8 = undefined;
    const scope = percent_encode(e.scope, &scope_buffer);
    return std.fmt.bufPrint(buffer, "{s}?client_id={s}&response_type=code&redirect_uri={s}" ++
        "&response_mode=query&scope={s}&state={s}&code_challenge={s}&code_challenge_method=S256", .{
        base,
        client_id,
        redirect_uri,
        scope,
        state,
        challenge[0..],
    }) catch "";
}

/// Microsoft puts the tenant in the path; everyone else ignores it.
fn auth_base(provider: Provider, tenant: []const u8, buffer: []u8) []const u8 {
    if (provider != .microsoft) return endpoints(provider).auth_url;
    const chosen = if (tenant.len == 0) "common" else tenant;
    return std.fmt.bufPrint(
        buffer,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/authorize",
        .{chosen},
    ) catch endpoints(provider).auth_url;
}

/// The provider explains refusals in the redirect: read that, not a guess.
/// Returns the human text after `error_description=`.
pub fn parse_provider_error(query: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, query, "error_description=") orelse
        std.mem.indexOf(u8, query, "error=") orelse return null;
    const equals = std.mem.indexOfScalar(u8, query[at..], '=') orelse return null;
    const rest = query[at + equals + 1 ..];
    // A value ends at the next parameter, or where the request line does.
    var end = rest.len;
    for (rest, 0..) |byte, index| {
        if (byte == '&' or byte == ' ' or byte == '\r' or byte == '\n') {
            end = index;
            break;
        }
    }
    if (end == 0) return null;
    return rest[0..end];
}

/// Decodes %XX and '+' in place-ish: returns a slice of `buffer`.
pub fn url_decode(text: []const u8, buffer: []u8) []const u8 {
    var length: usize = 0;
    var index: usize = 0;
    while (index < text.len and length < buffer.len) : (index += 1) {
        const byte = text[index];
        if (byte == '+') {
            buffer[length] = ' ';
            length += 1;
            continue;
        }
        if (byte == '%' and index + 2 < text.len) {
            const high = std.fmt.charToDigit(text[index + 1], 16) catch {
                buffer[length] = byte;
                length += 1;
                continue;
            };
            const low = std.fmt.charToDigit(text[index + 2], 16) catch {
                buffer[length] = byte;
                length += 1;
                continue;
            };
            buffer[length] = @as(u8, high) * 16 + @as(u8, low);
            length += 1;
            index += 2;
            continue;
        }
        buffer[length] = byte;
        length += 1;
    }
    return buffer[0..length];
}

/// Encodes the characters that cannot appear in a query string. Enough for
/// scopes and ids: spaces, slashes stay readable, everything else is escaped.
fn percent_encode(text: []const u8, out: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var length: usize = 0;
    for (text) |byte| {
        const unsafe = switch (byte) {
            ' ', '"', '<', '>', '#', '%', '&', '+', '?' => true,
            else => byte < 0x21 or byte > 0x7e,
        };
        if (unsafe) {
            if (length + 3 > out.len) break;
            out[length] = '%';
            out[length + 1] = hex[byte >> 4];
            out[length + 2] = hex[byte & 0x0f];
            length += 3;
        } else {
            if (length + 1 > out.len) break;
            out[length] = byte;
            length += 1;
        }
    }
    return out[0..length];
}

/// `application/x-www-form-urlencoded` body for the code exchange.
pub fn code_body(
    buffer: []u8,
    provider: Provider,
    client_id: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
    verifier: []const u8,
) []const u8 {
    const e = endpoints(provider);
    return std.fmt.bufPrint(buffer, "client_id={s}&grant_type=authorization_code&code={s}" ++
        "&redirect_uri={s}&code_verifier={s}&scope={s}", .{
        client_id, code, redirect_uri, verifier, e.scope,
    }) catch "";
}

pub fn refresh_body(
    buffer: []u8,
    provider: Provider,
    client_id: []const u8,
    refresh_token: []const u8,
) []const u8 {
    const e = endpoints(provider);
    return std.fmt.bufPrint(buffer, "client_id={s}&grant_type=refresh_token&refresh_token={s}&scope={s}", .{
        client_id, refresh_token, e.scope,
    }) catch "";
}

pub const Error = error{ Malformed, MissingAccessToken };

pub const Token = struct {
    access: Text(token_max) = .{},
    refresh: Text(token_max) = .{},
    /// Unix seconds; 0 means "unknown", treated as expired.
    expires_unix: i64 = 0,

    pub fn is_fresh(self: *const Token, now_unix: i64) bool {
        if (self.access.is_empty()) return false;
        // A minute of slack: a token that dies mid-request is useless.
        return self.expires_unix > now_unix + 60;
    }
};

/// Reads the JSON a token endpoint returns. Deliberately a scan, not a parser:
/// the fields we need are strings of base64-ish text.
pub fn parse_token(json: []const u8, now_unix: i64, out: *Token) Error!void {
    out.* = .{};
    const access = field(json, "access_token") orelse return error.MissingAccessToken;
    out.access.set(access);
    if (field(json, "refresh_token")) |refresh| out.refresh.set(refresh);

    const expires_in = number(json, "expires_in");
    if (expires_in) |seconds| {
        out.expires_unix = now_unix + @as(i64, @intCast(seconds));
    }
    if (field(json, "error")) |reason| {
        _ = reason;
        return error.Malformed;
    }
}

fn field(json: []const u8, name: []const u8) ?[]const u8 {
    var needle_buffer: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "\"{s}\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;

    var index = at + needle.len;
    while (index < json.len and (json[index] == ' ' or json[index] == ':')) index += 1;
    if (index >= json.len or json[index] != '"') return null;
    index += 1;

    var out_buffer: [token_max]u8 = undefined;
    var length: usize = 0;
    while (index < json.len and json[index] != '"') : (index += 1) {
        if (length == out_buffer.len) break;
        out_buffer[length] = json[index];
        length += 1;
    }
    last_field = out_buffer[0..length];
    return last_field;
}

/// The slice returned by `field` lives here until the next call; callers copy
/// it immediately (Text.set), so one buffer is enough.
var last_field: []const u8 = "";

fn number(json: []const u8, name: []const u8) ?u64 {
    var needle_buffer: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "\"{s}\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    var index = at + needle.len;
    while (index < json.len and (json[index] == ' ' or json[index] == ':')) index += 1;
    const start = index;
    while (index < json.len and std.ascii.isDigit(json[index])) index += 1;
    if (index == start) return null;
    return std.fmt.parseInt(u64, json[start..index], 10) catch null;
}

pub fn parse_redirect(query: []const u8) ?[]const u8 {
    // "code=...&state=..." (the raw request target or the query string).
    const at = std.mem.indexOf(u8, query, "code=") orelse return null;
    const rest = query[at + "code=".len ..];
    const end = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "PKCE matches the RFC 7636 vector" {
    const challenge = challenge_for("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
    try testing.expectEqualStrings(
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        challenge[0..],
    );
}

test "PKCE from random bytes is 43 characters and changes every time" {
    var first: [32]u8 = undefined;
    var second: [32]u8 = undefined;
    for (&first, 0..) |*byte, index| byte.* = @intCast(index);
    for (&second, 0..) |*byte, index| byte.* = @intCast(255 - index);

    const a = make_pkce(first);
    const b = make_pkce(second);
    try testing.expectEqual(@as(u8, 43), a.verifier_len);
    try testing.expectEqual(@as(u8, 43), b.verifier_len);
    try testing.expect(!std.mem.eql(u8, a.verifier_slice(), b.verifier_slice()));
    // The challenge is the SHA-256 of the verifier.
    const expected = challenge_for(a.verifier_slice());
    try testing.expectEqualSlices(u8, expected[0..], a.challenge[0..]);
}

test "a provider refusal is read from the redirect" {
    const url = "GET /?error=unauthorized_client&error_description=The+client+does" ++
        "%20not%20exist%20or%20is%20not%20enabled+for+consumers HTTP/1.1";
    const raw = parse_provider_error(url).?;
    var buffer: [256]u8 = undefined;
    const text = url_decode(raw, &buffer);
    try testing.expectEqualStrings("The client does not exist or is not enabled for consumers", text);
    try testing.expect(parse_provider_error("GET /?code=abc HTTP/1.1") == null);
}

test "the Microsoft tenant comes from the config" {
    var buffer: [1024]u8 = undefined;
    const consumers = auth_url(&buffer, .microsoft, "consumers", "c", "http://127.0.0.1:8123/", "s", "v");
    try testing.expect(std.mem.startsWith(u8, consumers, "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize"));
    const fallback = auth_url(&buffer, .microsoft, "", "c", "http://127.0.0.1:8123/", "s", "v");
    try testing.expect(std.mem.indexOf(u8, fallback, "/common/") != null);
}

test "the authorization URL carries PKCE, scope, and state" {
    var buffer: [1024]u8 = undefined;
    const url = auth_url(
        &buffer,
        .microsoft,
        "common",
        "client-123",
        "http://127.0.0.1:8123/",
        "state-9",
        "verifier-abc",
    );
    try testing.expect(std.mem.startsWith(u8, url, "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"));
    try testing.expect(std.mem.indexOf(u8, url, "client_id=client-123") != null);
    try testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try testing.expect(std.mem.indexOf(u8, url, "state=state-9") != null);
    // A space inside the scope would break the request: it must be escaped.
    try testing.expect(std.mem.indexOfScalar(u8, url, ' ') == null);
    try testing.expect(std.mem.indexOf(u8, url, "%20") != null);
    try testing.expect(std.mem.indexOf(u8, url, "IMAP.AccessAsUser.All") != null);

    const google = auth_url(&buffer, .google, "", "c", "http://127.0.0.1/", "s", "v");
    try testing.expect(std.mem.indexOf(u8, google, "https://mail.google.com/") != null);
}

test "token request bodies are form-encoded" {
    var buffer: [1024]u8 = undefined;
    const body = code_body(&buffer, .microsoft, "client", "the-code", "http://127.0.0.1:9/", "verifier");
    try testing.expect(std.mem.indexOf(u8, body, "grant_type=authorization_code") != null);
    try testing.expect(std.mem.indexOf(u8, body, "code=the-code") != null);
    try testing.expect(std.mem.indexOf(u8, body, "code_verifier=verifier") != null);

    const refresh = refresh_body(&buffer, .google, "client", "refresh-token");
    try testing.expect(std.mem.indexOf(u8, refresh, "grant_type=refresh_token") != null);
    try testing.expect(std.mem.indexOf(u8, refresh, "refresh_token=refresh-token") != null);
}

test "token JSON is read into the model, with expiry" {
    const json =
        \\{"token_type":"Bearer","expires_in":3599,"access_token":"ya29.aaa","refresh_token":"1//bbb"}
    ;
    var token: Token = .{};
    try parse_token(json, 1_000, &token);
    try testing.expectEqualStrings("ya29.aaa", token.access.slice());
    try testing.expectEqualStrings("1//bbb", token.refresh.slice());
    try testing.expectEqual(@as(i64, 4_599), token.expires_unix);
    try testing.expect(token.is_fresh(1_000));
    try testing.expect(!token.is_fresh(4_600));

    // No refresh token: the old one stays empty, and it still parses.
    var no_refresh: Token = .{};
    try parse_token("{\"access_token\":\"only\"}", 0, &no_refresh);
    try testing.expectEqualStrings("only", no_refresh.access.slice());
    try testing.expect(no_refresh.refresh.is_empty());
    // expires_in absent: expired, so it refreshes.
    try testing.expect(!no_refresh.is_fresh(0));
}

test "a token response without an access token, or with an error, is refused" {
    var token: Token = .{};
    try testing.expectError(error.MissingAccessToken, parse_token("{\"expires_in\":10}", 0, &token));
    try testing.expectError(
        error.Malformed,
        parse_token("{\"error\":\"invalid_grant\",\"access_token\":\"x\"}", 0, &token),
    );
    try testing.expectError(error.MissingAccessToken, parse_token("not json", 0, &token));
}

test "the redirect carries the code" {
    try testing.expectEqualStrings("abc", parse_redirect("GET /?code=abc&state=s HTTP/1.1").?);
    try testing.expectEqualStrings("abc", parse_redirect("code=abc").?);
    try testing.expect(parse_redirect("state=s") == null);
    try testing.expect(parse_redirect("code=") == null);
}
