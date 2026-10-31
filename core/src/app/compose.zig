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
const Address = @import("../domain/address.zig").Address;
const MessageId = @import("../domain/id.zig").MessageId;

pub const Field = enum { to, subject, body };

pub const Compose = struct {
    active: bool = false,
    field: Field = .to,
    to: Text(limits.address_max) = .{},
    subject: Text(limits.subject_max) = .{},
    body: [limits.body_max]u8 = undefined,
    body_len: u32 = 0,
    in_reply_to: MessageId = .unknown,

    pub fn reset(self: *Compose) void {
        self.active = true;
        self.field = .to;
        self.to.clear();
        self.subject.clear();
        self.body_len = 0;
        self.in_reply_to = .unknown;
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
