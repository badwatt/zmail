//! SMTP replies: `250 OK`, `250-first line` / `250 last line`, or `354 go`.

const std = @import("std");

pub const Reply = struct {
    code: u16,
    text: []const u8,
    /// True for the last line of a (possibly multi-line) reply.
    final: bool,
};

pub const Error = error{Malformed};

pub fn parse(input: []const u8) Error!Reply {
    const line = std.mem.trimEnd(u8, input, "\r\n");
    if (line.len < 3) return error.Malformed;

    const code = std.fmt.parseInt(u16, line[0..3], 10) catch return error.Malformed;
    if (code < 100 or code > 599) return error.Malformed;
    if (line.len == 3) return .{ .code = code, .text = "", .final = true };

    return switch (line[3]) {
        ' ' => .{ .code = code, .text = line[4..], .final = true },
        '-' => .{ .code = code, .text = line[4..], .final = false },
        else => error.Malformed,
    };
}

const testing = std.testing;

test "a single-line reply" {
    const reply = try parse("250 OK queued\r\n");
    try testing.expectEqual(@as(u16, 250), reply.code);
    try testing.expectEqualStrings("OK queued", reply.text);
    try testing.expect(reply.final);
}

test "multi-line replies continue until the space form" {
    const first = try parse("250-mail.example.com\r\n");
    try testing.expect(!first.final);
    try testing.expectEqualStrings("mail.example.com", first.text);

    const last = try parse("250 HELP");
    try testing.expect(last.final);
}

test "a reply with no text is valid" {
    const reply = try parse("220");
    try testing.expectEqual(@as(u16, 220), reply.code);
    try testing.expectEqualStrings("", reply.text);
    try testing.expect(reply.final);
}

test "malformed replies are refused" {
    try testing.expectError(error.Malformed, parse(""));
    try testing.expectError(error.Malformed, parse("22"));
    try testing.expectError(error.Malformed, parse("abc OK"));
    try testing.expectError(error.Malformed, parse("999 too big"));
    try testing.expectError(error.Malformed, parse("250xweird"));
}
