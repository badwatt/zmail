//! IMAP commands, rendered into a caller-provided buffer.
//!
//! Every command is built through `Render`, which collects the first problem
//! instead of plumbing errors through every line. The result is either a
//! complete command ending in CRLF or an error and no command at all — never a
//! half-written line on the wire.
//!
//! User-supplied values (mailbox names, the search query, the password) are
//! always written as quoted strings with escapes, and control characters are
//! refused: a mailbox name cannot inject a second command.

const std = @import("std");
const assert = std.debug.assert;

const Flags = @import("../../domain/message.zig").Flags;

pub const Error = error{
    NoSpaceLeft,
    InvalidTag,
    InvalidAstring,
    InvalidRange,
    InvalidNumber,
};

const Render = struct {
    writer: std.Io.Writer,
    problem: ?Error = null,

    fn fail(self: *Render, err: Error) void {
        if (self.problem == null) self.problem = err;
    }

    fn text(self: *Render, bytes: []const u8) void {
        self.writer.writeAll(bytes) catch self.fail(error.NoSpaceLeft);
    }

    fn byte(self: *Render, value: u8) void {
        self.writer.writeByte(value) catch self.fail(error.NoSpaceLeft);
    }

    fn number(self: *Render, value: u64) void {
        self.writer.print("{d}", .{value}) catch self.fail(error.NoSpaceLeft);
    }

    /// IMAP astring: a quoted string. Backslashes and quotes are escaped;
    /// control characters are impossible because CRLF ends a command.
    fn astring(self: *Render, bytes: []const u8) void {
        for (bytes) |value| {
            if (value < 0x20 or value == 0x7f) {
                self.fail(error.InvalidAstring);
                return;
            }
        }
        self.byte('"');
        for (bytes) |value| {
            if (value == '"' or value == '\\') self.byte('\\');
            self.byte(value);
        }
        self.byte('"');
    }

    fn tag(self: *Render, bytes: []const u8) void {
        if (bytes.len == 0) {
            self.fail(error.InvalidTag);
            return;
        }
        for (bytes) |value| {
            if (value <= 0x20 or value >= 0x7f) {
                self.fail(error.InvalidTag);
                return;
            }
            switch (value) {
                '(', ')', '{', '"', '%', '*' => {
                    self.fail(error.InvalidTag);
                    return;
                },
                else => {},
            }
        }
        self.text(bytes);
    }

    /// CRLF, then either the command or the first problem.
    fn finish(self: *Render) Error![]const u8 {
        self.text("\r\n");
        if (self.problem) |problem| return problem;
        return self.writer.buffered();
    }

    fn begin(buffer: []u8, tag_text: []const u8, verb: []const u8) Render {
        var render = Render{ .writer = std.Io.Writer.fixed(buffer) };
        render.tag(tag_text);
        render.byte(' ');
        render.text(verb);
        return render;
    }
};

pub fn login(buffer: []u8, tag: []const u8, user: []const u8, password: []const u8) Error![]const u8 {
    var render = Render.begin(buffer, tag, "LOGIN ");
    render.astring(user);
    render.byte(' ');
    render.astring(password);
    return render.finish();
}

/// Every mailbox on the server, with its SPECIAL-USE flags when supported.
pub fn list(buffer: []u8, tag: []const u8) Error![]const u8 {
    var render = Render.begin(buffer, tag, "LIST \"\" \"*\"");
    return render.finish();
}

pub fn select(buffer: []u8, tag: []const u8, mailbox: []const u8) Error![]const u8 {
    var render = Render.begin(buffer, tag, "SELECT ");
    render.astring(mailbox);
    return render.finish();
}

/// Envelopes only: UID, flags, date, and size. Bodies are fetched on demand.
pub fn fetch_envelopes(buffer: []u8, tag: []const u8, first_sequence: u32, last_sequence: u32) Error![]const u8 {
    if (first_sequence == 0) return error.InvalidRange;
    if (last_sequence < first_sequence) return error.InvalidRange;

    var render = Render.begin(buffer, tag, "FETCH ");
    render.number(first_sequence);
    render.byte(':');
    render.number(last_sequence);
    render.text(" (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)");
    return render.finish();
}

pub fn fetch_body(buffer: []u8, tag: []const u8, uid: u32) Error![]const u8 {
    if (uid == 0) return error.InvalidNumber;

    var render = Render.begin(buffer, tag, "UID FETCH ");
    render.number(uid);
    render.text(" (BODY.PEEK[])");
    return render.finish();
}

/// Replaces the server's flag set with ours, so local and remote agree.
pub fn store_flags(buffer: []u8, tag: []const u8, uid: u32, flags: Flags) Error![]const u8 {
    if (uid == 0) return error.InvalidNumber;

    var render = Render.begin(buffer, tag, "UID STORE ");
    render.number(uid);
    render.text(" FLAGS.SILENT (");
    var first = true;
    if (!flags.unread) {
        render.text("\\Seen");
        first = false;
    }
    if (flags.flagged) {
        if (!first) render.byte(' ');
        render.text("\\Flagged");
    }
    render.byte(')');
    return render.finish();
}

/// Flags one message as deleted (the expunge follows).
pub fn delete_forever(buffer: []u8, tag: []const u8, uid: u32) Error![]const u8 {
    if (uid == 0) return error.InvalidNumber;
    var render = Render.begin(buffer, tag, "UID STORE ");
    render.number(uid);
    render.text(" +FLAGS.SILENT (\\Deleted)");
    return render.finish();
}

/// Flags every message in the selected mailbox as deleted.
pub fn delete_all(buffer: []u8, tag: []const u8) Error![]const u8 {
    var render = Render.begin(buffer, tag, "STORE 1:* +FLAGS.SILENT (\\Deleted)");
    return render.finish();
}

pub fn expunge_uid(buffer: []u8, tag: []const u8, uid: u32) Error![]const u8 {
    if (uid == 0) return error.InvalidNumber;
    var render = Render.begin(buffer, tag, "UID EXPUNGE ");
    render.number(uid);
    return render.finish();
}

pub fn expunge(buffer: []u8, tag: []const u8) Error![]const u8 {
    var render = Render.begin(buffer, tag, "EXPUNGE");
    return render.finish();
}

pub fn move_message(buffer: []u8, tag: []const u8, uid: u32, mailbox: []const u8) Error![]const u8 {
    if (uid == 0) return error.InvalidNumber;

    var render = Render.begin(buffer, tag, "UID MOVE ");
    render.number(uid);
    render.byte(' ');
    render.astring(mailbox);
    return render.finish();
}

pub fn search(buffer: []u8, tag: []const u8, query: []const u8) Error![]const u8 {
    var render = Render.begin(buffer, tag, "UID SEARCH SUBJECT ");
    render.astring(query);
    return render.finish();
}

pub fn capability(buffer: []u8, tag: []const u8) Error![]const u8 {
    var render = Render.begin(buffer, tag, "CAPABILITY");
    return render.finish();
}

pub fn noop(buffer: []u8, tag: []const u8) Error![]const u8 {
    var render = Render.begin(buffer, tag, "NOOP");
    return render.finish();
}

pub fn logout(buffer: []u8, tag: []const u8) Error![]const u8 {
    var render = Render.begin(buffer, tag, "LOGOUT");
    return render.finish();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expect_command(expected: []const u8, actual: Error![]const u8) !void {
    try testing.expectEqualStrings(expected, try actual);
}

test "login quotes both strings and escapes them" {
    var buffer: [256]u8 = undefined;
    try expect_command(
        "a1 LOGIN \"me@example.com\" \"pa\\\"ss\\\\word\"\r\n",
        login(&buffer, "a1", "me@example.com", "pa\"ss\\word"),
    );
}

test "select quotes the mailbox" {
    var buffer: [128]u8 = undefined;
    try expect_command("a2 SELECT \"Archive 2023\"\r\n", select(&buffer, "a2", "Archive 2023"));
}

test "fetch_envelopes asks only for envelope attributes" {
    var buffer: [128]u8 = undefined;
    try expect_command(
        "a3 FETCH 1:50 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)\r\n",
        fetch_envelopes(&buffer, "a3", 1, 50),
    );
}

test "fetch_envelopes rejects impossible ranges" {
    var buffer: [128]u8 = undefined;
    try testing.expectError(error.InvalidRange, fetch_envelopes(&buffer, "a3", 0, 10));
    try testing.expectError(error.InvalidRange, fetch_envelopes(&buffer, "a3", 10, 9));
}

test "fetch_body uses UID and peeks so it does not mark the message read" {
    var buffer: [128]u8 = undefined;
    try expect_command("a4 UID FETCH 42 (BODY.PEEK[])\r\n", fetch_body(&buffer, "a4", 42));
}

test "fetch_body rejects uid zero" {
    var buffer: [128]u8 = undefined;
    try testing.expectError(error.InvalidNumber, fetch_body(&buffer, "a4", 0));
}

test "store_flags writes the whole set: seen and flagged" {
    var buffer: [128]u8 = undefined;
    try expect_command(
        "a5 UID STORE 7 FLAGS.SILENT (\\Seen \\Flagged)\r\n",
        store_flags(&buffer, "a5", 7, .{ .unread = false, .flagged = true }),
    );
}

test "store_flags writes an empty set for a fresh unread message" {
    var buffer: [128]u8 = undefined;
    try expect_command(
        "a5 UID STORE 7 FLAGS.SILENT ()\r\n",
        store_flags(&buffer, "a5", 7, .{ .unread = true, .flagged = false }),
    );
}

test "store_flags writes flagged alone" {
    var buffer: [128]u8 = undefined;
    try expect_command(
        "a5 UID STORE 7 FLAGS.SILENT (\\Flagged)\r\n",
        store_flags(&buffer, "a5", 7, .{ .unread = true, .flagged = true }),
    );
}

test "store_flags writes seen alone" {
    var buffer: [128]u8 = undefined;
    try expect_command(
        "a5 UID STORE 7 FLAGS.SILENT (\\Seen)\r\n",
        store_flags(&buffer, "a5", 7, .{ .unread = false, .flagged = false }),
    );
}

test "move_message quotes the destination" {
    var buffer: [128]u8 = undefined;
    try expect_command("a6 UID MOVE 9 \"Trash\"\r\n", move_message(&buffer, "a6", 9, "Trash"));
}

test "search quotes the query" {
    var buffer: [128]u8 = undefined;
    try expect_command(
        "a7 UID SEARCH SUBJECT \"invoice \\\"october\\\"\"\r\n",
        search(&buffer, "a7", "invoice \"october\""),
    );
}

test "capability, noop, and logout" {
    var buffer: [64]u8 = undefined;
    try expect_command("a8 CAPABILITY\r\n", capability(&buffer, "a8"));
    try expect_command("a9 NOOP\r\n", noop(&buffer, "a9"));
    try expect_command("a10 LOGOUT\r\n", logout(&buffer, "a10"));
}

test "a buffer that cannot hold the command fails, and writes no command" {
    var small: [8]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, login(&small, "a1", "user", "pass"));
}

test "an invalid tag is refused" {
    var buffer: [64]u8 = undefined;
    try testing.expectError(error.InvalidTag, noop(&buffer, ""));
    try testing.expectError(error.InvalidTag, noop(&buffer, "a b"));
    try testing.expectError(error.InvalidTag, noop(&buffer, "a(b"));
    try testing.expectError(error.InvalidTag, noop(&buffer, "a{b"));
    try testing.expectError(error.InvalidTag, noop(&buffer, "a\"b"));
    try testing.expectError(error.InvalidTag, noop(&buffer, "a\nb"));
}

test "an astring with a control character is refused" {
    var buffer: [128]u8 = undefined;
    try testing.expectError(error.InvalidAstring, select(&buffer, "a1", "Inbox\r\nLOGOUT"));
    try testing.expectError(error.InvalidAstring, select(&buffer, "a1", "Inbox\x7f"));
}

test "the first problem is the one reported" {
    var buffer: [4]u8 = undefined;
    // Tag too long for the buffer, then the astring would also fail: the tag
    // problem is reported because it happened first.
    try testing.expectError(error.NoSpaceLeft, select(&buffer, "averylongtag", "Inbox"));
}

test "move_message and fetch_body refuse uid zero" {
    var buffer: [64]u8 = undefined;
    try testing.expectError(error.InvalidNumber, move_message(&buffer, "a1", 0, "Trash"));
    try testing.expectError(error.InvalidNumber, store_flags(&buffer, "a1", 0, .{}));
}

test "quoted output is a valid single line for every printable input" {
    var buffer: [512]u8 = undefined;
    const nasty = "a\"b\\c d e";
    const command = try search(&buffer, "a1", nasty);
    try testing.expect(std.mem.indexOf(u8, command, "\r\n") == command.len - 2);
    assert(command[command.len - 2] == '\r');
    assert(command[command.len - 1] == '\n');
}
