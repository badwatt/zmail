//! The IMAP adapter: the `Mail` port on top of the protocol client.
//!
//! It owns the conversation state (which mailbox is selected) and maps protocol
//! errors onto the port's three cases, so the application never learns about
//! IMAP tags, literals, or TLS.
//!
//! The transport (TLS over a socket) is injected; this file is tested with a
//! scripted server.

const std = @import("std");

const client_mod = @import("../protocol/imap/client.zig");
const transport_mod = @import("../ports/transport.zig");
const port = @import("../ports/mail.zig");

const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Message = @import("../domain/message.zig").Message;
const Flags = @import("../domain/message.zig").Flags;
const MessageId = @import("../domain/id.zig").MessageId;

pub const ImapMail = struct {
    client: client_mod.Client,
    selected: ?Mailbox = null,
    exists: u32 = 0,

    /// Logs in. The caller owns the transport from here on.
    pub fn open(transport: transport_mod.Transport, user: []const u8, password: []const u8) client_mod.Error!ImapMail {
        var imap = ImapMail{ .client = client_mod.Client.init(transport) };
        try imap.client.login(user, password);
        return imap;
    }

    pub fn close(self: *ImapMail) void {
        self.client.logout();
        self.client.close();
    }

    pub fn mail(self: *ImapMail) port.Mail {
        return .{ .context = self, .vtable = &.{
            .fetch = fetchThunk,
            .fetch_body = fetchBodyThunk,
            .set_flags = setFlagsThunk,
            .move_message = moveThunk,
        } };
    }

    fn selectIfNeeded(self: *ImapMail, mailbox: Mailbox) port.Error!void {
        if (self.selected) |current| {
            if (current == mailbox) return;
        }
        self.exists = self.client.select(mailbox) catch |err| return mapError(err);
        self.selected = mailbox;
    }

    fn fetchThunk(context: *anyopaque, mailbox: Mailbox, out: []Message) port.Error!u32 {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        try self.selectIfNeeded(mailbox);

        const total = @min(self.exists, @as(u32, @intCast(out.len)));
        if (total == 0) return 0;
        return self.client.fetch_envelopes(mailbox, 1, total, out) catch |err| return mapError(err);
    }

    fn fetchBodyThunk(context: *anyopaque, id: MessageId, out: []u8) port.Error![]const u8 {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        return self.client.fetch_body(try uid_of(id), out) catch |err| return mapError(err);
    }

    fn setFlagsThunk(context: *anyopaque, id: MessageId, flags: Flags) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        self.client.set_flags(try uid_of(id), flags) catch |err| return mapError(err);
    }

    fn moveThunk(context: *anyopaque, id: MessageId, to: Mailbox) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        self.client.move_message(try uid_of(id), to) catch |err| return mapError(err);
    }
};

/// IMAP UIDs are 32-bit. A larger id cannot exist on the server, so it is a
/// stale reference, not a protocol error.
fn uid_of(id: MessageId) port.Error!u32 {
    return std.math.cast(u32, id.to_int()) orelse error.NotFound;
}

fn mapError(err: client_mod.Error) port.Error {
    return switch (err) {
        error.Unavailable, error.Timeout, error.ResponseTooLong => error.Unavailable,
        error.NotFound => error.NotFound,
        error.ProtocolError, error.Rejected, error.LoginFailed => error.Rejected,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Scripted = transport_mod.Scripted;

const login_ok = "a1 OK LOGIN completed\r\n";

test "open logs in and fetch selects the mailbox once" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* 2 EXISTS\r\n" ++
        "a2 OK selected\r\n" ++
        "* 1 FETCH (UID 10 ENVELOPE (NIL \"first\" ((\"Alice\" NIL \"alice\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "* 2 FETCH (UID 11 ENVELOPE (NIL \"second\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a3 OK fetched\r\n" };

    var imap = try ImapMail.open(scripted.transport(), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [8]Message = undefined;
    try testing.expectEqual(@as(u32, 2), try mail.fetch(.inbox, &messages));
    try testing.expectEqualStrings("first", messages[0].subject.slice());
    try testing.expectEqualStrings("Alice", messages[0].from.label());
    try testing.expectEqual(MessageId.from_int(10), messages[0].id);
    try testing.expectEqualStrings("second", messages[1].subject.slice());

    // The first fetch selected exactly once.
    var select_count: u32 = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, scripted.output_text(), start, "SELECT \"Inbox\"")) |position| {
        select_count += 1;
        start = position + 1;
    }
    try testing.expectEqual(@as(u32, 1), select_count);
}

test "fetch of an empty mailbox does not ask for envelopes" {
    var scripted: Scripted = .{ .input = login_ok ++ "* 0 EXISTS\r\na2 OK\r\n" };
    var imap = try ImapMail.open(scripted.transport(), "me", "pw");
    defer imap.close();

    var messages: [4]Message = undefined;
    try testing.expectEqual(@as(u32, 0), try imap.mail().fetch(.inbox, &messages));
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "FETCH") == null);
}

test "fetch truncates to the caller's buffer" {
    const script = login_ok ++
        "* 3 EXISTS\r\na2 OK\r\n" ++
        "* 1 FETCH (UID 1 ENVELOPE (NIL \"a\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "* 2 FETCH (UID 2 ENVELOPE (NIL \"b\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a3 OK\r\n";
    var scripted: Scripted = .{ .input = script };
    var imap = try ImapMail.open(scripted.transport(), "me", "pw");
    defer imap.close();

    var messages: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try imap.mail().fetch(.inbox, &messages));
    try testing.expectEqualStrings("a", messages[0].subject.slice());
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "FETCH 1:1 ") != null);
}

test "switching mailbox selects again" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* 1 EXISTS\r\na2 OK\r\n" ++
        "* 1 FETCH (UID 1)\r\na3 OK\r\n" ++
        "* 1 EXISTS\r\na4 OK\r\n" ++
        "* 1 FETCH (UID 2)\r\na5 OK\r\n" };
    var imap = try ImapMail.open(scripted.transport(), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [4]Message = undefined;
    _ = try mail.fetch(.inbox, &messages);
    _ = try mail.fetch(.archive, &messages);
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "SELECT \"Archive\"") != null);
}

test "body, flags, and move reach the right commands" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* 1 FETCH (BODY[TEXT] {2}\r\nhi)\r\na2 OK\r\n" ++
        "a3 OK\r\n" ++
        "a4 OK\r\n" };
    var imap = try ImapMail.open(scripted.transport(), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var body: [16]u8 = undefined;
    try testing.expectEqualStrings("hi", try mail.fetch_body(MessageId.from_int(7), &body));
    try mail.set_flags(MessageId.from_int(7), .{ .unread = false });
    try mail.move_message(MessageId.from_int(7), .trash);

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "UID FETCH 7") != null);
    try testing.expect(std.mem.indexOf(u8, output, "UID STORE 7 FLAGS.SILENT (\\Seen)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "UID MOVE 7 \"Trash\"") != null);
}

test "login failure is reported as Rejected through the port, and open fails" {
    var scripted: Scripted = .{ .input = "a1 NO bad credentials\r\n" };
    try testing.expectError(error.LoginFailed, ImapMail.open(scripted.transport(), "me", "wrong"));
}

test "a rejected select is NotFound, and a missing body too" {
    var rejected: Scripted = .{ .input = login_ok ++ "a2 NO [CANNOT] no\r\n" };
    var imap_rejected = try ImapMail.open(rejected.transport(), "me", "pw");
    defer imap_rejected.close();
    var messages: [1]Message = undefined;
    try testing.expectError(error.NotFound, imap_rejected.mail().fetch(.inbox, &messages));

    var missing: Scripted = .{ .input = login_ok ++ "* 1 EXISTS\r\na2 OK\r\na3 OK\r\n" };
    var imap_missing = try ImapMail.open(missing.transport(), "me", "pw");
    defer imap_missing.close();
    var body: [8]u8 = undefined;
    try testing.expectError(error.NotFound, imap_missing.mail().fetch_body(MessageId.from_int(9), &body));
}

test "every client error maps onto one of the port's three cases" {
    try testing.expectEqual(port.Error.Unavailable, mapError(error.Unavailable));
    try testing.expectEqual(port.Error.Unavailable, mapError(error.Timeout));
    try testing.expectEqual(port.Error.Unavailable, mapError(error.ResponseTooLong));
    try testing.expectEqual(port.Error.NotFound, mapError(error.NotFound));
    try testing.expectEqual(port.Error.Rejected, mapError(error.ProtocolError));
    try testing.expectEqual(port.Error.Rejected, mapError(error.Rejected));
    try testing.expectEqual(port.Error.Rejected, mapError(error.LoginFailed));
}

test "close logs out and closes the transport" {
    var scripted: Scripted = .{ .input = login_ok ++ "* BYE bye\r\na2 OK\r\n" };
    var imap = try ImapMail.open(scripted.transport(), "me", "pw");
    imap.close();
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "LOGOUT") != null);
    try testing.expectEqual(@as(u32, 1), scripted.close_calls);
}
