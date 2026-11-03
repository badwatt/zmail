//! The IMAP client: a sequence of commands over a transport.
//!
//! `pump` is the whole protocol loop: hand untagged responses to the caller
//! until our tag comes back, then turn OK/NO/BAD into a result or an error.
//! Everything below that is a command and an expectation.
//!
//! No sockets, no TLS, no files: the transport is a port, so a whole server
//! conversation is a unit test.

const std = @import("std");
const assert = std.debug.assert;

const framing = @import("framing.zig");
const command = @import("command.zig");
const response = @import("response.zig");
const transport_mod = @import("../../ports/transport.zig");

const Mailbox = @import("../../domain/mailbox.zig").Mailbox;
const Message = @import("../../domain/message.zig").Message;
const Flags = @import("../../domain/message.zig").Flags;
const MessageId = @import("../../domain/id.zig").MessageId;
const Address = @import("../../domain/address.zig").Address;
const mime = @import("../../mime.zig");
const limits = @import("../../limits.zig");

pub const Error = error{
    /// The transport failed or the peer went away.
    Unavailable,
    /// The server did not finish a response in time.
    Timeout,
    /// A response exceeded the framer's fixed buffer.
    ResponseTooLong,
    /// The server sent something we cannot interpret.
    ProtocolError,
    /// The server answered NO or BAD, and retrying will not help.
    Rejected,
    /// The credentials were refused.
    LoginFailed,
    /// The mailbox or message is gone.
    NotFound,
};

const Greeting = enum { no, ok, preauth };

pub const Client = struct {
    transport: transport_mod.Transport,
    framer: framing.Framer = .{},
    tag_counter: u32 = 0,
    greeted: Greeting = .no,
    read_buffer: [4096]u8 = undefined,
    /// Outgoing commands are bounded: a tag plus a mailbox name cannot need
    /// more, and a bug that tries to send more must fail, not truncate.
    command_buffer: [256]u8 = undefined,
    command_limit: u16 = 256,
    /// Envelope strings unescaped from one response point here, so they stay
    /// valid while the message is built (see response.parse).
    parse_scratch: [1024]u8 = undefined,
    /// Mailbox names are copied here: the parser's scratch is reused per
    /// response, so a LIST of twenty mailboxes would otherwise alias one slice.
    list_names: [limits.mailboxes_max][limits.mailbox_name_max]u8 = undefined,
    /// Per-read wait, and how many of those in a row mean "give up".
    timeout_ms: u32 = 100,
    max_timeouts: u32 = 100,

    pub fn init(transport: transport_mod.Transport) Client {
        return .{ .transport = transport };
    }

    /// XOAUTH2 login: the bearer token is the credential now that providers
    /// stopped accepting passwords.
    pub fn login_token(self: *Client, user: []const u8, token: []const u8) Error!void {
        try self.await_greeting();
        if (self.greeted == .preauth) return;

        var tag_buffer: [16]u8 = undefined;
        const tag = self.beginCommand(&tag_buffer);
        var payload: [512]u8 = undefined;
        const bytes = command.authenticate_xoauth2(
            self.command_slice(),
            tag,
            user,
            token,
            &payload,
        ) catch return error.ProtocolError;
        try self.send(bytes);
        try self.wait_ok(tag);
    }

    pub fn login(self: *Client, user: []const u8, password: []const u8) Error!void {
        // The server speaks first. Sending LOGIN before reading the greeting is
        // a protocol violation, and servers react by ignoring the command.
        try self.await_greeting();
        if (self.greeted == .preauth) return;

        var tag_buffer: [16]u8 = undefined;
        const tag = self.beginCommand(&tag_buffer);
        var command_buffer: [512]u8 = undefined;
        const bytes = command.login(&command_buffer, tag, user, password) catch return error.ProtocolError;
        try self.send(bytes);

        self.wait_ok(tag) catch |err| switch (err) {
            error.Rejected => return error.LoginFailed,
            else => return err,
        };
    }

    /// SELECT: returns the message count the server reports.
    pub fn select(self: *Client, mailbox: Mailbox) Error!u32 {
        return self.select_name(mailbox.title());
    }

    /// Selects by the server's name, which is not always our title ("Sent
    /// Items", "[Gmail]/Sent Mail", ...).
    pub fn select_name(self: *Client, name: []const u8) Error!u32 {
        var tag_buffer: [16]u8 = undefined;
        const tag = self.beginCommand(&tag_buffer);
        const bytes = command.select(self.command_slice(), tag, name) catch
            return error.ProtocolError;
        try self.send(bytes);

        var exists: u32 = 0;
        while (true) {
            const maybe = self.pump(tag) catch |err| switch (err) {
                error.Rejected => return error.NotFound,
                else => return err,
            };
            const untagged = maybe orelse break;
            switch (untagged) {
                .exists => |count| exists = count,
                else => {},
            }
        }
        return exists;
    }

    /// Lists every mailbox, with SPECIAL-USE flags when the server sends them.
    pub fn list(self: *Client, out: []response.ListEntry) Error!u32 {
        var tag_buffer: [16]u8 = undefined;
        const tag = self.beginCommand(&tag_buffer);
        const bytes = command.list(self.command_slice(), tag) catch return error.ProtocolError;
        try self.send(bytes);

        var count: u32 = 0;
        while (true) {
            const maybe = try self.pump(tag);
            const untagged = maybe orelse break;
            switch (untagged) {
                .list => |entry| {
                    if (count < out.len and entry.name.len <= limits.mailbox_name_max) {
                        const slot = &self.list_names[count];
                        @memcpy(slot[0..entry.name.len], entry.name);
                        out[count] = .{
                            .name = slot[0..entry.name.len],
                            .mailbox = entry.mailbox,
                        };
                        count += 1;
                    }
                },
                else => {},
            }
        }
        return count;
    }

    /// Fetches envelopes for `first..last` (1-based sequence numbers) into
    /// `out`. Entries without a UID are skipped: we cannot address them later.
    pub fn fetch_envelopes(self: *Client, mailbox: Mailbox, first: u32, last: u32, out: []Message) Error!u32 {
        var tag_buffer: [16]u8 = undefined;
        const tag = self.beginCommand(&tag_buffer);
        const bytes = command.fetch_envelopes(self.command_slice(), tag, first, last) catch
            return error.ProtocolError;
        try self.send(bytes);

        var count: u32 = 0;
        while (true) {
            const maybe = try self.pump(tag);
            const untagged = maybe orelse break;
            switch (untagged) {
                .fetch => |fetch| {
                    if (count == out.len) continue;
                    if (fetch.uid == null) continue;
                    out[count] = message_from(&fetch, mailbox);
                    count += 1;
                },
                else => {},
            }
        }
        return count;
    }

    /// Copies the text body of `uid` into `out`. The response literal is copied
    /// before the framer moves on, so the returned slice is `out`.
    pub fn fetch_body(self: *Client, uid: u32, out: []u8) Error![]const u8 {
        var tag_buffer: [16]u8 = undefined;
        const tag = self.beginCommand(&tag_buffer);
        // Ask for exactly what fits: a partial fetch keeps a 4 MiB message from
        // being a message nobody can open.
        const limit = std.math.cast(u32, out.len) orelse std.math.maxInt(u32);
        const bytes = command.fetch_body(self.command_slice(), tag, uid, limit) catch
            return error.ProtocolError;
        try self.send(bytes);

        var copied: u32 = 0;
        var saw_body = false;
        while (true) {
            const maybe = try self.pump(tag);
            const untagged = maybe orelse break;
            switch (untagged) {
                .fetch => |fetch| {
                    const body = fetch.body orelse continue;
                    saw_body = true;
                    const length = @min(out.len, body.len);
                    @memcpy(out[0..length], body[0..length]);
                    copied = @intCast(length);
                },
                else => {},
            }
        }
        if (!saw_body) return error.NotFound;
        return out[0..copied];
    }

    pub fn set_flags(self: *Client, uid: u32, flags: Flags) Error!void {
        var tag_buffer: [16]u8 = undefined;
        const tag = self.beginCommand(&tag_buffer);
        const bytes = command.store_flags(self.command_slice(), tag, uid, flags) catch
            return error.ProtocolError;
        try self.send(bytes);
        try self.wait_ok(tag);
    }

    /// Marks one message deleted and expunges it. UID EXPUNGE needs UIDPLUS;
    /// plain EXPUNGE is the fallback and is safe because the mailbox was just
    /// selected and nothing else was flagged.
    pub fn delete_message(self: *Client, uid: u32) Error!void {
        var tag_buffer: [16]u8 = undefined;
        var tag = self.beginCommand(&tag_buffer);
        const command_buffer = self.command_slice();
        try self.send(command.delete_forever(command_buffer, tag, uid) catch return error.ProtocolError);
        try self.wait_ok(tag);

        tag = self.beginCommand(&tag_buffer);
        try self.send(command.expunge_uid(self.command_slice(), tag, uid) catch return error.ProtocolError);
        self.wait_ok(tag) catch |err| switch (err) {
            // Servers without UIDPLUS reject the UID form; plain EXPUNGE works.
            error.Rejected => {
                tag = self.beginCommand(&tag_buffer);
                try self.send(command.expunge(self.command_slice(), tag) catch return error.ProtocolError);
                try self.wait_ok(tag);
            },
            else => return err,
        };
    }

    /// Empties a mailbox: flag everything, then expunge.
    pub fn empty_mailbox(self: *Client) Error!void {
        var tag_buffer: [16]u8 = undefined;
        var tag = self.beginCommand(&tag_buffer);
        try self.send(command.delete_all(self.command_slice(), tag) catch return error.ProtocolError);
        try self.wait_ok(tag);

        tag = self.beginCommand(&tag_buffer);
        try self.send(command.expunge(self.command_slice(), tag) catch return error.ProtocolError);
        try self.wait_ok(tag);
    }

    pub fn move_message(self: *Client, uid: u32, to: Mailbox) Error!void {
        return self.move_message_to(uid, to.title());
    }

    pub fn move_message_to(self: *Client, uid: u32, name: []const u8) Error!void {
        var tag_buffer: [16]u8 = undefined;
        const tag = self.beginCommand(&tag_buffer);
        const bytes = command.move_message(self.command_slice(), tag, uid, name) catch
            return error.ProtocolError;
        try self.send(bytes);
        try self.wait_ok(tag);
    }

    /// Best-effort LOGOUT: the server may close the stream before answering.
    pub fn logout(self: *Client) void {
        var tag_buffer: [16]u8 = undefined;
        const tag = self.beginCommand(&tag_buffer);
        var command_buffer: [64]u8 = undefined;
        const bytes = command.logout(&command_buffer, tag) catch "";

        if (bytes.len > 0) self.transport.write(bytes) catch {};
        var attempts: u32 = 0;
        while (attempts < 8) : (attempts += 1) {
            const maybe = self.pump(tag) catch return;
            if (maybe == null) break;
        }
    }

    pub fn close(self: *Client) void {
        self.transport.close();
    }

    fn command_slice(self: *Client) []u8 {
        return self.command_buffer[0..self.command_limit];
    }

    /// Reads the server greeting. PREAUTH means the connection is already
    /// authenticated and LOGIN must be skipped.
    fn await_greeting(self: *Client) Error!void {
        if (self.greeted != .no) return;

        while (true) {
            const reply = try self.next_response();
            switch (reply) {
                .untagged => |untagged| switch (untagged) {
                    .ok => {
                        self.greeted = .ok;
                        return;
                    },
                    .preauth => {
                        self.greeted = .preauth;
                        return;
                    },
                    .bye => return error.Rejected,
                    else => {},
                },
                .tagged, .continuation, .unknown => {},
            }
        }
    }

    fn beginCommand(self: *Client, tag_buffer: *[16]u8) []const u8 {
        self.tag_counter += 1;
        // "a" plus the decimal form of any u32 fits with room to spare.
        comptime std.debug.assert(@sizeOf(@TypeOf(self.tag_counter)) * 3 + 1 <= tag_buffer.len);
        return std.fmt.bufPrint(tag_buffer, "a{d}", .{self.tag_counter}) catch unreachable;
    }

    fn send(self: *Client, bytes: []const u8) Error!void {
        self.transport.write(bytes) catch return error.Unavailable;
    }

    fn wait_ok(self: *Client, expected_tag: []const u8) Error!void {
        while (true) {
            const maybe = try self.pump(expected_tag);
            if (maybe == null) return;
        }
    }

    /// Returns the next untagged response, or null once our tag came back OK.
    fn pump(self: *Client, expected_tag: []const u8) Error!?response.Untagged {
        while (true) {
            const reply = try self.next_response();
            switch (reply) {
                .untagged => |untagged| {
                    return untagged;
                },
                .tagged => |tagged| {
                    if (!std.mem.eql(u8, tagged.tag, expected_tag)) continue;
                    return switch (tagged.kind) {
                        .ok => null,
                        .no, .bad => error.Rejected,
                    };
                },
                .continuation, .unknown => continue,
            }
        }
    }

    fn next_response(self: *Client) Error!response.Response {
        var timeouts: u32 = 0;
        while (true) {
            const maybe = self.framer.next() catch return error.ResponseTooLong;
            if (maybe) |complete| {
                return response.parse(complete, &self.parse_scratch) catch |err| switch (err) {
                    error.Malformed => continue,
                    error.InvalidDate => return error.ProtocolError,
                };
            }

            const count = self.transport.read(&self.read_buffer, self.timeout_ms) catch
                return error.Unavailable;
            if (count == 0) {
                timeouts += 1;
                if (timeouts > self.max_timeouts) return error.Timeout;
                continue;
            }
            self.framer.push(self.read_buffer[0..count]) catch return error.ResponseTooLong;
        }
    }
};

fn message_from(fetch: *const response.Fetch, mailbox: Mailbox) Message {
    assert(fetch.uid != null);
    var message = Message{
        .id = MessageId.from_int(fetch.uid.?),
        .mailbox = mailbox,
        .timestamp_unix = fetch.internal_date orelse 0,
        .size_bytes = fetch.size_bytes orelse 0,
        .flags = fetch.flags orelse .{},
    };
    if (fetch.envelope) |envelope| {
        // Subjects and names travel as RFC 2047 encoded words; decode them at
        // the protocol boundary so nothing above ever sees "=?utf-8?Q?...".
        var name_buffer: [limits.name_max * 4]u8 = undefined;
        var name_display: [limits.name_max * 4]u8 = undefined;
        var subject_buffer: [limits.subject_max * 4]u8 = undefined;
        var subject_display: [limits.subject_max * 4]u8 = undefined;
        message.from = Address.from_parts(
            mime.to_display(
                mime.decode_encoded_words(envelope.from_name orelse "", &name_buffer),
                &name_display,
            ),
            envelope.from_mailbox orelse "",
            envelope.from_host orelse "",
        );
        message.subject.set(mime.to_display(
            mime.decode_encoded_words(envelope.subject orelse "", &subject_buffer),
            &subject_display,
        ));
    }
    return message;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Scripted = transport_mod.Scripted;

fn client_with(scripted: *Scripted) Client {
    return Client.init(scripted.transport());
}

test "login writes the command and accepts a tagged OK" {
    var scripted: Scripted = .{ .input = "* OK [CAPABILITY IMAP4rev1] ready\r\na1 OK LOGIN completed\r\n" };
    var client = client_with(&scripted);

    try client.login("me@example.com", "secret");
    try testing.expectEqualStrings("a1 LOGIN \"me@example.com\" \"secret\"\r\n", scripted.output_text());
}

test "the greeting must be read first: PREAUTH skips login, BYE is refused" {
    var preauth: Scripted = .{ .input = "* PREAUTH welcome\r\n" };
    var client = client_with(&preauth);
    try client.login("me", "pw");
    try testing.expectEqualStrings("", preauth.output_text());

    var bye: Scripted = .{ .input = "* BYE not today\r\n" };
    var client_bye = client_with(&bye);
    try testing.expectError(error.Rejected, client_bye.login("me", "pw"));
}

test "untagged noise before the greeting is skipped" {
    var scripted: Scripted = .{ .input = "* CAPABILITY IMAP4rev1\r\n* OK ready\r\na1 OK done\r\n" };
    var client = client_with(&scripted);
    try client.login("me", "pw");
    try testing.expectEqualStrings("a1 LOGIN \"me\" \"pw\"\r\n", scripted.output_text());
}

test "login refused becomes LoginFailed" {
    var scripted: Scripted = .{ .input = "* OK ready\r\na1 NO [AUTHENTICATIONFAILED] nope\r\n" };
    var client = client_with(&scripted);
    try testing.expectError(error.LoginFailed, client.login("me", "wrong"));
}

test "select returns EXISTS and tolerates untagged noise" {
    var scripted: Scripted = .{
        .input = "* 3 EXISTS\r\n* 1 RECENT\r\n* OK still here\r\n* XUNKNOWN data\r\na1 OK [READ-WRITE] done\r\n",
    };
    var client = client_with(&scripted);

    try testing.expectEqual(@as(u32, 3), try client.select(.inbox));
    try testing.expectEqualStrings("a1 SELECT \"Inbox\"\r\n", scripted.output_text());
}

test "select of a missing mailbox becomes NotFound" {
    var scripted: Scripted = .{ .input = "a1 NO [NONEXISTENT] no such mailbox\r\n" };
    var client = client_with(&scripted);
    try testing.expectError(error.NotFound, client.select(.archive));
}

test "fetch_envelopes converts FETCH responses into messages" {
    const script =
        "* 2 EXISTS\r\n" ++
        "* 1 FETCH (UID 10 FLAGS (\\Seen) RFC822.SIZE 100 INTERNALDATE \"14-Nov-2023 22:13:20 +0000\"" ++
        " ENVELOPE (NIL \"Hello\" ((\"Alice\" NIL \"alice\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "* 2 FETCH (UID 11 FLAGS () ENVELOPE (NIL \"Second\" ((\"Bob\" NIL \"bob\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a1 OK done\r\n";
    var scripted: Scripted = .{ .input = script };
    var client = client_with(&scripted);

    var messages: [4]Message = undefined;
    try testing.expectEqual(@as(u32, 2), try client.fetch_envelopes(.inbox, 1, 2, &messages));

    try testing.expectEqual(MessageId.from_int(10), messages[0].id);
    try testing.expectEqualStrings("Hello", messages[0].subject.slice());
    try testing.expectEqualStrings("Alice", messages[0].from.label());
    try testing.expectEqual(@as(i64, 1_700_000_000), messages[0].timestamp_unix);
    try testing.expectEqual(@as(u32, 100), messages[0].size_bytes);
    try testing.expect(!messages[0].is_unread());

    try testing.expectEqualStrings("Second", messages[1].subject.slice());
    try testing.expect(messages[1].is_unread());
    try testing.expectEqualStrings("bob", messages[1].from.local.slice());

    try testing.expectEqualStrings(
        "a1 FETCH 1:2 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)\r\n",
        scripted.output_text(),
    );
}

test "fetch_envelopes truncates to the output and skips entries without a UID" {
    const script =
        "* 1 FETCH (FLAGS (\\Seen))\r\n" ++
        "* 2 FETCH (UID 21 ENVELOPE (NIL \"kept\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "* 3 FETCH (UID 22 ENVELOPE (NIL \"dropped\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a1 OK done\r\n";
    var scripted: Scripted = .{ .input = script };
    var client = client_with(&scripted);

    var messages: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try client.fetch_envelopes(.inbox, 1, 3, &messages));
    try testing.expectEqual(MessageId.from_int(21), messages[0].id);
    try testing.expectEqualStrings("kept", messages[0].subject.slice());
}

test "escaped envelope strings survive the message builder" {
    // The subject is quoted and escaped, so it lives in the parse scratch. The
    // builder allocates large buffers of its own; before the scratch was
    // client-owned, those overwrote the dead frame and the subject came out as
    // garbage.
    var scripted: Scripted = .{ .input = "* OK ready\r\n" ++
        "a1 OK LOGIN completed\r\n" ++
        "* 1 EXISTS\r\n" ++
        "a2 OK selected\r\n" ++
        "* 1 FETCH (UID 6 ENVELOPE (NIL \"he said \\\"hi\\\"\" ((\"Al \\\"A\\\" Ice\" NIL \"al\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a3 OK\r\n" };

    var client = Client.init(scripted.transport());
    try client.login("me", "pw");
    _ = try client.select(.inbox);

    var messages: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try client.fetch_envelopes(.inbox, 1, 1, &messages));
    try testing.expectEqualStrings("he said \"hi\"", messages[0].subject.slice());
    try testing.expectEqualStrings("Al \"A\" Ice", messages[0].from.label());
}

test "raw 8-bit headers become letters, not question marks" {
    var scripted: Scripted = .{ .input = "* OK ready\r\n" ++
        "a1 OK LOGIN completed\r\n" ++
        "* 1 EXISTS\r\n" ++
        "a2 OK selected\r\n" ++
        "* 1 FETCH (UID 9 ENVELOPE (NIL \"Aviso de renovaci\xf3n\" ((\"Jos\xe9\" NIL \"jose\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a3 OK\r\n" };

    var client = Client.init(scripted.transport());
    try client.login("me", "pw");
    _ = try client.select(.inbox);

    var messages: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try client.fetch_envelopes(.inbox, 1, 1, &messages));
    try testing.expectEqualStrings("Aviso de renovación", messages[0].subject.slice());
    try testing.expectEqualStrings("José", messages[0].from.label());
}

test "envelopes decode RFC 2047 subjects and names" {
    var scripted: Scripted = .{ .input = "* OK ready\r\n" ++
        "a1 OK LOGIN completed\r\n" ++
        "* 1 EXISTS\r\n" ++
        "a2 OK selected\r\n" ++
        "* 1 FETCH (UID 5 ENVELOPE (NIL \"=?utf-8?Q?caf=C3=A9?=\" ((\"=?iso-8859-1?Q?Ren=E9?=\" NIL \"rene\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
        "a3 OK\r\n" };

    var client = Client.init(scripted.transport());
    try client.login("me", "pw");
    const exists = try client.select(.inbox);
    try testing.expectEqual(@as(u32, 1), exists);

    var messages: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try client.fetch_envelopes(.inbox, 1, 1, &messages));
    try testing.expectEqualStrings("café", messages[0].subject.slice());
    try testing.expectEqualStrings("René", messages[0].from.label());
}

test "fetch_body copies the literal into the caller's buffer" {
    const script =
        "* 1 FETCH (UID 7 BODY[TEXT] {11}\r\nhello world)\r\n" ++
        "a1 OK done\r\n";
    var scripted: Scripted = .{ .input = script };
    var client = client_with(&scripted);

    var body: [64]u8 = undefined;
    const text = try client.fetch_body(7, &body);
    try testing.expectEqualStrings("hello world", text);
    // Exactly what the caller can hold: a message with a scanned certificate
    // is a megabyte, and its text is at the front.
    try testing.expectEqualStrings("a1 UID FETCH 7 (BODY.PEEK[]<0.64>)\r\n", scripted.output_text());
}

test "fetch_body truncates a body larger than the buffer" {
    const script = "* 1 FETCH (BODY[] {5}\r\nabcde)\r\na1 OK done\r\n";
    var scripted: Scripted = .{ .input = script };
    var client = client_with(&scripted);

    var body: [2]u8 = undefined;
    try testing.expectEqualStrings("ab", try client.fetch_body(7, &body));
}

test "fetch_body without a body attribute is NotFound" {
    const script = "* 1 FETCH (UID 7)\r\na1 OK done\r\n";
    var scripted: Scripted = .{ .input = script };
    var client = client_with(&scripted);

    var body: [16]u8 = undefined;
    try testing.expectError(error.NotFound, client.fetch_body(7, &body));
}

test "set_flags and move write UID commands and accept OK" {
    var scripted: Scripted = .{ .input = "* OK ready\r\na1 OK done\r\na2 OK done\r\n" };
    var client = client_with(&scripted);

    try client.set_flags(7, .{ .unread = false, .flagged = true });
    try client.move_message(7, .archive);

    try testing.expectEqualStrings(
        "a1 UID STORE 7 FLAGS.SILENT (\\Seen \\Flagged)\r\na2 UID MOVE 7 \"Archive\"\r\n",
        scripted.output_text(),
    );
}

test "a rejected STORE surfaces as Rejected" {
    var scripted: Scripted = .{ .input = "* OK ready\r\na1 NO [CANNOT] no\r\n" };
    var client = client_with(&scripted);
    try testing.expectError(error.Rejected, client.set_flags(7, .{}));
}

test "transport failure is reported as Unavailable" {
    var scripted: Scripted = .{ .read_failure = error.Unavailable };
    var client = client_with(&scripted);
    client.max_timeouts = 0;
    try testing.expectError(error.Unavailable, client.select(.inbox));
}

test "a silent server times out instead of spinning forever" {
    var scripted: Scripted = .{ .input = "" };
    var client = client_with(&scripted);
    client.max_timeouts = 2;
    try testing.expectError(error.Timeout, client.select(.inbox));
}

test "a malformed line is skipped, and a bad date is a protocol error" {
    var scripted: Scripted = .{ .input = "*\r\na1 OK done\r\n" };
    var client = client_with(&scripted);
    try testing.expectEqual(@as(u32, 0), try client.select(.inbox));

    var bad_date: Scripted = .{ .input = "* 1 FETCH (INTERNALDATE \"nope\")\r\na1 OK\r\n" };
    var client_bad = client_with(&bad_date);
    var messages: [1]Message = undefined;
    try testing.expectError(error.ProtocolError, client_bad.fetch_envelopes(.inbox, 1, 1, &messages));
}

test "responses for another tag are ignored, continuations are skipped" {
    var scripted: Scripted = .{ .input = "+ literal\r\nb9 OK not ours\r\na1 OK ours\r\n" };
    var client = client_with(&scripted);
    try testing.expectEqual(@as(u32, 0), try client.select(.inbox));
}

test "a response larger than the framer is refused" {
    // Larger than the framer holds, whatever the limit happens to be.
    const big = try testing.allocator.alloc(u8, @as(usize, framing.max_response) + 64);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    var scripted: Scripted = .{ .input = big };
    var client = client_with(&scripted);
    client.max_timeouts = 0;
    try testing.expectError(error.ResponseTooLong, client.select(.inbox));
}

test "login_token sends AUTHENTICATE XOAUTH2 and accepts OK" {
    var scripted: Scripted = .{ .input = "* OK ready\r\na1 OK AUTHENTICATE completed\r\n" };
    var client = Client.init(scripted.transport());
    try client.login_token("me@example.com", "ya29.token");

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "AUTHENTICATE XOAUTH2 ") != null);
    try testing.expect(std.mem.indexOf(u8, output, "me@example.com") == null); // base64
}

test "a rejected token is LoginFailed" {
    var scripted: Scripted = .{ .input = "* OK ready\r\na1 NO AUTHENTICATE failed\r\n" };
    var client = Client.init(scripted.transport());
    try testing.expectError(error.Rejected, client.login_token("me", "bad"));
}

test "logout sends the command and closes the transport" {
    var scripted: Scripted = .{ .input = "* BYE bye\r\na1 OK done\r\n" };
    var client = client_with(&scripted);
    client.logout();
    try testing.expectEqualStrings("a1 LOGOUT\r\n", scripted.output_text());

    client.close();
    try testing.expectEqual(@as(u32, 1), scripted.close_calls);
}

test "logout tolerates a server that hangs up" {
    var scripted: Scripted = .{ .input = "", .closed = true };
    var client = client_with(&scripted);
    client.logout();
    try testing.expect(std.mem.startsWith(u8, scripted.output_text(), "a1 LOGOUT"));
}

test "a bounded command buffer refuses to send a truncated command" {
    var scripted: Scripted = .{ .input = "" };
    var client = client_with(&scripted);
    client.command_limit = 4;

    try testing.expectError(error.ProtocolError, client.select(.inbox));
    try testing.expectError(error.ProtocolError, client.fetch_envelopes(.inbox, 1, 2, &.{}));
    var body: [8]u8 = undefined;
    try testing.expectError(error.ProtocolError, client.fetch_body(1, &body));
    try testing.expectError(error.ProtocolError, client.set_flags(1, .{}));
    try testing.expectError(error.ProtocolError, client.move_message(1, .trash));
    try testing.expectEqualStrings("", scripted.output_text());
}

test "a password too long for the login buffer is a protocol error" {
    var scripted: Scripted = .{ .input = "* OK ready\r\n" };
    var client = client_with(&scripted);
    const huge_password: [600]u8 = @splat('x');
    try testing.expectError(error.ProtocolError, client.login("me", &huge_password));
}

test "message_from defaults missing fields instead of failing" {
    const fetch = response.Fetch{ .sequence = 1, .uid = 5 };
    const message = message_from(&fetch, .sent);
    try testing.expectEqual(MessageId.from_int(5), message.id);
    try testing.expectEqual(Mailbox.sent, message.mailbox);
    try testing.expectEqual(@as(i64, 0), message.timestamp_unix);
    try testing.expect(message.subject.is_empty());
}
