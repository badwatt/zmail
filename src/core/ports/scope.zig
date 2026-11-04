//! The scope the reader left in: one account, or all of them.
//!
//! A preference, not a secret and not state: one short label, kept next to the
//! config so a restart opens where you left off. An empty label means "all
//! accounts", which is also what a missing file means.

const std = @import("std");
const Text = @import("../domain/text.zig").Text;
const limits = @import("../limits.zig");

pub const Error = error{Unavailable};

pub const Scope = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Copies the remembered label into `out`; false when there is none.
        load: *const fn (context: *anyopaque, out: *Text(limits.label_max)) bool,
        /// An empty label remembers "all accounts".
        save: *const fn (context: *anyopaque, label: []const u8) Error!void,
    };

    pub fn load(self: Scope, out: *Text(limits.label_max)) bool {
        return self.vtable.load(self.context, out);
    }

    pub fn save(self: Scope, label: []const u8) Error!void {
        return self.vtable.save(self.context, label);
    }
};

/// In-memory scope for tests.
pub const Memory = struct {
    remembered: Text(limits.label_max) = .{},
    save_calls: u32 = 0,
    fail: bool = false,

    pub fn scope(self: *Memory) Scope {
        return .{ .context = self, .vtable = &.{ .load = loadThunk, .save = saveThunk } };
    }

    fn loadThunk(context: *anyopaque, out: *Text(limits.label_max)) bool {
        const self: *Memory = @ptrCast(@alignCast(context));
        if (self.remembered.is_empty()) return false;
        out.set(self.remembered.slice());
        return true;
    }

    fn saveThunk(context: *anyopaque, label: []const u8) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.save_calls += 1;
        if (self.fail) return error.Unavailable;
        self.remembered.set(label);
    }
};

const testing = std.testing;

test "the scope remembers a label, and an empty one means all accounts" {
    var memory: Memory = .{};
    const scope = memory.scope();

    var out: Text(limits.label_max) = .{};
    try testing.expect(!scope.load(&out));

    try scope.save("work");
    try testing.expect(scope.load(&out));
    try testing.expectEqualStrings("work", out.slice());

    try scope.save("");
    try testing.expect(!scope.load(&out));
    try testing.expectEqual(@as(u32, 2), memory.save_calls);
}

test "a failing scope is not fatal: saving reports, loading says nothing" {
    var memory: Memory = .{ .fail = true };
    const scope = memory.scope();
    try testing.expectError(error.Unavailable, scope.save("work"));

    var out: Text(limits.label_max) = .{};
    try testing.expect(!scope.load(&out));
}
