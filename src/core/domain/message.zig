//! A message as the client needs it: enough to list and read, nothing to
//! execute. Bodies are fetched separately and never stored here.

const std = @import("std");
const limits = @import("../limits.zig");
const Text = @import("text.zig").Text;
const contains_ignore_case = @import("text.zig").contains_ignore_case;
const Address = @import("address.zig").Address;
const MessageId = @import("id.zig").MessageId;
const AccountId = @import("id.zig").AccountId;
const Mailbox = @import("mailbox.zig").Mailbox;
const folder = @import("folder.zig");

pub const Flags = packed struct(u8) {
    unread: bool = true,
    flagged: bool = false,
    answered: bool = false,
    _reserved: u5 = 0,

    pub fn mark_read(self: Flags) Flags {
        var flags = self;
        flags.unread = false;
        return flags;
    }

    pub fn mark_unread(self: Flags) Flags {
        var flags = self;
        flags.unread = true;
        return flags;
    }

    pub fn toggle_unread(self: Flags) Flags {
        var flags = self;
        flags.unread = !flags.unread;
        return flags;
    }

    pub fn toggle_flagged(self: Flags) Flags {
        var flags = self;
        flags.flagged = !flags.flagged;
        return flags;
    }
};

pub const Message = struct {
    id: MessageId = .unknown,
    account: AccountId = .unknown,
    mailbox: Mailbox = .inbox,
    /// Set when the message lives in a folder that is not one of the six: the
    /// slot of that folder in its account's list. `folder.none` means the
    /// mailbox above is the whole address.
    named: u8 = folder.none,
    from: Address = .{},
    subject: Text(limits.subject_max) = .{},
    snippet: Text(limits.snippet_max) = .{},
    timestamp_unix: i64 = 0,
    size_bytes: u32 = 0,
    flags: Flags = .{},

    pub fn is_unread(self: *const Message) bool {
        return self.flags.unread;
    }

    pub fn is_flagged(self: *const Message) bool {
        return self.flags.flagged;
    }

    /// Free-text match over everything the list shows. Case-insensitive for
    /// ASCII only; the needle comes from the user and is never interpreted.
    pub fn matches(self: *const Message, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (contains_ignore_case(self.from.name.slice(), needle)) return true;
        if (contains_ignore_case(self.from.local.slice(), needle)) return true;
        if (contains_ignore_case(self.from.domain.slice(), needle)) return true;
        if (contains_ignore_case(self.subject.slice(), needle)) return true;
        if (contains_ignore_case(self.snippet.slice(), needle)) return true;
        return false;
    }
};

comptime {
    // Flags must stay one byte: it is stored per message and copied by value.
    std.debug.assert(@sizeOf(Flags) == 1);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sample() Message {
    return .{
        .id = MessageId.from_int(7),
        .account = AccountId.from_int(1),
        .mailbox = .inbox,
        .from = Address.init("Alice <alice@example.com>") catch unreachable,
        .subject = Text(limits.subject_max).init("Design tokens review"),
        .snippet = Text(limits.snippet_max).init("Can you look at the palette?"),
        .timestamp_unix = 1_700_000_000,
        .size_bytes = 4096,
        .flags = .{},
    };
}

test "Flags: a fresh message is unread and unflagged" {
    const flags = Flags{};
    try testing.expect(flags.unread);
    try testing.expect(!flags.flagged);
    try testing.expect(!flags.answered);
}

test "Flags: mark_read, mark_unread, and toggle_unread" {
    const unread = Flags{};
    try testing.expect(!unread.mark_read().unread);
    try testing.expect(unread.mark_read().mark_unread().unread);
    try testing.expect(!unread.toggle_unread().unread);
    try testing.expect(unread.toggle_unread().toggle_unread().unread);
}

test "Flags: toggle_flagged flips only the flag" {
    const clean = Flags{};
    const flagged = clean.toggle_flagged();
    try testing.expect(flagged.flagged);
    try testing.expect(flagged.unread);
    try testing.expect(!flagged.toggle_flagged().flagged);
}

test "Message: reads flags back" {
    const message = sample();
    try testing.expect(message.is_unread());
    try testing.expect(!message.is_flagged());
}

test "Message: an empty needle matches everything" {
    try testing.expect(sample().matches(""));
}

test "Message: matches the display name, local part, and domain" {
    const message = sample();
    try testing.expect(message.matches("alice"));
    try testing.expect(message.matches("ALICE"));
    try testing.expect(message.matches("example.com"));
}

test "Message: matches the subject and snippet" {
    const message = sample();
    try testing.expect(message.matches("tokens"));
    try testing.expect(message.matches("palette"));
}

test "Message: does not match unrelated text" {
    try testing.expect(!sample().matches("invoice"));
}
