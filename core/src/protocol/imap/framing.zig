//! IMAP response framing.
//!
//! A "response" is not a line: literals (`{n}\r\n<n bytes>`) can contain CRLF,
//! and a single response may contain several of them. Reading until the next
//! CRLF would split a body in half, so the framer understands literal markers
//! and only emits a response once its final CRLF has arrived.
//!
//! The buffer is fixed. A server that never terminates a response is an error,
//! not a memory growth event.

const std = @import("std");
const assert = std.debug.assert;

pub const max_response: u32 = 64 * 1024;

pub const Error = error{
    ResponseTooLong,
    InvalidLiteral,
};

/// The trailing `{n}` or `{n+}` of a line, if any.
pub fn trailing_literal_size(line: []const u8) ?u32 {
    if (line.len < 3) return null;
    if (line[line.len - 1] != '}') return null;

    var close = line.len - 1;
    const plus = line[close - 1] == '+';
    if (plus) close -= 1;

    var open = close;
    while (open > 0) : (open -= 1) {
        if (line[open - 1] == '{') break;
    }
    if (open == close) return null;
    if (line[open - 1] != '{') return null;

    const digits = line[open..close];
    if (digits.len == 0) return null;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

pub const Framer = struct {
    /// Bytes received but not yet framed.
    pending: [max_response]u8 = undefined,
    pending_len: u32 = 0,
    /// Stable copy of the response being returned, so shifting `pending` does
    /// not invalidate the slice the caller is parsing.
    response: [max_response]u8 = undefined,

    pub fn push(self: *Framer, bytes: []const u8) Error!void {
        if (bytes.len > self.pending.len - self.pending_len) return error.ResponseTooLong;
        @memcpy(self.pending[self.pending_len..][0..bytes.len], bytes);
        self.pending_len += @intCast(bytes.len);
    }

    /// Pops one complete response, CRLF included. The returned slice is valid
    /// until the next call to `next`.
    pub fn next(self: *Framer) Error!?[]const u8 {
        var search_start: u32 = 0;
        while (true) {
            const line_end = indexOfCrlf(self.pending[0..self.pending_len], search_start) orelse return null;
            const line = self.pending[search_start..line_end];

            const literal_size = trailing_literal_size(line) orelse {
                return self.take(line_end + 2);
            };
            if (literal_size > max_response) return error.InvalidLiteral;

            const payload_start = line_end + 2;
            if (literal_size > self.pending_len - payload_start) return null;

            // The response continues after the literal; look for its CRLF.
            search_start = payload_start + literal_size;
        }
    }

    fn take(self: *Framer, response_len: u32) []const u8 {
        assert(response_len <= self.pending_len);
        @memcpy(self.response[0..response_len], self.pending[0..response_len]);

        const remaining = self.pending_len - response_len;
        std.mem.copyForwards(u8, self.pending[0..remaining], self.pending[response_len..self.pending_len]);
        self.pending_len = remaining;
        return self.response[0..response_len];
    }

    pub fn is_empty(self: *const Framer) bool {
        return self.pending_len == 0;
    }
};

fn indexOfCrlf(buffer: []const u8, start: u32) ?u32 {
    var index = start;
    while (index + 1 < buffer.len) : (index += 1) {
        if (buffer[index] == '\r' and buffer[index + 1] == '\n') return index;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expect_next(framer: *Framer, expected: []const u8) !void {
    const response = (try framer.next()) orelse return error.TestExpectedResponse;
    try testing.expectEqualStrings(expected, response);
}

test "a single line is one response" {
    var framer: Framer = .{};
    try framer.push("* 3 EXISTS\r\n");
    try expect_next(&framer, "* 3 EXISTS\r\n");
    try testing.expect(try framer.next() == null);
    try testing.expect(framer.is_empty());
}

test "two lines in one push are two responses" {
    var framer: Framer = .{};
    try framer.push("* 1 EXISTS\r\na1 OK done\r\n");
    try expect_next(&framer, "* 1 EXISTS\r\n");
    try expect_next(&framer, "a1 OK done\r\n");
    try testing.expect(try framer.next() == null);
}

test "a line split across pushes waits for the rest" {
    var framer: Framer = .{};
    try framer.push("* 2 EX");
    try testing.expect(try framer.next() == null);
    try framer.push("ISTS\r\n");
    try expect_next(&framer, "* 2 EXISTS\r\n");
}

test "a literal with CRLF inside stays one response" {
    var framer: Framer = .{};
    try framer.push("* 1 FETCH (BODY[TEXT] {5}\r\nab\r\nc)\r\n");
    try expect_next(&framer, "* 1 FETCH (BODY[TEXT] {5}\r\nab\r\nc)\r\n");
}

test "a non-synchronizing literal is framed the same way" {
    var framer: Framer = .{};
    try framer.push("* 1 FETCH (BODY[] {3+}\r\nxyz)\r\n");
    try expect_next(&framer, "* 1 FETCH (BODY[] {3+}\r\nxyz)\r\n");
}

test "an incomplete literal waits for its payload" {
    var framer: Framer = .{};
    try framer.push("* 1 FETCH (BODY[] {7}\r\nshort");
    try testing.expect(try framer.next() == null);
    try framer.push("er)\r\n");
    try expect_next(&framer, "* 1 FETCH (BODY[] {7}\r\nshorter)\r\n");
}

test "multiple literals in one response are handled" {
    var framer: Framer = .{};
    const wire = "* 1 FETCH (HEADER {4}\r\na\r\nb TEXT {3}\r\ncd\r\ne)\r\n";
    try framer.push(wire);
    try expect_next(&framer, wire);
}

test "data after a literal is kept for the next response" {
    var framer: Framer = .{};
    try framer.push("* 1 FETCH (BODY[] {2}\r\nok)\r\na2 OK done\r\n");
    try expect_next(&framer, "* 1 FETCH (BODY[] {2}\r\nok)\r\n");
    try expect_next(&framer, "a2 OK done\r\n");
}

test "a full buffer that still needs bytes is an error" {
    var framer: Framer = .{};
    const chunk: [1024]u8 = @splat('x');
    var pushed: u32 = 0;
    while (pushed + chunk.len <= framer.pending.len) : (pushed += chunk.len) {
        try framer.push(&chunk);
    }
    try testing.expectError(error.ResponseTooLong, framer.push("x"));
}

test "a literal larger than the buffer is an error" {
    var framer: Framer = .{};
    var line_buffer: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buffer, "* 1 FETCH (BODY[] {{{d}}}\r\n", .{max_response + 1});
    try framer.push(line);
    try testing.expectError(error.InvalidLiteral, framer.next());
}

test "a brace group that is not a literal is part of the line" {
    var framer: Framer = .{};
    try framer.push("* 1 FETCH (X {abc})\r\n");
    try expect_next(&framer, "* 1 FETCH (X {abc})\r\n");
}

test "trailing_literal_size understands the marker shapes" {
    try testing.expectEqual(@as(?u32, 5), trailing_literal_size("a {5}"));
    try testing.expectEqual(@as(?u32, 5), trailing_literal_size("a {5+}"));
    try testing.expectEqual(@as(?u32, 0), trailing_literal_size("a {0}"));
    try testing.expect(trailing_literal_size("a {5}x") == null);
    try testing.expect(trailing_literal_size("a {}") == null);
    try testing.expect(trailing_literal_size("a {x}") == null);
    try testing.expect(trailing_literal_size("{}") == null);
    try testing.expect(trailing_literal_size("{") == null);
    try testing.expect(trailing_literal_size("{1") == null);
    try testing.expect(trailing_literal_size("ab") == null);
    try testing.expect(trailing_literal_size("x {99999999999}") == null);
}

test "an empty push leaves the framer empty" {
    var framer: Framer = .{};
    try framer.push("");
    try testing.expect(try framer.next() == null);
    try testing.expect(framer.is_empty());
}
