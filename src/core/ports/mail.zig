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
const AccountId = @import("../domain/id.zig").AccountId;

/// One folder, as the server listed it, with the numbers it reports about
/// itself when the server said them.
pub const Listed = struct {
    /// The name the server knows the folder by: what a port call must send.
    name: []const u8,
    /// What to show instead, when the name carries a namespace that is only
    /// layout ("[Gmail]/All Mail" is "All Mail"). Empty means the name itself.
    title: []const u8 = "",
    canonical: ?Mailbox = null,
    unread: u32 = 0,
};

/// Which folder. A canonical mailbox is named by the mailbox the app knows;
/// every other folder by the name the server gave it, which is the whole address
/// a folder has on the wire. The port is already one account's.
pub const Place = struct {
    mailbox: ?Mailbox = null,
    name: []const u8 = "",

    pub const inbox: Place = .{ .mailbox = .inbox };
    pub const sent: Place = .{ .mailbox = .sent };
    pub const drafts: Place = .{ .mailbox = .drafts };
    pub const archive: Place = .{ .mailbox = .archive };
    pub const trash: Place = .{ .mailbox = .trash };
    pub const junk: Place = .{ .mailbox = .junk };

    /// A folder the six do not cover: the server's own name for it.
    pub fn named(name: []const u8) Place {
        return .{ .name = name };
    }

    pub fn is_named(self: Place) bool {
        return self.mailbox == null;
    }
};

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

    /// Most ports are connected the moment they exist.
    fn alwaysConnected(_: *anyopaque) bool {
        return true;
    }

    /// A port with no folder list of its own: nothing to add to the sidebar.
    fn no_folders(_: *anyopaque, _: []Listed) Error!u32 {
        return 0;
    }

    pub const VTable = struct {
        /// Whether this connection is already open. A port that opens lazily
        /// reports false until its first use, so the caller can open it on the
        /// thread that owns the transport instead of discovering it in a worker.
        connected: *const fn (context: *anyopaque) bool = alwaysConnected,
        /// Copies the envelope (headers only, never bodies) of `mailbox` into
        /// `out`, newest first, and returns how many were written. If `out` is
        /// too small, the oldest messages are dropped.
        /// The folders the server has, once it has said. A port that never
        /// lists (the demo's memory mail says all it knows) returns 0.
        folders: *const fn (context: *anyopaque, out: []Listed) Error!u32 = no_folders,
        fetch: *const fn (context: *anyopaque, place: Place, out: []Message) Error!u32,
        /// Copies the displayable text of `id` (which lives in `mailbox`) into
        /// `out` and returns the written slice. Bodies are fetched on demand and
        /// never cached in envelopes. UIDs are per mailbox, so the mailbox is
        /// part of the address.
        fetch_body: *const fn (context: *anyopaque, place: Place, id: MessageId, out: []u8) Error![]const u8,
        /// The message as the server sent it: the reader renders text and HTML
        /// from the same bytes, so switching views costs no second fetch.
        fetch_raw: *const fn (context: *anyopaque, place: Place, id: MessageId, out: []u8) Error![]const u8,
        set_flags: *const fn (context: *anyopaque, place: Place, id: MessageId, flags: Flags) Error!void,
        move_message: *const fn (context: *anyopaque, place: Place, id: MessageId, to: Place) Error!void,
        /// Removes a message for good: mark deleted, then expunge.
        delete_message: *const fn (context: *anyopaque, place: Place, id: MessageId) Error!void,
        /// Removes every message in a folder for good.
        empty_mailbox: *const fn (context: *anyopaque, place: Place) Error!void,
    };

    pub fn connected(self: Mail) bool {
        return self.vtable.connected(self.context);
    }

    pub fn folders(self: Mail, out: []Listed) Error!u32 {
        return self.vtable.folders(self.context, out);
    }

    pub fn fetch(self: Mail, place: Place, out: []Message) Error!u32 {
        return self.vtable.fetch(self.context, place, out);
    }

    pub fn fetch_body(self: Mail, place: Place, id: MessageId, out: []u8) Error![]const u8 {
        return self.vtable.fetch_body(self.context, place, id, out);
    }

    pub fn fetch_raw(self: Mail, place: Place, id: MessageId, out: []u8) Error![]const u8 {
        return self.vtable.fetch_raw(self.context, place, id, out);
    }

    pub fn set_flags(self: Mail, place: Place, id: MessageId, flags: Flags) Error!void {
        return self.vtable.set_flags(self.context, place, id, flags);
    }

    pub fn move_message(self: Mail, place: Place, id: MessageId, to: Place) Error!void {
        return self.vtable.move_message(self.context, place, id, to);
    }

    pub fn delete_message(self: Mail, place: Place, id: MessageId) Error!void {
        return self.vtable.delete_message(self.context, place, id);
    }

    pub fn empty_mailbox(self: Mail, place: Place) Error!void {
        return self.vtable.empty_mailbox(self.context, place);
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
    last_place: Place = .{},
    last_folders_out: u32 = 0,
    last_id: MessageId = .unknown,
    last_flags: Flags = .{},
    last_target: Mailbox = .inbox,
    fetch_calls: u32 = 0,
    fetch_error: ?Error = null,

    fn mail(self: *Recorder) Mail {
        return .{ .context = self, .vtable = &.{
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

    fn fetchThunk(context: *anyopaque, place: Place, out: []Message) Error!u32 {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.fetch_calls += 1;
        self.last_place = place;
        if (self.fetch_error) |err| return err;
        if (out.len == 0) return 0;
        out[0] = .{ .id = MessageId.from_int(1) };
        return 1;
    }

    fn fetchBodyThunk(context: *anyopaque, place: Place, id: MessageId, out: []u8) Error![]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_place = place;
        if (out.len == 0) return "";
        out[0] = 'x';
        return out[0..1];
    }

    fn fetchRawThunk(context: *anyopaque, place: Place, id: MessageId, out: []u8) Error![]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_place = place;
        if (out.len < 3) return "";
        @memcpy(out[0..3], "raw");
        return out[0..3];
    }

    fn setFlagsThunk(context: *anyopaque, _: Place, id: MessageId, flags: Flags) Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_flags = flags;
    }

    fn deleteThunk(context: *anyopaque, place: Place, id: MessageId) Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_place = place;
    }

    fn emptyThunk(context: *anyopaque, place: Place) Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_place = place;
    }

    fn moveThunk(context: *anyopaque, _: Place, id: MessageId, to: Place) Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.last_id = id;
        self.last_target = to.mailbox orelse .inbox;
    }

    fn foldersThunk(context: *anyopaque, out: []Listed) Error!u32 {
        const self: *Recorder = @ptrCast(@alignCast(context));
        if (out.len == 0) return 0;
        out[0] = .{ .name = "Receipts" };
        self.last_folders_out = 1;
        return 1;
    }
};

test "Mail.fetch forwards the mailbox and returns the count" {
    var recorder: Recorder = .{};
    const mail = recorder.mail();

    var out: [2]Message = undefined;
    const count = try mail.fetch(Place.archive, &out);
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(u32, 1), recorder.fetch_calls);
    try testing.expectEqual(Mailbox.archive, recorder.last_place.mailbox.?);
    try testing.expectEqual(MessageId.from_int(1), out[0].id);
}

test "Mail.fetch surfaces adapter errors unchanged" {
    var recorder: Recorder = .{ .fetch_error = error.Unavailable };
    try testing.expectError(error.Unavailable, recorder.mail().fetch(Place.inbox, &.{}));
}

test "Mail.fetch with no room writes nothing and succeeds" {
    var recorder: Recorder = .{};
    try testing.expectEqual(@as(u32, 0), try recorder.mail().fetch(Place.inbox, &.{}));
}

test "Mail.fetch_body forwards the id and returns a slice into out" {
    var recorder: Recorder = .{};
    var out: [4]u8 = undefined;
    const body = try recorder.mail().fetch_body(Place.inbox, MessageId.from_int(9), &out);
    try testing.expectEqualStrings("x", body);
    try testing.expectEqual(MessageId.from_int(9), recorder.last_id);
}

test "Mail.fetch_raw forwards the same way" {
    var recorder: Recorder = .{};
    var out: [8]u8 = undefined;
    const raw = try recorder.mail().fetch_raw(Place.sent, MessageId.from_int(4), &out);
    try testing.expectEqualStrings("raw", raw);
    try testing.expectEqual(Mailbox.sent, recorder.last_place.mailbox.?);
    try testing.expectEqual(MessageId.from_int(4), recorder.last_id);
}

test "Mail.fetch_body handles an empty output buffer" {
    var recorder: Recorder = .{};
    var out: [0]u8 = undefined;
    try testing.expectEqualStrings("", try recorder.mail().fetch_body(Place.inbox, MessageId.from_int(9), &out));
}

test "Mail.set_flags forwards id and flags" {
    var recorder: Recorder = .{};
    const flags = Flags{ .unread = false, .flagged = true };
    try recorder.mail().set_flags(Place.inbox, MessageId.from_int(3), flags);
    try testing.expectEqual(MessageId.from_int(3), recorder.last_id);
    try testing.expectEqual(flags, recorder.last_flags);
}

test "Mail.move_message forwards id and target mailbox" {
    var recorder: Recorder = .{};
    try recorder.mail().move_message(Place.inbox, MessageId.from_int(4), Place.trash);
    try testing.expectEqual(MessageId.from_int(4), recorder.last_id);
    try testing.expectEqual(Mailbox.trash, recorder.last_target);
}

test "Mail.delete_message and empty_mailbox reach the vtable" {
    var recorder: Recorder = .{};
    const mail = recorder.mail();
    try mail.delete_message(Place.trash, MessageId.from_int(5));
    try testing.expectEqual(MessageId.from_int(5), recorder.last_id);
    try testing.expectEqual(Mailbox.trash, recorder.last_place.mailbox.?);

    try mail.empty_mailbox(Place.junk);
    try testing.expectEqual(Mailbox.junk, recorder.last_place.mailbox.?);
}

test "Deps carries the mail port" {
    var recorder: Recorder = .{};
    const deps: Deps = .{ .mail = recorder.mail() };
    try testing.expectEqual(@as(u32, 0), try deps.mail.fetch(Place.inbox, &.{}));
    assert(recorder.fetch_calls == 1);
}

test "Place: a canonical mailbox and a named folder are told apart" {
    try testing.expect(!Place.inbox.is_named());
    try testing.expectEqual(Mailbox.inbox, Place.inbox.mailbox.?);
    const named = Place.named("Clients");
    try testing.expect(named.is_named());
    try testing.expectEqualStrings("Clients", named.name);
    try testing.expectEqual(@as(?Mailbox, null), named.mailbox);
}

test "Mail.folders reports nothing when a port does not list" {
    var recorder: Recorder = .{};
    var out: [4]Listed = undefined;
    // The recorder has a list; a port that does not declare one gets the default.
    try testing.expectEqual(@as(u32, 1), try recorder.mail().folders(&out));
    try testing.expectEqualStrings("Receipts", out[0].name);

    const plain = Mail{ .context = &recorder, .vtable = &.{
        .fetch = Recorder.fetchThunk,
        .fetch_body = Recorder.fetchBodyThunk,
        .fetch_raw = Recorder.fetchRawThunk,
        .set_flags = Recorder.setFlagsThunk,
        .move_message = Recorder.moveThunk,
        .delete_message = Recorder.deleteThunk,
        .empty_mailbox = Recorder.emptyThunk,
    } };
    try testing.expectEqual(@as(u32, 0), try plain.folders(&out));
}

test "a port that does not open lazily still answers open" {
    var recorder: Recorder = .{};
    const plain = Mail{ .context = &recorder, .vtable = &.{
        .fetch = Recorder.fetchThunk,
        .fetch_body = Recorder.fetchBodyThunk,
        .fetch_raw = Recorder.fetchRawThunk,
        .set_flags = Recorder.setFlagsThunk,
        .move_message = Recorder.moveThunk,
        .delete_message = Recorder.deleteThunk,
        .empty_mailbox = Recorder.emptyThunk,
    } };
    // A port with no folder list of its own says so instead of inventing one.
    var out: [4]Listed = undefined;
    try testing.expectEqual(@as(u32, 0), try plain.folders(&out));
    // And one that says nothing about its connection is connected: the demo's
    // mail has no socket to be missing.
    try testing.expect(plain.connected());
}
