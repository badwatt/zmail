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
        /// Null keeps the credential already on disk (editing a name, a host).
        password: ?[]const u8 = null,
        /// The account this draft replaces, or null for a new one.
        replaces: ?AccountId = null,
    };

    /// A freshly opened account: enough to add it to the view and fetch mail.
    pub const Connected = struct {
        id: AccountId = .unknown,
        label: []const u8 = "",
        address_text: []const u8 = "",
        imap_host: []const u8 = "",
        imap_port: u16 = 0,
        username: []const u8 = "",
        smtp_host: []const u8 = "",
        smtp_port: u16 = 0,
        smtp: bool = false,
        mail: ?@import("../ports/mail.zig").Mail = null,
    };

    pub const VTable = struct {
        /// Rewrites the config (and deletes the credential) without `account`.
        remove: *const fn (context: *anyopaque, account: AccountId) Error!void,
        /// Adds an account, or replaces one; writes its sealed credential.
        /// Adds or replaces an account and returns its id (1-based).
        save: *const fn (context: *anyopaque, draft: Accounts.Draft) Error!AccountId,
        /// Changes only the label: the config section and the credential file.
        rename: *const fn (context: *anyopaque, account: AccountId, label: []const u8) Error!void,
        /// Opens the account now, so it can be used without a restart.
        connect: *const fn (context: *anyopaque, account: AccountId, out: *Connected) Error!void,
        /// Closes a connection opened by `connect`.
        disconnect: *const fn (context: *anyopaque, account: AccountId) Error!void,
    };

    pub fn remove(self: Accounts, account: AccountId) Error!void {
        return self.vtable.remove(self.context, account);
    }

    pub fn save(self: Accounts, draft: Draft) Error!AccountId {
        return self.vtable.save(self.context, draft);
    }

    pub fn rename(self: Accounts, account: AccountId, label: []const u8) Error!void {
        return self.vtable.rename(self.context, account, label);
    }

    pub fn connect(self: Accounts, account: AccountId, out: *Connected) Error!void {
        return self.vtable.connect(self.context, account, out);
    }

    pub fn disconnect(self: Accounts, account: AccountId) Error!void {
        return self.vtable.disconnect(self.context, account);
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
    renamed: AccountId = .unknown,
    connected: AccountId = .unknown,
    connect_mail: ?@import("../ports/mail.zig").Mail = null,
    disconnected: AccountId = .unknown,

    pub fn accounts(self: *Memory) Accounts {
        return .{ .context = self, .vtable = &.{
            .remove = removeThunk,
            .save = saveThunk,
            .rename = renameThunk,
            .connect = connectThunk,
            .disconnect = disconnectThunk,
        } };
    }

    fn removeThunk(context: *anyopaque, account: AccountId) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.removed += 1;
        self.last_removed = account;
        if (self.fail) return error.Unavailable;
    }

    fn connectThunk(context: *anyopaque, account: AccountId, out: *Accounts.Connected) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.connected = account;
        if (self.fail) return error.Unavailable;
        out.* = .{
            .id = account,
            .label = "new",
            .address_text = "new@example.com",
            .imap_host = "imap.example.com",
            .imap_port = 993,
            .username = "new",
            .mail = self.connect_mail,
        };
    }

    fn disconnectThunk(context: *anyopaque, account: AccountId) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.disconnected = account;
    }

    fn renameThunk(context: *anyopaque, account: AccountId, label: []const u8) Error!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.renamed = account;
        self.saved += 1;
        const length = @min(label.len, self.last_label.len);
        @memcpy(self.last_label[0..length], label[0..length]);
        self.last_label_len = @intCast(length);
        if (self.fail) return error.Unavailable;
    }

    fn saveThunk(context: *anyopaque, draft: Accounts.Draft) Error!AccountId {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.saved += 1;
        self.last_replaces = draft.replaces;
        const length = @min(draft.label.len, self.last_label.len);
        @memcpy(self.last_label[0..length], draft.label[0..length]);
        self.last_label_len = @intCast(length);
        if (self.fail) return error.Unavailable;
        return AccountId.from_int(1);
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

    _ = try accounts.save(.{ .text = "x", .label = "new", .password = "pw" });
    try testing.expectEqual(@as(u32, 1), memory.saved);
    try testing.expectEqualStrings("new", memory.last_label[0..memory.last_label_len]);
    try testing.expect(memory.last_replaces == null);

    _ = try accounts.save(.{ .text = "x", .label = "work", .password = "pw", .replaces = AccountId.from_int(3) });
    try testing.expectEqual(AccountId.from_int(3), memory.last_replaces.?);

    var opened: Accounts.Connected = .{};
    try accounts.connect(AccountId.from_int(1), &opened);
    try testing.expectEqual(AccountId.from_int(1), memory.connected);
    try testing.expectEqualStrings("imap.example.com", opened.imap_host);
    try accounts.disconnect(AccountId.from_int(1));
    try testing.expectEqual(AccountId.from_int(1), memory.disconnected);

    try accounts.rename(AccountId.from_int(1), "club");
    try testing.expectEqual(AccountId.from_int(1), memory.renamed);
    try testing.expectEqualStrings("club", memory.last_label[0..memory.last_label_len]);
}

test "Memory accounts: failures surface as Unavailable" {
    var memory: Memory = .{ .fail = true };
    try testing.expectError(error.Unavailable, memory.accounts().remove(AccountId.from_int(1)));
    try testing.expectError(
        error.Unavailable,
        memory.accounts().save(.{ .text = "x", .label = "new", .password = "pw" }),
    );
    try testing.expectError(error.Unavailable, memory.accounts().rename(AccountId.from_int(1), "x"));
}
