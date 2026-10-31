//! The demo account: a realistic inbox with no network, no account, and no
//! credentials. This is what `amail` opens by default, so a first-time user
//! sees a working, beautiful client before configuring anything.

const std = @import("std");
const assert = std.debug.assert;

const Mailbox = @import("domain/mailbox.zig").Mailbox;
const Message = @import("domain/message.zig").Message;
const MessageId = @import("domain/id.zig").MessageId;
const Address = @import("domain/address.zig").Address;
const MemoryMail = @import("adapters/memory_mail.zig").MemoryMail;

const Entry = struct {
    id: u64,
    mailbox: Mailbox,
    from: []const u8,
    subject: []const u8,
    snippet: []const u8,
    age_seconds: i64,
    size_bytes: u32,
    unread: bool = false,
    flagged: bool = false,
};

/// Ages are relative to `now_unix`, so the list always looks alive ("14m", "2h")
/// no matter when the demo is opened.
const entries = [_]Entry{
    .{
        .id = 1,
        .mailbox = .inbox,
        .from = "Alice Rivera <alice@rivera.dev>",
        .subject = "Re: design tokens review",
        .snippet = "The palette reads calmer now. Two nits on contrast, both in the dark theme.",
        .age_seconds = 95,
        .size_bytes = 6_842,
        .unread = true,
    },
    .{
        .id = 2,
        .mailbox = .inbox,
        .from = "Bob Chen <bob@chenworks.io>",
        .subject = "Zig 0.17 release notes",
        .snippet = "Async I/O landed. Worth a read before we commit to the port.",
        .age_seconds = 14 * 60,
        .size_bytes = 12_480,
        .unread = true,
        .flagged = true,
    },
    .{
        .id = 3,
        .mailbox = .inbox,
        .from = "GitHub <notifications@github.com>",
        .subject = "[amail] TUI skeleton merged (#42)",
        .snippet = "A small, tested foundation: bounded text, typed ids, and a screen buffer.",
        .age_seconds = 2 * 3600,
        .size_bytes = 1_536,
    },
    .{
        .id = 4,
        .mailbox = .inbox,
        .from = "NixOS Weekly <weekly@nixos.org>",
        .subject = "NixOS Weekly #312",
        .snippet = "Reproducible builds, one more time. Plus: a terminal mail client in Zig.",
        .age_seconds = 5 * 3600,
        .size_bytes = 18_944,
    },
    .{
        .id = 5,
        .mailbox = .inbox,
        .from = "Ana Torres <ana@torres.studio>",
        .subject = "Invoice for October",
        .snippet = "Attached: invoice-2024-10.pdf. Due in 14 days, no rush.",
        .age_seconds = 26 * 3600,
        .size_bytes = 4_096,
        .unread = true,
        .flagged = true,
    },
    .{
        .id = 6,
        .mailbox = .inbox,
        .from = "Linear <no-reply@linear.app>",
        .subject = "Your week in review",
        .snippet = "12 issues closed, 3 in progress, 1 waiting on review.",
        .age_seconds = 3 * 86_400,
        .size_bytes = 7_168,
    },
    .{
        .id = 7,
        .mailbox = .inbox,
        .from = "Hacker News <digest@hn.example>",
        .subject = "The best of last week",
        .snippet = "Why terminals are back, and four other links worth your coffee.",
        .age_seconds = 9 * 86_400,
        .size_bytes = 11_264,
    },
    .{
        .id = 8,
        .mailbox = .sent,
        .from = "Me <me@amail.local>",
        .subject = "Re: design tokens review",
        .snippet = "Agreed on both nits. Pushed the contrast fix and a screenshot.",
        .age_seconds = 30 * 60,
        .size_bytes = 2_048,
    },
    .{
        .id = 9,
        .mailbox = .sent,
        .from = "Me <me@amail.local>",
        .subject = "Re: Zig 0.17 release notes",
        .snippet = "Reading tonight. The new Io model is a lot to absorb.",
        .age_seconds = 2 * 3600,
        .size_bytes = 1_536,
    },
    .{
        .id = 10,
        .mailbox = .drafts,
        .from = "Me <me@amail.local>",
        .subject = "Draft: notes on hexagonal mail",
        .snippet = "Core does not know what a terminal is. That is the whole trick.",
        .age_seconds = 10 * 60,
        .size_bytes = 512,
    },
    .{
        .id = 11,
        .mailbox = .archive,
        .from = "Marta Ruiz <marta@ruiz.es>",
        .subject = "Conference talk accepted",
        .snippet = "See you in Berlin. Slides due two weeks before.",
        .age_seconds = 12 * 86_400,
        .size_bytes = 3_584,
    },
};

/// Fills `mail` with the demo inbox. `now_unix` anchors the relative ages.
pub fn seed(mail: *MemoryMail, now_unix: i64) !void {
    for (entries) |entry| {
        var message = Message{
            .id = MessageId.from_int(entry.id),
            .mailbox = entry.mailbox,
            .from = try Address.init(entry.from),
            .timestamp_unix = now_unix - entry.age_seconds,
            .size_bytes = entry.size_bytes,
            .flags = .{ .unread = entry.unread, .flagged = entry.flagged },
        };
        message.subject.set(entry.subject);
        message.snippet.set(entry.snippet);
        try mail.seed(&message);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "seed fills every demo mailbox" {
    var mail = MemoryMail.init();
    try seed(&mail, 1_700_000_000);

    try testing.expectEqual(@as(u32, entries.len), mail.len);
    var inbox: u32 = 0;
    var sent: u32 = 0;
    var drafts: u32 = 0;
    var archive: u32 = 0;
    for (mail.messages[0..mail.len]) |message| {
        switch (message.mailbox) {
            .inbox => inbox += 1,
            .sent => sent += 1,
            .drafts => drafts += 1,
            .archive => archive += 1,
            .trash, .junk => {},
        }
    }
    try testing.expectEqual(@as(u32, 7), inbox);
    try testing.expectEqual(@as(u32, 2), sent);
    try testing.expectEqual(@as(u32, 1), drafts);
    try testing.expectEqual(@as(u32, 1), archive);
}

test "seed uses unique ids and no future timestamps" {
    var mail = MemoryMail.init();
    const now: i64 = 1_700_000_000;
    try seed(&mail, now);

    for (mail.messages[0..mail.len], 0..) |message, index| {
        try testing.expect(message.timestamp_unix <= now);
        for (mail.messages[index + 1 .. mail.len]) |other| {
            try testing.expect(message.id != other.id);
        }
    }
}

test "seed keeps messages ordered newest-first" {
    var mail = MemoryMail.init();
    try seed(&mail, 1_700_000_000);

    var index: u32 = 1;
    while (index < mail.len) : (index += 1) {
        try testing.expect(mail.messages[index - 1].timestamp_unix >= mail.messages[index].timestamp_unix);
    }
}

test "seed sets unread and flagged exactly as the table says" {
    var mail = MemoryMail.init();
    try seed(&mail, 1_700_000_000);

    const first = mail.find(MessageId.from_int(1)).?;
    try testing.expect(first.is_unread());
    try testing.expect(!first.is_flagged());

    const second = mail.find(MessageId.from_int(2)).?;
    try testing.expect(second.is_unread());
    try testing.expect(second.is_flagged());

    const third = mail.find(MessageId.from_int(3)).?;
    try testing.expect(!third.is_unread());
}

test "seed is deterministic for a given clock" {
    var first = MemoryMail.init();
    var second = MemoryMail.init();
    try seed(&first, 1_700_000_000);
    try seed(&second, 1_700_000_000);

    try testing.expectEqual(first.len, second.len);
    for (first.messages[0..first.len], second.messages[0..second.len]) |a, b| {
        try testing.expectEqual(a.id, b.id);
        try testing.expectEqual(a.timestamp_unix, b.timestamp_unix);
        try testing.expect(a.subject.eql(&b.subject));
    }
}
