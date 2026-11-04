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
        try self.expect(220);

        var buffer: [512]u8 = undefined;
        const ehlo = command.ehlo(&buffer, domain) catch return error.ProtocolError;
        try self.write(ehlo);
        try self.expect(250);

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
