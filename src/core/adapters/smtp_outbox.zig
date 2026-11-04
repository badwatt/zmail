//! SMTP outbox: the `Outbox` port over the SMTP client.
//!
//! The connection is opened, authenticated, and kept for the session. A send
//! that fails maps onto the port's two cases; the draft stays in compose state.

const std = @import("std");

const client_mod = @import("../protocol/smtp/client.zig");
const transport_mod = @import("../ports/transport.zig");
const port = @import("../ports/outbox.zig");
const Outgoing = @import("../domain/outgoing.zig").Outgoing;
const time = @import("../domain/time.zig");

pub const Now = *const fn () i64;

pub const SmtpOutbox = struct {
    client: client_mod.Client,
    now: Now,

    pub fn connect(
        transport: transport_mod.Transport,
        domain: []const u8,
        user: []const u8,
        password: []const u8,
        now: Now,
    ) client_mod.Error!SmtpOutbox {
        var adapter = SmtpOutbox{ .client = client_mod.Client.init(transport), .now = now };
        try adapter.client.connect(domain, user, password);
        return adapter;
    }

    pub fn outbox(self: *SmtpOutbox) port.Outbox {
        return .{ .context = self, .vtable = &.{ .send = sendThunk } };
    }

    pub fn close(self: *SmtpOutbox) void {
        self.client.quit();
        self.client.close();
    }

    fn sendThunk(context: *anyopaque, message: *const Outgoing) port.Error!void {
        const self: *SmtpOutbox = @ptrCast(@alignCast(context));
        var date_buffer: [40]u8 = undefined;
        const date = time.rfc5322_date(&date_buffer, self.now());
        self.client.send(message, date) catch |err| switch (err) {
            error.Unavailable, error.Timeout => return error.Unavailable,
            error.Rejected, error.ProtocolError => return error.Rejected,
        };
    }
};

const testing = std.testing;
const Scripted = transport_mod.Scripted;

fn fixed_now() i64 {
    return 1_700_000_000;
}

const connect_ok = "220 hi\r\n250 ok\r\n235 accepted\r\n";

test "connect performs the SMTP handshake" {
    var scripted: Scripted = .{ .input = connect_ok };
    var smtp = try SmtpOutbox.connect(scripted.transport(), "localhost", "me", "pw", fixed_now);
    defer smtp.close();

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "EHLO localhost") != null);
    try testing.expect(std.mem.indexOf(u8, output, "AUTH PLAIN") != null);
}

test "send writes the message with headers and the fixed date" {
    var scripted: Scripted = .{ .input = connect_ok ++ "250 mail\r\n250 rcpt\r\n354 go\r\n250 queued\r\n" };
    var smtp = try SmtpOutbox.connect(scripted.transport(), "localhost", "me", "pw", fixed_now);
    defer smtp.close();

    var message = Outgoing{
        .from = try @import("../domain/address.zig").Address.init("me@example.com"),
        .to = try @import("../domain/address.zig").Address.init("alice@example.com"),
        .body = "hello",
    };
    message.subject.set("Hi");
    try smtp.outbox().send(&message);

    const output = scripted.output_text();
    try testing.expect(std.mem.indexOf(u8, output, "Date: Tue, 14 Nov 2023 22:13:20 +0000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "hello\r\n.\r\n") != null);
}

test "errors are mapped onto the outbox's two cases" {
    const message = Outgoing{
        .from = try @import("../domain/address.zig").Address.init("me@example.com"),
        .to = try @import("../domain/address.zig").Address.init("alice@example.com"),
        .body = "x",
    };

    var temporary: Scripted = .{ .input = connect_ok ++ "451 later\r\n" };
    var smtp_temp = try SmtpOutbox.connect(temporary.transport(), "localhost", "me", "pw", fixed_now);
    defer smtp_temp.close();
    try testing.expectError(error.Unavailable, smtp_temp.outbox().send(&message));

    var refused: Scripted = .{ .input = connect_ok ++ "550 no\r\n" };
    var smtp_refused = try SmtpOutbox.connect(refused.transport(), "localhost", "me", "pw", fixed_now);
    defer smtp_refused.close();
    try testing.expectError(error.Rejected, smtp_refused.outbox().send(&message));
}

test "close sends QUIT and closes the transport" {
    var scripted: Scripted = .{ .input = connect_ok ++ "221 bye\r\n" };
    var smtp = try SmtpOutbox.connect(scripted.transport(), "localhost", "me", "pw", fixed_now);
    smtp.close();
    try testing.expect(std.mem.indexOf(u8, scripted.output_text(), "QUIT") != null);
    try testing.expectEqual(@as(u32, 1), scripted.close_calls);
}

test "a refused login fails connect" {
    var scripted: Scripted = .{ .input = "220 hi\r\n250 ok\r\n535 bad\r\n" };
    try testing.expectError(error.Rejected, SmtpOutbox.connect(scripted.transport(), "localhost", "me", "pw", fixed_now));
}
