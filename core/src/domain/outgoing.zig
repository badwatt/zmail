//! A message the user is about to send.

const std = @import("std");
const limits = @import("../limits.zig");
const Text = @import("text.zig").Text;
const Address = @import("address.zig").Address;
const MessageId = @import("id.zig").MessageId;
const AccountId = @import("id.zig").AccountId;

pub const Outgoing = struct {
    /// Which account sends this message.
    account: AccountId = .unknown,
    from: Address = .{},
    to: Address = .{},
    subject: Text(limits.subject_max) = .{},
    /// Borrowed from the compose buffer in application state.
    body: []const u8 = "",
    /// Set when this is a reply.
    in_reply_to: MessageId = .unknown,

    pub fn isReply(self: *const Outgoing) bool {
        return self.in_reply_to.is_known();
    }
};

const testing = std.testing;

test "Outgoing: a fresh message is not a reply" {
    try testing.expect(!(Outgoing{}).isReply());
}

test "Outgoing: carrying a message id makes it a reply" {
    var outgoing = Outgoing{ .in_reply_to = MessageId.from_int(7) };
    try testing.expect(outgoing.isReply());
    try testing.expectEqualStrings("", outgoing.body);
}
