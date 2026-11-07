//! What the reader chose with a key and expects to still be true tomorrow.
//!
//! One flag today -- whether pictures are shown -- and it is a preference, not a
//! secret: one line in a file next to the config. Off until asked for, because a
//! message that fetches a URL tells a stranger that the mail was read.

const std = @import("std");

pub const Error = error{Unavailable};

pub const Preferences = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Whether pictures are shown, as the last run left it.
        load_images: *const fn (context: *anyopaque) bool,
        save_images: *const fn (context: *anyopaque, on: bool) Error!void,
    };

    pub fn load_images(self: Preferences) bool {
        return self.vtable.load_images(self.context);
    }

    pub fn save_images(self: Preferences, on: bool) Error!void {
        return self.vtable.save_images(self.context, on);
    }
};

/// In-memory preferences for tests.
pub const Memory = struct {
    images: bool = false,
    saves: u32 = 0,
    fail: bool = false,

    pub fn prefs(self: *Memory) Preferences {
        return .{ .context = self, .vtable = &.{ .load_images = loadThunk, .save_images = saveThunk } };
    }

    fn loadThunk(context: *anyopaque) bool {
        const self: *Memory = @ptrCast(@alignCast(context));
        if (self.fail) return false;
        return self.images;
    }

    fn saveThunk(context: *anyopaque, on: bool) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.saves += 1;
        if (self.fail) return error.Unavailable;
        self.images = on;
    }
};

const testing = std.testing;

test "the pictures preference is off until someone turns it on" {
    var memory: Memory = .{};
    const prefs = memory.prefs();
    try testing.expect(!prefs.load_images());

    try prefs.save_images(true);
    try testing.expect(prefs.load_images());
    try testing.expectEqual(@as(u32, 1), memory.saves);

    // And back off, because a key that only goes one way is half a key.
    try prefs.save_images(false);
    try testing.expect(!prefs.load_images());
}

test "a preference that cannot be kept is not fatal" {
    var memory: Memory = .{ .fail = true };
    const prefs = memory.prefs();
    try testing.expectError(error.Unavailable, prefs.save_images(true));
    // A file that cannot be read answers the default rather than an error.
    try testing.expect(!prefs.load_images());
}
