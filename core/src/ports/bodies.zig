//! The body cache port: the reader should not wait for the network twice.
//!
//! Envelopes make the list instant; bodies make *reading* instant. The cache is
//! best effort in both directions: a miss is a normal fetch, and a failure to
//! save is a slower next time, never an error the user sees.

const std = @import("std");
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const MessageId = @import("../domain/id.zig").MessageId;
const AccountId = @import("../domain/id.zig").AccountId;
const limits = @import("../limits.zig");

pub const Error = error{Unavailable};

pub const BodyCache = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Copies a cached body into `out`; null means "not cached".
        load: *const fn (context: *anyopaque, account: AccountId, mailbox: Mailbox, id: MessageId, out: []u8) Error!?[]const u8,
        save: *const fn (context: *anyopaque, account: AccountId, mailbox: Mailbox, id: MessageId, body: []const u8) Error!void,
    };

    pub fn load(self: BodyCache, account: AccountId, mailbox: Mailbox, id: MessageId, out: []u8) Error!?[]const u8 {
        return self.vtable.load(self.context, account, mailbox, id, out);
    }

    pub fn save(self: BodyCache, account: AccountId, mailbox: Mailbox, id: MessageId, body: []const u8) Error!void {
        return self.vtable.save(self.context, account, mailbox, id, body);
    }
};

/// In-memory cache for tests: one slot, plus failure switches.
pub const Memory = struct {
    stored: [limits.body_max]u8 = undefined,
    stored_len: u32 = 0,
    have: bool = false,
    load_failure: bool = false,
    save_failure: bool = false,
    loads: u32 = 0,
    saves: u32 = 0,
    last_id: MessageId = .unknown,
    last_mailbox: Mailbox = .inbox,
    last_account: AccountId = .unknown,

    pub fn cache(self: *Memory) BodyCache {
        return .{ .context = self, .vtable = &.{ .load = loadThunk, .save = saveThunk } };
    }

    fn loadThunk(
        context: *anyopaque,
        account: AccountId,
        mailbox: Mailbox,
        id: MessageId,
        out: []u8,
    ) Error!?[]const u8 {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.loads += 1;
        self.last_account = account;
        self.last_mailbox = mailbox;
        self.last_id = id;
        if (self.load_failure) return error.Unavailable;
        if (!self.have) return null;
        const length = @min(self.stored_len, @as(u32, @intCast(out.len)));
        @memcpy(out[0..length], self.stored[0..length]);
        return out[0..length];
    }

    fn saveThunk(
        context: *anyopaque,
        account: AccountId,
        mailbox: Mailbox,
        id: MessageId,
        body: []const u8,
    ) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.saves += 1;
        self.last_account = account;
        self.last_mailbox = mailbox;
        self.last_id = id;
        if (self.save_failure) return error.Unavailable;

        const length = @min(body.len, self.stored.len);
        @memcpy(self.stored[0..length], body[0..length]);
        self.stored_len = @intCast(length);
        self.have = true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Memory body cache: save then load round-trips and records the key" {
    var memory: Memory = .{};
    const cache = memory.cache();
    try cache.save(AccountId.from_int(2), .sent, MessageId.from_int(42), "hello");

    var out: [32]u8 = undefined;
    const body = (try cache.load(AccountId.from_int(2), .sent, MessageId.from_int(42), &out)).?;
    try testing.expectEqualStrings("hello", body);
    try testing.expectEqual(MessageId.from_int(42), memory.last_id);
    try testing.expectEqual(Mailbox.sent, memory.last_mailbox);
    try testing.expectEqual(AccountId.from_int(2), memory.last_account);
}

test "Memory body cache: a miss is null, and failures surface as Unavailable" {
    var memory: Memory = .{};
    var out: [8]u8 = undefined;
    try testing.expect(try memory.cache().load(AccountId.from_int(1), .inbox, MessageId.from_int(1), &out) == null);

    memory.load_failure = true;
    try testing.expectError(error.Unavailable, memory.cache().load(AccountId.from_int(1), .inbox, MessageId.from_int(1), &out));

    memory.save_failure = true;
    try testing.expectError(error.Unavailable, memory.cache().save(AccountId.from_int(1), .inbox, MessageId.from_int(1), "x"));
}

test "Memory body cache: a small buffer truncates instead of overflowing" {
    var memory: Memory = .{};
    try memory.cache().save(AccountId.from_int(1), .inbox, MessageId.from_int(1), "0123456789");
    var out: [4]u8 = undefined;
    const body = (try memory.cache().load(AccountId.from_int(1), .inbox, MessageId.from_int(1), &out)).?;
    try testing.expectEqualStrings("0123", body);
}
