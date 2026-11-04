//! SMTP commands and message rendering, into caller-provided buffers.

const std = @import("std");
const Outgoing = @import("../../domain/outgoing.zig").Outgoing;
const Address = @import("../../domain/address.zig").Address;
const mime = @import("../../mime.zig");
const limits = @import("../../limits.zig");

pub const Error = error{
    NoSpaceLeft,
    InvalidValue,
};

const Render = struct {
    writer: std.Io.Writer,
    failed: bool = false,

    fn text(self: *Render, bytes: []const u8) void {
        self.writer.writeAll(bytes) catch {
            self.failed = true;
        };
    }

    fn byte(self: *Render, value: u8) void {
        self.writer.writeByte(value) catch {
            self.failed = true;
        };
    }

    fn print(self: *Render, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch {
            self.failed = true;
        };
    }

    fn finish(self: *Render, buffer: []const u8) Error![]const u8 {
        _ = buffer;
        if (self.failed) return error.NoSpaceLeft;
        return self.writer.buffered();
    }

    fn line(self: *Render) void {
        self.text("\r\n");
    }
};

fn begin(buffer: []u8) Render {
    return .{ .writer = std.Io.Writer.fixed(buffer) };
}

pub fn ehlo(buffer: []u8, domain: []const u8) Error![]const u8 {
    if (!valid_domain(domain)) return error.InvalidValue;
    var render = begin(buffer);
    render.print("EHLO {s}", .{domain});
    render.line();
    return render.finish(buffer);
}

/// AUTH PLAIN with the initial response: base64("\0user\0password").
pub fn auth_plain(buffer: []u8, user: []const u8, password: []const u8) Error![]const u8 {
    var credentials: [1024]u8 = undefined;
    const needed = 1 + user.len + 1 + password.len;
    if (needed > credentials.len) return error.InvalidValue;
    credentials[0] = 0;
    @memcpy(credentials[1..][0..user.len], user);
    credentials[1 + user.len] = 0;
    @memcpy(credentials[2 + user.len ..][0..password.len], password);

    var encoded: [1400]u8 = undefined;
    const encoder = std.base64.standard.Encoder;
    if (encoder.calcSize(needed) > encoded.len) return error.InvalidValue;
    const payload = encoder.encode(&encoded, credentials[0..needed]);

    var render = begin(buffer);
    render.print("AUTH PLAIN {s}", .{payload});
    render.line();
    return render.finish(buffer);
}

pub fn mail_from(buffer: []u8, address: *const Address) Error![]const u8 {
    return envelope(buffer, "MAIL FROM:<", address);
}

pub fn rcpt_to(buffer: []u8, address: *const Address) Error![]const u8 {
    return envelope(buffer, "RCPT TO:<", address);
}

fn envelope(buffer: []u8, prefix: []const u8, address: *const Address) Error![]const u8 {
    var addr_buffer: [300]u8 = undefined;
    const addr = address.addr_spec(&addr_buffer);
    if (addr.len == 0 or address.local.is_empty()) return error.InvalidValue;

    var render = begin(buffer);
    render.text(prefix);
    render.text(addr);
    render.text(">");
    render.line();
    return render.finish(buffer);
}

pub fn data(buffer: []u8) Error![]const u8 {
    var render = begin(buffer);
    render.text("DATA");
    render.line();
    return render.finish(buffer);
}

pub fn quit(buffer: []u8) Error![]const u8 {
    var render = begin(buffer);
    render.text("QUIT");
    render.line();
    return render.finish(buffer);
}

/// Headers only; the body is streamed separately so it never needs a copy.
pub fn write_headers(writer: *std.Io.Writer, message: *const Outgoing, date: []const u8) error{WriteFailed}!void {
    var name_scratch: [mime.encoded_bound(limits.name_max)]u8 = undefined;
    var subject_scratch: [mime.encoded_bound(limits.subject_max)]u8 = undefined;

    try writer.writeAll("From: ");
    try write_address(writer, &message.from, &name_scratch);
    try writer.writeAll("\r\nTo: ");
    try write_address(writer, &message.to, &name_scratch);
    const subject = mime.encode_header_value(message.subject.slice(), &subject_scratch);
    try writer.print("\r\nSubject: {s}\r\nDate: {s}\r\n", .{ subject, date });
    try writer.writeAll("MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n");
    try writer.writeAll("Content-Transfer-Encoding: 8bit\r\n\r\n");
}

/// `Name <local@domain>`, with the name RFC 2047 encoded when it has to be.
/// The angle-addr is never encoded: a server that cannot read it rejects the
/// mail, and a person reading the raw headers would not recognise it.
fn write_address(writer: *std.Io.Writer, address: *const Address, scratch: []u8) error{WriteFailed}!void {
    if (address.name.is_empty()) {
        try writer.print("{s}@{s}", .{ address.local.slice(), address.domain.slice() });
        return;
    }
    const name = mime.encode_header_value(address.name.slice(), scratch);
    try writer.print("{s} <{s}@{s}>", .{ name, address.local.slice(), address.domain.slice() });
}

fn valid_domain(domain: []const u8) bool {
    if (domain.len == 0) return false;
    for (domain) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '-', '_' => continue,
            else => return false,
        }
    }
    return true;
}

const testing = std.testing;

fn expect_command(expected: []const u8, actual: Error![]const u8) !void {
    try testing.expectEqualStrings(expected, try actual);
}

test "EHLO names the client" {
    var buffer: [64]u8 = undefined;
    try expect_command("EHLO localhost\r\n", ehlo(&buffer, "localhost"));
    try testing.expectError(error.InvalidValue, ehlo(&buffer, ""));
    try testing.expectError(error.InvalidValue, ehlo(&buffer, "bad host"));
}

test "AUTH PLAIN encodes NUL-separated credentials" {
    var buffer: [256]u8 = undefined;
    const command = try auth_plain(&buffer, "alice", "secret");
    try testing.expect(std.mem.startsWith(u8, command, "AUTH PLAIN "));
    try testing.expect(std.mem.endsWith(u8, command, "\r\n"));

    const payload = command["AUTH PLAIN ".len .. command.len - 2];
    var decoded: [64]u8 = undefined;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(payload);
    try std.base64.standard.Decoder.decode(decoded[0..size], payload);
    try testing.expectEqualStrings("\x00alice\x00secret", decoded[0..size]);
}

test "AUTH PLAIN refuses credentials that do not fit" {
    var buffer: [64]u8 = undefined;
    const huge: [2000]u8 = @splat('x');
    try testing.expectError(error.InvalidValue, auth_plain(&buffer, &huge, "x"));
}

test "MAIL FROM and RCPT TO use angle brackets" {
    var buffer: [128]u8 = undefined;
    var from = try Address.init("Me <me@example.com>");
    var to = try Address.init("alice@example.com");
    try expect_command("MAIL FROM:<me@example.com>\r\n", mail_from(&buffer, &from));
    try expect_command("RCPT TO:<alice@example.com>\r\n", rcpt_to(&buffer, &to));
}

test "envelope commands refuse an empty local part" {
    var buffer: [64]u8 = undefined;
    const empty = Address{};
    try testing.expectError(error.InvalidValue, mail_from(&buffer, &empty));
}

test "DATA and QUIT are plain lines" {
    var buffer: [16]u8 = undefined;
    try expect_command("DATA\r\n", data(&buffer));
    try expect_command("QUIT\r\n", quit(&buffer));
}

test "a buffer too small fails instead of truncating a command" {
    var buffer: [8]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, ehlo(&buffer, "mail.example.com"));
}

test "headers encode a non-ASCII subject and display name" {
    var outgoing = Outgoing{
        .from = Address.from_parts("Álvaro Núñez", "alvaro", "example.com"),
        .to = try Address.init("alice@example.com"),
    };
    outgoing.subject.set("Re: café ☕");

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write_headers(&writer, &outgoing, "Tue, 14 Nov 2023 22:13:20 +0000");
    const headers = writer.buffered();

    var decoded: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "Re: café ☕",
        mime.decode_encoded_words(header_line(headers, "Subject"), &decoded),
    );

    const from = header_line(headers, "From");
    const bracket = std.mem.indexOfScalar(u8, from, '<').?;
    try testing.expectEqualStrings(
        "Álvaro Núñez ",
        mime.decode_encoded_words(from[0..bracket], &decoded),
    );
    try testing.expectEqualStrings("<alvaro@example.com>", from[bracket..]);

    try testing.expectEqualStrings("alice@example.com", header_line(headers, "To"));
}

/// The value of one header, up to the CRLF, from a rendered header block.
fn header_line(headers: []const u8, name: []const u8) []const u8 {
    var buffer: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buffer, "{s}: ", .{name}) catch return "";
    const start = std.mem.indexOf(u8, headers, prefix) orelse return "";
    const value = start + prefix.len;
    const end = std.mem.indexOf(u8, headers[value..], "\r\n") orelse return headers[value..];
    return headers[value..][0..end];
}

test "headers carry from, to, subject, date, and MIME" {
    var outgoing = Outgoing{
        .from = try Address.init("Me <me@example.com>"),
        .to = try Address.init("Alice <alice@example.com>"),
    };
    outgoing.subject.set("Hello");

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write_headers(&writer, &outgoing, "Tue, 14 Nov 2023 22:13:20 +0000");
    const headers = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, headers, "From: Me <me@example.com>\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, headers, "To: Alice <alice@example.com>\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, headers, "Subject: Hello\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, headers, "Date: Tue, 14 Nov 2023 22:13:20 +0000\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, headers, "\r\n\r\n"));
}
