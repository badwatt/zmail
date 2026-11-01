//! Effects: the I/O the application asks for, returned alongside the new state.
//!
//! `update` never performs I/O. It returns a bounded list of effects and the
//! front end (or a test) executes them against the ports. Bounded because a
//! single keystroke may never ask for unbounded work.

const std = @import("std");
const assert = std.debug.assert;

const limits = @import("../limits.zig");
const Mailbox = @import("../domain/mailbox.zig").Mailbox;
const MessageId = @import("../domain/id.zig").MessageId;
const Flags = @import("../domain/message.zig").Flags;
const AccountId = @import("../domain/id.zig").AccountId;
const Outgoing = @import("../domain/outgoing.zig").Outgoing;

pub const Effect = union(enum) {
    sync_flags: struct { account: AccountId, id: MessageId, flags: Flags },
    move_message: struct { account: AccountId, id: MessageId, to: Mailbox },
    fetch_body: struct { account: AccountId, mailbox: Mailbox, id: MessageId },
    /// Null account means every account (the unified view).
    refresh: struct { account: ?AccountId, mailbox: Mailbox, force: bool = false },
    /// Accounts: rewrite the config without this one.
    remove_account: struct { account: AccountId },
    /// Accounts: open the form, for a new account (null) or an existing one.
    edit_account: struct { account: ?AccountId },
    /// Accounts: rename one, without touching the rest of its settings.
    rename_account: struct { account: AccountId },
    /// Remove for good (only offered in Trash).
    delete_message: struct { account: AccountId, mailbox: Mailbox, id: MessageId },
    /// Empty a mailbox for good (only offered in Trash). Null account = all.
    empty_mailbox: struct { account: ?AccountId, mailbox: Mailbox },
    /// Hand the message to the outbox. The body is borrowed from compose state.
    send: Outgoing,
};

pub const Effects = struct {
    items: [limits.actions_max]Effect = undefined,
    len: u32 = 0,

    pub fn add(self: *Effects, effect: Effect) void {
        assert(self.len < limits.actions_max);
        self.items[self.len] = effect;
        self.len += 1;
    }

    pub fn slice(self: *const Effects) []const Effect {
        assert(self.len <= limits.actions_max);
        return self.items[0..self.len];
    }

    pub fn is_empty(self: *const Effects) bool {
        return self.len == 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Effects: starts empty and grows in order" {
    var effects: Effects = .{};
    try testing.expect(effects.is_empty());
    try testing.expectEqual(@as(usize, 0), effects.slice().len);

    const id = MessageId.from_int(7);
    const account = AccountId.from_int(1);
    effects.add(.{ .fetch_body = .{ .account = account, .mailbox = .inbox, .id = id } });
    effects.add(.{ .refresh = .{ .account = account, .mailbox = .inbox } });

    try testing.expect(!effects.is_empty());
    try testing.expectEqual(@as(usize, 2), effects.slice().len);
    try testing.expectEqual(id, effects.slice()[0].fetch_body.id);
    try testing.expectEqual(Mailbox.inbox, effects.slice()[1].refresh.mailbox);
}

test "Effects: fills to the declared bound" {
    var effects: Effects = .{};
    const id = MessageId.from_int(1);
    var index: u32 = 0;
    while (index < limits.actions_max) : (index += 1) {
        effects.add(.{ .fetch_body = .{ .account = AccountId.from_int(1), .mailbox = .inbox, .id = id } });
    }
    try testing.expectEqual(limits.actions_max, effects.len);
}
