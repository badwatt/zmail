//! Typed message identifiers.
//!
//! A `MessageId` is deliberately not a `u32` index: cursors, list positions, and
//! store indexes are all integers, and mixing them up is the classic off-by-one
//! bug. The enum makes that mix-up a compile error.

const std = @import("std");
const assert = std.debug.assert;

pub const MessageId = enum(u64) {
    /// Sentinel for "no message". Never valid in the store.
    unknown = 0,
    _,

    pub fn from_int(value: u64) MessageId {
        assert(value != 0);
        return @fromBackingInt(@intCast(value));
    }

    pub fn to_int(self: MessageId) u64 {
        const value = @backingInt(self);
        assert(value != 0);
        return value;
    }

    pub fn is_known(self: MessageId) bool {
        return @backingInt(self) != 0;
    }
};

/// Identifies one configured account. UIDs are per account, so every lookup
/// pairs this with a `MessageId`.
pub const AccountId = enum(u8) {
    unknown = 0,
    _,

    pub fn from_int(value: u8) AccountId {
        assert(value != 0);
        return @fromBackingInt(@intCast(value));
    }

    pub fn to_int(self: AccountId) u8 {
        const value = @backingInt(self);
        assert(value != 0);
        return value;
    }

    pub fn is_known(self: AccountId) bool {
        return @backingInt(self) != 0;
    }
};

const testing = std.testing;

test "MessageId: round-trips through its integer representation" {
    const id = MessageId.from_int(42);
    try testing.expectEqual(@as(u64, 42), id.to_int());
    try testing.expect(id.is_known());
}

test "MessageId: the zero tag is not a known message" {
    try testing.expect(!MessageId.unknown.is_known());
    try testing.expectEqual(@as(u64, 0), @backingInt(MessageId.unknown));
}

test "AccountId: round-trips and rejects the unknown tag" {
    const account = AccountId.from_int(2);
    try testing.expectEqual(@as(u8, 2), account.to_int());
    try testing.expect(account.is_known());
    try testing.expect(!AccountId.unknown.is_known());
}

test "MessageId: distinct ids are distinct values" {
    try testing.expect(MessageId.from_int(1) != MessageId.from_int(2));
}
