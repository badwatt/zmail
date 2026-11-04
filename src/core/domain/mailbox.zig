//! Mailboxes are a fixed, ordered set. Not a string: a server must not be able
//! to invent a mailbox that the UI has no place for.

const std = @import("std");
const assert = std.debug.assert;

pub const Mailbox = enum(u8) {
    inbox,
    sent,
    drafts,
    archive,
    trash,
    junk,

    /// Every mailbox, in display order. The TUI maps number keys 1..6 onto it.
    pub const all = [_]Mailbox{
        .inbox,
        .sent,
        .drafts,
        .archive,
        .trash,
        .junk,
    };

    pub fn title(self: Mailbox) []const u8 {
        return switch (self) {
            .inbox => "Inbox",
            .sent => "Sent",
            .drafts => "Drafts",
            .archive => "Archive",
            .trash => "Trash",
            .junk => "Junk",
        };
    }

    /// Index in `all`, used for tab positions and number keys.
    pub fn index(self: Mailbox) u8 {
        return @backingInt(self);
    }

    pub fn from_index(position: u8) Mailbox {
        assert(position < all.len);
        return all[position];
    }

    /// Cycles forward. The list never grows, so this always terminates.
    pub fn next(self: Mailbox) Mailbox {
        const position: usize = @backingInt(self);
        return from_index(@intCast((position + 1) % all.len));
    }

    /// Cycles backward.
    pub fn previous(self: Mailbox) Mailbox {
        const position: usize = @backingInt(self);
        return from_index(@intCast((position + all.len - 1) % all.len));
    }
};

comptime {
    assert(Mailbox.all.len == @typeInfo(Mailbox).@"enum".field_names.len);
    for (Mailbox.all, 0..) |mailbox, position| {
        assert(@backingInt(mailbox) == position);
    }
}

const testing = std.testing;

test "every mailbox has a distinct, non-empty title" {
    for (Mailbox.all, 0..) |mailbox, position| {
        try testing.expect(mailbox.title().len > 0);
        for (Mailbox.all[position + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, mailbox.title(), other.title()));
        }
    }
}

test "index and from_index round-trip" {
    for (Mailbox.all) |mailbox| {
        try testing.expectEqual(mailbox, Mailbox.from_index(mailbox.index()));
    }
}

test "next cycles forward through every mailbox and wraps" {
    var mailbox: Mailbox = .inbox;
    for (1..Mailbox.all.len) |_| {
        mailbox = mailbox.next();
    }
    try testing.expectEqual(Mailbox.junk, mailbox);
    try testing.expectEqual(Mailbox.inbox, mailbox.next());
}

test "previous cycles backward through every mailbox and wraps" {
    try testing.expectEqual(Mailbox.junk, Mailbox.inbox.previous());
    try testing.expectEqual(Mailbox.inbox, Mailbox.sent.previous());
}
