//! Folders: the six mailboxes the app knows by heart, and the ones a server
//! names.
//!
//! `Mailbox` is a closed set, and stays closed: the list, the tabs, the keys and
//! the actions all speak it. What a server has that the six do not cover
//! ("Receipts", "[Gmail]/All Mail") is a *slot* in that account's list, learned
//! from `LIST`, and addressed by name. A message therefore belongs either to a
//! canonical mailbox or to a named folder of its account -- never to a string
//! the app has no place for.

const std = @import("std");
const Message = @import("message.zig").Message;
const assert = std.debug.assert;
const Text = @import("text.zig").Text;
const Mailbox = @import("mailbox.zig").Mailbox;
const AccountId = @import("id.zig").AccountId;
const limits = @import("../limits.zig");

pub const name_max: u32 = limits.mailbox_name_max;
pub const accounts_max: u8 = 4;
/// Folders one account may have. A real account with a folder tree fits; a
/// server that floods `LIST` gets the first ones and no more.
pub const per_account_max: u8 = 24;

/// The value of `Message.named` for a message that lives in a canonical mailbox.
pub const none: u8 = 0xff;

/// One folder of one account: what the server calls it, and which of the six it
/// is, when it is one.
pub const Entry = struct {
    /// The name the server knows this folder by, which is what a port call sends.
    name: Text(name_max) = .{},
    /// What the sidebar shows: the name without the namespace it sits in, when
    /// the server has one. Empty means "the name".
    title: Text(name_max) = .{},
    /// The mailbox this folder *is*: "Sent Items" is Sent, "INBOX" is Inbox.
    canonical: ?Mailbox = null,
    /// What the server said `STATUS` reports: mail nobody has read yet.
    unread: u32 = 0,

    /// The words this folder goes by on screen.
    pub fn display(self: *const Entry) []const u8 {
        if (!self.title.is_empty()) return self.title.slice();
        return self.name.slice();
    }
};

/// Where mail can be: one of the six, or one of the account's own folders.
pub const MoveTarget = union(enum) {
    mailbox: Mailbox,
    named: Ref,
};

/// The folder a message is in.
pub fn of(message: *const Message) MoveTarget {
    return if (message.named == none)
        .{ .mailbox = message.mailbox }
    else
        .{ .named = .{ .account = message.account, .slot = message.named } };
}

/// Whether two targets name the same folder.
pub fn same(first: MoveTarget, second: MoveTarget) bool {
    if (first != std.meta.activeTag(second)) return false;
    return switch (first) {
        .mailbox => |mailbox| mailbox == second.mailbox,
        .named => |ref| ref.eql(second.named),
    };
}

/// Identifies one named folder: whose, and which slot of its list.
pub const Ref = struct {
    account: AccountId,
    slot: u8,

    pub fn eql(self: Ref, other: Ref) bool {
        return self.account == other.account and self.slot == other.slot;
    }
};

/// Every account's folders, in the order the server listed them. Bounded, and
/// allocated with the rest of the state: nothing here can grow at runtime.
pub const Table = struct {
    entries: [accounts_max][per_account_max]Entry = @splat(@splat(.{})),
    len: [accounts_max]u8 = @splat(0),

    fn index(account: AccountId) usize {
        assert(account.is_known());
        const position: usize = account.to_int() - 1;
        assert(position < accounts_max);
        return position;
    }

    /// Forgets an account's folders: a new login re-lists them.
    pub fn reset(self: *Table, account: AccountId) void {
        const position = index(account);
        self.entries[position] = @splat(.{});
        self.len[position] = 0;
    }

    /// Adds one folder, in the order the server listed it. Returns its slot, or
    /// null when the account already has as many as we keep. A repeated name is
    /// the same folder, and keeps its place.
    pub fn add(self: *Table, account: AccountId, name: []const u8, canonical: ?Mailbox) ?u8 {
        return self.add_counted(account, name, "", canonical, 0);
    }

    /// The same, with the words to show and the unread count the server gave.
    pub fn add_counted(
        self: *Table,
        account: AccountId,
        name: []const u8,
        title: []const u8,
        canonical: ?Mailbox,
        unread: u32,
    ) ?u8 {
        const position = index(account);
        const used = self.len[position];
        var slot: u8 = 0;
        while (slot < used) : (slot += 1) {
            const entry = &self.entries[position][slot];
            if (!std.mem.eql(u8, entry.name.slice(), name)) continue;
            if (entry.canonical == null) entry.canonical = canonical;
            if (unread > 0) entry.unread = unread;
            if (entry.title.is_empty() and title.len > 0) entry.title.set(title);
            return slot;
        }
        // Two names can be the same folder: a server that flags both "Junk" and
        // "Spam" with \Junk is telling us about one Junk, and two rows for it
        // would let J walk in place forever.
        if (canonical) |wanted| {
            var existing: u8 = 0;
            while (existing < used) : (existing += 1) {
                const entry = &self.entries[position][existing];
                const have = entry.canonical orelse continue;
                if (have != wanted) continue;
                if (unread > entry.unread) entry.unread = unread;
                return existing;
            }
        }

        if (used == per_account_max) return null;
        self.entries[position][used] = .{ .canonical = canonical, .unread = unread };
        self.entries[position][used].name.set(name);
        self.entries[position][used].title.set(title);
        self.len[position] = used + 1;
        return used;
    }

    pub fn count(self: *const Table, account: AccountId) u8 {
        return self.len[index(account)];
    }

    pub fn is_empty(self: *const Table, account: AccountId) bool {
        return self.len[index(account)] == 0;
    }

    pub fn at(self: *const Table, account: AccountId, slot: u8) ?*const Entry {
        if (slot >= self.len[index(account)]) return null;
        return &self.entries[index(account)][slot];
    }

    /// The slot whose folder is `mailbox`, when the account has one.
    pub fn slot_of(self: *const Table, account: AccountId, mailbox: Mailbox) ?u8 {
        const used = self.len[index(account)];
        var slot: u8 = 0;
        while (slot < used) : (slot += 1) {
            const entry = &self.entries[index(account)][slot];
            if (entry.canonical) |canonical| {
                if (canonical == mailbox) return slot;
            }
        }
        return null;
    }

    /// The server's name for a canonical mailbox, when `LIST` named it.
    /// The slot of a folder by the name it was saved under: the one the server
    /// called it, or the words the sidebar showed. What a restart writes down is
    /// a name, and this is how a name becomes a folder again.
    pub fn slot_named(self: *const Table, account: AccountId, saved: []const u8) ?u8 {
        const used = self.len[index(account)];
        var slot: u8 = 0;
        while (slot < used) : (slot += 1) {
            const entry = &self.entries[index(account)][slot];
            if (entry.canonical != null) continue;
            if (std.mem.eql(u8, entry.name.slice(), saved)) return slot;
            if (std.mem.eql(u8, entry.display(), saved)) return slot;
        }
        return null;
    }

    pub fn name_of(self: *const Table, account: AccountId, mailbox: Mailbox) ?[]const u8 {
        const slot = self.slot_of(account, mailbox) orelse return null;
        return self.entries[index(account)][slot].name.slice();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "folder: a saved name finds its folder again" {
    var table: Table = .{};
    const account = AccountId.from_int(1);
    _ = table.add(account, "INBOX", .inbox);
    _ = table.add_counted(account, "[Gmail]/Sent Mail", "Sent Mail", .sent, 0);
    const clients = table.add(account, "Clients", null).?;

    try testing.expectEqual(clients, table.slot_named(account, "Clients").?);
    try testing.expectEqual(@as(?u8, null), table.slot_named(account, "Sent Mail"));
    try testing.expectEqual(@as(?u8, null), table.slot_named(account, "Missing"));
    // Another account's name means nothing here.
    try testing.expectEqual(@as(?u8, null), table.slot_named(AccountId.from_int(2), "Clients"));
}

test "folder: a listed folder keeps its slot, and a repeated name keeps it too" {
    var table: Table = .{};
    const account = AccountId.from_int(1);
    try testing.expectEqual(@as(u8, 0), table.add(account, "INBOX", .inbox).?);
    try testing.expectEqual(@as(u8, 1), table.add(account, "Sent Items", .sent).?);
    try testing.expectEqual(@as(u8, 2), table.add(account, "Receipts", null).?);
    try testing.expectEqual(@as(u8, 3), table.count(account));

    // The same name is the same folder, and it can learn what it is.
    try testing.expectEqual(@as(u8, 2), table.add(account, "Receipts", null).?);
    try testing.expectEqual(@as(u8, 1), table.add(account, "Sent Items", .sent).?);
    try testing.expectEqual(@as(u8, 3), table.count(account));
}

test "folder: names, canonical mapping and slots" {
    var table: Table = .{};
    const account = AccountId.from_int(2);
    _ = table.add(account, "INBOX", .inbox);
    _ = table.add(account, "Sent Items", .sent);
    _ = table.add(account, "Receipts", null);

    try testing.expectEqualStrings("Sent Items", table.name_of(account, .sent).?);
    try testing.expectEqual(@as(?[]const u8, null), table.name_of(account, .trash));
    try testing.expectEqual(@as(u8, 1), table.slot_of(account, .sent).?);
    try testing.expectEqual(@as(?u8, null), table.slot_of(account, .junk));

    try testing.expectEqualStrings("Receipts", table.at(account, 2).?.name.slice());
    try testing.expectEqual(@as(?*const Entry, null), table.at(account, 3));
    // Another account has its own list.
    try testing.expectEqual(@as(u8, 0), table.count(AccountId.from_int(1)));
}

test "folder: an account that floods LIST keeps what fits, and resets" {
    var table: Table = .{};
    const account = AccountId.from_int(3);
    var buffer: [32]u8 = undefined;
    var index: u8 = 0;
    while (index < per_account_max) : (index += 1) {
        const name = std.fmt.bufPrint(&buffer, "Folder {d}", .{index}) catch unreachable;
        try testing.expect(table.add(account, name, null) != null);
    }
    try testing.expectEqual(@as(?u8, null), table.add(account, "One more", null));
    try testing.expectEqual(per_account_max, table.count(account));

    table.reset(account);
    try testing.expectEqual(@as(u8, 0), table.count(account));
    try testing.expectEqual(@as(?*const Entry, null), table.at(account, 0));
}

test "folder: a slot of one account cannot be read as another's" {
    var table: Table = .{};
    _ = table.add(AccountId.from_int(1), "Receipts", null);
    try testing.expect(table.at(AccountId.from_int(2), 0) == null);
    try testing.expect(table.at(AccountId.from_int(1), 0) != null);
}

test "folder: two names that are the same mailbox are one folder" {
    var table: Table = .{};
    const account = AccountId.from_int(1);
    try testing.expectEqual(@as(u8, 0), table.add(account, "Junk", .junk).?);
    // The server also lists "Spam" as \Junk: same folder, same row.
    try testing.expectEqual(@as(u8, 0), table.add_counted(account, "Spam", "", .junk, 4).?);
    try testing.expectEqual(@as(u8, 1), table.count(account));
    try testing.expectEqual(@as(u32, 4), table.at(account, 0).?.unread);
    // The name it keeps is the first one the server gave: that is what a port
    // call has to send.
    try testing.expectEqualStrings("Junk", table.at(account, 0).?.name.slice());
}
