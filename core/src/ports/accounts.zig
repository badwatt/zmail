//! The accounts port: the session can add or remove an account, and the process
//! boundary owns the config file (and the assistant that fills it in).
//!
//! The session never parses or rewrites the config itself: that is I/O, and the
//! core stays free of it.

const std = @import("std");
const AccountId = @import("../domain/id.zig").AccountId;
const limits = @import("../limits.zig");

pub const Error = error{ Unavailable, Cancelled };

pub const Accounts = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Draft = struct {
        /// The `[account label]` section, ready to append or to replace with.
        text: []const u8,
        label: []const u8,
        password: []const u8,
        /// The account this draft replaces, or null for a new one.
        replaces: ?AccountId = null,
    };

    pub const VTable = struct {
        /// Rewrites the config (and deletes the credential) without `account`.
        remove: *const fn (context: *anyopaque, account: AccountId) Error!void,
        /// Adds an account, or replaces one; writes its sealed credential.
        save: *const fn (context: *anyopaque, draft: Accounts.Draft) Error!void,
    };

    pub fn remove(self: Accounts, account: AccountId) Error!void {
        return self.vtable.remove(self.context, account);
    }

    pub fn save(self: Accounts, draft: Draft) Error!void {
        return self.vtable.save(self.context, draft);
    }
};

/// In-memory double: records calls and can fail on demand.
pub const Memory = struct {
    removed: u32 = 0,
    saved: u32 = 0,
    fail: bool = false,
    last_removed: AccountId = .unknown,
    last_label: [limits.label_max]u8 = @splat(0),
    last_label_len: u8 = 0,
    last_replaces: ?AccountId = null,

    pub fn accounts(self: *Memory) Accounts {
        return .{ .context = self, .vtable = &.{ .remove = removeThunk, .save = saveThunk } };
    }

    fn removeThunk(context: *anyopaque, account: AccountId) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.removed += 1;
        self.last_removed = account;
        if (self.fail) return error.Unavailable;
    }

    fn saveThunk(context: *anyopaque, draft: Accounts.Draft) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.saved += 1;
        self.last_replaces = draft.replaces;
        const length = @min(draft.label.len, self.last_label.len);
        @memcpy(self.last_label[0..length], draft.label[0..length]);
        self.last_label_len = @intCast(length);
        if (self.fail) return error.Unavailable;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Memory accounts: remove and save record what they were asked" {
    var memory: Memory = .{};
    const accounts = memory.accounts();

    try accounts.remove(AccountId.from_int(2));
    try testing.expectEqual(@as(u32, 1), memory.removed);
    try testing.expectEqual(AccountId.from_int(2), memory.last_removed);

    try accounts.save(.{ .text = "x", .label = "new", .password = "pw" });
    try testing.expectEqual(@as(u32, 1), memory.saved);
    try testing.expectEqualStrings("new", memory.last_label[0..memory.last_label_len]);
    try testing.expect(memory.last_replaces == null);

    try accounts.save(.{ .text = "x", .label = "work", .password = "pw", .replaces = AccountId.from_int(3) });
    try testing.expectEqual(AccountId.from_int(3), memory.last_replaces.?);
}

test "Memory accounts: failures surface as Unavailable" {
    var memory: Memory = .{ .fail = true };
    try testing.expectError(error.Unavailable, memory.accounts().remove(AccountId.from_int(1)));
    try testing.expectError(
        error.Unavailable,
        memory.accounts().save(.{ .text = "x", .label = "new", .password = "pw" }),
    );
}
