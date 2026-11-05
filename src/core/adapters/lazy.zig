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

const port = @import("../ports/mail.zig");
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
    open_fn: *const fn (context: *anyopaque) port.Error!port.Mail,
    close_fn: *const fn (context: *anyopaque) void,
    inner: ?port.Mail = null,

    pub fn mail(self: *LazyMail) port.Mail {
        return .{ .context = self, .vtable = &.{
            .connected = connectedThunk,
            .folders = foldersThunk,
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

    fn ensure(self: *LazyMail) port.Error!port.Mail {
        if (self.inner) |opened| return opened;
        // Keep the reason: a rejected login must be reported as such, not as a
        // generic "could not load".
        const opened = self.open_fn(self.context) catch |err| return err;
        self.inner = opened;
        return opened;
    }

    /// Runs one port call; if the server turned out to be gone, opens it again and
    /// runs the call once more.
    ///
    /// Servers hang up: a mailbox with forty folders is forty `STATUS` commands,
    /// and Gmail answers a burst of those by closing the socket. Without this,
    /// every call after that burst failed with "could not load this message" and
    /// only a restart helped -- and mail you have already seen must open.
    fn attempt(
        self: *LazyMail,
        comptime T: type,
        args: anytype,
        comptime call: fn (@TypeOf(args), port.Mail) port.Error!T,
    ) port.Error!T {
        const opened = self.ensure() catch |err| return err;
        return call(args, opened) catch |err| {
            // One retry, on a fresh connection: a loop here would be a mail client
            // hammering a server that is down.
            if (err != error.Unavailable) return err;
            self.close();
            const again = self.ensure() catch |second| return second;
            return call(args, again);
        };
    }

    fn connectedThunk(context: *anyopaque) bool {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        return self.connected();
    }

    fn foldersThunk(context: *anyopaque, out: []port.Listed) port.Error!u32 {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        const Call = struct {
            fn run(args: @TypeOf(.{out}), opened: port.Mail) port.Error!u32 {
                return opened.folders(args[0]);
            }
        };
        return self.attempt(u32, .{out}, Call.run);
    }

    fn fetchThunk(context: *anyopaque, place: port.Place, out: []Message) port.Error!u32 {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        const Call = struct {
            fn run(args: @TypeOf(.{ place, out }), opened: port.Mail) port.Error!u32 {
                return opened.fetch(args[0], args[1]);
            }
        };
        return self.attempt(u32, .{ place, out }, Call.run);
    }

    fn fetchBodyThunk(
        context: *anyopaque,
        place: port.Place,
        id: MessageId,
        out: []u8,
    ) port.Error![]const u8 {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        const Call = struct {
            fn run(args: @TypeOf(.{ place, id, out }), opened: port.Mail) port.Error![]const u8 {
                return opened.fetch_body(args[0], args[1], args[2]);
            }
        };
        return self.attempt([]const u8, .{ place, id, out }, Call.run);
    }

    fn fetchRawThunk(
        context: *anyopaque,
        place: port.Place,
        id: MessageId,
        out: []u8,
    ) port.Error![]const u8 {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        const Call = struct {
            fn run(args: @TypeOf(.{ place, id, out }), opened: port.Mail) port.Error![]const u8 {
                return opened.fetch_raw(args[0], args[1], args[2]);
            }
        };
        return self.attempt([]const u8, .{ place, id, out }, Call.run);
    }

    fn setFlagsThunk(context: *anyopaque, place: port.Place, id: MessageId, flags: Flags) port.Error!void {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        const Call = struct {
            fn run(args: @TypeOf(.{ place, id, flags }), opened: port.Mail) port.Error!void {
                return opened.set_flags(args[0], args[1], args[2]);
            }
        };
        return self.attempt(void, .{ place, id, flags }, Call.run);
    }

    fn deleteThunk(context: *anyopaque, place: port.Place, id: MessageId) port.Error!void {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        const Call = struct {
            fn run(args: @TypeOf(.{ place, id }), opened: port.Mail) port.Error!void {
                return opened.delete_message(args[0], args[1]);
            }
        };
        return self.attempt(void, .{ place, id }, Call.run);
    }

    fn emptyThunk(context: *anyopaque, place: port.Place) port.Error!void {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        const Call = struct {
            fn run(args: @TypeOf(.{place}), opened: port.Mail) port.Error!void {
                return opened.empty_mailbox(args[0]);
            }
        };
        return self.attempt(void, .{place}, Call.run);
    }

    fn moveThunk(context: *anyopaque, place: port.Place, id: MessageId, to: port.Place) port.Error!void {
        const self: *LazyMail = @ptrCast(@alignCast(context));
        const Call = struct {
            fn run(args: @TypeOf(.{ place, id, to }), opened: port.Mail) port.Error!void {
                return opened.move_message(args[0], args[1], args[2]);
            }
        };
        return self.attempt(void, .{ place, id, to }, Call.run);
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const MemoryMail = @import("memory_mail.zig").MemoryMail;
const AccountId = @import("../domain/id.zig").AccountId;

const Opener = struct {
    mail: MemoryMail = MemoryMail.init(),
    /// When set, the connection hands out this port instead of `mail`.
    flaky: ?*Flaky = null,
    opens: u32 = 0,
    closes: u32 = 0,
    fail: bool = false,

    fn openMail(context: *anyopaque) port.Error!port.Mail {
        const self: *Opener = @ptrCast(@alignCast(context));
        self.opens += 1;
        if (self.fail) return error.Unavailable;
        if (self.flaky) |flaky| return flaky.mail();
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

    // Nothing opened yet: the session needs to know, because the thread that
    // owns the transport is the only one allowed to open it.
    try testing.expect(!lazy.mail().connected());

    var out: [4]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try lazy.mail().fetch(port.Place.inbox, &out));
    try testing.expectEqual(@as(u32, 1), opener.opens);
    try testing.expect(lazy.connected());
    try testing.expect(lazy.mail().connected());

    try testing.expectEqual(@as(u32, 1), try lazy.mail().fetch(port.Place.inbox, &out));
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
    // The reader renders text and HTML from these same bytes, so they are the
    // message itself -- and they open the connection like any other call.
    const raw = try lazy.mail().fetch_raw(port.Place.inbox, MessageId.from_int(1), &out);
    try testing.expectEqual(@as(u32, 1), opener.opens);
    try testing.expect(raw.len > 0);
}

test "lazy mail: a failed open is Unavailable and is retried next time" {
    var opener: Opener = .{ .fail = true };
    var lazy = opener.lazy();
    defer lazy.close();

    var out: [1]Message = undefined;
    try testing.expectError(error.Unavailable, lazy.mail().fetch(port.Place.inbox, &out));
    var body_out: [8]u8 = undefined;
    try testing.expectError(
        error.Unavailable,
        lazy.mail().fetch_body(port.Place.inbox, MessageId.from_int(1), &body_out),
    );
    try testing.expectEqual(@as(u32, 2), opener.opens);
    try testing.expect(!lazy.connected());

    opener.fail = false;
    var body: [8]u8 = undefined;
    var message = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(1) };
    try opener.mail.seed(&message);
    _ = lazy.mail().fetch(port.Place.inbox, &out) catch {};
    _ = lazy.mail().fetch_body(port.Place.inbox, MessageId.from_int(1), &body) catch {};
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

    try lazy.mail().delete_message(port.Place.trash, MessageId.from_int(1));
    try testing.expectEqual(@as(u32, 1), opener.opens);
    try testing.expect(opener.mail.find(MessageId.from_int(1)) == null);

    try lazy.mail().empty_mailbox(port.Place.trash);
}

test "lazy mail: flags and moves go through the opened connection" {
    var opener: Opener = .{};
    var lazy = opener.lazy();
    defer lazy.close();

    var message = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(1) };
    try opener.mail.seed(&message);

    try lazy.mail().set_flags(port.Place.inbox, MessageId.from_int(1), .{ .unread = false });
    try lazy.mail().move_message(port.Place.inbox, MessageId.from_int(1), port.Place.trash);
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

test "lazy mail: the folder list goes through the opened connection" {
    var opener: Opener = .{};
    var lazy = opener.lazy();
    defer lazy.close();

    var out: [16]port.Listed = undefined;
    const count = try lazy.mail().folders(&out);
    try testing.expectEqual(@as(u32, 1), opener.opens);
    try testing.expect(count > 0);
    try testing.expectEqualStrings("Inbox", out[0].name);
}

test "lazy mail: a server that hung up is opened again for the same call" {
    var flaky: Flaky = .{};
    var opener = Opener{ .flaky = &flaky };
    var lazy = opener.lazy();
    defer lazy.close();
    var message = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(1) };
    try flaky.inner.seed(&message);

    var out: [4]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try lazy.mail().fetch(port.Place.inbox, &out));
    try testing.expectEqual(@as(u32, 1), opener.opens);

    // The open connection is dead: the first call on it fails with Unavailable,
    // which is what a server that hung up looks like from here.
    flaky.hang_ups = 1;
    try testing.expectEqual(@as(u32, 1), try lazy.mail().fetch(port.Place.inbox, &out));
    try testing.expectEqual(@as(u32, 2), opener.opens);

    // A rejection is the server saying no, not a hang-up: no second attempt.
    flaky.reject = true;
    try testing.expectError(error.Rejected, lazy.mail().fetch(port.Place.inbox, &out));
    try testing.expectEqual(@as(u32, 2), opener.opens);

    // Every call recovers the same way, not just the one that shows the list.
    flaky.reject = false;
    flaky.hang_ups = 1;
    var body: [64]u8 = undefined;
    _ = try lazy.mail().fetch_raw(port.Place.inbox, MessageId.from_int(1), &body);
    try testing.expectEqual(@as(u32, 3), opener.opens);
    try lazy.mail().set_flags(port.Place.inbox, MessageId.from_int(1), .{ .unread = false });
    try lazy.mail().move_message(port.Place.inbox, MessageId.from_int(1), port.Place.archive);
    // It is in Archive now, and only there: the same call in Trash is a NotFound,
    // which is the server's answer and not something to retry.
    try lazy.mail().empty_mailbox(port.Place.trash);
    try lazy.mail().delete_message(port.Place.archive, MessageId.from_int(1));
}

/// A mail port that hangs up (or refuses) on demand, so the lazy wrapper has
/// something to recover from.
const Flaky = struct {
    inner: MemoryMail = MemoryMail.init(),
    hang_ups: u32 = 0,
    reject: bool = false,

    fn answer(self: *Flaky) ?port.Error {
        if (self.reject) return error.Rejected;
        if (self.hang_ups > 0) {
            self.hang_ups -= 1;
            return error.Unavailable;
        }
        return null;
    }

    fn mail(self: *Flaky) port.Mail {
        return .{ .context = self, .vtable = &.{
            .fetch = fetchThunk,
            .fetch_body = fetchRawThunk,
            .fetch_raw = fetchRawThunk,
            .set_flags = setFlagsThunk,
            .move_message = moveThunk,
            .delete_message = deleteThunk,
            .empty_mailbox = emptyThunk,
        } };
    }

    fn fetchThunk(context: *anyopaque, place: port.Place, out: []Message) port.Error!u32 {
        const self: *Flaky = @ptrCast(@alignCast(context));
        if (self.answer()) |err| return err;
        return self.inner.mail().fetch(place, out);
    }

    fn fetchRawThunk(context: *anyopaque, place: port.Place, id: MessageId, out: []u8) port.Error![]const u8 {
        const self: *Flaky = @ptrCast(@alignCast(context));
        if (self.answer()) |err| return err;
        return self.inner.mail().fetch_raw(place, id, out);
    }

    fn setFlagsThunk(context: *anyopaque, place: port.Place, id: MessageId, flags: Flags) port.Error!void {
        const self: *Flaky = @ptrCast(@alignCast(context));
        if (self.answer()) |err| return err;
        return self.inner.mail().set_flags(place, id, flags);
    }

    fn moveThunk(context: *anyopaque, place: port.Place, id: MessageId, to: port.Place) port.Error!void {
        const self: *Flaky = @ptrCast(@alignCast(context));
        if (self.answer()) |err| return err;
        return self.inner.mail().move_message(place, id, to);
    }

    fn deleteThunk(context: *anyopaque, place: port.Place, id: MessageId) port.Error!void {
        const self: *Flaky = @ptrCast(@alignCast(context));
        if (self.answer()) |err| return err;
        return self.inner.mail().delete_message(place, id);
    }

    fn emptyThunk(context: *anyopaque, place: port.Place) port.Error!void {
        const self: *Flaky = @ptrCast(@alignCast(context));
        if (self.answer()) |err| return err;
        return self.inner.mail().empty_mailbox(place);
    }
};
