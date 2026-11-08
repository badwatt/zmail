//! Deciding when to say "there is new mail": the part of a watcher that has no
//! clock and no socket.
//!
//! A watcher polls the same number a folder list already carries -- unread in
//! Inbox -- and compares it with what it saw a minute ago. What it does with the
//! answer is a subprocess and a sleep, which is why this file only decides.

const std = @import("std");
const assert = std.debug.assert;

const limits = @import("../limits.zig");
const Text = @import("../domain/text.zig").Text;
const AccountId = @import("../domain/id.zig").AccountId;
const Message = @import("../domain/message.zig").Message;

/// Accounts a single watcher follows: the client's own bound.
pub const accounts_max = @import("state.zig").accounts_max;

/// The most messages one poll reports: a mailbox that gains a hundred and fifty
/// overnight is one "you have mail", not a hundred and fifty windows.
pub const reports_max: u32 = 3;

/// What grew, and by how much.
pub const Growth = struct {
    account: AccountId,
    label: []const u8,
    unread: u32,
    /// New messages the poll can name, newest first, at most `reports_max`.
    reports: []const Message,
};

pub const Watcher = struct {
    const Seen = struct {
        id: AccountId = .unknown,
        label: Text(limits.label_max) = .{},
        unread: u32 = 0,
        /// The highest id seen, so the next poll knows which are new.
        highest: u64 = 0,
        /// Nobody has looked yet: the first poll is the baseline, not news.
        primed: bool = false,
    };

    seen: [accounts_max]Seen = @splat(.{}),
    len: u8 = 0,

    fn slot(self: *Watcher, account: AccountId) *Seen {
        assert(account.is_known());
        var index: u8 = 0;
        while (index < self.len) : (index += 1) {
            if (self.seen[index].id == account) return &self.seen[index];
        }
        assert(self.len < accounts_max);
        self.seen[self.len] = .{ .id = account };
        self.len += 1;
        return &self.seen[self.len - 1];
    }

    /// One poll's numbers for one account: unread in Inbox, and the mail itself
    /// when there is more of it than before. Null means "nothing to say" -- the
    /// first look, or no change, or fewer unread, which is somebody reading.
    pub fn observe(
        self: *Watcher,
        account: AccountId,
        label: []const u8,
        unread: u32,
        messages: []const Message,
        reports: []Message,
    ) ?Growth {
        const seen = self.slot(account);
        seen.label.set(label);

        var highest: u64 = seen.highest;
        for (messages) |message| {
            if (message.account != account) continue;
            if (message.id.to_int() > highest) highest = message.id.to_int();
        }

        // The first look sets the baseline: a watcher that starts at nine in the
        // morning must not announce the mail that arrived before it.
        if (!seen.primed) {
            seen.primed = true;
            seen.unread = unread;
            seen.highest = highest;
            return null;
        }

        const grew = unread > seen.unread;
        seen.unread = unread;
        if (!grew) {
            // Fewer unread means somebody is reading elsewhere; more mail may still
            // have arrived behind them, so the high-water mark only moves forward.
            if (highest > seen.highest) seen.highest = highest;
            return null;
        }

        // Newest first: the message a notification names is the one that arrived.
        var count: usize = 0;
        for (messages) |message| {
            if (count == reports.len or count == reports_max) break;
            if (message.account != account) continue;
            if (message.id.to_int() <= seen.highest) continue;
            reports[count] = message;
            count += 1;
        }
        seen.highest = highest;
        return .{
            .account = account,
            .label = seen.label.slice(),
            .unread = unread,
            .reports = reports[0..count],
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const MessageId = @import("../domain/id.zig").MessageId;

const account_one = AccountId.from_int(1);
const account_two = AccountId.from_int(2);

fn message_with(id: u64, account: AccountId) Message {
    var message = Message{
        .id = MessageId.from_int(id),
        .account = account,
        .timestamp_unix = 1_700_000_000,
    };
    message.subject.set("hello");
    return message;
}

test "watch: the first look is the baseline, not news" {
    var watcher: Watcher = .{};
    var reports: [reports_max]Message = undefined;
    const inbox = [_]Message{message_with(10, account_one)};

    try testing.expectEqual(
        @as(?Growth, null),
        watcher.observe(account_one, "work", 3, &inbox, &reports),
    );

    // And the same numbers again say nothing either.
    try testing.expectEqual(
        @as(?Growth, null),
        watcher.observe(account_one, "work", 3, &inbox, &reports),
    );
}

test "watch: one more unread names the message that arrived" {
    var watcher: Watcher = .{};
    var reports: [reports_max]Message = undefined;
    const before = [_]Message{message_with(10, account_one)};
    _ = watcher.observe(account_one, "work", 1, &before, &reports);

    const after = [_]Message{ message_with(11, account_one), message_with(10, account_one) };
    const growth = watcher.observe(account_one, "work", 2, &after, &reports).?;
    try testing.expectEqual(account_one, growth.account);
    try testing.expectEqualStrings("work", growth.label);
    try testing.expectEqual(@as(u32, 2), growth.unread);
    try testing.expectEqual(@as(usize, 1), growth.reports.len);
    try testing.expectEqual(MessageId.from_int(11), growth.reports[0].id);

    // Once reported, the same messages are not news again.
    try testing.expectEqual(
        @as(?Growth, null),
        watcher.observe(account_one, "work", 2, &after, &reports),
    );
}

test "watch: fewer unread is somebody reading, and says nothing" {
    var watcher: Watcher = .{};
    var reports: [reports_max]Message = undefined;
    const before = [_]Message{ message_with(10, account_one), message_with(11, account_one) };
    _ = watcher.observe(account_one, "work", 2, &before, &reports);

    const after = [_]Message{message_with(10, account_one)};
    try testing.expectEqual(
        @as(?Growth, null),
        watcher.observe(account_one, "work", 1, &after, &reports),
    );
    // A count that grows again without a new message -- mail moved back to unread,
    // or a folder somebody dragged into Inbox -- is still news, with no name to it.
    const again = watcher.observe(account_one, "work", 2, &before, &reports).?;
    try testing.expectEqual(@as(u32, 2), again.unread);
    try testing.expectEqual(@as(usize, 0), again.reports.len);
}

test "watch: a hundred new messages are one report with three names" {
    var watcher: Watcher = .{};
    var reports: [reports_max]Message = undefined;
    _ = watcher.observe(account_one, "work", 0, &.{}, &reports);

    var mailbox: [150]Message = undefined;
    for (&mailbox, 0..) |*message, index| message.* = message_with(100 + index, account_one);
    const growth = watcher.observe(account_one, "work", 150, &mailbox, &reports).?;
    try testing.expectEqual(@as(u32, 150), growth.unread);
    // Bounded: a window per message is not a notification, it is an attack.
    try testing.expectEqual(@as(usize, reports_max), growth.reports.len);
}

test "watch: two accounts keep their own numbers, and a new one is a baseline" {
    var watcher: Watcher = .{};
    var reports: [reports_max]Message = undefined;
    _ = watcher.observe(account_one, "work", 0, &.{}, &reports);

    // The second account appears mid-run: it starts from what is there.
    try testing.expectEqual(
        @as(?Growth, null),
        watcher.observe(account_two, "home", 4, &.{message_with(1, account_two)}, &reports),
    );

    // The first one still reports its own news, with its own label.
    const growth = watcher.observe(account_one, "work", 1, &.{message_with(2, account_one)}, &reports).?;
    try testing.expectEqualStrings("work", growth.label);
    try testing.expectEqual(@as(u8, 2), watcher.len);

    // A message of another account in the same slice is not this account's news.
    const mixed = [_]Message{ message_with(3, account_two), message_with(4, account_one) };
    const second = watcher.observe(account_one, "work", 2, &mixed, &reports).?;
    try testing.expectEqual(@as(usize, 1), second.reports.len);
    try testing.expectEqual(MessageId.from_int(4), second.reports[0].id);
}
