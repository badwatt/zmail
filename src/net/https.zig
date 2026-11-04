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

/// GETs `host`/`path` into `out`. Used for the pictures a message points at.
pub fn get(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    path: []const u8,
    out: []u8,
) Error!Response {
    const first = try getOnce(gpa, io, host, path, out);
    // A picture that moved: one hop, and only to https. The body of a 301 is a note
    // to the browser, not the picture, and a terminal cannot paint a note.
    if (first.status == 301 or first.status == 302 or first.status == 307 or first.status == 308) {
        const moved = location(out) orelse return first;
        var host_buffer: [256]u8 = undefined;
        var path_buffer: [1024]u8 = undefined;
        const target = splitUrl(moved, &host_buffer, &path_buffer) orelse return first;
        if (target.host.len == 0) return first;
        return getOnce(gpa, io, target.host, target.path, out);
    }
    return first;
}

/// The `Location:` header of a response, or null.
fn location(raw: []u8) ?[]const u8 {
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    var lines = std.mem.splitSequence(u8, raw[0..split], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "location")) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

const Target = struct { host: []const u8, path: []const u8 };

/// `https://host/path` into its two halves. Anything else is refused: this client
/// opens one kind of door.
fn splitUrl(url: []const u8, host_buffer: []u8, path_buffer: []u8) ?Target {
    const rest = if (std.mem.startsWith(u8, url, "https://")) url["https://".len..] else return null;
    const cut = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..cut];
    if (host.len == 0 or host.len > host_buffer.len or rest.len > 2048) return null;
    if (rest[cut..].len > path_buffer.len) return null;
    @memcpy(host_buffer[0..host.len], host);
    const path = rest[cut..];
    @memcpy(path_buffer[0..path.len], path);
    return .{ .host = host_buffer[0..host.len], .path = path_buffer[0..path.len] };
}

fn getOnce(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    path: []const u8,
    out: []u8,
) Error!Response {
    var tls = TlsTransport{};
    defer tls.deinit();
    tls.open(gpa, io, host, 443) catch return error.Unavailable;
    const transport = tls.transport();

    var header_buffer: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buffer, "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        // Identity: a gzipped picture is a picture that needs a decoder we do not
        // have. What the server has is already compressed.
        // PNG, and only PNG: a terminal paints nothing else, so a server that can
        // choose should choose the format we can actually show.
        "Accept: image/png\r\n" ++
        "Accept-Encoding: identity\r\n" ++
        "User-Agent: zmail\r\n" ++
        "Connection: close\r\n\r\n", .{ path, host }) catch return error.Malformed;

    transport.write(header) catch return error.Unavailable;

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
pub fn parse(raw: []u8) Error!Response {
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.Malformed;
    const head = raw[0..split];
    // The body is decoded in place, so `parse` takes the buffer it was given.
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
    // A chunked body carries its own framing: size lines and a last empty chunk. Cut
    // into the buffer as it is, a picture arrives with hex numbers in it -- which is
    // bytes that are not a PNG, and a reader that says "not a PNG" about a PNG.
    if (chunked) {
        const decoded = dechunk(body) orelse return error.Malformed;
        return .{ .status = status, .body = decoded };
    }
    const usable = if (length) |value| body[0..@min(value, body.len)] else body;
    return .{ .status = status, .body = usable };
}

/// The payload of a `Transfer-Encoding: chunked` body, written over itself: every
/// chunk is smaller than what precedes it, so the output never overtakes the input.
pub fn dechunk(body: []u8) ?[]const u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < body.len) {
        const line_end = std.mem.indexOfPos(u8, body, read, "\r\n") orelse return null;
        const size_text = std.mem.trim(u8, body[read..line_end], " \t");
        // Extensions after a semicolon are legal and none of our business.
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
