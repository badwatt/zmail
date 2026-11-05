//! The local message cache: a fixed-capacity array, allocated once at startup.
//!
//! Messages from several accounts share one array ordered newest-first, which
//! is what the unified view needs. UIDs are per account, so every lookup pairs
//! an `AccountId` with a `MessageId`.

const std = @import("std");
const assert = std.debug.assert;
const Message = @import("message.zig").Message;
const MessageId = @import("id.zig").MessageId;
const AccountId = @import("id.zig").AccountId;
const Mailbox = @import("mailbox.zig").Mailbox;
const folder = @import("folder.zig");
const Flags = @import("message.zig").Flags;

pub const Store = struct {
    messages: []Message,
    len: u32 = 0,

    pub const InsertError = error{Full};

    pub fn init(gpa: std.mem.Allocator, slots: u32) error{OutOfMemory}!Store {
        assert(slots > 0);
        return .{ .messages = try gpa.alloc(Message, slots) };
    }

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        @memset(self.messages, std.mem.zeroes(Message));
        gpa.free(self.messages);
        self.* = undefined;
    }

    pub fn capacity(self: *const Store) u32 {
        return @intCast(self.messages.len);
    }

    /// Inserts a copy, keeping the list ordered newest-first. Ties keep the
    /// earlier arrival first.
    pub fn insert(self: *Store, message: *const Message) InsertError!void {
        assert(message.id.is_known());
        assert(message.account.is_known());
        if (self.len == self.capacity()) return error.Full;

        var position: u32 = self.len;
        while (position > 0) : (position -= 1) {
            if (self.messages[position - 1].timestamp_unix >= message.timestamp_unix) break;
        }

        var cursor: u32 = self.len;
        while (cursor > position) : (cursor -= 1) {
            self.messages[cursor] = self.messages[cursor - 1];
        }
        self.messages[position] = message.*;
        self.len += 1;
        assert(self.len <= self.capacity());
    }

    pub fn at(self: *Store, index: u32) *Message {
        assert(index < self.len);
        return &self.messages[index];
    }

    pub fn at_const(self: *const Store, index: u32) *const Message {
        assert(index < self.len);
        return &self.messages[index];
    }

    pub fn index_of(self: *const Store, account: AccountId, id: MessageId) ?u32 {
        assert(account.is_known());
        var index: u32 = 0;
        while (index < self.len) : (index += 1) {
            const message = &self.messages[index];
            if (message.id == id and message.account == account) return index;
        }
        return null;
    }

    pub fn get(self: *Store, account: AccountId, id: MessageId) ?*Message {
        const index = self.index_of(account, id) orelse return null;
        return self.at(index);
    }

    pub fn get_const(self: *const Store, account: AccountId, id: MessageId) ?*const Message {
        const index = self.index_of(account, id) orelse return null;
        return self.at_const(index);
    }

    /// Removes and returns the message, shifting the tail down and zeroing the
    /// vacated slot.
    pub fn remove_by_id(self: *Store, account: AccountId, id: MessageId) ?Message {
        const index = self.index_of(account, id) orelse return null;
        const removed = self.messages[index];

        var cursor = index;
        while (cursor + 1 < self.len) : (cursor += 1) {
            self.messages[cursor] = self.messages[cursor + 1];
        }
        self.len -= 1;
        self.messages[self.len] = std.mem.zeroes(Message);
        return removed;
    }

    /// Removes every message of one account, compacting in one pass.
    pub fn remove_account(self: *Store, account: AccountId) u32 {
        assert(account.is_known());
        var read: u32 = 0;
        var write: u32 = 0;
        while (read < self.len) : (read += 1) {
            if (self.messages[read].account == account) continue;
            self.messages[write] = self.messages[read];
            write += 1;
        }
        const removed = self.len - write;
        while (self.len > write) {
            self.len -= 1;
            self.messages[self.len] = std.mem.zeroes(Message);
        }
        return removed;
    }

    /// Removes every message of `account` in `mailbox`, compacting in one pass.
    pub fn remove_in(self: *Store, account: AccountId, mailbox: Mailbox) u32 {
        assert(account.is_known());
        var read: u32 = 0;
        var write: u32 = 0;
        while (read < self.len) : (read += 1) {
            const message = &self.messages[read];
            if (message.account == account and message.mailbox == mailbox and message.named == folder.none) continue;
            if (write != read) self.messages[write] = self.messages[read];
            write += 1;
        }
        const removed = self.len - write;
        @memset(self.messages[write..self.len], std.mem.zeroes(Message));
        self.len = write;
        assert(self.len <= self.capacity());
        return removed;
    }

    pub fn set_flags(self: *Store, account: AccountId, id: MessageId, flags: Flags) bool {
        const message = self.get(account, id) orelse return false;
        message.flags = flags;
        return true;
    }

    /// Removes every message of `account` in one of its own folders.
    pub fn remove_named(self: *Store, account: AccountId, slot: u8) u32 {
        var read: u32 = 0;
        var write: u32 = 0;
        var removed: u32 = 0;
        while (read < self.len) : (read += 1) {
            const message = &self.messages[read];
            if (message.account == account and message.named == slot) {
                removed += 1;
                continue;
            }
            self.messages[write] = self.messages[read];
            write += 1;
        }
        self.len = write;
        return removed;
    }

    /// Counts messages in `mailbox`, optionally only one account (null = the
    /// unified view).
    pub fn count_in(self: *const Store, mailbox: Mailbox, account: ?AccountId) u32 {
        var count: u32 = 0;
        var index: u32 = 0;
        while (index < self.len) : (index += 1) {
            const message = &self.messages[index];
            if (message.mailbox != mailbox or message.named != folder.none) continue;
            if (account) |filter| {
                if (message.account != filter) continue;
            }
            count += 1;
        }
        return count;
    }

    pub fn unread_in(self: *const Store, mailbox: Mailbox, account: ?AccountId) u32 {
        var count: u32 = 0;
        var index: u32 = 0;
        while (index < self.len) : (index += 1) {
            const message = &self.messages[index];
            if (message.mailbox != mailbox or message.named != folder.none) continue;
            if (account) |filter| {
                if (message.account != filter) continue;
            }
            if (message.is_unread()) count += 1;
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const account_one = AccountId.from_int(1);
const account_two = AccountId.from_int(2);

fn message_with(id: u64, mailbox: Mailbox, timestamp_unix: i64) Message {
    return .{
        .id = MessageId.from_int(id),
        .account = account_one,
        .mailbox = mailbox,
        .timestamp_unix = timestamp_unix,
        .flags = .{ .unread = true },
    };
}

fn new_store(capacity: u32) !Store {
    return Store.init(testing.allocator, capacity);
}

test "Store: starts empty with the requested capacity" {
    var store = try new_store(4);
    defer store.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), store.len);
    try testing.expectEqual(@as(u32, 4), store.capacity());
}

test "Store: insert keeps the list ordered newest-first across accounts" {
    var store = try new_store(4);
    defer store.deinit(testing.allocator);

    const oldest = message_with(1, .inbox, 100);
    var newest = message_with(2, .inbox, 300);
    newest.account = account_two;
    const middle = message_with(3, .inbox, 200);
    try store.insert(&oldest);
    try store.insert(&newest);
    try store.insert(&middle);

    try testing.expectEqual(@as(u32, 3), store.len);
    try testing.expectEqual(MessageId.from_int(2), store.at(0).id);
    try testing.expectEqual(account_two, store.at(0).account);
    try testing.expectEqual(MessageId.from_int(3), store.at(1).id);
    try testing.expectEqual(MessageId.from_int(1), store.at(2).id);
}

test "Store: equal timestamps keep insertion order" {
    var store = try new_store(2);
    defer store.deinit(testing.allocator);

    const first = message_with(1, .inbox, 100);
    const second = message_with(2, .inbox, 100);
    try store.insert(&first);
    try store.insert(&second);

    try testing.expectEqual(MessageId.from_int(1), store.at(0).id);
    try testing.expectEqual(MessageId.from_int(2), store.at(1).id);
}

test "Store: refuses to insert past capacity" {
    var store = try new_store(1);
    defer store.deinit(testing.allocator);

    const only = message_with(1, .inbox, 100);
    try store.insert(&only);
    const extra = message_with(2, .inbox, 200);
    try testing.expectError(error.Full, store.insert(&extra));
}

test "Store: the same uid in two accounts is two messages" {
    var store = try new_store(4);
    defer store.deinit(testing.allocator);

    var one = message_with(7, .inbox, 100);
    var two = message_with(7, .inbox, 200);
    two.account = account_two;
    try store.insert(&one);
    try store.insert(&two);

    try testing.expectEqual(@as(u32, 2), store.len);
    try testing.expectEqual(@as(u32, 1), store.index_of(account_one, MessageId.from_int(7)).?);
    try testing.expectEqual(@as(u32, 0), store.index_of(account_two, MessageId.from_int(7)).?);
    try testing.expect(store.index_of(account_two, MessageId.from_int(8)) == null);
    try testing.expect(store.get(account_one, MessageId.from_int(7)) != null);
    try testing.expect(store.get_const(account_two, MessageId.from_int(7)) != null);
}

test "Store: remove_account removes every mailbox of one account" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);

    var first = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(1), .mailbox = .inbox };
    var second = Message{ .id = MessageId.from_int(1), .account = AccountId.from_int(2), .mailbox = .inbox };
    var third = Message{ .id = MessageId.from_int(2), .account = AccountId.from_int(1), .mailbox = .sent };
    try store.insert(&first);
    try store.insert(&second);
    try store.insert(&third);

    try testing.expectEqual(@as(u32, 2), store.remove_account(AccountId.from_int(1)));
    try testing.expectEqual(@as(u32, 1), store.len);
    try testing.expectEqual(AccountId.from_int(2), store.at(0).account);
    try testing.expectEqual(@as(u32, 0), store.remove_account(AccountId.from_int(9)));
}

test "Store: remove_by_id removes the right account's copy" {
    var store = try new_store(4);
    defer store.deinit(testing.allocator);

    var one = message_with(7, .inbox, 100);
    var two = message_with(7, .inbox, 200);
    two.account = account_two;
    try store.insert(&one);
    try store.insert(&two);

    const removed = store.remove_by_id(account_two, MessageId.from_int(7)).?;
    try testing.expectEqual(account_two, removed.account);
    try testing.expectEqual(@as(u32, 1), store.len);
    try testing.expect(store.get(account_one, MessageId.from_int(7)) != null);
    try testing.expect(store.get(account_two, MessageId.from_int(7)) == null);
    try testing.expect(store.remove_by_id(account_two, MessageId.from_int(7)) == null);

    const zeroed = store.messages[1];
    try testing.expectEqual(MessageId.unknown, zeroed.id);
    try testing.expectEqual(@as(i64, 0), zeroed.timestamp_unix);
}

test "Store: remove_by_id works at the head and the tail" {
    var store = try new_store(2);
    defer store.deinit(testing.allocator);

    const newest = message_with(2, .inbox, 200);
    const oldest = message_with(1, .inbox, 100);
    try store.insert(&oldest);
    try store.insert(&newest);

    _ = store.remove_by_id(account_one, MessageId.from_int(2));
    try testing.expectEqual(@as(u32, 1), store.len);
    try testing.expectEqual(MessageId.from_int(1), store.at(0).id);

    _ = store.remove_by_id(account_one, MessageId.from_int(1));
    try testing.expectEqual(@as(u32, 0), store.len);
}

test "Store: set_flags updates the right account's message" {
    var store = try new_store(2);
    defer store.deinit(testing.allocator);

    const message = message_with(1, .inbox, 100);
    try store.insert(&message);

    try testing.expect(store.set_flags(account_one, MessageId.from_int(1), .{ .unread = false }));
    try testing.expect(!store.at(0).is_unread());
    try testing.expect(!store.set_flags(account_two, MessageId.from_int(1), .{ .unread = false }));
    try testing.expect(!store.set_flags(account_one, MessageId.from_int(2), .{ .unread = false }));
}

test "Store: remove_in removes one account's mailbox only" {
    var store = try new_store(6);
    defer store.deinit(testing.allocator);

    const inbox_a = message_with(1, .inbox, 400);
    var inbox_other = message_with(2, .inbox, 300);
    inbox_other.account = account_two;
    const sent = message_with(3, .sent, 200);
    try store.insert(&inbox_a);
    try store.insert(&inbox_other);
    try store.insert(&sent);

    try testing.expectEqual(@as(u32, 1), store.remove_in(account_one, .inbox));
    try testing.expectEqual(@as(u32, 2), store.len);
    try testing.expect(store.get(account_one, MessageId.from_int(1)) == null);
    try testing.expect(store.get(account_two, MessageId.from_int(2)) != null);
    try testing.expectEqual(@as(u32, 0), store.remove_in(account_one, .inbox));
}

test "Store: counts honour the account filter" {
    var store = try new_store(4);
    defer store.deinit(testing.allocator);

    const one = message_with(1, .inbox, 400);
    const two = message_with(2, .inbox, 300);
    var other = message_with(3, .inbox, 200);
    other.account = account_two;
    var other_read = message_with(4, .inbox, 100);
    other_read.account = account_two;
    other_read.flags = .{ .unread = false };
    try store.insert(&one);
    try store.insert(&two);
    try store.insert(&other);
    try store.insert(&other_read);

    try testing.expectEqual(@as(u32, 4), store.count_in(.inbox, null));
    try testing.expectEqual(@as(u32, 2), store.count_in(.inbox, account_one));
    try testing.expectEqual(@as(u32, 2), store.count_in(.inbox, account_two));
    try testing.expectEqual(@as(u32, 0), store.count_in(.sent, null));

    try testing.expectEqual(@as(u32, 3), store.unread_in(.inbox, null));
    try testing.expectEqual(@as(u32, 2), store.unread_in(.inbox, account_one));
    try testing.expectEqual(@as(u32, 1), store.unread_in(.inbox, account_two));
}

test "Store: remove_named removes one account's own folder only" {
    var store = try Store.init(testing.allocator, 8);
    defer store.deinit(testing.allocator);
    var first = message_with(1, .inbox, 100);
    first.account = AccountId.from_int(1);
    first.named = 2;
    var second = message_with(2, .inbox, 200);
    second.account = AccountId.from_int(1);
    second.named = 2;
    var third = message_with(3, .inbox, 300);
    third.account = AccountId.from_int(2);
    third.named = 2;
    var canonical = message_with(4, .inbox, 400);
    canonical.account = AccountId.from_int(1);
    for ([_]Message{ first, second, third, canonical }) |message| try store.insert(&message);

    try testing.expectEqual(@as(u32, 2), store.remove_named(AccountId.from_int(1), 2));
    try testing.expectEqual(@as(u32, 2), store.len);
    // The other account's folder of the same slot, and the canonical inbox, stay.
    try testing.expectEqual(@as(u32, 1), store.count_in(.inbox, null));
}

test "Store: a message in one of the account's folders is not in a mailbox" {
    var store = try Store.init(testing.allocator, 4);
    defer store.deinit(testing.allocator);
    var message = message_with(1, .inbox, 100);
    message.named = 0;
    try store.insert(&message);

    // It is in Inbox's slot of the account's own list, not in Inbox.
    try testing.expectEqual(@as(u32, 0), store.count_in(.inbox, null));
    try testing.expectEqual(@as(u32, 0), store.unread_in(.inbox, null));
    try testing.expectEqual(@as(u32, 1), store.len);
}
