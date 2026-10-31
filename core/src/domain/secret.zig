//! Secrets: fixed-capacity, zeroed on drop, redacted when printed.
//!
//! The type exists to make two mistakes hard:
//!   - formatting a password into a log line, and
//!   - leaving it in memory after the account is closed.
//!
//! It is initialized in place (`init(bytes, &secret)`) so no copy of the plain
//! bytes is made on the stack before it reaches its final home.

const std = @import("std");
const assert = std.debug.assert;
const limits = @import("../limits.zig");

pub const Secret = struct {
    buffer: [limits.secret_max]u8 = @splat(0),
    len: u32 = 0,

    pub const InitError = error{TooLong};

    pub fn init(bytes: []const u8, out: *Secret) InitError!void {
        if (bytes.len > limits.secret_max) return error.TooLong;
        @memset(&out.buffer, 0);
        @memcpy(out.buffer[0..bytes.len], bytes);
        out.len = @intCast(bytes.len);
        assert(out.len <= limits.secret_max);
    }

    /// Zeroes the buffer. Call this the moment the credential is no longer
    /// needed, not when the garbage collector feels like it (there is none).
    pub fn deinit(self: *Secret) void {
        assert(self.len <= limits.secret_max);
        @memset(&self.buffer, 0);
        self.len = 0;
    }

    /// Hands the plain bytes to the caller. Every call site is an audit point.
    pub fn expose(self: *const Secret) []const u8 {
        assert(self.len <= limits.secret_max);
        return self.buffer[0..self.len];
    }

    pub fn is_empty(self: *const Secret) bool {
        return self.len == 0;
    }

    /// `{f}` on a secret prints this, never the secret itself.
    pub fn format(self: *const Secret, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.writeAll("<redacted>");
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Secret: init copies the bytes and expose returns them" {
    var secret: Secret = undefined;
    try Secret.init("hunter2", &secret);
    defer secret.deinit();

    try testing.expectEqualStrings("hunter2", secret.expose());
    try testing.expectEqual(@as(u32, 7), secret.len);
    try testing.expect(!secret.is_empty());
}

test "Secret: an empty secret is empty" {
    var secret: Secret = undefined;
    try Secret.init("", &secret);
    defer secret.deinit();
    try testing.expect(secret.is_empty());
    try testing.expectEqualStrings("", secret.expose());
}

test "Secret: refuses more bytes than the capacity" {
    var secret: Secret = undefined;
    const too_long: [limits.secret_max + 1]u8 = @splat('x');
    try testing.expectError(error.TooLong, Secret.init(&too_long, &secret));
}

test "Secret: accepts exactly the capacity" {
    var secret: Secret = undefined;
    const exact: [limits.secret_max]u8 = @splat('y');
    try Secret.init(&exact, &secret);
    defer secret.deinit();
    try testing.expectEqual(limits.secret_max, secret.len);
}

test "Secret: deinit zeroes every byte" {
    var secret: Secret = undefined;
    try Secret.init("correct horse battery staple", &secret);
    secret.deinit();

    try testing.expectEqual(@as(u32, 0), secret.len);
    for (secret.buffer) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Secret: reinitializing a secret does not leak the previous tail" {
    var secret: Secret = undefined;
    try Secret.init("a-much-longer-secret", &secret);
    try Secret.init("short", &secret);
    defer secret.deinit();

    try testing.expectEqualStrings("short", secret.expose());
    for (secret.buffer[secret.len..]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Secret: formatting redacts the value" {
    var secret: Secret = undefined;
    try Secret.init("hunter2", &secret);
    defer secret.deinit();

    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try secret.format(&writer);
    try testing.expectEqualStrings("<redacted>", writer.buffered());
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "hunter2") == null);
}
