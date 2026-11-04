//! The cache port: keep the last known envelopes so a restart is instant.
//!
//! The application still calls the mail port for fresh data; this port only
//! shortens the wait and makes offline reading possible. A cache miss is never
//! an error: it just means "fetch".

const std = @import("std");
const Message = @import("../domain/message.zig").Message;
const MessageId = @import("../domain/id.zig").MessageId;
const AccountId = @import("../domain/id.zig").AccountId;
const Mailbox = @import("../domain/mailbox.zig").Mailbox;

pub const Error = error{Unavailable};

pub const Cache = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Copies cached envelopes into `out` and returns how many were read.
        load: *const fn (context: *anyopaque, account: AccountId, mailbox: Mailbox, out: []Message) Error!u32,
        /// Replaces the cached copy of one mailbox.
        save: *const fn (context: *anyopaque, account: AccountId, mailbox: Mailbox, messages: []const Message) Error!void,
    };

    pub fn load(self: Cache, account: AccountId, mailbox: Mailbox, out: []Message) Error!u32 {
        return self.vtable.load(self.context, account, mailbox, out);
    }

    pub fn save(self: Cache, account: AccountId, mailbox: Mailbox, messages: []const Message) Error!void {
        return self.vtable.save(self.context, account, mailbox, messages);
    }
};

/// In-memory cache for tests: returns a scripted count and records saves.
pub const Memory = struct {
    /// What `load` reports. Zero means "nothing cached".
    load_count: u32 = 0,
    load_failure: bool = false,
    save_failure: bool = false,
    loads: u32 = 0,
    saves: u32 = 0,
    last_account: AccountId = .unknown,
    last_mailbox: Mailbox = .inbox,
    last_saved: u32 = 0,

    pub fn cache(self: *Memory) Cache {
        return .{ .context = self, .vtable = &.{ .load = loadThunk, .save = saveThunk } };
    }

    fn loadThunk(context: *anyopaque, account: AccountId, mailbox: Mailbox, out: []Message) Error!u32 {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.loads += 1;
        self.last_account = account;
        self.last_mailbox = mailbox;
        if (self.load_failure) return error.Unavailable;

        const count = @min(self.load_count, @as(u32, @intCast(out.len)));
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            out[index] = .{
                .id = MessageId.from_int(index + 1),
                .account = account,
                .mailbox = mailbox,
                .timestamp_unix = @as(i64, 1000) - index,
            };
            out[index].subject.set("cached");
        }
        return count;
    }

    fn saveThunk(context: *anyopaque, account: AccountId, mailbox: Mailbox, messages: []const Message) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.saves += 1;
        self.last_account = account;
        self.last_mailbox = mailbox;
        self.last_saved = @intCast(messages.len);
        if (self.save_failure) return error.Unavailable;
    }
};

const testing = std.testing;

test "Memory cache: load reports the scripted count and records the call" {
    var memory: Memory = .{ .load_count = 3 };
    var out: [4]Message = undefined;
    try testing.expectEqual(@as(u32, 3), try memory.cache().load(AccountId.from_int(2), .sent, &out));
    try testing.expectEqual(@as(u32, 1), memory.loads);
    try testing.expectEqual(AccountId.from_int(2), memory.last_account);
    try testing.expectEqual(Mailbox.sent, memory.last_mailbox);
}

test "Memory cache: load is bounded by the output buffer" {
    var memory: Memory = .{ .load_count = 9 };
    var out: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 2), try memory.cache().load(AccountId.from_int(1), .inbox, &out));
}

test "Memory cache: save records the count and failures pass through" {
    var memory: Memory = .{};
    try memory.cache().save(AccountId.from_int(1), .inbox, &.{ .{}, .{} });
    try testing.expectEqual(@as(u32, 1), memory.saves);
    try testing.expectEqual(@as(u32, 2), memory.last_saved);

    memory.save_failure = true;
    try testing.expectError(error.Unavailable, memory.cache().save(AccountId.from_int(1), .inbox, &.{}));

    memory.load_failure = true;
    var out: [1]Message = undefined;
    try testing.expectError(error.Unavailable, memory.cache().load(AccountId.from_int(1), .inbox, &out));
}
