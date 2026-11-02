//! The mail port: everything the application needs from a mail server, and
//! nothing about how it is reached.
//!
//! Adapters implement this vtable (an in-memory demo today, IMAP/SMTP later).
//! The application never sees TLS, sockets, or protocols.

const std = @import("std");
const assert = std.debug.assert;
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Message = @import("../domain/message.zig").Message;
const Flags = @import("../domain/message.zig").Flags;
const MessageId = @import("../domain/id.zig").MessageId;

pub const Error = error{
    /// The server cannot be reached right now. Retrying may work.
    Unavailable,
    /// The message or mailbox does not exist.
    NotFound,
    /// The server refused the request. Retrying will not help.
    Rejected,
};

pub const Mail = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Copies the envelope (headers only, never bodies) of `mailbox` into
        /// `out`, newest first, and returns how many were written. If `out` is
        /// too small, the oldest messages are dropped.
        fetch: *const fn (context: *anyopaque, mailbox: Mailbox, out: []Message) Error!u32,
        /// Copies the displayable text of `id` (which lives in `mailbox`) into
        /// `out` and returns the written slice. Bodies are fetched on demand and
        /// never cached in envelopes. UIDs are per mailbox, so the mailbox is
        /// part of the address.
        fetch_body: *const fn (context: *anyopaque, mailbox: Mailbox, id: MessageId, out: []u8) Error![]const u8,
        /// The message as the server sent it: the reader renders text and HTML
        /// from the same bytes, so switching views costs no second fetch.
        fetch_raw: *const fn (context: *anyopaque, mailbox: Mailbox, id: MessageId, out: []u8) Error![]const u8,
        set_flags: *const fn (context: *anyopaque, id: MessageId, flags: Flags) Error!void,
        move_message: *const fn (context: *anyopaque, id: MessageId, to: Mailbox) Error!void,
        /// Removes a message for good: mark deleted, then expunge.
        delete_message: *const fn (context: *anyopaque, mailbox: Mailbox, id: MessageId) Error!void,
        /// Removes every message in a mailbox for good.
        empty_mailbox: *const fn (context: *anyopaque, mailbox: Mailbox) Error!void,
    };

    pub fn fetch(self: Mail, mailbox: Mailbox, out: []Message) Error!u32 {
        return self.vtable.fetch(self.context, mailbox, out);
    }

    pub fn fetch_body(self: Mail, mailbox: Mailbox, id: MessageId, out: []u8) Error![]const u8 {
        return self.vtable.fetch_body(self.context, mailbox, id, out);
    }

    pub fn fetch_raw(self: Mail, mailbox: Mailbox, id: MessageId, out: []u8) Error![]const u8 {
        return self.vtable.fetch_raw(self.context, mailbox, id, out);
    }

    pub fn set_flags(self: Mail, id: MessageId, flags: Flags) Error!void {
        return self.vtable.set_flags(self.context, id, flags);
    }

    pub fn move_message(self: Mail, id: MessageId, to: Mailbox) Error!void {
        return self.vtable.move_message(self.context, id, to);
    }

    pub fn delete_message(self: Mail, mailbox: Mailbox, id: MessageId) Error!void {
        return self.vtable.delete_message(self.context, mailbox, id);
    }

    pub fn empty_mailbox(self: Mail, mailbox: Mailbox) Error!void {
        return self.vtable.empty_mailbox(self.context, mailbox);
    }
};

/// The `Deps` struct: the complete set of things the application cannot compute
/// by itself. A GUI and the TUI pass the same shape, only the adapters differ.
pub const Deps = struct {
    mail: Mail,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A fake that records what it was asked, to prove the thunks forward both the
/// context and every argument.
const Recorder = struct {
    last_mailbox: Mailbox = .inbox,
    last_id: MessageId = .unknown,
    last_flags: Flags = .{},
    last_target: Mailbox = .inbox,
    fetch_calls: u32 = 0,
    fetch_error: ?Error = null,

    fn mail(self: *Recorder) Mail {
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

    fn fetchThunk(context: *anyopaque, mailbox: Mailbox, out: []Message) Error!u32 {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.fetch_calls += 1;
        self.last_mailbox = mailbox;
        if (self.fetch_error) |err| return err;
        if (out.len == 0) return 0;
        out[0] = .{ .id = MessageId.from_int(1) };
        return 1;
    }

    fn fetchBodyThunk(context: *anyopaque, mailbox: Mailbox, id: MessageId, out: []u8) Error![]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_mailbox = mailbox;
        if (out.len == 0) return "";
        out[0] = 'x';
        return out[0..1];
    }

    fn fetchRawThunk(context: *anyopaque, mailbox: Mailbox, id: MessageId, out: []u8) Error![]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_mailbox = mailbox;
        if (out.len < 3) return "";
        @memcpy(out[0..3], "raw");
        return out[0..3];
    }

    fn setFlagsThunk(context: *anyopaque, id: MessageId, flags: Flags) Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_flags = flags;
    }

    fn deleteThunk(context: *anyopaque, mailbox: Mailbox, id: MessageId) Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_mailbox = mailbox;
    }

    fn emptyThunk(context: *anyopaque, mailbox: Mailbox) Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_mailbox = mailbox;
    }

    fn moveThunk(context: *anyopaque, id: MessageId, to: Mailbox) Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_target = to;
    }
};

test "Mail.fetch forwards the mailbox and returns the count" {
    var recorder: Recorder = .{};
    const mail = recorder.mail();

    var out: [2]Message = undefined;
    const count = try mail.fetch(.archive, &out);
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(u32, 1), recorder.fetch_calls);
    try testing.expectEqual(Mailbox.archive, recorder.last_mailbox);
    try testing.expectEqual(MessageId.from_int(1), out[0].id);
}

test "Mail.fetch surfaces adapter errors unchanged" {
    var recorder: Recorder = .{ .fetch_error = error.Unavailable };
    try testing.expectError(error.Unavailable, recorder.mail().fetch(.inbox, &.{}));
}

test "Mail.fetch with no room writes nothing and succeeds" {
    var recorder: Recorder = .{};
    try testing.expectEqual(@as(u32, 0), try recorder.mail().fetch(.inbox, &.{}));
}

test "Mail.fetch_body forwards the id and returns a slice into out" {
    var recorder: Recorder = .{};
    var out: [4]u8 = undefined;
    const body = try recorder.mail().fetch_body(.inbox, MessageId.from_int(9), &out);
    try testing.expectEqualStrings("x", body);
    try testing.expectEqual(MessageId.from_int(9), recorder.last_id);
}

test "Mail.fetch_raw forwards the same way" {
    var recorder: Recorder = .{};
    var out: [8]u8 = undefined;
    const raw = try recorder.mail().fetch_raw(.sent, MessageId.from_int(4), &out);
    try testing.expectEqualStrings("raw", raw);
    try testing.expectEqual(Mailbox.sent, recorder.last_mailbox);
    try testing.expectEqual(MessageId.from_int(4), recorder.last_id);
}

test "Mail.fetch_body handles an empty output buffer" {
    var recorder: Recorder = .{};
    var out: [0]u8 = undefined;
    try testing.expectEqualStrings("", try recorder.mail().fetch_body(.inbox, MessageId.from_int(9), &out));
}

test "Mail.set_flags forwards id and flags" {
    var recorder: Recorder = .{};
    const flags = Flags{ .unread = false, .flagged = true };
    try recorder.mail().set_flags(MessageId.from_int(3), flags);
    try testing.expectEqual(MessageId.from_int(3), recorder.last_id);
    try testing.expectEqual(flags, recorder.last_flags);
}

test "Mail.move_message forwards id and target mailbox" {
    var recorder: Recorder = .{};
    try recorder.mail().move_message(MessageId.from_int(4), .trash);
    try testing.expectEqual(MessageId.from_int(4), recorder.last_id);
    try testing.expectEqual(Mailbox.trash, recorder.last_target);
}

test "Mail.delete_message and empty_mailbox reach the vtable" {
    var recorder: Recorder = .{};
    const mail = recorder.mail();
    try mail.delete_message(.trash, MessageId.from_int(5));
    try testing.expectEqual(MessageId.from_int(5), recorder.last_id);
    try testing.expectEqual(Mailbox.trash, recorder.last_mailbox);

    try mail.empty_mailbox(.junk);
    try testing.expectEqual(Mailbox.junk, recorder.last_mailbox);
}

test "Deps carries the mail port" {
    var recorder: Recorder = .{};
    const deps: Deps = .{ .mail = recorder.mail() };
    try testing.expectEqual(@as(u32, 0), try deps.mail.fetch(.inbox, &.{}));
    assert(recorder.fetch_calls == 1);
}
