//! The cache port: keep the last known envelopes so a restart is instant.
//!
//! The application still calls the mail port for fresh data; this port only
//! shortens the wait and makes offline reading possible. A cache miss is never
//! an error: it just means "fetch".

const std = @import("std");
const Message = @import("../domain/message.zig").Message;
const MessageId = @import("../domain/id.zig").MessageId;
const Text = @import("../domain/text.zig").Text;
const cache_mod = @import("../cache.zig");

/// The folder record the cache reads and writes: names are slices the caller
/// copies, because the cache's buffer is reused.
pub const Folder = cache_mod.Folder;
const AccountId = @import("../domain/id.zig").AccountId;

pub const Error = error{Unavailable};

pub const Cache = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Copies cached envelopes into `out` and returns how many were read.
        ///
        /// `folder` is the cache's name for the folder: one of the six by its
        /// title, or the server's own name for the folders `LIST` added.
        load: *const fn (context: *anyopaque, account: AccountId, folder: []const u8, out: []Message) Error!u32,
        /// Replaces the cached copy of one folder.
        save: *const fn (context: *anyopaque, account: AccountId, folder: []const u8, messages: []const Message) Error!void,
        /// The folders an account had the last time its server said: the sidebar
        /// is there before the network is.
        load_folders: *const fn (context: *anyopaque, account: AccountId, out: []Folder) Error!u32 = no_folders,
        save_folders: *const fn (context: *anyopaque, account: AccountId, folders: []const Folder) Error!void = drop_folders,
    };

    pub fn load(self: Cache, account: AccountId, folder: []const u8, out: []Message) Error!u32 {
        return self.vtable.load(self.context, account, folder, out);
    }

    pub fn save(self: Cache, account: AccountId, folder: []const u8, messages: []const Message) Error!void {
        return self.vtable.save(self.context, account, folder, messages);
    }

    pub fn load_folders(self: Cache, account: AccountId, out: []Folder) Error!u32 {
        return self.vtable.load_folders(self.context, account, out);
    }

    pub fn save_folders(self: Cache, account: AccountId, folders: []const Folder) Error!void {
        return self.vtable.save_folders(self.context, account, folders);
    }

    /// A cache that does not keep folders (the demo's, a test's) is not an error:
    /// the sidebar just waits for the server like it used to.
    fn no_folders(_: *anyopaque, _: AccountId, _: []Folder) Error!u32 {
        return 0;
    }

    fn drop_folders(_: *anyopaque, _: AccountId, _: []const Folder) Error!void {}
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
    last_folder: Text(64) = .{},
    last_saved: u32 = 0,

    /// What the folder cache holds for the tests: written by `save_folders`,
    /// read back by `load_folders`, so a test sees the round trip.
    folders: [16]cache_mod.Folder = @splat(.{}),
    folder_names: [16][96]u8 = @splat(@splat(0)),
    folder_count: u8 = 0,
    folder_titles: [16][96]u8 = @splat(@splat(0)),
    folder_loads: u32 = 0,
    folder_saves: u32 = 0,

    pub fn cache(self: *Memory) Cache {
        return .{ .context = self, .vtable = &.{
            .load = loadThunk,
            .save = saveThunk,
            .load_folders = loadFoldersThunk,
            .save_folders = saveFoldersThunk,
        } };
    }

    fn loadFoldersThunk(context: *anyopaque, account: AccountId, out: []Folder) Error!u32 {
        _ = account;
        const self: *Memory = @ptrCast(@alignCast(context));
        self.folder_loads += 1;
        const count = @min(@as(usize, self.folder_count), out.len);
        for (self.folders[0..count], 0..) |folder, index| {
            out[index] = .{
                .name = self.folder_names[index][0..folder.name.len],
                .title = self.folder_titles[index][0..folder.title.len],
                .canonical = folder.canonical,
                .unread = folder.unread,
            };
        }
        return @intCast(count);
    }

    fn saveFoldersThunk(context: *anyopaque, account: AccountId, folders: []const Folder) Error!void {
        _ = account;
        const self: *Memory = @ptrCast(@alignCast(context));
        self.folder_saves += 1;
        const count = @min(folders.len, self.folders.len);
        self.folder_count = @intCast(count);
        for (folders[0..count], 0..) |folder, index| {
            self.folders[index] = .{ .canonical = folder.canonical, .unread = folder.unread };
            const name = folder.name[0..@min(folder.name.len, self.folder_names[index].len)];
            @memcpy(self.folder_names[index][0..name.len], name);
            self.folders[index].name = self.folder_names[index][0..name.len];
            const title = folder.title[0..@min(folder.title.len, self.folder_titles[index].len)];
            @memcpy(self.folder_titles[index][0..title.len], title);
            self.folders[index].title = self.folder_titles[index][0..title.len];
        }
    }

    fn loadThunk(context: *anyopaque, account: AccountId, folder: []const u8, out: []Message) Error!u32 {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.loads += 1;
        self.last_account = account;
        self.last_folder.set(folder);
        if (self.load_failure) return error.Unavailable;

        const count = @min(self.load_count, @as(u32, @intCast(out.len)));
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            out[index] = .{
                .id = MessageId.from_int(index + 1),
                .account = account,
                .timestamp_unix = @as(i64, 1000) - index,
            };
            out[index].subject.set("cached");
        }
        return count;
    }

    fn saveThunk(context: *anyopaque, account: AccountId, folder: []const u8, messages: []const Message) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.saves += 1;
        self.last_account = account;
        self.last_folder.set(folder);
        self.last_saved = @intCast(messages.len);
        if (self.save_failure) return error.Unavailable;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Mailbox = @import("../domain/mailbox.zig").Mailbox;

test "Memory cache: load reports the scripted count and records the call" {
    var memory: Memory = .{ .load_count = 3 };
    var out: [4]Message = undefined;
    try testing.expectEqual(@as(u32, 3), try memory.cache().load(AccountId.from_int(2), "sent", &out));
    try testing.expectEqual(@as(u32, 1), memory.loads);
    try testing.expectEqual(AccountId.from_int(2), memory.last_account);
    try testing.expectEqualStrings("sent", memory.last_folder.slice());
}

test "Memory cache: load is bounded by the output buffer" {
    var memory: Memory = .{ .load_count = 9 };
    var out: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 2), try memory.cache().load(AccountId.from_int(1), "inbox", &out));
}

test "Memory cache: save records the count and failures pass through" {
    var memory: Memory = .{};
    try memory.cache().save(AccountId.from_int(1), "inbox", &.{ .{}, .{} });
    try testing.expectEqual(@as(u32, 1), memory.saves);
    try testing.expectEqual(@as(u32, 2), memory.last_saved);

    memory.save_failure = true;
    try testing.expectError(error.Unavailable, memory.cache().save(AccountId.from_int(1), "inbox", &.{}));

    memory.load_failure = true;
    var out: [1]Message = undefined;
    try testing.expectError(error.Unavailable, memory.cache().load(AccountId.from_int(1), "inbox", &out));
}

test "a cache that keeps no folders answers politely" {
    var memory: Memory = .{};
    const plain = Cache{ .context = &memory, .vtable = &.{ .load = Memory.loadThunk, .save = Memory.saveThunk } };

    var out: [4]Folder = undefined;
    try testing.expectEqual(@as(u32, 0), try plain.load_folders(AccountId.from_int(1), &out));
    try plain.save_folders(AccountId.from_int(1), &.{.{ .name = "Clients" }});
    try testing.expectEqual(@as(u8, 0), memory.folder_count);
    try testing.expectEqual(@as(u32, 0), memory.folder_saves);
}

test "Memory cache: folders go in and come back out" {
    var memory: Memory = .{};
    const cache = memory.cache();
    try cache.save_folders(AccountId.from_int(1), &.{
        .{ .name = "INBOX", .title = "INBOX", .canonical = .inbox, .unread = 4 },
        .{ .name = "[Gmail]/All Mail", .title = "All Mail", .unread = 7 },
    });

    var out: [4]Folder = undefined;
    try testing.expectEqual(@as(u32, 2), try cache.load_folders(AccountId.from_int(1), &out));
    try testing.expectEqualStrings("INBOX", out[0].name);
    try testing.expectEqual(Mailbox.inbox, out[0].canonical.?);
    try testing.expectEqual(@as(u32, 4), out[0].unread);
    try testing.expectEqualStrings("All Mail", out[1].title);
    try testing.expectEqual(@as(?Mailbox, null), out[1].canonical);
    try testing.expectEqual(@as(u32, 1), memory.folder_loads);
}
