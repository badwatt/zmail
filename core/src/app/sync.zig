//! Reconciling the local cache with what the server just sent.
//!
//! The store is a cache: a refresh replaces one mailbox wholesale, which keeps
//! flags and deletions from the server authoritative. Other mailboxes are
//! untouched, so switching tabs does not wipe what is already loaded.

const std = @import("std");
const Store = @import("../domain/store.zig").Store;
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const Message = @import("../domain/message.zig").Message;

pub fn replace_mailbox(store: *Store, mailbox: Mailbox, fetched: []const Message) void {
    _ = store.remove_in(mailbox);
    for (fetched) |*message| {
        // A server that sends more than the cache can hold is truncated, not
        // allowed to fail the refresh: partial mail is better than no mail.
        store.insert(message) catch {};
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const MessageId = @import("../domain/id.zig").MessageId;

fn message_with(id: u64, mailbox: Mailbox, timestamp_unix: i64) Message {
    return .{ .id = MessageId.from_int(id), .mailbox = mailbox, .timestamp_unix = timestamp_unix };
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
    replace_mailbox(&store, .inbox, &fresh);

    try testing.expectEqual(@as(u32, 3), store.len);
    try testing.expectEqual(@as(u32, 2), store.count_in(.inbox));
    try testing.expectEqual(@as(u32, 1), store.count_in(.sent));
    try testing.expect(store.get(MessageId.from_int(1)) == null);
    try testing.expect(store.get(MessageId.from_int(3)) != null);
}

test "replace_mailbox with nothing truncates the mailbox to empty" {
    var store = try Store.init(testing.allocator, 4);
    defer store.deinit(testing.allocator);

    const old = message_with(1, .inbox, 100);
    try store.insert(&old);

    replace_mailbox(&store, .inbox, &.{});
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
    replace_mailbox(&store, .inbox, &fresh);

    try testing.expectEqual(@as(u32, 2), store.len);
    try testing.expectEqual(MessageId.from_int(1), store.at(0).id);
    try testing.expectEqual(MessageId.from_int(2), store.at(1).id);
}
