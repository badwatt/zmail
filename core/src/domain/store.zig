//! The local message cache: a fixed-capacity array, allocated once at startup.
//!
//! No growth, no reallocation, no allocator on the hot path. Insert keeps the
//! list ordered newest-first so the list view is a slice, not a sort.
//!
//! Eviction zeroes the vacated slot: mail the user deleted must not stay
//! readable in the process's memory.

const std = @import("std");
const assert = std.debug.assert;
const Message = @import("message.zig").Message;
const MessageId = @import("id.zig").MessageId;
const Mailbox = @import("mailbox.zig").Mailbox;
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

    pub fn index_of(self: *const Store, id: MessageId) ?u32 {
        var index: u32 = 0;
        while (index < self.len) : (index += 1) {
            if (self.messages[index].id == id) return index;
        }
        return null;
    }

    pub fn get(self: *Store, id: MessageId) ?*Message {
        const index = self.index_of(id) orelse return null;
        return self.at(index);
    }

    pub fn get_const(self: *const Store, id: MessageId) ?*const Message {
        const index = self.index_of(id) orelse return null;
        return self.at_const(index);
    }

    /// Removes and returns the message, shifting the tail down and zeroing the
    /// vacated slot.
    pub fn remove_by_id(self: *Store, id: MessageId) ?Message {
        const index = self.index_of(id) orelse return null;
        const removed = self.messages[index];

        var cursor = index;
        while (cursor + 1 < self.len) : (cursor += 1) {
            self.messages[cursor] = self.messages[cursor + 1];
        }
        self.len -= 1;
        self.messages[self.len] = std.mem.zeroes(Message);
        return removed;
    }

    /// Removes every message in `mailbox`, compacting in one pass. Returns how
    /// many were removed. Used when a mailbox is refreshed from the server.
    pub fn remove_in(self: *Store, mailbox: Mailbox) u32 {
        var read: u32 = 0;
        var write: u32 = 0;
        while (read < self.len) : (read += 1) {
            if (self.messages[read].mailbox == mailbox) continue;
            if (write != read) self.messages[write] = self.messages[read];
            write += 1;
        }
        const removed = self.len - write;
        @memset(self.messages[write..self.len], std.mem.zeroes(Message));
        self.len = write;
        assert(self.len <= self.capacity());
        return removed;
    }

    pub fn set_flags(self: *Store, id: MessageId, flags: Flags) bool {
        const message = self.get(id) orelse return false;
        message.flags = flags;
        return true;
    }

    pub fn count_in(self: *const Store, mailbox: Mailbox) u32 {
        var count: u32 = 0;
        var index: u32 = 0;
        while (index < self.len) : (index += 1) {
            if (self.messages[index].mailbox == mailbox) count += 1;
        }
        return count;
    }

    pub fn unread_in(self: *const Store, mailbox: Mailbox) u32 {
        var count: u32 = 0;
        var index: u32 = 0;
        while (index < self.len) : (index += 1) {
            const message = &self.messages[index];
            if (message.mailbox != mailbox) continue;
            if (message.is_unread()) count += 1;
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn message_with(id: u64, mailbox: Mailbox, timestamp_unix: i64) Message {
    return .{
        .id = MessageId.from_int(id),
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

test "Store: insert keeps the list ordered newest-first" {
    var store = try new_store(4);
    defer store.deinit(testing.allocator);

    const oldest = message_with(1, .inbox, 100);
    const newest = message_with(2, .inbox, 300);
    const middle = message_with(3, .inbox, 200);
    try store.insert(&oldest);
    try store.insert(&newest);
    try store.insert(&middle);

    try testing.expectEqual(@as(u32, 3), store.len);
    try testing.expectEqual(MessageId.from_int(2), store.at(0).id);
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

test "Store: index_of and get find by id, and miss cleanly" {
    var store = try new_store(2);
    defer store.deinit(testing.allocator);

    const message = message_with(5, .inbox, 100);
    try store.insert(&message);

    try testing.expectEqual(@as(u32, 0), store.index_of(MessageId.from_int(5)).?);
    try testing.expectEqual(@as(u32, 0), store.get(MessageId.from_int(5)).?.id.to_int() - 5);
    try testing.expect(store.index_of(MessageId.from_int(6)) == null);
    try testing.expect(store.get(MessageId.from_int(6)) == null);
    try testing.expect(store.get_const(MessageId.from_int(5)) != null);
    try testing.expect(store.get_const(MessageId.from_int(6)) == null);
}

test "Store: remove_by_id shifts the tail down and zeroes the slot" {
    var store = try new_store(3);
    defer store.deinit(testing.allocator);

    const newest = message_with(3, .inbox, 300);
    const middle = message_with(2, .inbox, 200);
    const oldest = message_with(1, .inbox, 100);
    try store.insert(&oldest);
    try store.insert(&middle);
    try store.insert(&newest);

    const removed = store.remove_by_id(MessageId.from_int(2)).?;
    try testing.expectEqual(MessageId.from_int(2), removed.id);
    try testing.expectEqual(@as(u32, 2), store.len);
    try testing.expectEqual(MessageId.from_int(3), store.at(0).id);
    try testing.expectEqual(MessageId.from_int(1), store.at(1).id);

    const zeroed = store.messages[2];
    try testing.expectEqual(MessageId.unknown, zeroed.id);
    try testing.expectEqual(@as(i64, 0), zeroed.timestamp_unix);
    try testing.expect(zeroed.subject.is_empty());
}

test "Store: remove_by_id reports a miss" {
    var store = try new_store(1);
    defer store.deinit(testing.allocator);
    try testing.expect(store.remove_by_id(MessageId.from_int(9)) == null);
}

test "Store: remove_by_id works at the head and the tail" {
    var store = try new_store(2);
    defer store.deinit(testing.allocator);

    const newest = message_with(2, .inbox, 200);
    const oldest = message_with(1, .inbox, 100);
    try store.insert(&oldest);
    try store.insert(&newest);

    _ = store.remove_by_id(MessageId.from_int(2));
    try testing.expectEqual(@as(u32, 1), store.len);
    try testing.expectEqual(MessageId.from_int(1), store.at(0).id);

    _ = store.remove_by_id(MessageId.from_int(1));
    try testing.expectEqual(@as(u32, 0), store.len);
}

test "Store: set_flags updates a known message and reports a miss" {
    var store = try new_store(1);
    defer store.deinit(testing.allocator);

    const message = message_with(1, .inbox, 100);
    try store.insert(&message);

    try testing.expect(store.set_flags(MessageId.from_int(1), .{ .unread = false }));
    try testing.expect(!store.at(0).is_unread());
    try testing.expect(!store.set_flags(MessageId.from_int(2), .{ .unread = false }));
}

test "Store: count_in and unread_in are per mailbox" {
    var store = try new_store(4);
    defer store.deinit(testing.allocator);

    const inbox_read = Message{ .id = MessageId.from_int(1), .mailbox = .inbox, .flags = .{ .unread = false } };
    const inbox_unread = Message{ .id = MessageId.from_int(2), .mailbox = .inbox, .flags = .{ .unread = true } };
    const sent = Message{ .id = MessageId.from_int(3), .mailbox = .sent, .flags = .{ .unread = false } };
    try store.insert(&inbox_read);
    try store.insert(&inbox_unread);
    try store.insert(&sent);

    try testing.expectEqual(@as(u32, 2), store.count_in(.inbox));
    try testing.expectEqual(@as(u32, 1), store.unread_in(.inbox));
    try testing.expectEqual(@as(u32, 1), store.count_in(.sent));
    try testing.expectEqual(@as(u32, 0), store.unread_in(.sent));
    try testing.expectEqual(@as(u32, 0), store.count_in(.trash));
}
