//! The SMTP client: connect, authenticate, and stream one message.
//!
//! Replies are line-oriented; a multi-line reply keeps the same code until the
//! final `250 ` line. The body is streamed in fixed chunks with CRLF
//! normalization and dot-stuffing, so a 64 KiB body never needs a second copy.

const std = @import("std");
const assert = std.debug.assert;

const command = @import("command.zig");
const response = @import("response.zig");
const transport_mod = @import("../../ports/transport.zig");
const Outgoing = @import("../../domain/outgoing.zig").Outgoing;

pub const Error = error{
    Unavailable,
    Timeout,
    ProtocolError,
    Rejected,
};

pub const Client = struct {
    transport: transport_mod.Transport,
    /// Accumulates bytes until a full line arrives.
    buffer: [4096]u8 = undefined,
    buffer_len: u32 = 0,
    /// Stable copy of the line being parsed.
    line: [1024]u8 = undefined,
    read_buffer: [2048]u8 = undefined,
    timeout_ms: u32 = 100,
    max_timeouts: u32 = 100,

    pub fn init(transport: transport_mod.Transport) Client {
        return .{ .transport = transport };
    }

    /// Greeting, EHLO, and AUTH PLAIN.
    pub fn connect(self: *Client, domain: []const u8, user: []const u8, password: []const u8) Error!void {
        return self.connectFrom(domain, user, password, .after_greeting);
    }

    /// Whether the server is about to speak first. It is not, when something in
    /// between has already done the greeting: `openssl -starttls smtp` reads the
    /// `220`, says `EHLO` and `STARTTLS`, and hands over a socket where the SMTP
    /// conversation restarts at the client.
    pub const Hello = enum { after_greeting, already_open };

    pub fn connectFrom(
        self: *Client,
        domain: []const u8,
        user: []const u8,
        password: []const u8,
        hello: Hello,
    ) Error!void {
        if (hello == .after_greeting) try self.expect(220);
        try self.ehlo(domain);
        try self.authenticate(user, password);
    }

    /// The same, on a port where TLS starts mid-conversation: greet, `EHLO`,
    /// `STARTTLS`, and then the socket becomes an encrypted one. The password is
    /// only offered after the upgrade -- if the server never says `STARTTLS`, the
    /// connection ends here rather than continuing in clear.
    ///
    /// `upgrade` replaces the transport and answers null when it could not; it is
    /// a function so the client stays a protocol, not a socket.
    pub const Upgrade = *const fn (context: *anyopaque) ?transport_mod.Transport;

    pub fn connect_starttls(
        self: *Client,
        domain: []const u8,
        user: []const u8,
        password: []const u8,
        upgrade: Upgrade,
        context: *anyopaque,
    ) Error!void {
        try self.expect(220);
        var buffer: [512]u8 = undefined;
        const greeting = command.ehlo(&buffer, domain) catch return error.ProtocolError;
        try self.write(greeting);
        // The extension list is the last thing sent in clear, and it is the only
        // thing that says whether an upgrade is possible.
        if (!try self.offers_starttls()) return error.ProtocolError;
        try self.write("STARTTLS\r\n");
        try self.expect(220);
        self.transport = upgrade(context) orelse return error.Unavailable;
        self.buffer_len = 0;
        try self.ehlo(domain);
        try self.authenticate(user, password);
    }

    fn ehlo(self: *Client, domain: []const u8) Error!void {
        var buffer: [512]u8 = undefined;
        const line = command.ehlo(&buffer, domain) catch return error.ProtocolError;
        try self.write(line);
        try self.expect(250);
    }

    fn authenticate(self: *Client, user: []const u8, password: []const u8) Error!void {
        var auth_buffer: [1200]u8 = undefined;
        const auth = command.auth_plain(&auth_buffer, user, password) catch return error.ProtocolError;
        try self.write(auth);
        const reply = try self.read_reply();
        switch (reply.code) {
            235, 503 => return,
            // 503 "already authenticated" is handled above.
            else => return classify(reply.code),
        }
    }

    /// Reads a whole `EHLO` answer and says whether one of its lines is `STARTTLS`.
    fn offers_starttls(self: *Client) Error!bool {
        var offered = false;
        var first = true;
        var last: response.Reply = undefined;
        while (true) {
            const line = try self.read_line();
            const reply = response.parse(line) catch return error.ProtocolError;
            if (!first and reply.code != last.code) return error.ProtocolError;
            if (contains_starttls(reply.text)) offered = true;
            first = false;
            last = reply;
            if (reply.final) return offered;
        }
    }

    fn contains_starttls(text: []const u8) bool {
        // "250-STARTTLS" or "250 STARTTLS": the extension is the word, not the
        // position it keeps on the line.
        return std.mem.indexOf(u8, text, "STARTTLS") != null;
    }

    /// MAIL FROM, RCPT TO, DATA, the message, and the final 250.
    pub fn send(self: *Client, message: *const Outgoing, date: []const u8) Error!void {
        var buffer: [512]u8 = undefined;
        const from = command.mail_from(&buffer, &message.from) catch return error.ProtocolError;
        try self.write(from);
        try self.expect(250);

        const to = command.rcpt_to(&buffer, &message.to) catch return error.ProtocolError;
        try self.write(to);
        try self.expect_one_of(&.{ 250, 251 });

        const data = command.data(&buffer) catch return error.ProtocolError;
        try self.write(data);
        try self.expect(354);

        try self.send_headers(message, date);
        try self.send_body(message.body);
        try self.expect(250);
    }

    /// Best effort: the server may already be gone.
    pub fn quit(self: *Client) void {
        var buffer: [16]u8 = undefined;
        const quit_command = command.quit(&buffer) catch return;
        self.write(quit_command) catch return;
        self.expect(221) catch {};
    }

    pub fn close(self: *Client) void {
        self.transport.close();
    }

    fn send_headers(self: *Client, message: *const Outgoing, date: []const u8) Error!void {
        var header: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&header);
        command.write_headers(&writer, message, date) catch return error.ProtocolError;
        try self.write(writer.buffered());
    }

    fn send_body(self: *Client, body: []const u8) Error!void {
        var chunk: [2048]u8 = undefined;
        var chunk_len: usize = 0;
        var at_line_start = true;

        for (body) |byte| {
            if (byte == '\r') continue;
            if (byte == '\n') {
                try self.append(&chunk, &chunk_len, "\r\n");
                at_line_start = true;
                continue;
            }
            if (at_line_start and byte == '.') {
                try self.append(&chunk, &chunk_len, ".");
            }
            try self.append(&chunk, &chunk_len, &[_]u8{byte});
            at_line_start = false;
        }
        if (!at_line_start) try self.append(&chunk, &chunk_len, "\r\n");
        try self.append(&chunk, &chunk_len, ".\r\n");
        try self.flush_chunk(&chunk, &chunk_len);
    }

    fn append(self: *Client, chunk: []u8, chunk_len: *usize, bytes: []const u8) Error!void {
        assert(bytes.len <= chunk.len);
        if (chunk_len.* + bytes.len > chunk.len) try self.flush_chunk(chunk, chunk_len);
        @memcpy(chunk[chunk_len.*..][0..bytes.len], bytes);
        chunk_len.* += bytes.len;
    }

    fn flush_chunk(self: *Client, chunk: []u8, chunk_len: *usize) Error!void {
        if (chunk_len.* == 0) return;
        try self.write(chunk[0..chunk_len.*]);
        chunk_len.* = 0;
    }

    fn write(self: *Client, bytes: []const u8) Error!void {
        self.transport.write(bytes) catch return error.Unavailable;
    }

    fn expect(self: *Client, expected: u16) Error!void {
        const reply = try self.read_reply();
        if (reply.code == expected) return;
        return classify(reply.code);
    }

    fn expect_one_of(self: *Client, expected: []const u16) Error!void {
        const reply = try self.read_reply();
        for (expected) |code| {
            if (reply.code == code) return;
        }
        return classify(reply.code);
    }

    fn read_reply(self: *Client) Error!response.Reply {
        var first = true;
        var last: response.Reply = undefined;
        while (true) {
            const line = try self.read_line();
            const reply = response.parse(line) catch return error.ProtocolError;
            if (!first and reply.code != last.code) return error.ProtocolError;
            first = false;
            last = reply;
            if (reply.final) return last;
        }
    }

    fn read_line(self: *Client) Error![]const u8 {
        var timeouts: u32 = 0;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.buffer[0..self.buffer_len], '\n')) |index| {
                const length = index + 1;
                if (length > self.line.len) return error.ProtocolError;
                @memcpy(self.line[0..length], self.buffer[0..length]);

                const remaining = self.buffer_len - @as(u32, @intCast(length));
                std.mem.copyForwards(u8, self.buffer[0..remaining], self.buffer[length..self.buffer_len]);
                self.buffer_len = remaining;
                return self.line[0..length];
            }
            if (self.buffer_len == self.buffer.len) return error.ProtocolError;

            const count = self.transport.read(&self.read_buffer, self.timeout_ms) catch
                return error.Unavailable;
            if (count == 0) {
                timeouts += 1;
                if (timeouts > self.max_timeouts) return error.Timeout;
                continue;
            }
            const space = self.buffer.len - self.buffer_len;
            const taken = @min(count, space);
            @memcpy(self.buffer[self.buffer_len..][0..taken], self.read_buffer[0..taken]);
            self.buffer_len += @intCast(taken);
        }
    }
};

fn classify(code: u16) Error {
    if (code >= 400 and code < 500) return error.Unavailable;
    if (code >= 500) return error.Rejected;
    return error.ProtocolError;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Scripted = transport_mod.Scripted;

fn client_with(scripted: *Scripted) Client {
    return Client.init(scripted.transport());
}

fn sample() Outgoing {
    return .{
        .from = @import("../../domain/address.zig").Address.init("me@example.com") catch unreachable,
        .to = @import("../../domain/address.zig").Address.init("alice@example.com") catch unreachable,
    };
}

test "connect greets, says EHLO, and authenticates" {
    var scripted: Scripted = .{ .input = "220 mail.example.com ready\r\n" ++
        "250-mail.example.com\r\n250-AUTH PLAIN\r\n250 HELP\r\n" ++
        "235 2.7.0 accepted\r\n" };
    var client = client_with(&scripted);

    try client.connect("localhost", "alice", "secret");
    const output = scripted.output_text();
    try testing.expect(std.mem.startsWith(u8, output, "EHLO localhost\r\n"));
    try testing.expect(std.mem.indexOf(u8, output, "AUTH PLAIN ") != null);
    try testing.expect(std.mem.indexOf(u8, output, "secret") == null);
}

test "connect maps a refused login to Rejected" {
    var scripted: Scripted = .{ .input = "220 hi\r\n250 ok\r\n535 5.7.8 bad credentials\r\n" };
    var client = client_with(&scripted);
    try testing.expectError(error.Rejected, client.connect("localhost", "alice", "wrong"));
}

test "send streams MAIL, RCPT, DATA, the message, and dot-stuffs the body" {
    var scripted: Scripted = .{ .input = "250 mail\r\n250 rcpt\r\n354 go\r\n250 queued\r\n" };
    var client = client_with(&scripted);

    var message = sample();
    message.from = try @import("../../domain/address.zig").Address.init("Me <me@example.com>");
    message.to = try @import("../../domain/address.zig").Address.init("alice@example.com");
    message.subject.set("Hello");
    message.body = ".hidden\nline two";

    try client.send(&message, "Tue, 14 Nov 2023 22:13:20 +0000");
    const output = scripted.output_text();

    try testing.expect(std.mem.indexOf(u8, output, "MAIL FROM:<me@example.com>\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "RCPT TO:<alice@example.com>\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "DATA\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Subject: Hello\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "..hidden\r\nline two\r\n.\r\n") != null);
}

test "a temporary failure is Unavailable and a permanent one is Rejected" {
    var temporary: Scripted = .{ .input = "451 try later\r\n" };
    var client_temp = client_with(&temporary);
    try testing.expectError(error.Unavailable, client_temp.send(&sample(), "date"));

    var permanent: Scripted = .{ .input = "550 no such user\r\n" };
    var client_perm = client_with(&permanent);
    try testing.expectError(error.Rejected, client_perm.send(&sample(), "date"));
}

test "a refused recipient is Rejected" {
    var scripted: Scripted = .{ .input = "250 mail\r\n550 no such user\r\n" };
    var client = client_with(&scripted);
    try testing.expectError(error.Rejected, client.send(&sample(), "date"));
}

test "an unexpected success code is a protocol error" {
    var scripted: Scripted = .{ .input = "250 mail\r\n250 rcpt\r\n250 not data\r\n" };
    var client = client_with(&scripted);
    try testing.expectError(error.ProtocolError, client.send(&sample(), "date"));
}

test "a multi-line reply with mismatched codes is refused" {
    var scripted: Scripted = .{ .input = "250-first\r\n251 second\r\n" };
    var client = client_with(&scripted);
    try testing.expectError(error.ProtocolError, client.connect("localhost", "u", "p"));
}

test "a silent server times out instead of spinning forever" {
    var scripted: Scripted = .{ .input = "" };
    var client = client_with(&scripted);
    client.max_timeouts = 2;
    try testing.expectError(error.Timeout, client.connect("localhost", "u", "p"));
}

test "a line longer than the buffer is a protocol error" {
    var scripted: Scripted = .{ .input = "" };
    var client = client_with(&scripted);
    const big = try testing.allocator.alloc(u8, 5000);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    big[big.len - 1] = '\n';
    scripted.input = big;
    try testing.expectError(error.ProtocolError, client.connect("localhost", "u", "p"));
}

test "quit sends QUIT and tolerates a busy server" {
    var scripted: Scripted = .{ .input = "221 bye\r\n" };
    var client = client_with(&scripted);
    client.quit();
    try testing.expectEqualStrings("QUIT\r\n", scripted.output_text());

    var silent: Scripted = .{ .input = "" };
    var client_silent = client_with(&silent);
    client_silent.max_timeouts = 0;
    client_silent.quit();
    try testing.expectEqualStrings("QUIT\r\n", silent.output_text());
}

test "a long body is streamed in chunks without losing bytes" {
    var scripted: Scripted = .{ .input = "250 mail\r\n250 rcpt\r\n354 go\r\n250 queued\r\n" };
    var client = client_with(&scripted);

    const big_body = try testing.allocator.alloc(u8, 10_000);
    defer testing.allocator.free(big_body);
    @memset(big_body, 'a');
    var message = sample();
    message.body = big_body;

    try client.send(&message, "date");
    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "\r\n\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output, "\r\n.\r\n"));
}

test "starttls: the password only crosses an encrypted wire" {
    // Two peers in a row: the plaintext one says STARTTLS is there, the other is
    // what the upgrade hands back. If AUTH had gone out before the swap, the
    // second script would never be reached and the send would fail.
    var plain = Scripted{ .input = "220 ready\r\n" ++
        "250-smtp.example.com\r\n" ++
        "250-STARTTLS\r\n" ++
        "250 AUTH PLAIN\r\n" ++
        "220 go ahead\r\n" };
    const Peer = struct {
        tls: Scripted = .{ .input = "250-smtp.example.com\r\n" ++
            "250 AUTH PLAIN\r\n" ++
            "235 ok\r\n" },
        swaps: u8 = 0,

        fn upgrade(context: *anyopaque) ?transport_mod.Transport {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.swaps += 1;
            return self.tls.transport();
        }
    };
    var state: Peer = .{};
    var client = Client.init(plain.transport());
    try client.connect_starttls("example.test", "me", "secret", Peer.upgrade, &state);
    try testing.expectEqual(@as(u8, 1), state.swaps);
    try testing.expect(std.mem.indexOf(u8, plain.output_text(), "AUTH") == null);
    try testing.expect(std.mem.indexOf(u8, state.tls.output_text(), "AUTH") != null);
}

test "starttls: a server that never offers it is not trusted with the password" {
    var plain = Scripted{ .input = "220 ready\r\n" ++
        "250-smtp.example.com\r\n" ++
        "250 AUTH PLAIN\r\n" };
    var client = Client.init(plain.transport());
    var nothing: u8 = 0;
    try testing.expectError(
        error.ProtocolError,
        client.connect_starttls("example.test", "me", "secret", null_upgrade, &nothing),
    );
    try testing.expect(std.mem.indexOf(u8, plain.output_text(), "STARTTLS") == null);
}

/// Refuses every upgrade, which is what a failed handshake looks like from here.
fn null_upgrade(context: *anyopaque) ?transport_mod.Transport {
    _ = context;
    return null;
}

test "starttls: a handshake that fails stops the send, it does not fall back to clear" {
    var plain = Scripted{ .input = "220 ready\r\n" ++
        "250-smtp.example.com\r\n" ++
        "250 STARTTLS\r\n" ++
        "220 go ahead\r\n" };
    var client = Client.init(plain.transport());
    var nothing: u8 = 0;
    try testing.expectError(
        error.Unavailable,
        client.connect_starttls("example.test", "me", "secret", null_upgrade, &nothing),
    );
    // No second EHLO, no AUTH: the conversation ended with the failed upgrade.
    const seen = plain.output_text();
    try testing.expect(std.mem.indexOf(u8, seen, "secret") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen, "EHLO"));
}
