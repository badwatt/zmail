//! The scope the reader left in: one account, or all of them -- and, for every
//! account, the folder it was reading.
//!
//! A preference, not a secret and not state: one short label and one folder name,
//! kept next to the config so a restart opens where you left off. An empty label
//! means "all accounts", which is also what a missing file means.

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
        /// The folder that account was reading, by the name the sidebar knows it
        /// by; false when it has never been opened, which means its first folder.
        load_folder: *const fn (context: *anyopaque, label: []const u8, out: *Text(limits.mailbox_name_max)) bool,
        /// Keeps it. Losing this is not fatal: the account opens on its first folder.
        save_folder: *const fn (context: *anyopaque, label: []const u8, folder: []const u8) Error!void,
    };

    pub fn load(self: Scope, out: *Text(limits.label_max)) bool {
        return self.vtable.load(self.context, out);
    }

    pub fn save(self: Scope, label: []const u8) Error!void {
        return self.vtable.save(self.context, label);
    }

    /// Where this account was, or false for an account that has never been opened.
    pub fn load_folder(self: Scope, label: []const u8, out: *Text(limits.mailbox_name_max)) bool {
        return self.vtable.load_folder(self.context, label, out);
    }

    pub fn save_folder(self: Scope, label: []const u8, folder: []const u8) Error!void {
        return self.vtable.save_folder(self.context, label, folder);
    }
};

/// In-memory scope for tests.
pub const Memory = struct {
    remembered: Text(limits.label_max) = .{},
    folder_place: [accounts_max]Place = @splat(.{}),
    folder_count: u8 = 0,
    save_calls: u32 = 0,
    fail: bool = false,

    pub const accounts_max = 8;

    pub const Place = struct {
        label: Text(limits.label_max) = .{},
        folder: Text(limits.mailbox_name_max) = .{},
    };

    pub fn scope(self: *Memory) Scope {
        return .{ .context = self, .vtable = &.{
            .load = loadThunk,
            .save = saveThunk,
            .load_folder = loadFolderThunk,
            .save_folder = saveFolderThunk,
        } };
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

    fn place_of(self: *Memory, label: []const u8) ?*Place {
        for (self.folder_place[0..self.folder_count]) |*place| {
            if (std.mem.eql(u8, place.label.slice(), label)) return place;
        }
        return null;
    }

    fn loadFolderThunk(context: *anyopaque, label: []const u8, out: *Text(limits.mailbox_name_max)) bool {
        const self: *Memory = @ptrCast(@alignCast(context));
        const place = self.place_of(label) orelse return false;
        if (place.folder.is_empty()) return false;
        out.set(place.folder.slice());
        return true;
    }

    fn saveFolderThunk(context: *anyopaque, label: []const u8, folder: []const u8) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        if (self.fail) return error.Unavailable;
        if (self.place_of(label)) |place| {
            place.folder.set(folder);
            return;
        }
        if (self.folder_count == accounts_max) return error.Unavailable;
        self.folder_place[self.folder_count] = .{};
        self.folder_place[self.folder_count].label.set(label);
        self.folder_place[self.folder_count].folder.set(folder);
        self.folder_count += 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

test "every account keeps its own folder, and none keeps nothing" {
    var memory: Memory = .{};
    const scope = memory.scope();
    var out: Text(limits.mailbox_name_max) = .{};

    try testing.expect(!scope.load_folder("work", &out));
    try scope.save_folder("work", "Sent");
    try scope.save_folder("home", "Drafts");
    try testing.expect(scope.load_folder("work", &out));
    try testing.expectEqualStrings("Sent", out.slice());
    try testing.expect(scope.load_folder("home", &out));
    try testing.expectEqualStrings("Drafts", out.slice());

    // Saving again moves the same account, it does not add a second one.
    try scope.save_folder("work", "Junk");
    try testing.expect(scope.load_folder("work", &out));
    try testing.expectEqualStrings("Junk", out.slice());
    try testing.expectEqual(@as(u8, 2), memory.folder_count);
    try testing.expect(!scope.load_folder("other", &out));
}

test "a failing scope is not fatal: saving reports, loading says nothing" {
    var memory: Memory = .{ .fail = true };
    const scope = memory.scope();
    try testing.expectError(error.Unavailable, scope.save("work"));

    var out: Text(limits.label_max) = .{};
    try testing.expect(!scope.load(&out));

    // A folder that cannot be kept is a restart on the first folder, not an error.
    try testing.expectError(error.Unavailable, scope.save_folder("work", "Sent"));
    var folder_out: Text(limits.mailbox_name_max) = .{};
    try testing.expect(!scope.load_folder("work", &folder_out));
}
