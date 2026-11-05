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
const bodystructure = @import("../protocol/imap/bodystructure.zig");
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
    raw: [limits.body_max]u8 = undefined,
    scratch: [limits.body_max]u8 = undefined,
    selected: ?Mailbox = null,
    /// The server's name of what is selected, and whether it is one of the six.
    selected_name: Text(limits.mailbox_name_max) = .{},
    selected_named: bool = false,
    exists: u32 = 0,
    /// Mailbox names learned from LIST: "Sent" is "Sent Items" on some servers.
    listed: bool = false,
    entries: [limits.mailboxes_max]Entry = undefined,
    entry_count: u32 = 0,

    /// Logs in. The caller owns the transport from here on.
    /// Logs in, in place. The struct is megabytes -- two framers, the raw message
    /// and its scratch -- so it is never returned by value: a copy of it is a stack
    /// overflow waiting for the platform with the smaller stack, which is what macOS
    /// turned out to be.
    pub fn open(
        self: *ImapMail,
        transport: transport_mod.Transport,
        account: AccountId,
        user: []const u8,
        password: []const u8,
    ) client_mod.Error!void {
        self.* = .{ .client = client_mod.Client.init(transport), .account = account };
        try self.client.login(user, password);
    }

    /// Opens with an OAuth2 token instead of a password.
    pub fn open_token(
        self: *ImapMail,
        transport: transport_mod.Transport,
        account: AccountId,
        user: []const u8,
        token: []const u8,
    ) client_mod.Error!void {
        self.* = .{ .client = client_mod.Client.init(transport), .account = account };
        try self.client.login_token(user, token);
    }

    pub fn close(self: *ImapMail) void {
        self.client.logout();
        self.client.close();
    }

    pub fn mail(self: *ImapMail) port.Mail {
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

    const Entry = struct {
        mailbox: ?Mailbox = null,
        name: Text(limits.mailbox_name_max) = .{},
        /// What the sidebar shows: the name without the namespace that only
        /// holds it. `[Gmail]/All Mail` is a folder called "All Mail".
        title: Text(limits.mailbox_name_max) = .{},
        /// False for a name Gmail-style servers use as a heading ("[Gmail]"):
        /// it cannot be selected, so it is not a folder of its own.
        selectable: bool = true,
    };

    fn listOnce(self: *ImapMail) void {
        if (self.listed) return;
        self.listed = true;

        var raw: [limits.mailboxes_max]response_mod.ListEntry = undefined;
        const count = self.client.list(&raw) catch return;
        const bounded = @min(count, @as(u32, raw.len));
        for (raw[0..bounded], 0..) |entry, index| {
            // INBOX is Inbox by definition (RFC 3501 §5.1), whether the server
            // bothered to flag it or not: without this it becomes a folder named
            // "INBOX" that the app treats as a stranger.
            const mailbox = entry.mailbox orelse if (std.ascii.eqlIgnoreCase(entry.name, "INBOX")) Mailbox.inbox else null;
            self.entries[index] = .{ .mailbox = mailbox, .selectable = entry.selectable };
            self.entries[index].name.set(entry.name);
        }
        self.entry_count = bounded;

        // A folder under a heading shows without the heading: the row is the
        // folder, not the path to it.
        for (self.entries[0..bounded]) |*entry| {
            entry.title.set(entry.name.slice());
            for (self.entries[0..bounded]) |heading| {
                if (heading.selectable) continue;
                const prefix = heading.name.slice();
                if (entry.name.slice().len <= prefix.len + 1) continue;
                if (!std.ascii.startsWithIgnoreCase(entry.name.slice(), prefix)) continue;
                if (entry.name.slice()[prefix.len] != '/') continue;
                entry.title.set(entry.name.slice()[prefix.len + 1 ..]);
            }
        }
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

    /// Selects the folder a port call names, learning the server's names for the
    /// six mailboxes on the first refusal. Returns false when it does not exist.
    fn selectIfNeeded(self: *ImapMail, place: port.Place) port.Error!bool {
        if (place.mailbox) |mailbox| {
            if (self.selected == mailbox and !self.selected_named and !self.selected_name.is_empty()) return true;
        } else if (self.selected_named and std.mem.eql(u8, self.selected_name.slice(), place.name)) {
            return true;
        }

        if (place.mailbox) |mailbox| {
            // The caller may already know what this server calls the folder -- the
            // sidebar's list is saved for exactly that -- and then there is nothing
            // to discover: no refused SELECT, no LIST, no second round trip.
            const name = if (place.name.len > 0) place.name else self.serverName(mailbox) orelse return false;
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
            self.selected_name.set(name);
            self.selected_named = false;
            return true;
        }

        // A folder the server named itself: no aliases to try, no LIST to learn.
        self.exists = self.client.select_name(place.name) catch |err| return mapError(err);
        self.selected = null;
        self.selected_name.set(place.name);
        self.selected_named = true;
        return true;
    }

    /// The account's folders, as the server listed them.
    /// How many folders get a `STATUS` per listing. The sidebar shows the top of
    /// the list; asking about forty of them is a second of round trips for numbers
    /// nobody scrolls to.
    pub const max_status_per_listing: u8 = 8;

    fn foldersThunk(context: *anyopaque, out: []port.Listed) port.Error!u32 {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        self.listOnce();
        var index: u32 = 0;
        var written: u32 = 0;
        while (index < self.entry_count and written < out.len) : (index += 1) {
            const entry = &self.entries[index];
            // A heading holds folders; it is not one.
            if (!entry.selectable) continue;
            // The numbers come from STATUS: one round trip each, so only the top
            // of the list gets one. A folder whose count failed is still a folder:
            // zero unread, not an error that loses the list.
            const numbers = if (written < max_status_per_listing)
                self.client.status(entry.name.slice()) catch response_mod.Status{}
            else
                response_mod.Status{};
            out[written] = .{
                .name = entry.name.slice(),
                .title = entry.title.slice(),
                .canonical = entry.mailbox,
                .unread = numbers.unseen,
            };
            written += 1;
        }
        return written;
    }

    fn fetchThunk(context: *anyopaque, place: port.Place, out: []Message) port.Error!u32 {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        if (!try self.selectIfNeeded(place)) return 0;

        const total = @min(self.exists, @as(u32, @intCast(out.len)));
        if (total == 0) return 0;
        const count = self.client.fetch_envelopes(place.mailbox orelse .inbox, 1, total, out) catch |err| return mapError(err);
        for (out[0..count]) |*message| message.account = self.account;
        return count;
    }

    fn fetchBodyThunk(
        context: *anyopaque,
        place: port.Place,
        id: MessageId,
        out: []u8,
    ) port.Error![]const u8 {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        // UIDs are per mailbox, and after a cached start no mailbox may be
        // selected yet: select before fetching, always.
        if (!try self.selectIfNeeded(place)) return error.NotFound;
        const uid = try uid_of(id);

        // The words only. A message with a certificate as a PDF is a megabyte of
        // base64, and none of it is text: the shape says which part to read, and
        // asking for that part is one round trip for two sections.
        if (self.text_part(uid, out)) |text| return text else |_| {}

        const raw = self.client.fetch_body(uid, &self.raw) catch |err| return mapError(err);
        return mime.text_body(raw, out, &self.scratch);
    }

    /// The part of the message that holds the words, or an error when the shape
    /// is not understood: the caller then reads the whole message instead, which
    /// is what every server understands.
    fn text_part(self: *ImapMail, uid: u32, out: []u8) ![]const u8 {
        var structure = bodystructure.Structure{};
        try self.client.fetch_structure(uid, &structure);
        const section = structure.reading_part() orelse return error.NoTextPart;
        const part = try self.client.fetch_part(uid, section, &self.raw);
        return mime.part_body(part.mime, part.body, out, &self.scratch);
    }

    fn fetchRawThunk(
        context: *anyopaque,
        place: port.Place,
        id: MessageId,
        out: []u8,
    ) port.Error![]const u8 {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        if (!try self.selectIfNeeded(place)) return error.NotFound;
        const raw = self.client.fetch_body(try uid_of(id), &self.raw) catch |err| return mapError(err);
        // Truncate, never refuse: an attachment-heavy message is still a
        // message, and the text of it is almost always in the part that fits.
        const length = @min(raw.len, out.len);
        @memcpy(out[0..length], raw[0..length]);
        return out[0..length];
    }

    fn setFlagsThunk(context: *anyopaque, _: port.Place, id: MessageId, flags: Flags) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        self.client.set_flags(try uid_of(id), flags) catch |err| return mapError(err);
    }

    fn deleteThunk(context: *anyopaque, place: port.Place, id: MessageId) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        if (!try self.selectIfNeeded(place)) return error.NotFound;
        self.client.delete_message(try uid_of(id)) catch |err| return mapError(err);
    }

    fn emptyThunk(context: *anyopaque, place: port.Place) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        if (!try self.selectIfNeeded(place)) return error.NotFound;
        self.client.empty_mailbox() catch |err| return mapError(err);
    }

    fn moveThunk(context: *anyopaque, place: port.Place, id: MessageId, to: port.Place) port.Error!void {
        const self: *ImapMail = @ptrCast(@alignCast(context));
        if (!try self.selectIfNeeded(place)) return error.NotFound;
        const mailbox = to.mailbox orelse return error.Rejected;
        const name = self.serverName(mailbox) orelse return error.NotFound;
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

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [8]Message = undefined;
    try testing.expectEqual(@as(u32, 2), try mail.fetch(port.Place.inbox, &messages));
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
    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();

    var messages: [4]Message = undefined;
    try testing.expectEqual(@as(u32, 0), try imap.mail().fetch(port.Place.inbox, &messages));
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "FETCH") == null);
}

test "fetch truncates to the caller's buffer" {
    const script = login_ok ++
        "* 3 EXISTS\r\na2 OK\r\n" ++
        "* 1 FETCH (UID 1 ENVELOPE (NIL \"a\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "* 2 FETCH (UID 2 ENVELOPE (NIL \"b\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a3 OK\r\n";
    var scripted: Scripted = .{ .input = script };
    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();

    var messages: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try imap.mail().fetch(port.Place.inbox, &messages));
    try testing.expectEqualStrings("a", messages[0].subject.slice());
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "FETCH 1:1 ") != null);
}

test "switching mailbox selects again" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* 1 EXISTS\r\na2 OK\r\n" ++
        "* 1 FETCH (UID 1)\r\na3 OK\r\n" ++
        "* 1 EXISTS\r\na4 OK\r\n" ++
        "* 1 FETCH (UID 2)\r\na5 OK\r\n" };
    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [4]Message = undefined;
    _ = try mail.fetch(port.Place.inbox, &messages);
    _ = try mail.fetch(port.Place.archive, &messages);
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "SELECT \"Archive\"") != null);
}

test "body, flags, and move reach the right commands" {
    // The body is read through the shape: which part holds the words, then that
    // part's headers and content in one command.
    var scripted: Scripted = .{ .input = login_ok ++
        "* 1 EXISTS\r\na2 OK selected\r\n" ++
        "* 1 FETCH (UID 7 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 2 1 NIL NIL NIL NIL))\r\na3 OK\r\n" ++
        "* 1 FETCH (BODY[1.MIME] {74}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64 BODY[1] {12}\r\naGkgdGhlcmU=)\r\na4 OK\r\n" ++
        "a5 OK\r\n" ++
        "a6 OK\r\n" };
    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var body: [64]u8 = undefined;
    // The part's own headers say it is base64, and the text comes out decoded.
    try testing.expectEqualStrings("hi there", try mail.fetch_body(port.Place.inbox, MessageId.from_int(7), &body));
    try mail.set_flags(port.Place.inbox, MessageId.from_int(7), .{ .unread = false });
    try mail.move_message(port.Place.inbox, MessageId.from_int(7), port.Place.trash);

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "UID FETCH 7 (BODYSTRUCTURE)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "BODY.PEEK[1.MIME] BODY.PEEK[1]<0.") != null);
    try testing.expect(std.mem.indexOf(u8, output, "UID STORE 7 FLAGS.SILENT (\\Seen)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "UID MOVE 7 \"Trash\"") != null);
}

test "a message whose shape is not understood is read whole, not refused" {
    const message = "Content-Type: text/plain; charset=utf-8\r\n\r\nhi";
    var scripted: Scripted = .{
        .input = login_ok ++
            "* 1 EXISTS\r\na2 OK selected\r\n" ++
            // A server that answers the shape with something unreadable.
            "a3 BAD no\r\n" ++
            "* 1 FETCH (BODY[]<0> {45}\r\n" ++ message ++ ")\r\na4 OK\r\n",
    };
    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();

    var body: [64]u8 = undefined;
    try testing.expectEqualStrings("hi", try imap.mail().fetch_body(port.Place.inbox, MessageId.from_int(7), &body));
    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "BODY.PEEK[]<0.") != null);
}

test "the raw message is handed over as sent, cut to the caller's buffer" {
    const message = "Content-Type: text/plain; charset=utf-8\r\n\r\nhi";
    var scripted: Scripted = .{ .input = login_ok ++
        "* 1 EXISTS\r\na2 OK selected\r\n" ++
        "* 1 FETCH (BODY[]<0> {45}\r\n" ++ message ++ ")\r\na3 OK\r\n" ++
        "* 1 FETCH (BODY[]<0> {45}\r\n" ++ message ++ ")\r\na4 OK\r\n" };
    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();

    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(message, try imap.mail().fetch_raw(port.Place.inbox, MessageId.from_int(7), &out));

    var small: [8]u8 = undefined;
    try testing.expectEqualStrings(message[0..8], try imap.mail().fetch_raw(port.Place.inbox, MessageId.from_int(7), &small));
}

test "delete flags the message and expunges it, falling back without UIDPLUS" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* 1 EXISTS\r\na2 OK selected\r\n" ++
        "a3 OK flagged\r\n" ++
        "a4 NO [CANNOT] UID EXPUNGE unsupported\r\n" ++
        "a5 OK expunged\r\n" };

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    try imap.mail().delete_message(port.Place.inbox, MessageId.from_int(7));

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

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    try imap.mail().delete_message(port.Place.inbox, MessageId.from_int(7));
    try imap.mail().empty_mailbox(port.Place.inbox);

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "STORE 1:* +FLAGS.SILENT (\\Deleted)") != null);
}

test "delete in a mailbox the server does not have is NotFound" {
    var scripted: Scripted = .{ .input = login_ok ++
        "a2 NO [NONEXISTENT] no such mailbox\r\n" ++
        "* LIST (\\Sent) \"/\" \"Sent Items\"\r\n" ++
        "a3 OK LIST done\r\n" };

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    try testing.expectError(
        error.NotFound,
        imap.mail().delete_message(port.Place.inbox, MessageId.from_int(7)),
    );
    try testing.expectError(error.NotFound, imap.mail().empty_mailbox(port.Place.inbox));
}

test "open_token logs in with a bearer token" {
    var scripted: Scripted = .{ .input = login_ok ++ "* 1 EXISTS\r\na2 OK selected\r\n" ++
        "* 1 FETCH (UID 3 ENVELOPE (NIL \"token mail\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a3 OK fetched\r\n" };
    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open_token(imap, scripted.transport(), AccountId.from_int(1), "me", "ya29.t");
    defer imap.close();

    var messages: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try imap.mail().fetch(port.Place.inbox, &messages));
    try testing.expectEqualStrings("token mail", messages[0].subject.slice());
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "AUTHENTICATE XOAUTH2") != null);
}

test "login failure is reported as Rejected through the port, and open fails" {
    var scripted: Scripted = .{ .input = "* OK ready\r\na1 NO bad credentials\r\n" };
    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try testing.expectError(error.LoginFailed, ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "wrong"));
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

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try mail.fetch(port.Place.sent, &messages));
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

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();
    const mail = imap.mail();

    var messages: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 0), try mail.fetch(port.Place.inbox, &messages));

    var body: [8]u8 = undefined;
    try testing.expectError(error.NotFound, mail.fetch_body(port.Place.inbox, MessageId.from_int(9), &body));
    try testing.expectError(error.NotFound, mail.move_message(port.Place.inbox, MessageId.from_int(9), port.Place.inbox));
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
    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    imap.close();
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "LOGOUT") != null);
    try testing.expectEqual(@as(u32, 1), scripted.close_calls);
}

test "the folders LIST named are the ones the sidebar can show" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* LIST (\\Sent) \"/\" \"Sent Items\"\r\n" ++
        "* LIST () \"/\" \"Clients\"\r\n" ++
        "a2 OK LIST done\r\n" };

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();

    var out: [8]port.Listed = undefined;
    const count = try imap.mail().folders(&out);
    try testing.expectEqual(@as(u32, 2), count);
    // The special-use flag is what says "this is Sent", whatever the server calls it.
    try testing.expectEqualStrings("Sent Items", out[0].name);
    try testing.expectEqual(Mailbox.sent, out[0].canonical.?);
    // A folder the six do not cover has no canonical mailbox, and keeps its name.
    try testing.expectEqual(@as(?Mailbox, null), out[1].canonical);
    try testing.expectEqualStrings("Clients", out[1].name);
}

test "a folder the server named itself is selected by that name" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* 0 EXISTS\r\n" ++
        "a2 OK [READ-WRITE] selected\r\n" };

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();

    var messages: [2]Message = undefined;
    // The folder is not one of the six, so the name is the whole address.
    try testing.expectEqual(@as(u32, 0), try imap.mail().fetch(port.Place.named("Clients"), &messages));
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "SELECT \"Clients\"") != null);
}

test "a Gmail-shaped LIST gives folders, not the namespace that holds them" {
    var scripted: Scripted = .{
        .input = login_ok ++
            "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n" ++
            "* LIST (\\Noselect \\HasChildren) \"/\" \"[Gmail]\"\r\n" ++
            "* LIST (\\Drafts \\HasNoChildren) \"/\" \"[Gmail]/Drafts\"\r\n" ++
            "* LIST (\\Sent \\HasNoChildren) \"/\" \"[Gmail]/Sent Mail\"\r\n" ++
            "* LIST (\\All \\HasNoChildren) \"/\" \"[Gmail]/All Mail\"\r\n" ++
            "* LIST (\\Trash \\HasNoChildren) \"/\" \"[Gmail]/Trash\"\r\n" ++
            "a2 OK LIST done\r\n" ++
            // One STATUS per selectable folder, in the order they were listed.
            "* STATUS \"INBOX\" (UNSEEN 4 MESSAGES 100)\r\n" ++
            "a3 OK done\r\n" ++
            "* STATUS \"[Gmail]/Drafts\" (UNSEEN 0 MESSAGES 2)\r\n" ++
            "a4 OK done\r\n" ++
            "* STATUS \"[Gmail]/Sent Mail\" (UNSEEN 0 MESSAGES 9)\r\n" ++
            "a5 OK done\r\n" ++
            "* STATUS \"[Gmail]/All Mail\" (UNSEEN 7 MESSAGES 900)\r\n" ++
            "a6 OK done\r\n" ++
            "* STATUS \"[Gmail]/Trash\" (UNSEEN 0 MESSAGES 1)\r\n" ++
            "a7 OK done\r\n",
    };

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();

    var out: [8]port.Listed = undefined;
    const count = try imap.mail().folders(&out);
    // Five: the heading is not a folder, and INBOX is Inbox.
    try testing.expectEqual(@as(u32, 5), count);

    try testing.expectEqualStrings("INBOX", out[0].name);
    try testing.expectEqual(Mailbox.inbox, out[0].canonical.?);
    try testing.expectEqual(@as(u32, 4), out[0].unread);

    // The children show without the name of the heading they sit under, and keep
    // the full name for the port: that is what the server answers to.
    try testing.expectEqualStrings("[Gmail]/All Mail", out[3].name);
    try testing.expectEqualStrings("All Mail", out[3].title);
    try testing.expectEqual(@as(u32, 7), out[3].unread);
    try testing.expectEqualStrings("Sent Mail", out[2].title);
    // Nothing offers "[Gmail]" as somewhere to go.
    for (out[0..count]) |listed| {
        try testing.expect(!std.mem.eql(u8, listed.name, "[Gmail]"));
    }
}

test "a mailbox with more folders than the sidebar shows does not ask about all of them" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* LIST () \"/\" \"A\"\r\n" ++
        "* LIST () \"/\" \"B\"\r\n" ++
        "* LIST () \"/\" \"C\"\r\n" ++
        "* LIST () \"/\" \"D\"\r\n" ++
        "* LIST () \"/\" \"E\"\r\n" ++
        "* LIST () \"/\" \"F\"\r\n" ++
        "* LIST () \"/\" \"G\"\r\n" ++
        "* LIST () \"/\" \"H\"\r\n" ++
        "* LIST () \"/\" \"I\"\r\n" ++
        "* LIST () \"/\" \"J\"\r\n" ++
        "a2 OK LIST done\r\n" ++
        "* STATUS \"A\" (UNSEEN 1 MESSAGES 3)\r\n" ++ "a3 OK done\r\n" ++
        "* STATUS \"B\" (UNSEEN 2 MESSAGES 3)\r\n" ++ "a4 OK done\r\n" ++
        "* STATUS \"C\" (UNSEEN 3 MESSAGES 3)\r\n" ++ "a5 OK done\r\n" ++
        "* STATUS \"D\" (UNSEEN 4 MESSAGES 3)\r\n" ++ "a6 OK done\r\n" ++
        "* STATUS \"E\" (UNSEEN 5 MESSAGES 3)\r\n" ++ "a7 OK done\r\n" ++
        "* STATUS \"F\" (UNSEEN 6 MESSAGES 3)\r\n" ++ "a8 OK done\r\n" ++
        "* STATUS \"G\" (UNSEEN 7 MESSAGES 3)\r\n" ++ "a9 OK done\r\n" ++
        "* STATUS \"H\" (UNSEEN 8 MESSAGES 3)\r\n" ++ "a10 OK done\r\n" };

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();

    var out: [16]port.Listed = undefined;
    const count = try imap.mail().folders(&out);
    try testing.expectEqual(@as(u32, 10), count);
    // Eight asked, and the last two are folders without a number rather than
    // folders without a row.
    try testing.expectEqual(@as(u32, 8), out[ImapMail.max_status_per_listing - 1].unread);
    try testing.expectEqual(@as(u32, 0), out[ImapMail.max_status_per_listing].unread);
    try testing.expectEqualStrings("I", out[ImapMail.max_status_per_listing].name);
}

test "a folder the caller can name is selected by that name, without a LIST" {
    var scripted: Scripted = .{ .input = login_ok ++
        "* SELECT \"[Gmail]/Sent Mail\"\r\n" ++
        "* 0 EXISTS\r\n" ++
        "a2 OK [READ-WRITE] selected\r\n" };

    const imap = try testing.allocator.create(ImapMail);
    defer testing.allocator.destroy(imap);
    try ImapMail.open(imap, scripted.transport(), AccountId.from_int(1), "me", "pw");
    defer imap.close();

    // "Sent" is "[Gmail]/Sent Mail" here, and the sidebar's saved list is what
    // says so: one SELECT, and no LIST to discover it after a refusal.
    var messages: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 0), try imap.mail().fetch(
        .{ .mailbox = .sent, .name = "[Gmail]/Sent Mail" },
        &messages,
    ));
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "SELECT \"[Gmail]/Sent Mail\"") != null);
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "LIST") == null);
}
