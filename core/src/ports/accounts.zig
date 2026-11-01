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

    pub const VTable = struct {
        /// Rewrites the config (and deletes the credential) without `account`.
        remove: *const fn (context: *anyopaque, account: AccountId) Error!void,
        /// Runs the assistant and appends the new account; returns its label.
        add: *const fn (context: *anyopaque, label: []u8) Error![]const u8,
    };

    pub fn remove(self: Accounts, account: AccountId) Error!void {
        return self.vtable.remove(self.context, account);
    }

    pub fn add(self: Accounts, label: []u8) Error![]const u8 {
        return self.vtable.add(self.context, label);
    }
};

/// In-memory double: records calls and can fail on demand.
pub const Memory = struct {
    removed: u32 = 0,
    added: u32 = 0,
    fail: bool = false,
    last_removed: AccountId = .unknown,
    new_label: []const u8 = "new",

    pub fn accounts(self: *Memory) Accounts {
        return .{ .context = self, .vtable = &.{ .remove = removeThunk, .add = addThunk } };
    }

    fn removeThunk(context: *anyopaque, account: AccountId) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.removed += 1;
        self.last_removed = account;
        if (self.fail) return error.Unavailable;
    }

    fn addThunk(context: *anyopaque, label: []u8) Error![]const u8 {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.added += 1;
        if (self.fail) return error.Unavailable;
        const length = @min(self.new_label.len, label.len);
        @memcpy(label[0..length], self.new_label[0..length]);
        return label[0..length];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Memory accounts: remove and add record what they were asked" {
    var memory: Memory = .{};
    const accounts = memory.accounts();

    try accounts.remove(AccountId.from_int(2));
    try testing.expectEqual(@as(u32, 1), memory.removed);
    try testing.expectEqual(AccountId.from_int(2), memory.last_removed);

    var label: [limits.label_max]u8 = undefined;
    try testing.expectEqualStrings("new", try accounts.add(&label));
    try testing.expectEqual(@as(u32, 1), memory.added);
}

test "Memory accounts: failures surface as Unavailable" {
    var memory: Memory = .{ .fail = true };
    try testing.expectError(error.Unavailable, memory.accounts().remove(AccountId.from_int(1)));
    var label: [limits.label_max]u8 = undefined;
    try testing.expectError(error.Unavailable, memory.accounts().add(&label));
}
