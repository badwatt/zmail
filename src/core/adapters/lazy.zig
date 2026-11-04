//! Lazy wrappers: connect only when a port is actually used.
//!
//! Opening an IMAP (or SMTP) connection costs a TLS handshake and a login, and
//! that used to happen before the first frame was painted. With a cache, most
//! starts need no network at all; when they do, the connection is attempted at
//! the first call and its failure becomes an ordinary port error instead of a
//! reason not to start.
//!
//! Both wrappers keep the *opener* outside: the process boundary owns the
//! sockets, the password, and the error messages.

const std = @import("std");
const assert = std.debug.assert;

const mail_port = @import("../ports/mail.zig");
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Message = @import("../domain/message.zig").Message;
const MessageId = @import("../domain/id.zig").MessageId;
const Flags = @import("../domain/message.zig").Flags;
const outbox_port = @import("../ports/outbox.zig");
const Outgoing = @import("../domain/outgoing.zig").Outgoing;

/// Connection state shared by both wrappers: a failed attempt is not cached,
/// so the next call (an explicit refresh) tries again.
pub const LazyMail = struct {
    context: *anyopaque,
    open_fn: *const fn (context: *anyopaque) mail_port.Error!mail_port.Mail,
    close_fn: *const fn (context: *anyopaque) void,
    inner: ?mail_port.Mail = null,

    pub fn mail(self: *LazyMail) mail_port.Mail {
        return .{ .context = self, .vtable = &.{
            .connected = connectedThunk,
            .fetch = fetchThunk,
            .fetch_body = fetchBodyThunk,
            .fetch_raw = fetchRawThunk,
            .set_flags = setFlagsThunk,
            .move_message = moveThunk,
            .delete_message = deleteThunk,
            .empty_mailbox = emptyThunk,
        } };
    }

    pub fn connected(self: *const LazyMail) bool {
        return self.inner != null;
    }

    pub fn close(self: *LazyMail) void {
        if (self.inner != null) self.close_fn(self.context);
        self.inner = null;
    }

    fn ensure(self: *LazyMail) mail_port.Error!mail_port.Mail {
        if (self.inner) |opened| return opened;
        const opened = self.open_fn(self.context) catch |err| return err;
        self.inner = opened;
        return opened;
    }

    fn connectedThunk(context: *anyopaque) bool {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        return self.connected();
    }

    fn fetchThunk(context: *anyopaque, mailbox: Mailbox, out: []Message) mail_port.Error!u32 {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        return (try self.ensure()).fetch(mailbox, out);
    }

    fn fetchBodyThunk(
        context: *anyopaque,
        mailbox: Mailbox,
        id: MessageId,
        out: []u8,
    ) mail_port.Error![]const u8 {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        return (try self.ensure()).fetch_body(mailbox, id, out);
    }

    fn fetchRawThunk(
        context: *anyopaque,
        mailbox: Mailbox,
        id: MessageId,
        out: []u8,
    ) mail_port.Error![]const u8 {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        return (try self.ensure()).fetch_raw(mailbox, id, out);
    }

    fn setFlagsThunk(context: *anyopaque, id: MessageId, flags: Flags) mail_port.Error!void {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        return (try self.ensure()).set_flags(id, flags);
    }

    fn deleteThunk(context: *anyopaque, mailbox: Mailbox, id: MessageId) mail_port.Error!void {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        return (try self.ensure()).delete_message(mailbox, id);
    }

    fn emptyThunk(context: *anyopaque, mailbox: Mailbox) mail_port.Error!void {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        return (try self.ensure()).empty_mailbox(mailbox);
    }

    fn moveThunk(context: *anyopaque, id: MessageId, to: Mailbox) mail_port.Error!void {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        return (try self.ensure()).move_message(id, to);
    }
};

pub const LazyOutbox = struct {
    context: *anyopaque,
    open_fn: *const fn (context: *anyopaque) outbox_port.Error!outbox_port.Outbox,
    close_fn: *const fn (context: *anyopaque) void,
    inner: ?outbox_port.Outbox = null,

    pub fn outbox(self: *LazyOutbox) outbox_port.Outbox {
        return .{ .context = self, .vtable = &.{ .send = sendThunk } };
    }

    pub fn connected(self: *const LazyOutbox) bool {
        return self.inner != null;
    }

    pub fn close(self: *LazyOutbox) void {
        if (self.inner != null) self.close_fn(self.context);
        self.inner = null;
    }

    fn ensure(self: *LazyOutbox) outbox_port.Error!outbox_port.Outbox {
        if (self.inner) |opened| return opened;
        const opened = self.open_fn(self.context) catch return error.Unavailable;
        self.inner = opened;
        return opened;
    }

    fn sendThunk(context: *anyopaque, message: *const Outgoing) outbox_port.Error!void {
        const self: *LazyOutbox = @ptrCast(@alignCast(context));
        return (try self.ensure()).send(message);
    }
};

const testing = std.testing;
const MemoryMail = @import("memory_mail.zig").MemoryMail;
const AccountId = @import("../domain/id.zig").AccountId;

const Opener = struct {
    mail: MemoryMail = MemoryMail.init(),
    opens: u32 = 0,
    closes: u32 = 0,
    fail: bool = false,

    fn openMail(context: *anyopaque) mail_port.Error!mail_port.Mail {
        const self: *Opener = @ptrCast(@alignCast(context));
        self.opens += 1;
        if (self.fail) return error.Unavailable;
        return self.mail.mail();
    }

    fn closeMail(context: *anyopaque) void {
        const self: *Opener = @ptrCast(@alignCast(context));
        self.closes += 1;
    }

    fn lazy(self: *Opener) LazyMail {
        return .{ .context = self, .open_fn = openMail, .close_fn = closeMail };
    }
};

test "lazy mail: the first call opens, later calls reuse the connection" {
    var opener: Opener = .{};
    var lazy = opener.lazy();
    defer lazy.close();

    var message = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(1) };
    try opener.mail.seed(&message);

    try testing.expect(!lazy.mail().connected());

    var out: [4]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try lazy.mail().fetch(.inbox, &out));
    try testing.expectEqual(@as(u32, 1), opener.opens);
    try testing.expect(lazy.connected());
    try testing.expect(lazy.mail().connected());

    try testing.expectEqual(@as(u32, 1), try lazy.mail().fetch(.inbox, &out));
    try testing.expectEqual(@as(u32, 1), opener.opens);

    lazy.close();
    try testing.expect(!lazy.connected());
    try testing.expectEqual(@as(u32, 1), opener.closes);
}

test "lazy mail: the raw message goes through the opened connection" {
    var opener: Opener = .{};
    var lazy = opener.lazy();
    defer lazy.close();
    var message = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(1) };
    try opener.mail.seed(&message);

    var out: [64]u8 = undefined;
    const raw = try lazy.mail().fetch_raw(.inbox, MessageId.from_int(1), &out);
    try testing.expectEqual(@as(u32, 1), opener.opens);
    try testing.expect(raw.len > 0);
}

test "lazy mail: a failed open is Unavailable and is retried next time" {
    var opener: Opener = .{ .fail = true };
    var lazy = opener.lazy();
    defer lazy.close();

    var out: [1]Message = undefined;
    try testing.expectError(error.Unavailable, lazy.mail().fetch(.inbox, &out));
    var body_out: [8]u8 = undefined;
    try testing.expectError(
        error.Unavailable,
        lazy.mail().fetch_body(.inbox, MessageId.from_int(1), &body_out),
    );
    try testing.expectEqual(@as(u32, 2), opener.opens);
    try testing.expect(!lazy.connected());

    opener.fail = false;
    var body: [8]u8 = undefined;
    var message = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(1) };
    try opener.mail.seed(&message);
    _ = lazy.mail().fetch(.inbox, &out) catch {};
    _ = lazy.mail().fetch_body(.inbox, MessageId.from_int(1), &body) catch {};
    try testing.expectEqual(@as(u32, 3), opener.opens);
}

test "lazy mail: delete and empty go through the opened connection" {
    var opener: Opener = .{};
    var lazy = opener.lazy();
    defer lazy.close();

    var message = Message{
        .id = MessageId.from_int(1),
        .account = AccountId.from_int(1),
        .mailbox = .trash,
    };
    try opener.mail.seed(&message);

    try lazy.mail().delete_message(.trash, MessageId.from_int(1));
    try testing.expectEqual(@as(u32, 1), opener.opens);
    try testing.expect(opener.mail.find(MessageId.from_int(1)) == null);

    try lazy.mail().empty_mailbox(.trash);
}

test "lazy mail: flags and moves go through the opened connection" {
    var opener: Opener = .{};
    var lazy = opener.lazy();
    defer lazy.close();

    var message = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(1) };
    try opener.mail.seed(&message);

    try lazy.mail().set_flags(MessageId.from_int(1), .{ .unread = false });
    try lazy.mail().move_message(MessageId.from_int(1), .trash);
    try testing.expectEqual(@as(u32, 1), opener.opens);
    try testing.expectEqual(Mailbox.trash, opener.mail.find(MessageId.from_int(1)).?.mailbox);
}

const OutboxOpener = struct {
    opens: u32 = 0,
    fail: bool = false,
    fake: FakeOutbox = .{},

    const FakeOutbox = struct {
        sends: u32 = 0,

        fn sendThunk(context: *anyopaque, _: *const Outgoing) outbox_port.Error!void {
            const self: *FakeOutbox = @ptrCast(@alignCast(context));
            self.sends += 1;
        }

        fn outbox(self: *FakeOutbox) outbox_port.Outbox {
            return .{ .context = self, .vtable = &.{ .send = sendThunk } };
        }
    };

    fn openOutbox(context: *anyopaque) outbox_port.Error!outbox_port.Outbox {
        const self: *OutboxOpener = @ptrCast(@alignCast(context));
        self.opens += 1;
        if (self.fail) return error.Unavailable;
        return self.fake.outbox();
    }

    fn closeOutbox(_: *anyopaque) void {}

    fn lazy(self: *OutboxOpener) LazyOutbox {
        return .{ .context = self, .open_fn = openOutbox, .close_fn = closeOutbox };
    }
};

test "lazy outbox: sending opens once, and a failure is retried" {
    var opener: OutboxOpener = .{ .fail = true };
    var lazy = opener.lazy();
    defer lazy.close();

    var message = Outgoing{};
    try testing.expectError(error.Unavailable, lazy.outbox().send(&message));
    try testing.expectEqual(@as(u32, 1), opener.opens);

    opener.fail = false;
    try lazy.outbox().send(&message);
    try lazy.outbox().send(&message);
    try testing.expectEqual(@as(u32, 2), opener.opens);
    try testing.expectEqual(@as(u32, 2), opener.fake.sends);
    try testing.expect(lazy.connected());

    lazy.close();
    try testing.expect(!lazy.connected());
}
