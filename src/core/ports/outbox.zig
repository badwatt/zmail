//! The outbox port: hand a finished message to something that can send it.
//!
//! Sending is a different connection (SMTP) and a different failure mode than
//! reading, so it gets its own port instead of widening `Mail`.

const std = @import("std");
const Outgoing = @import("../domain/outgoing.zig").Outgoing;

pub const Error = error{
    /// Try again later: the server is unreachable or asked us to wait.
    Unavailable,
    /// The server refused the message itself. Retrying will not help.
    Rejected,
};

pub const Outbox = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (context: *anyopaque, message: *const Outgoing) Error!void,
    };

    pub fn send(self: Outbox, message: *const Outgoing) Error!void {
        return self.vtable.send(self.context, message);
    }
};

const testing = std.testing;

const Recorder = struct {
    sent: u32 = 0,
    failure: ?Error = null,

    fn outbox(self: *Recorder) Outbox {
        return .{ .context = self, .vtable = &.{ .send = sendThunk } };
    }

    fn sendThunk(context: *anyopaque, message: *const Outgoing) Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        if (self.failure) |err| return err;
        _ = message;
        self.sent += 1;
    }
};

test "Outbox: send forwards the message to the adapter" {
    var recorder: Recorder = .{};
    try recorder.outbox().send(&.{});
    try testing.expectEqual(@as(u32, 1), recorder.sent);
}

test "Outbox: adapter errors pass through" {
    var recorder: Recorder = .{ .failure = error.Rejected };
    try testing.expectError(error.Rejected, recorder.outbox().send(&.{}));
    try testing.expectEqual(@as(u32, 0), recorder.sent);
}
