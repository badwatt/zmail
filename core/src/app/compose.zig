//! Compose state: one recipient, a subject, and a body.
//!
//! Editing is append/backspace at the end of the active field, plus clearing
//! the field. That is a deliberate first version: it keeps the state machine
//! small and every key path testable, and it is enough to write and send a
//! reply. A cursor inside a line comes with the richer editor later.

const std = @import("std");
const assert = std.debug.assert;

const limits = @import("../limits.zig");
const Text = @import("../domain/text.zig").Text;
const copy_sanitized_body = @import("../domain/text.zig").copy_sanitized_body;
const Address = @import("../domain/address.zig").Address;
const MessageId = @import("../domain/id.zig").MessageId;
const AccountId = @import("../domain/id.zig").AccountId;

pub const Field = enum { to, subject, body };

pub const Compose = struct {
    active: bool = false,
    field: Field = .to,
    to: Text(limits.address_max) = .{},
    subject: Text(limits.subject_max) = .{},
    body: [limits.body_max]u8 = undefined,
    body_len: u32 = 0,
    in_reply_to: MessageId = .unknown,
    /// Which account sends this draft, and from which address.
    account: AccountId = .unknown,
    from: Address = .{},

    pub fn reset(self: *Compose) void {
        self.active = true;
        self.field = .to;
        self.to.clear();
        self.subject.clear();
        self.body_len = 0;
        self.in_reply_to = .unknown;
        self.account = .unknown;
        self.from = .{};
    }

    pub fn body_slice(self: *const Compose) []const u8 {
        assert(self.body_len <= limits.body_max);
        return self.body[0..self.body_len];
    }

    pub fn append(self: *Compose, codepoint: u21) void {
        switch (self.field) {
            .to => self.to.append_codepoint(codepoint),
            .subject => self.subject.append_codepoint(codepoint),
            .body => append_body(self, codepoint),
        }
    }

    pub fn append_newline(self: *Compose) void {
        if (self.field != .body) {
            self.next_field();
            return;
        }
        if (self.body_len == self.body.len) return;
        self.body[self.body_len] = '\n';
        self.body_len += 1;
    }

    pub fn backspace(self: *Compose) void {
        switch (self.field) {
            .to => self.to.pop_codepoint(),
            .subject => self.subject.pop_codepoint(),
            .body => pop_body_codepoint(self),
        }
    }

    pub fn clear_field(self: *Compose) void {
        switch (self.field) {
            .to => self.to.clear(),
            .subject => self.subject.clear(),
            .body => self.body_len = 0,
        }
    }

    pub fn next_field(self: *Compose) void {
        self.field = switch (self.field) {
            .to => .subject,
            .subject => .body,
            .body => .to,
        };
    }

    pub fn previous_field(self: *Compose) void {
        self.field = switch (self.field) {
            .to => .body,
            .subject => .to,
            .body => .subject,
        };
    }

    /// Replaces the body with text that did not arrive as keystrokes: an
    /// editor's file. Sanitized and cut at a UTF-8 boundary like any other
    /// ingress, because a file on disk is exactly as trustworthy as the program
    /// that wrote it.
    pub fn set_body(self: *Compose, text: []const u8) void {
        self.body_len = copy_sanitized_body(self.body[0..], text);
    }

    /// Appends the original below the draft, the way a reply reads: the
    /// attribution, then every line prefixed with `> `.
    ///
    /// The draft comes first because the composer only edits at the end: what
    /// the user types lands above the quote, which is where a reader expects it.
    /// A line that does not fit ends the quote, so a truncated body looks
    /// short rather than corrupted.
    pub fn append_quote(self: *Compose, text: []const u8, attribution: []const u8) void {
        if (text.len == 0) return;

        var lines = std.mem.splitScalar(u8, text, '\n');
        const first = std.mem.trimEnd(u8, lines.next() orelse return, "\r");

        // The attribution is written only when at least one quoted line fits:
        // a body that ends on "wrote:" promises a quote that is not there.
        const room = (if (self.body_len != 0) @as(usize, 1) else 0) +
            attribution.len + 1 + 2 + first.len + 1;
        if (@as(usize, self.body_len) + room > self.body.len) return;

        if (self.body_len != 0) _ = self.append_line("", "");
        if (!self.append_line("", attribution)) return;
        _ = self.append_line("> ", first);
        while (lines.next()) |line| {
            if (!self.append_line("> ", std.mem.trimEnd(u8, line, "\r"))) return;
        }
    }

    /// One whole line, or nothing. The newline is part of the line, so the body
    /// is always a sequence of complete lines.
    fn append_line(self: *Compose, prefix: []const u8, line: []const u8) bool {
        const needed = prefix.len + line.len + 1;
        if (@as(usize, self.body_len) + needed > self.body.len) return false;
        @memcpy(self.body[self.body_len..][0..prefix.len], prefix);
        self.body_len += @intCast(prefix.len);
        @memcpy(self.body[self.body_len..][0..line.len], line);
        self.body_len += @intCast(line.len);
        self.body[self.body_len] = '\n';
        self.body_len += 1;
        return true;
    }

    /// The recipient, if the field parses as an address.
    pub fn recipient(self: *const Compose) ?Address {
        return Address.init(self.to.slice()) catch null;
    }
};

fn append_body(self: *Compose, codepoint: u21) void {
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &encoded) catch return;
    if (self.body_len + length > self.body.len) return;
    @memcpy(self.body[self.body_len..][0..length], encoded[0..length]);
    self.body_len += length;
}

fn pop_body_codepoint(self: *Compose) void {
    if (self.body_len == 0) return;
    var index: u32 = self.body_len - 1;
    while (index > 0) : (index -= 1) {
        if (self.body[index] & 0b1100_0000 != 0b1000_0000) break;
    }
    self.body_len = index;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "append_quote puts the attribution and a quoted line per line" {
    var compose = Compose{ .active = true, .field = .body };
    compose.append_quote("hello\r\nworld", "On 14 Nov 2023, Alice wrote:");
    try testing.expectEqualStrings(
        "On 14 Nov 2023, Alice wrote:\n> hello\n> world\n",
        compose.body_slice(),
    );
}

test "append_quote keeps the draft above, with a blank line between" {
    var compose = Compose{ .active = true, .field = .body };
    compose.append('o');
    compose.append('k');
    compose.append_quote("hi", "On 1 Jan 2024, Bob wrote:");
    try testing.expectEqualStrings("ok\nOn 1 Jan 2024, Bob wrote:\n> hi\n", compose.body_slice());
}

test "an original with no text quotes nothing" {
    var compose = Compose{ .active = true, .field = .body };
    compose.append('x');
    compose.append_quote("", "On 1 Jan 2024, Bob wrote:");
    try testing.expectEqualStrings("x", compose.body_slice());
}

test "a quote with no room at all is not started" {
    var compose = Compose{ .active = true, .field = .body };
    @memset(compose.body[0 .. limits.body_max - 4], 'x');
    compose.body_len = limits.body_max - 4;
    compose.append_quote("hi", "On 1 Jan 2024, Bob wrote:");

    // Four bytes left: no room for the attribution plus a line, so nothing is
    // written and the body still ends where the user left it.
    try testing.expectEqual(limits.body_max - 4, compose.body_len);
}

test "a quote stops at the last line that fits" {
    var compose = Compose{ .active = true, .field = .body };
    compose.body_len = limits.body_max - 40;
    @memset(compose.body[0..compose.body_len], 'x');

    var original: [206]u8 = undefined;
    @memcpy(original[0..6], "short\n");
    @memset(original[6..], 'y');
    compose.append_quote(&original, "attr:");

    const quoted = compose.body[limits.body_max - 40 .. compose.body_len];
    try testing.expectEqualStrings("\nattr:\n> short\n", quoted);
}

test "set_body replaces the body, sanitized as if it came from the wire" {
    var compose = Compose{ .active = true, .field = .body };
    compose.append('x');
    compose.set_body("hello\x1bthere\n");
    try testing.expectEqualStrings("hello there\n", compose.body_slice());

    // A file on disk is sized by nobody: the body stops at its capacity instead.
    const huge = try testing.allocator.alloc(u8, limits.body_max + 8);
    defer testing.allocator.free(huge);
    @memset(huge, 'y');
    compose.set_body(huge);
    try testing.expectEqual(limits.body_max, compose.body_len);
}

test "reset starts an empty compose at the recipient" {
    var compose = Compose{};
    compose.reset();
    try testing.expect(compose.active);
    try testing.expectEqual(Field.to, compose.field);
    try testing.expect(compose.to.is_empty());
    try testing.expect(compose.subject.is_empty());
    try testing.expectEqualStrings("", compose.body_slice());
    try testing.expectEqual(MessageId.unknown, compose.in_reply_to);
}

test "typing goes to the active field only" {
    var compose = Compose{ .active = true };
    compose.append('a');
    compose.append('b');
    try testing.expectEqualStrings("ab", compose.to.slice());
    try testing.expect(compose.subject.is_empty());

    compose.next_field();
    compose.append('S');
    try testing.expectEqualStrings("S", compose.subject.slice());
    try testing.expectEqualStrings("ab", compose.to.slice());
}

test "the body keeps newlines and UTF-8, and backspace removes whole codepoints" {
    var compose = Compose{ .active = true, .field = .body };
    compose.append('o');
    compose.append('l');
    compose.append(0xe1);
    compose.append_newline();
    compose.append('x');
    try testing.expectEqualStrings("olá\nx", compose.body_slice());

    compose.backspace();
    compose.backspace();
    try testing.expectEqualStrings("olá", compose.body_slice());
    compose.backspace();
    try testing.expectEqualStrings("ol", compose.body_slice());
}

test "enter in a header field moves to the next field" {
    var compose = Compose{ .active = true };
    compose.append_newline();
    try testing.expectEqual(Field.subject, compose.field);
    compose.append_newline();
    try testing.expectEqual(Field.body, compose.field);
    compose.append_newline();
    try testing.expectEqualStrings("\n", compose.body_slice());
}

test "clear_field empties only the active field" {
    var compose = Compose{ .active = true };
    compose.append('a');
    compose.next_field();
    compose.append('s');
    compose.clear_field();
    try testing.expect(compose.subject.is_empty());
    try testing.expectEqualStrings("a", compose.to.slice());

    compose.field = .body;
    compose.append('x');
    compose.clear_field();
    try testing.expectEqualStrings("", compose.body_slice());
}

test "field cycling wraps in both directions" {
    var compose = Compose{ .active = true };
    compose.previous_field();
    try testing.expectEqual(Field.body, compose.field);
    compose.previous_field();
    try testing.expectEqual(Field.subject, compose.field);
    compose.next_field();
    try testing.expectEqual(Field.body, compose.field);
    compose.next_field();
    try testing.expectEqual(Field.to, compose.field);
}

test "backspace removes from the subject too, and clear_field empties the recipient" {
    var compose = Compose{ .active = true };
    compose.to.set("alice@example.com");
    compose.field = .subject;
    compose.append('a');
    compose.append('b');
    compose.backspace();
    try testing.expectEqualStrings("a", compose.subject.slice());

    compose.field = .to;
    compose.clear_field();
    try testing.expect(compose.to.is_empty());
}

test "backspace on empty fields and an empty body is harmless" {
    var compose = Compose{ .active = true };
    compose.backspace();
    compose.field = .body;
    compose.backspace();
    try testing.expect(compose.to.is_empty());
    try testing.expectEqualStrings("", compose.body_slice());
}

test "a full body stops accepting bytes instead of overflowing" {
    var compose = Compose{ .active = true, .field = .body };
    var index: u32 = 0;
    while (index < limits.body_max + 10) : (index += 1) compose.append('x');
    try testing.expectEqual(limits.body_max, compose.body_len);
}

test "recipient parses, and rejects malformed addresses" {
    var compose = Compose{ .active = true };
    try testing.expect(compose.recipient() == null);
    compose.to.set("alice@example.com");
    try testing.expectEqualStrings("alice", compose.recipient().?.local.slice());
    compose.to.set("not an address");
    try testing.expect(compose.recipient() == null);
}
