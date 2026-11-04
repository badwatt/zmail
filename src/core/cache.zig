//! On-disk cache codec: one tab-separated record per message.
//!
//! TSV because every field is already sanitized (no control bytes, so no tabs
//! or newlines can appear) and because a cache you can read with `less` is a
//! cache you can debug. The header carries a version so a format change is a
//! clean miss instead of garbage in the list.

const std = @import("std");
const meta = @import("meta.zig");
const assert = std.debug.assert;

const limits = @import("limits.zig");
const Message = @import("domain/message.zig").Message;
const MessageId = @import("domain/id.zig").MessageId;
const AccountId = @import("domain/id.zig").AccountId;
const Mailbox = @import("domain/mailbox.zig").Mailbox;
const Flags = @import("domain/message.zig").Flags;

pub const header = meta.cache_header;

pub const Error = error{
    WrongVersion,
    Malformed,
    Overflow,
};

pub fn encode(writer: *std.Io.Writer, messages: []const Message) std.Io.Writer.Error!void {
    try writer.print("{s}\n", .{header});
    for (messages) |message| {
        try writer.print("{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\n", .{
            message.id.to_int(),
            message.account.to_int(),
            @backingInt(message.mailbox),
            message.from.name.slice(),
            message.from.local.slice(),
            message.from.domain.slice(),
            message.subject.slice(),
            message.snippet.slice(),
            message.timestamp_unix,
            message.size_bytes,
            @as(u8, @bitCast(message.flags)),
        });
    }
}

/// Decodes into `out`, returning how many messages were read. Stops early when
/// `out` is full.
pub fn decode(text: []const u8, out: []Message) Error!u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return error.Malformed;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), header)) return error.WrongVersion;

    var count: u32 = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (count == out.len) break;

        var fields = std.mem.splitScalar(u8, line, '\t');
        var message = Message{};

        const id_value = try number(&fields, u64);
        if (id_value == 0) return error.Malformed;
        message.id = MessageId.from_int(id_value);

        const account_value = try number(&fields, u8);
        if (account_value == 0) return error.Malformed;
        message.account = AccountId.from_int(account_value);
        const mailbox_value = try number(&fields, u8);
        if (mailbox_value >= Mailbox.all.len) return error.Malformed;
        message.mailbox = Mailbox.from_index(mailbox_value);

        message.from.name.set(try text_field(&fields));
        message.from.local.set(try text_field(&fields));
        message.from.domain.set(try text_field(&fields));
        message.subject.set(try text_field(&fields));
        message.snippet.set(try text_field(&fields));
        message.timestamp_unix = try number(&fields, i64);
        message.size_bytes = try number(&fields, u32);
        const flags_value = try number(&fields, u8);
        message.flags = @bitCast(@as(Flags, @bitCast(flags_value)));

        if (fields.next() != null) return error.Malformed;

        out[count] = message;
        count += 1;
    }
    return count;
}

fn text_field(fields: *std.mem.SplitIterator(u8, .scalar)) Error![]const u8 {
    return fields.next() orelse return error.Malformed;
}

fn number(fields: *std.mem.SplitIterator(u8, .scalar), comptime T: type) Error!T {
    const text = fields.next() orelse return error.Malformed;
    return std.fmt.parseInt(T, text, 10) catch return error.Malformed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sample(id: u64, account: u8, mailbox: Mailbox, timestamp_unix: i64) Message {
    var message = Message{
        .id = MessageId.from_int(id),
        .account = AccountId.from_int(account),
        .mailbox = mailbox,
        .timestamp_unix = timestamp_unix,
        .size_bytes = 4096,
        .flags = .{ .unread = true, .flagged = true },
    };
    message.from = @import("domain/address.zig").Address.from_parts("Alice", "alice", "example.com");
    message.subject.set("Hello");
    message.snippet.set("first line");
    return message;
}

test "cache: encode and decode round-trip" {
    const messages = [_]Message{
        sample(7, 1, .inbox, 1_700_000_000),
        sample(9, 2, .sent, 1_699_999_000),
    };

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encode(&writer, &messages);

    var decoded: [4]Message = undefined;
    const count = try decode(writer.buffered(), &decoded);
    try testing.expectEqual(@as(u32, 2), count);

    try testing.expectEqual(MessageId.from_int(7), decoded[0].id);
    try testing.expectEqual(AccountId.from_int(1), decoded[0].account);
    try testing.expectEqual(Mailbox.inbox, decoded[0].mailbox);
    try testing.expectEqualStrings("Alice", decoded[0].from.name.slice());
    try testing.expectEqualStrings("alice", decoded[0].from.local.slice());
    try testing.expectEqualStrings("example.com", decoded[0].from.domain.slice());
    try testing.expectEqualStrings("Hello", decoded[0].subject.slice());
    try testing.expectEqualStrings("first line", decoded[0].snippet.slice());
    try testing.expectEqual(@as(i64, 1_700_000_000), decoded[0].timestamp_unix);
    try testing.expectEqual(@as(u32, 4096), decoded[0].size_bytes);
    try testing.expect(decoded[0].is_unread());
    try testing.expect(decoded[0].is_flagged());

    try testing.expectEqual(AccountId.from_int(2), decoded[1].account);
    try testing.expectEqual(Mailbox.sent, decoded[1].mailbox);
}

test "cache: an empty cache keeps just the header" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encode(&writer, &.{});

    var decoded: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 0), try decode(writer.buffered(), &decoded));
}

test "cache: stops at the output capacity" {
    const messages = [_]Message{
        sample(1, 1, .inbox, 100),
        sample(2, 1, .inbox, 200),
        sample(3, 1, .inbox, 300),
    };
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encode(&writer, &messages);

    var decoded: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try decode(writer.buffered(), &decoded));
    try testing.expectEqual(MessageId.from_int(1), decoded[0].id);
}

test "cache: a different version is a clean miss" {
    try testing.expectError(error.WrongVersion, decode(meta.name ++ "-cache 2\n", &.{}));
    try testing.expectError(error.WrongVersion, decode("", &.{}));
    try testing.expectError(error.WrongVersion, decode("garbage\n", &.{}));
}

test "cache: malformed records are refused" {
    var decoded: [1]Message = undefined;
    try testing.expectError(error.Malformed, decode(header ++ "\n1\n", &decoded));
    try testing.expectError(error.Malformed, decode(header ++ "\n1\t1\t0\tA\tb\tc\ts\ts\tnope\t1\t0\n", &decoded));
    try testing.expectError(error.Malformed, decode(header ++ "\n1\t1\t99\tA\tb\tc\ts\ts\t0\t1\t0\n", &decoded));
    try testing.expectError(error.Malformed, decode(header ++ "\n0\t1\t0\tA\tb\tc\ts\ts\t0\t1\t0\n", &decoded));
    try testing.expectError(error.Malformed, decode(header ++ "\n1\t1\t0\tA\tb\tc\ts\ts\t0\t1\t0\textra\n", &decoded));
}

test "cache: blank lines and CRLF are tolerated" {
    const text = header ++ "\r\n\r\n" ++
        "1\t1\t0\tA\tb\tc\ts\ts\t0\t1\t0\r\n";
    var decoded: [1]Message = undefined;
    try testing.expectEqual(@as(u32, 1), try decode(text, &decoded));
    try testing.expectEqual(MessageId.from_int(1), decoded[0].id);
}
