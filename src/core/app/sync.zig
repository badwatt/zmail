//! Reconciling the local cache with what the server just sent.
//!
//! The store is a cache: a refresh replaces one mailbox wholesale, which keeps
//! flags and deletions from the server authoritative. Other mailboxes are
//! untouched, so switching tabs does not wipe what is already loaded.

const std = @import("std");
const Store = @import("../domain/store.zig").Store;
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const folder = @import("../domain/folder.zig");
const AccountId = @import("../domain/id.zig").AccountId;
const Message = @import("../domain/message.zig").Message;

pub fn replace_mailbox(store: *Store, account: AccountId, mailbox: Mailbox, fetched: []const Message) void {
    _ = store.remove_in(account, mailbox);
    for (fetched) |message| {
        // The caller asked for this mailbox, so this is where the mail is: an
        // adapter cannot file a message somewhere the request did not name.
        var copy = message;
        copy.account = account;
        copy.mailbox = mailbox;
        copy.named = folder.none;
        // A server that sends more than the cache can hold is truncated, not
        // allowed to fail the refresh: partial mail is better than no mail.
        store.insert(&copy) catch {};
    }
}

/// Renumbers a named folder after the server's list changed order under it.
pub fn reslot(store: *Store, account: AccountId, from: u8, to: u8) void {
    store.reslot(account, from, to);
}

/// The same, for one of the account's own folders: the messages are stamped with
/// the slot they were asked for, never with a canonical mailbox.
pub fn replace_named(store: *Store, account: AccountId, slot: u8, fetched: []const Message) void {
    _ = store.remove_named(account, slot);
    for (fetched) |message| {
        var copy = message;
        copy.account = account;
        copy.named = slot;
        store.insert(&copy) catch {};
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const MessageId = @import("../domain/id.zig").MessageId;

const test_account = AccountId.from_int(1);
const other_account = AccountId.from_int(2);

fn message_with(id: u64, mailbox: Mailbox, timestamp_unix: i64) Message {
    return .{
        .id = MessageId.from_int(id),
        .account = test_account,
        .mailbox = mailbox,
        .timestamp_unix = timestamp_unix,
    };
}

test "replace_mailbox swaps one mailbox and preserves the others" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);

    const old_inbox = message_with(1, .inbox, 100);
    const sent = message_with(2, .sent, 200);
    try store.insert(&old_inbox);
    try store.insert(&sent);

    const fresh = [_]Message{
        message_with(3, .inbox, 400),
        message_with(4, .inbox, 300),
    };
    replace_mailbox(&store, test_account, .inbox, &fresh);

    try testing.expectEqual(@as(u32, 3), store.len);
    try testing.expectEqual(@as(u32, 2), store.count_in(.inbox, null));
    try testing.expectEqual(@as(u32, 1), store.count_in(.sent, null));
    try testing.expect(store.get(test_account, MessageId.from_int(1)) == null);
    try testing.expect(store.get(test_account, MessageId.from_int(3)) != null);
}

test "replace_mailbox with nothing truncates the mailbox to empty" {
    var store = try Store.init(testing.allocator, 4);
    defer store.deinit(testing.allocator);

    const old = message_with(1, .inbox, 100);
    try store.insert(&old);

    replace_mailbox(&store, test_account, .inbox, &.{});
    try testing.expectEqual(@as(u32, 0), store.len);
}

test "replace_mailbox truncates a fetch larger than the cache instead of failing" {
    var store = try Store.init(testing.allocator, 2);
    defer store.deinit(testing.allocator);

    const fresh = [_]Message{
        message_with(1, .inbox, 500),
        message_with(2, .inbox, 400),
        message_with(3, .inbox, 300),
    };
    replace_mailbox(&store, test_account, .inbox, &fresh);

    try testing.expectEqual(@as(u32, 2), store.len);
    try testing.expectEqual(MessageId.from_int(1), store.at(0).id);
    try testing.expectEqual(MessageId.from_int(2), store.at(1).id);
}

test "replace_mailbox leaves another account's mailbox alone" {
    var store = try Store.init(testing.allocator, 4);
    defer store.deinit(testing.allocator);

    const mine = message_with(1, .inbox, 100);
    var theirs = message_with(9, .inbox, 200);
    theirs.account = other_account;
    try store.insert(&mine);
    try store.insert(&theirs);

    replace_mailbox(&store, test_account, .inbox, &.{});
    try testing.expect(store.get(test_account, MessageId.from_int(1)) == null);
    try testing.expect(store.get(other_account, MessageId.from_int(9)) != null);
}

test "replace_named files messages in one of the account's folders" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);
    // A message already there, in the same folder and in another one.
    var stale = message_with(1, .inbox, 100);
    stale.account = test_account;
    stale.named = 3;
    var kept = message_with(2, .inbox, 200);
    kept.account = test_account;
    kept.named = 4;
    try store.insert(&stale);
    try store.insert(&kept);

    const fresh = message_with(9, .sent, 300);
    replace_named(&store, test_account, 3, &.{fresh});

    // The folder was replaced, not appended to, and the message is stamped with
    // the slot it was asked for, not with the mailbox it says.
    try testing.expectEqual(@as(u32, 2), store.len);
    var found: ?*Message = null;
    for (store.messages[0..store.len]) |*message| {
        if (message.id == MessageId.from_int(9)) found = message;
    }
    try testing.expectEqual(@as(u8, 3), found.?.named);
    try testing.expectEqual(Mailbox.sent, found.?.mailbox);
}

test "replace_mailbox stamps the mailbox it was asked for" {
    var store = try Store.init(testing.allocator, 4);
    defer store.deinit(testing.allocator);
    const message = message_with(1, .inbox, 100);
    // A server that answers with the wrong mailbox cannot file the mail elsewhere.
    replace_mailbox(&store, test_account, .trash, &.{message});
    try testing.expectEqual(Mailbox.trash, store.at(0).mailbox);
    try testing.expectEqual(test_account, store.at(0).account);
}
