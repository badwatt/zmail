//! In-memory mail adapter: the demo account and the tests' server double.
//!
//! It holds the "server side" of a mailbox in a fixed array. The application's
//! cache is a separate `Store`; `fetch` copies envelopes across the boundary, so
//! the same code path is exercised as with a real IMAP adapter.

const std = @import("std");
const assert = std.debug.assert;

const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Message = @import("../domain/message.zig").Message;
const Flags = @import("../domain/message.zig").Flags;
const MessageId = @import("../domain/id.zig").MessageId;
const Address = @import("../domain/address.zig").Address;
const port = @import("../ports/mail.zig");
const civil_from_unix = @import("../domain/time.zig").civil_from_unix;

pub const MemoryMail = struct {
    messages: [capacity]Message = undefined,
    len: u32 = 0,

    pub const capacity: u32 = 64;
    pub const SeedError = error{Full};

    pub fn init() MemoryMail {
        return .{};
    }

    pub fn seed(self: *MemoryMail, message: *const Message) SeedError!void {
        assert(message.id.is_known());
        if (self.len == capacity) return error.Full;
        // Keep the fake server ordered newest-first, like a real fetch.
        var position: u32 = self.len;
        while (position > 0) : (position -= 1) {
            if (self.messages[position - 1].timestamp_unix >= message.timestamp_unix) break;
        }
        var cursor: u32 = self.len;
        while (cursor > position) : (cursor -= 1) {
            self.messages[cursor] = self.messages[cursor - 1];
        }
        self.messages[position] = message.*;
        self.len += 1;
    }

    pub fn mail(self: *MemoryMail) port.Mail {
        return .{ .context = self, .vtable = &.{
            .fetch = fetchThunk,
            .fetch_body = fetchBodyThunk,
            .fetch_raw = fetchRawThunk,
            .set_flags = setFlagsThunk,
            .move_message = moveThunk,
            .delete_message = deleteThunk,
            .empty_mailbox = emptyThunk,
        } };
    }

    fn fetchThunk(context: *anyopaque, mailbox: Mailbox, out: []Message) port.Error!u32 {
        const self: *MemoryMail = @ptrCast(@alignCast(context));
        var written: u32 = 0;
        for (self.messages[0..self.len]) |message| {
            if (message.mailbox != mailbox) continue;
            if (written == out.len) break;
            out[written] = message;
            written += 1;
        }
        return written;
    }

    fn fetchBodyThunk(context: *anyopaque, mailbox: Mailbox, id: MessageId, out: []u8) port.Error![]const u8 {
        const self: *MemoryMail = @ptrCast(@alignCast(context));
        const message = self.find(id) orelse return error.NotFound;
        if (message.mailbox != mailbox) return error.NotFound;
        return render_body(message, out);
    }

    /// The memory adapter stores whole messages, so the raw form is the same
    /// bytes the text form is rendered from.
    fn fetchRawThunk(context: *anyopaque, mailbox: Mailbox, id: MessageId, out: []u8) port.Error![]const u8 {
        const self: *MemoryMail = @ptrCast(@alignCast(context));
        const message = self.find(id) orelse return error.NotFound;
        if (message.mailbox != mailbox) return error.NotFound;
        const text = render_body(message, out);
        return text;
    }

    fn setFlagsThunk(context: *anyopaque, id: MessageId, flags: Flags) port.Error!void {
        const self: *MemoryMail = @ptrCast(@alignCast(context));
        const message = self.find(id) orelse return error.NotFound;
        message.flags = flags;
    }

    fn deleteThunk(context: *anyopaque, mailbox: Mailbox, id: MessageId) port.Error!void {
        const self: *MemoryMail = @ptrCast(@alignCast(context));
        var index: u32 = 0;
        while (index < self.len) : (index += 1) {
            if (self.messages[index].id == id and self.messages[index].mailbox == mailbox) {
                self.len -= 1;
                var cursor = index;
                while (cursor < self.len) : (cursor += 1) {
                    self.messages[cursor] = self.messages[cursor + 1];
                }
                self.messages[self.len] = @import("../domain/message.zig").Message{};
                return;
            }
        }
        return error.NotFound;
    }

    fn emptyThunk(context: *anyopaque, mailbox: Mailbox) port.Error!void {
        const self: *MemoryMail = @ptrCast(@alignCast(context));
        var read: u32 = 0;
        var write: u32 = 0;
        while (read < self.len) : (read += 1) {
            if (self.messages[read].mailbox != mailbox) {
                self.messages[write] = self.messages[read];
                write += 1;
            }
        }
        self.len = write;
    }

    fn moveThunk(context: *anyopaque, id: MessageId, to: Mailbox) port.Error!void {
        const self: *MemoryMail = @ptrCast(@alignCast(context));
        const message = self.find(id) orelse return error.NotFound;
        message.mailbox = to;
    }

    pub fn find(self: *MemoryMail, id: MessageId) ?*Message {
        for (self.messages[0..self.len]) |*message| {
            if (message.id == id) return message;
        }
        return null;
    }
};

/// Builds a plausible plain-text body from the envelope. The demo has no real
/// messages, and this keeps 64 kilobytes times 64 messages out of the binary.
pub fn render_body(message: *const Message, out: []u8) []const u8 {
    // The first message is a real MIME message with an HTML part.
    if (message.id.to_int() == 1) {
        const length = @min(html_message.len, out.len);
        @memcpy(out[0..length], html_message[0..length]);
        return out[0..length];
    }

    var writer = std.Io.Writer.fixed(out);
    writer.print("From: ", .{}) catch return "";
    message.from.format(&writer) catch return "";

    const timestamp = civil_from_unix(message.timestamp_unix);
    writer.print(
        \\
        \\Date: {d}-{d:0>2}-{d:0>2}
        \\Subject: {s}
        \\
        \\{s}
        \\
        \\{s}
        \\
        \\--
        \\{s}
        \\
    ,
        .{
            timestamp.year,
            timestamp.month,
            timestamp.day,
            message.subject.slice(),
            message.snippet.slice(),
            template(message.id),
            message.from.label(),
        },
    ) catch return "";
    return writer.buffered();
}

/// The first message arrives as a real MIME message with an HTML part, so the
/// HTML view has something to render in the demo.
const html_message =
    "Content-Type: multipart/alternative; boundary=\"demo\"\n" ++
    "\n" ++
    "--demo\n" ++
    "Content-Type: text/plain\n" ++
    "\n" ++
    "A short note with a link: https://example.com/doc/plan\n" ++
    "\n" ++
    "The plain-text part of this message is what the reader shows by default, so\n" ++
    "pressing H reads the HTML version instead: headings, lists and links, all\n" ++
    "in the terminal.\n" ++
    "\n" ++
    "Nothing in this demo leaves the machine: the mail lives in memory and the\n" ++
    "rendering happens from that copy.\n" ++
    "\n" ++
    "--demo\n" ++
    "Content-Type: text/html\n" ++
    "\n" ++
    "<h2>Plan</h2><p>A short note with a <a href=\"https://example.com/doc/plan\">link</a>.</p>" ++
    "<ul><li>ship the simple version</li><li>then the fancy one</li></ul>" ++
    "<p>The plain-text part of this message is what the reader shows by default, " ++
    "so pressing H reads the HTML version instead: headings, lists and links, " ++
    "all in the terminal.</p>" ++
    "<p>Nothing in this demo leaves the machine: the mail lives in memory and " ++
    "the rendering happens from that copy.</p>\n" ++
    "--demo--\n";

fn template(id: MessageId) []const u8 {
    const templates = [_][]const u8{
        "Thanks for the note. Short answer: yes, and I think it is the right\n" ++
            "call for now. I left the details in the doc so we can revisit them\n" ++
            "next week with fresh eyes.\n",
        "A couple of thoughts before we commit to this:\n\n" ++
            "  1. The simplest version ships this week.\n" ++
            "  2. The fancy version ships next month.\n" ++
            "  3. We can always do (1) and then (2).\n\n" ++
            "Pick one and I will make it happen.",
        "Heads up: the build is green again. The failure was a stale cache,\n" ++
            "not the change itself. Nothing to do on your side.",
        "I have attached nothing on purpose: amail is text-only and offline\n" ++
            "in demo mode. When live accounts land, attachments will be shown\n" ++
            "as a name and size, never opened automatically.",
    };
    const index: usize = @intCast(id.to_int() % templates.len);
    return templates[index];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const core_mime = @import("../mime.zig");

fn seeded() !MemoryMail {
    var mail = MemoryMail.init();
    const first = Message{
        .id = MessageId.from_int(1),
        .mailbox = .inbox,
        .from = try Address.init("Alice <alice@example.com>"),
        .subject = .{},
        .snippet = .{},
        .timestamp_unix = 300,
    };
    const second = Message{
        .id = MessageId.from_int(2),
        .mailbox = .inbox,
        .from = try Address.init("Bob <bob@example.com>"),
        .subject = .{},
        .snippet = .{},
        .timestamp_unix = 200,
    };
    const third = Message{
        .id = MessageId.from_int(3),
        .mailbox = .sent,
        .from = try Address.init("me <me@example.com>"),
        .subject = .{},
        .snippet = .{},
        .timestamp_unix = 100,
    };
    try mail.seed(&first);
    try mail.seed(&second);
    try mail.seed(&third);
    return mail;
}

test "MemoryMail: seed keeps messages newest-first" {
    const mail = try seeded();
    try testing.expectEqual(@as(u32, 3), mail.len);
    try testing.expectEqual(MessageId.from_int(1), mail.messages[0].id);
    try testing.expectEqual(MessageId.from_int(3), mail.messages[2].id);
}

test "MemoryMail: seed refuses more than the capacity" {
    var mail = MemoryMail.init();
    var message = Message{ .id = MessageId.from_int(1) };
    const total: u32 = MemoryMail.capacity + 1;
    var index: u32 = 0;
    while (index < MemoryMail.capacity) : (index += 1) {
        message.id = MessageId.from_int(index + 1);
        message.timestamp_unix = @intCast(index);
        try mail.seed(&message);
    }
    message.id = MessageId.from_int(total);
    try testing.expectError(error.Full, mail.seed(&message));
}

test "MemoryMail: fetch only returns the requested mailbox" {
    var mail = try seeded();
    var out: [8]Message = undefined;
    const count = try mail.mail().fetch(.inbox, &out);
    try testing.expectEqual(@as(u32, 2), count);
    try testing.expectEqual(MessageId.from_int(1), out[0].id);
    try testing.expectEqual(MessageId.from_int(2), out[1].id);
}

test "MemoryMail: fetch respects the output capacity" {
    var mail = try seeded();
    var out: [1]Message = undefined;
    const count = try mail.mail().fetch(.inbox, &out);
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(MessageId.from_int(1), out[0].id);
}

test "MemoryMail: fetch of an empty mailbox returns zero" {
    var mail = try seeded();
    var out: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 0), try mail.mail().fetch(.junk, &out));
}

test "MemoryMail: fetch_body renders a bounded body" {
    var mail = try seeded();
    var out: [4096]u8 = undefined;
    const body = try mail.mail().fetch_body(.inbox, MessageId.from_int(2), &out);
    try testing.expect(body.len > 0);
    try testing.expect(std.mem.indexOf(u8, body, "From: Bob <bob@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Subject:") != null);
}

test "MemoryMail: fetch_body reports an unknown id" {
    var mail = try seeded();
    var out: [64]u8 = undefined;
    try testing.expectError(error.NotFound, mail.mail().fetch_body(.inbox, MessageId.from_int(99), &out));
}

test "MemoryMail: fetch_body is scoped to a mailbox" {
    var mail = try seeded();
    var out: [64]u8 = undefined;
    // UIDs are per mailbox: the right id in the wrong mailbox is not found.
    try testing.expectError(error.NotFound, mail.mail().fetch_body(.sent, MessageId.from_int(1), &out));
}

test "MemoryMail: delete removes one message, empty clears the mailbox" {
    var mail = try seeded();
    const before = mail.len;

    try mail.mail().delete_message(.inbox, MessageId.from_int(1));
    try testing.expectEqual(before - 1, mail.len);
    try testing.expect(mail.find(MessageId.from_int(1)) == null);
    try testing.expectError(error.NotFound, mail.mail().delete_message(.inbox, MessageId.from_int(99)));

    try mail.mail().empty_mailbox(.inbox);
    var index: u32 = 0;
    while (index < mail.len) : (index += 1) {
        try testing.expect(mail.messages[index].mailbox != .inbox);
    }
}

test "MemoryMail: set_flags mutates the server copy" {
    var mail = try seeded();
    try mail.mail().set_flags(MessageId.from_int(1), .{ .unread = false });
    try testing.expect(!mail.messages[0].is_unread());
}

test "MemoryMail: set_flags reports an unknown id" {
    var mail = try seeded();
    try testing.expectError(error.NotFound, mail.mail().set_flags(MessageId.from_int(99), .{}));
}

test "MemoryMail: move_message changes the mailbox" {
    var mail = try seeded();
    try mail.mail().move_message(MessageId.from_int(1), .archive);
    try testing.expectEqual(Mailbox.archive, mail.messages[0].mailbox);

    var out: [8]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try mail.mail().fetch(.inbox, &out));
}

test "MemoryMail: move_message reports an unknown id" {
    var mail = try seeded();
    try testing.expectError(error.NotFound, mail.mail().move_message(MessageId.from_int(99), .archive));
}

test "render_body uses a rotating template so the demo is not repetitive" {
    var out: [4096]u8 = undefined;
    const first = Message{ .id = MessageId.from_int(1), .from = try Address.init("a@example.com") };
    const second = Message{ .id = MessageId.from_int(2), .from = try Address.init("a@example.com") };
    const first_body = render_body(&first, &out);
    var other_out: [4096]u8 = undefined;
    const second_body = render_body(&second, &other_out);
    try testing.expect(!std.mem.eql(u8, first_body, second_body));
}

test "render_body refuses a buffer that cannot hold the header" {
    var out: [4]u8 = undefined;
    const message = Message{ .id = MessageId.from_int(2), .from = try Address.init("a@example.com") };
    try testing.expectEqualStrings("", render_body(&message, &out));
}

test "render_body refuses a buffer that fits the address but not the body" {
    var out: [24]u8 = undefined;
    const message = Message{ .id = MessageId.from_int(2), .from = try Address.init("a@example.com") };
    try testing.expectEqualStrings("", render_body(&message, &out));
}

test "the first message is a MIME message with an HTML part" {
    var out: [4096]u8 = undefined;
    const message = Message{ .id = MessageId.from_int(1), .from = try Address.init("a@example.com") };
    const raw = render_body(&message, &out);
    try testing.expect(std.mem.indexOf(u8, raw, "multipart/alternative") != null);
    try testing.expect(core_mime.html_body(raw, &out, &out) != null);
}
