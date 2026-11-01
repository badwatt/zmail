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

/// Splits "HTTP/1.1 200 OK\r\n...\r\n\r\nbody".
pub fn parse(raw: []const u8) Error!Response {
    const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.Malformed;
    const head = raw[0..split];
    const body = raw[split + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.Malformed;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.Malformed;
    const code = parts.next() orelse return error.Malformed;
    const status = std.fmt.parseInt(u16, code, 10) catch return error.Malformed;

    // Content-Length is enough for a token endpoint; chunked is refused.
    var length: ?usize = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            length = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch null;
        }
    }
    const usable = if (length) |value| body[0..@min(value, body.len)] else body;
    return .{ .status = status, .body = usable };
}
