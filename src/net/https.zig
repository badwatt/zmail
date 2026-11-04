//! The smallest HTTPS POST that can talk to a token endpoint: one request, one
//! response, no redirects, no chunked bodies. Token endpoints answer in one
//! small JSON body, and anything bigger is refused rather than buffered.
//!
//! Process-boundary code: it owns sockets, so it is excluded from coverage and
//! exercised by the live OAuth run.

const std = @import("std");
const TlsTransport = @import("tls.zig").TlsTransport;

pub const max_response: usize = 16 * 1024;

pub const Response = struct {
    status: u16 = 0,
    body: []const u8 = "",
};

pub const Error = error{ Unavailable, TooLarge, Malformed };

/// POSTs `body` to `host`/`path` and returns the status and the body (a slice
/// of `out`).
pub fn post(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
    out: []u8,
) Error!Response {
    var tls = TlsTransport{};
    defer tls.deinit();
    tls.open(gpa, io, host, 443) catch return error.Unavailable;
    const transport = tls.transport();

    var header_buffer: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Accept: application/json\r\n" ++
        "Connection: close\r\n\r\n", .{ path, host, content_type, body.len }) catch
        return error.Malformed;

    transport.write(header) catch return error.Unavailable;
    transport.write(body) catch return error.Unavailable;

    var total: usize = 0;
    var idle: u32 = 0;
    while (total < out.len) {
        if (transport.read(out[total..], 100)) |count| {
            if (count == 0) {
                idle += 1;
                if (idle > 100) break;
                continue;
            }
            idle = 0;
            total += count;
        } else |_| break;
    }
    if (total == out.len) return error.TooLarge;
    return parse(out[0..total]);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Splits "HTTP/1.1 200 OK\r\n...\r\n\r\nbody".
///
/// Some servers write two responses on one connection -- a redirect and then the thing
/// it pointed at -- so the body can begin with another status line. That is not a
/// picture, and it is not what the server meant either: the second response is taken
/// instead, twice at most.
pub fn parse(raw: []u8) Error!Response {
    return parseDepth(raw, 0);
}

fn parseDepth(raw: []u8, depth: u8) Error!Response {
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.Malformed;
    const head = raw[0..split];
    const body = raw[split + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.Malformed;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.Malformed;
    const code = parts.next() orelse return error.Malformed;
    const status = std.fmt.parseInt(u16, code, 10) catch return error.Malformed;

    var length: ?usize = null;
    var chunked = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            chunked = containsIgnoreCase(value, "chunked");
        }
    }
    if (chunked) {
        const decoded = dechunk(body) orelse return error.Malformed;
        if (depth < 2 and std.mem.startsWith(u8, decoded, "HTTP/1.")) {
            const offset = @intFromPtr(decoded.ptr) - @intFromPtr(raw.ptr);
            return parseDepth(raw[offset..], depth + 1);
        }
        return .{ .status = status, .body = decoded };
    }
    const usable = if (length) |value| body[0..@min(value, body.len)] else body;
    if (depth < 2) {
        if (findResponseStart(usable)) |offset| {
            const base = @intFromPtr(usable.ptr) - @intFromPtr(raw.ptr);
            return parseDepth(raw[base + offset ..], depth + 1);
        }
    }
    return .{ .status = status, .body = usable };
}

/// Where the next HTTP response starts inside `body`, if it starts there at all. A
/// server that answers twice leaves one, and what comes before it is the blank line
/// that ended the first.
fn findResponseStart(body: []const u8) ?usize {
    const window = @min(body.len, 16);
    var index: usize = 0;
    while (index + 7 <= window) : (index += 1) {
        if (std.mem.startsWith(u8, body[index..], "HTTP/1.")) return index;
    }
    return null;
}

/// The payload of a `Transfer-Encoding: chunked` body, written over itself: every
/// chunk is smaller than what precedes it, so the output never overtakes the input.
pub fn dechunk(body: []u8) ?[]const u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < body.len) {
        const line_end = std.mem.indexOfPos(u8, body, read, "\r\n") orelse return null;
        const size_text = std.mem.trim(u8, body[read..line_end], " \t");
        const hex = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
        const size = std.fmt.parseInt(usize, size_text[0..hex], 16) catch return null;
        read = line_end + 2;
        if (size == 0) return body[0..write];
        if (size > body.len - read) return null;
        @memcpy(body[write..][0..size], body[read..][0..size]);
        write += size;
        read += size;
        if (read + 2 <= body.len and std.mem.eql(u8, body[read..][0..2], "\r\n")) read += 2;
    }
    return null;
}

const testing = std.testing;

test "a body that begins with another response is that response" {
    const raw_text = "HTTP/1.1 301 Moved\r\nLocation: https://x/y.png\r\nContent-Length: 0\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\n\r\n\x89PNG";
    var raw: [256]u8 = undefined;
    @memcpy(raw[0..raw_text.len], raw_text);
    const response = try parse(raw[0..raw_text.len]);
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("\x89PNG", response.body);
}

test "a chunked body is dechunked" {
    const raw_text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "4\r\n\x89PNG\r\n0\r\n\r\n";
    var raw: [256]u8 = undefined;
    @memcpy(raw[0..raw_text.len], raw_text);
    const response = try parse(raw[0..raw_text.len]);
    try testing.expectEqualStrings("\x89PNG", response.body);
}
