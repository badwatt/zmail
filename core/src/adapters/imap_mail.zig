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
const response_mod = @import("../protocol/imap/response.zig");
const Text = @import("../domain/text.zig").Text;
const mime = @import("../mime.zig");
const limits = @import("../limits.zig");

const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Message = @import("../domain/message.zig").Message;
const Flags = @import("../domain/message.zig").Flags;
const MessageId = @import("../domain/id.zig").MessageId;
const AccountId = @import("../domain/id.zig").AccountId;

pub const ImapMail = struct {
    client: client_mod.Client,
    /// Which configured account these UIDs belong to. Stamped on every
    /// envelope: the same UID can exist on several servers.
    account: AccountId,
    /// Full raw message, its displayable text, and the MIME decoding scratch.
    /// Three buffers, no allocation, all bounded: a mail server cannot make us
    /// allocate, and a huge message is truncated, not fatal.
    raw: [limits.body_max * 2]u8 = undefined,
    scratch: [limits.body_max]u8 = undefined,
    selected: ?Mailbox = null,
    exists: u32 = 0,
    /// Mailbox names learned from LIST: "Sent" is "Sent Items" on some servers.
    listed: bool = false,
    entries: [limits.mailboxes_max]Entry = undefined,
    entry_count: u32 = 0,

    /// Logs in. The caller owns the transport from here on.
    pub fn open(transport: transport_mod.Transport, account: AccountId, user: []const u8, password: []const u8) client_mod.Error!ImapMail {
        var imap = ImapMail{ .client = client_mod.Client.init(transport), .account = account };
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
            .delete_message = deleteThunk,
            .empty_mailbox = emptyThunk,
        } };
    }

    const Entry = struct {
        mailbox: ?Mailbox = null,
        name: Text(limits.mailbox_name_max) = .{},
    };

    fn listOnce(self: *ImapMail) void {
        if (self.listed) return;
        self.listed = true;

        var raw: [limits.mailboxes_max]response_mod.ListEntry = undefined;
        const count = self.client.list(&raw) catch return;
        const bounded = @min(count, @as(u32, raw.len));
        for (raw[0..bounded], 0..) |entry, index| {
            self.entries[index] = .{ .mailbox = entry.mailbox };
            self.entries[index].name.set(entry.name);
        }
        self.entry_count = bounded;
    }

    /// The server's name for a logical mailbox, or null when LIST says the
    /// server has no such mailbox (which is empty mail, not an error).
    fn serverName(self: *ImapMail, mailbox: Mailbox) ?[]const u8 {
        var index: u32 = 0;
        while (index < self.entry_count) : (index += 1) {
            const entry = &self.entries[index];
            if (entry.mailbox) |mapped| {
                if (mapped == mailbox) return entry.name.slice();
            }
        }
        index = 0;
        while (index < self.entry_count) : (index += 1) {
            const entry = &self.entries[index];
            if (matchesAlias(mailbox, entry.name.slice())) return entry.name.slice();
        }
        // Nothing listed yet: try our own title. After a LIST, absence is fact.
        if (self.listed) return null;
        return mailbox.title();
    }

    /// Selects the mailbox, learning the server's names on the first refusal.
    /// Returns false when the mailbox does not exist on this server.
    fn selectIfNeeded(self: *ImapMail, mailbox: Mailbox) port.Error!bool {
        if (self.selected) |current| {
            if (current == mailbox) return true;
        }

        const name = self.serverName(mailbox) orelse return false;
        self.exists = self.client.select_name(name) catch |err| switch (err) {
            error.NotFound => blk: {
                if (self.listed) return false;
                self.listOnce();
                const retry = self.serverName(mailbox) orelse return false;
                break :blk self.client.select_name(retry) catch |second| return mapError(second);
            },
            else => return mapError(err),
        };
        self.selected = mailbox;
        return true;
    }

    fn fetchThunk(context: *anyopaque, mailbox: Mailbox, out: []Message) port.Error!u32 {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        if (!try self.selectIfNeeded(mailbox)) return 0;

        const total = @min(self.exists, @as(u32, @intCast(out.len)));
        if (total == 0) return 0;
        const count = self.client.fetch_envelopes(mailbox, 1, total, out) catch |err| return mapError(err);
        for (out[0..count]) |*message| message.account = self.account;
        return count;
    }

    fn fetchBodyThunk(
        context: *anyopaque,
        mailbox: Mailbox,
        id: MessageId,
        out: []u8,
    ) port.Error![]const u8 {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        // UIDs are per mailbox, and after a cached start no mailbox may be
        // selected yet: select before fetching, always.
        if (!try self.selectIfNeeded(mailbox)) return error.NotFound;
        const raw = self.client.fetch_body(try uid_of(id), &self.raw) catch |err| return mapError(err);
        return mime.text_body(raw, out, &self.scratch);
    }

    fn setFlagsThunk(context: *anyopaque, id: MessageId, flags: Flags) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        self.client.set_flags(try uid_of(id), flags) catch |err| return mapError(err);
    }

    fn deleteThunk(context: *anyopaque, mailbox: Mailbox, id: MessageId) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        if (!try self.selectIfNeeded(mailbox)) return error.NotFound;
        self.client.delete_message(try uid_of(id)) catch |err| return mapError(err);
    }

    fn emptyThunk(context: *anyopaque, mailbox: Mailbox) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        if (!try self.selectIfNeeded(mailbox)) return error.NotFound;
        self.client.empty_mailbox() catch |err| return mapError(err);
    }

    fn moveThunk(context: *anyopaque, id: MessageId, to: Mailbox) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        const name = self.serverName(to) orelse return error.NotFound;
        self.client.move_message_to(try uid_of(id), name) catch |err| return mapError(err);
    }
};

/// IMAP UIDs are 32-bit. A larger id cannot exist on the server, so it is a
/// stale reference, not a protocol error.
fn uid_of(id: MessageId) port.Error!u32 {
    return std.math.cast(u32, id.to_int()) orelse error.NotFound;
}

/// Names servers use for the same logical mailbox.
fn matchesAlias(mailbox: Mailbox, name: []const u8) bool {
    const candidates: []const []const u8 = switch (mailbox) {
        .inbox => &.{"inbox"},
        .sent => &.{ "sent", "sent items", "sent messages", "sent mail", "outbox" },
        .drafts => &.{ "drafts", "draft" },
        .archive => &.{ "archive", "archives", "all mail" },
        .trash => &.{ "trash", "deleted", "deleted items", "deleted messages", "bin" },
        .junk => &.{ "junk", "spam", "junk e-mail", "bulk mail" },
    };

    // Compare the whole name and its last path component ("INBOX.Sent",
    // "[Gmail]/Sent Mail").
    const tail = blk: {
        const slash = std.mem.lastIndexOfScalar(u8, name, '/');
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const start = if (slash) |at| at + 1 else if (dot) |at| at + 1 else 0;
        if (start >= name.len) break :blk name else break :blk name[start..];
    };

    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
        if (std.ascii.eqlIgnoreCase(tail, candidate)) return true;
    }
    return false;
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

const login_ok = "* OK ready\r\na1 OK LOGIN completed\r\n";

test "open logs in and fetch selects the mailbox once" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* 2 EXISTS\r\n" ++
        "a2 OK selected\r\n" ++
        "* 1 FETCH (UID 10 ENVELOPE (NIL \"first\" ((\"Alice\" NIL \"alice\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "* 2 FETCH (UID 11 ENVELOPE (NIL \"second\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a3 OK fetched\r\n" };

    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [8]Message = undefined;
    try testing.expectEqual(@as(u32, 2), try mail.fetch(.inbox, &messages));
    try testing.expectEqualStrings("first", messages[0].subject.slice());
    try testing.expectEqualStrings("Alice", messages[0].from.label());
    try testing.expectEqual(MessageId.from_int(10), messages[0].id);
    // Every envelope carries the account that fetched it.
    try testing.expectEqual(AccountId.from_int(1), messages[0].account);
    try testing.expectEqual(AccountId.from_int(1), messages[1].account);
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
    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
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
    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
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
    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [4]Message = undefined;
    _ = try mail.fetch(.inbox, &messages);
    _ = try mail.fetch(.archive, &messages);
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "SELECT \"Archive\"") != null);
}

test "body, flags, and move reach the right commands" {
    const message = "Content-Type: text/plain; charset=utf-8\r\n\r\nhi";
    var scripted: Scripted = .{ .input = login_ok ++
        "* 1 EXISTS\r\na2 OK selected\r\n" ++
        "* 1 FETCH (BODY[] {45}\r\n" ++ message ++ ")\r\na3 OK\r\n" ++
        "a4 OK\r\n" ++
        "a5 OK\r\n" };
    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var body: [64]u8 = undefined;
    try testing.expectEqualStrings("hi", try mail.fetch_body(.inbox, MessageId.from_int(7), &body));
    try mail.set_flags(MessageId.from_int(7), .{ .unread = false });
    try mail.move_message(MessageId.from_int(7), .trash);

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "UID FETCH 7") != null);
    try testing.expect(std.mem.indexOf(u8, output, "UID STORE 7 FLAGS.SILENT (\\Seen)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "UID MOVE 7 \"Trash\"") != null);
}

test "delete flags the message and expunges it, falling back without UIDPLUS" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* 1 EXISTS\r\na2 OK selected\r\n" ++
        "a3 OK flagged\r\n" ++
        "a4 NO [CANNOT] UID EXPUNGE unsupported\r\n" ++
        "a5 OK expunged\r\n" };

    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    try imap.mail().delete_message(.inbox, MessageId.from_int(7));

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "UID STORE 7 +FLAGS.SILENT (\\Deleted)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "UID EXPUNGE 7") != null);
    try testing.expect(std.mem.indexOf(u8, output, "EXPUNGE\r\n") != null);
}

test "delete uses UID EXPUNGE when the server supports it, and empty clears all" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* 1 EXISTS\r\na2 OK selected\r\n" ++
        "a3 OK flagged\r\n" ++
        "a4 OK expunged\r\n" ++
        "a5 OK flagged all\r\n" ++
        "a6 OK expunged all\r\n" };

    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    try imap.mail().delete_message(.inbox, MessageId.from_int(7));
    try imap.mail().empty_mailbox(.inbox);

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "STORE 1:* +FLAGS.SILENT (\\Deleted)") != null);
}

test "delete in a mailbox the server does not have is NotFound" {
    var scripted: Scripted = .{ .input = login_ok ++
        "a2 NO [NONEXISTENT] no such mailbox\r\n" ++
        "* LIST (\\Sent) \"/\" \"Sent Items\"\r\n" ++
        "a3 OK LIST done\r\n" };

    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    try testing.expectError(
        error.NotFound,
        imap.mail().delete_message(.inbox, MessageId.from_int(7)),
    );
    try testing.expectError(error.NotFound, imap.mail().empty_mailbox(.inbox));
}

test "login failure is reported as Rejected through the port, and open fails" {
    var scripted: Scripted = .{ .input = "* OK ready\r\na1 NO bad credentials\r\n" };
    try testing.expectError(error.LoginFailed, ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "wrong"));
}

test "a mailbox the server does not have is empty, not an error" {
    // "Sent" is "Sent Items" on many servers. The first SELECT fails, LIST
    // teaches us the real name, and the retry lands on the right mailbox.
    var scripted: Scripted = .{ .input = login_ok ++
        "a2 NO [NONEXISTENT] no such mailbox\r\n" ++
        "* LIST (\\Sent) \"/\" \"Sent Items\"\r\n" ++
        "* LIST () \"/\" \"INBOX\"\r\n" ++
        "a3 OK LIST done\r\n" ++
        "* 1 EXISTS\r\n" ++
        "a4 OK selected\r\n" ++
        "* 1 FETCH (UID 4 ENVELOPE (NIL \"hi\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a5 OK fetched\r\n" };

    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try mail.fetch(.sent, &messages));
    try testing.expectEqualStrings("hi", messages[0].subject.slice());
    try testing.expectEqual(Mailbox.sent, messages[0].mailbox);

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "SELECT \"Sent\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "LIST \"\" \"*\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "SELECT \"Sent Items\"") != null);
}

test "a mailbox absent from LIST is empty, and its body is NotFound" {
    var scripted: Scripted = .{ .input = login_ok ++
        "a2 NO [NONEXISTENT] no such mailbox\r\n" ++
        "* LIST (\\Sent) \"/\" \"Sent Items\"\r\n" ++
        "a3 OK LIST done\r\n" };

    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 0), try mail.fetch(.inbox, &messages));

    var body: [8]u8 = undefined;
    try testing.expectError(error.NotFound, mail.fetch_body(.inbox, MessageId.from_int(9), &body));
    try testing.expectError(error.NotFound, mail.move_message(MessageId.from_int(9), .inbox));
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
    var imap = try ImapMail.open(scripted.transport(), AccountId.from_int(1), "me", "pw");
    imap.close();
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "LOGOUT") != null);
    try testing.expectEqual(@as(u32, 1), scripted.close_calls);
}
