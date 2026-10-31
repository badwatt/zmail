//! Demo outbox: "sending" appends the message to the demo account's Sent
//! mailbox, so composing works offline and visibly.

const std = @import("std");
const assert = std.debug.assert;

const Outgoing = @import("../domain/outgoing.zig").Outgoing;
const Message = @import("../domain/message.zig").Message;
const Address = @import("../domain/address.zig").Address;
const MessageId = @import("../domain/id.zig").MessageId;
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Text = @import("../domain/text.zig").Text;
const limits = @import("../limits.zig");
const port = @import("../ports/outbox.zig");
const MemoryMail = @import("memory_mail.zig").MemoryMail;

pub const MemoryOutbox = struct {
    mail: *MemoryMail,
    next_id: u64 = 100,
    now_unix: i64 = 0,

    pub fn init(mail: *MemoryMail, now_unix: i64) MemoryOutbox {
        return .{ .mail = mail, .now_unix = now_unix };
    }

    pub fn outbox(self: *MemoryOutbox) port.Outbox {
        return .{ .context = self, .vtable = &.{ .send = sendThunk } };
    }

    pub fn sentCount(self: *const MemoryOutbox) u32 {
        var count: u32 = 0;
        for (self.mail.messages[0..self.mail.len]) |message| {
            if (message.mailbox == .sent) count += 1;
        }
        return count;
    }

    fn sendThunk(context: *anyopaque, message: *const Outgoing) port.Error!void {
        const self: *MemoryOutbox = @ptrCast(@alignCast(context));
        assert(message.to.local.len > 0);

        self.next_id += 1;
        var stored = Message{
            .id = MessageId.from_int(self.next_id),
            .mailbox = .sent,
            .from = message.from,
            .timestamp_unix = self.now_unix,
            .flags = .{ .unread = false },
        };
        stored.subject.set(message.subject.slice());
        const line = first_line(message.body);
        stored.snippet.set(line[0..@min(line.len, limits.snippet_max)]);
        if (stored.from.local.is_empty()) stored.from = Address.from_parts("", "me", "amail.local");

        self.mail.seed(&stored) catch return error.Unavailable;
    }
};

fn first_line(body: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    return std.mem.trimEnd(u8, body[0..end], " \r");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fixture() MemoryMail {
    return MemoryMail.init();
}

test "sending appends to Sent with the outgoing fields" {
    var mail = fixture();
    var outbox = MemoryOutbox.init(&mail, 1_700_000_000);

    var outgoing = Outgoing{
        .from = try Address.init("me <me@amail.local>"),
        .to = try Address.init("alice@example.com"),
        .body = "First line\nsecond line",
    };
    outgoing.subject.set("Hello");
    try outbox.outbox().send(&outgoing);

    try testing.expectEqual(@as(u32, 1), outbox.sentCount());
    const sent = mail.find(MessageId.from_int(101)).?;
    try testing.expectEqual(Mailbox.sent, sent.mailbox);
    try testing.expectEqualStrings("Hello", sent.subject.slice());
    try testing.expectEqualStrings("First line", sent.snippet.slice());
    try testing.expectEqual(@as(i64, 1_700_000_000), sent.timestamp_unix);
    try testing.expect(!sent.is_unread());
}

test "a missing from address is filled with the demo account" {
    var mail = fixture();
    var outbox = MemoryOutbox.init(&mail, 0);
    var outgoing = Outgoing{ .to = try Address.init("bob@example.com"), .body = "hi" };
    outgoing.subject.set("Hi");
    try outbox.outbox().send(&outgoing);

    const sent = mail.find(MessageId.from_int(101)).?;
    var address_buffer: [limits.address_max]u8 = undefined;
    try testing.expectEqualStrings("me@amail.local", sent.from.addr_spec(&address_buffer));
}

test "a full mailbox is reported as Unavailable" {
    var mail = fixture();
    var filler = Message{ .id = MessageId.from_int(1), .mailbox = .sent };
    while (mail.len < MemoryMail.capacity) {
        filler.id = MessageId.from_int(mail.len + 1);
        try mail.seed(&filler);
    }
    var outbox = MemoryOutbox.init(&mail, 0);
    try testing.expectError(error.Unavailable, outbox.outbox().send(&.{ .to = try Address.init("a@b.c"), .body = "" }));
}

test "first_line handles no newline and trims trailing spaces" {
    try testing.expectEqualStrings("abc", first_line("abc"));
    try testing.expectEqualStrings("abc", first_line("abc  \r\nrest"));
    try testing.expectEqualStrings("", first_line(""));
}
