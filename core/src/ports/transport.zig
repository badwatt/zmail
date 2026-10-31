//! The transport port: bytes in, bytes out, with a bounded wait.
//!
//! The IMAP client speaks to this interface, never to a socket or a TLS stream.
//! The real adapter (TLS) lives outside the core; tests use `Scripted`, which
//! plays a whole server conversation from a byte string.

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{
    /// The peer or the connection failed.
    Unavailable,
    /// The peer closed the stream.
    Closed,
};

pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Reads whatever is available, waiting at most `timeout_ms`.
        /// Returns zero on timeout.
        read: *const fn (context: *anyopaque, buffer: []u8, timeout_ms: u32) Error!usize,
        write: *const fn (context: *anyopaque, bytes: []const u8) Error!void,
        close: *const fn (context: *anyopaque) void,
    };

    pub fn read(self: Transport, buffer: []u8, timeout_ms: u32) Error!usize {
        return self.vtable.read(self.context, buffer, timeout_ms);
    }

    pub fn write(self: Transport, bytes: []const u8) Error!void {
        return self.vtable.write(self.context, bytes);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.context);
    }
};

/// Replays a fixed server script and captures everything the client writes.
/// A script that runs out behaves like a connection with nothing to say
/// (reads time out), unless `closed` is set.
pub const Scripted = struct {
    input: []const u8 = "",
    input_pos: u32 = 0,
    output: [16 * 1024]u8 = undefined,
    output_len: u32 = 0,
    closed: bool = false,
    read_failure: ?Error = null,
    write_failure: ?Error = null,
    close_calls: u32 = 0,
    timeouts_before_data: u32 = 0,

    pub fn transport(self: *Scripted) Transport {
        return .{ .context = self, .vtable = &.{
            .read = readThunk,
            .write = writeThunk,
            .close = closeThunk,
        } };
    }

    pub fn output_text(self: *const Scripted) []const u8 {
        return self.output[0..self.output_len];
    }

    fn readThunk(context: *anyopaque, buffer: []u8, timeout_ms: u32) Error!usize {
        _ = timeout_ms;
        const self: *Scripted = @ptrCast(@alignCast(context));
        if (self.read_failure) |err| return err;
        if (self.timeouts_before_data > 0) {
            self.timeouts_before_data -= 1;
            return 0;
        }
        if (self.input_pos == self.input.len) {
            if (self.closed) return error.Closed;
            return 0;
        }

        const available = self.input.len - self.input_pos;
        const count = @min(@as(u32, @intCast(buffer.len)), available);
        @memcpy(buffer[0..count], self.input[self.input_pos..][0..count]);
        self.input_pos += count;
        return count;
    }

    fn writeThunk(context: *anyopaque, bytes: []const u8) Error!void {
        const self: *Scripted = @ptrCast(@alignCast(context));
        if (self.write_failure) |err| return err;
        if (bytes.len > self.output.len - self.output_len) return error.Unavailable;
        @memcpy(self.output[self.output_len..][0..bytes.len], bytes);
        self.output_len += @intCast(bytes.len);
    }

    fn closeThunk(context: *anyopaque) void {
        const self: *Scripted = @ptrCast(@alignCast(context));
        self.close_calls += 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Scripted: reads its script in order, then times out" {
    var scripted: Scripted = .{ .input = "hello" };
    const transport = scripted.transport();

    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try transport.read(&buffer, 10));
    try testing.expectEqualStrings("hello", buffer[0..5]);
    try testing.expectEqual(@as(usize, 0), try transport.read(&buffer, 10));
}

test "Scripted: honours the caller's buffer size" {
    var scripted: Scripted = .{ .input = "abcdef" };
    var buffer: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try scripted.transport().read(&buffer, 10));
    try testing.expectEqualStrings("ab", buffer[0..2]);
}

test "Scripted: closed input reports Closed" {
    var scripted: Scripted = .{ .input = "", .closed = true };
    var buffer: [1]u8 = undefined;
    try testing.expectError(error.Closed, scripted.transport().read(&buffer, 10));
}

test "Scripted: timeouts can be scripted" {
    var scripted: Scripted = .{ .input = "later", .timeouts_before_data = 2 };
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try scripted.transport().read(&buffer, 10));
    try testing.expectEqual(@as(usize, 0), try scripted.transport().read(&buffer, 10));
    try testing.expectEqual(@as(usize, 5), try scripted.transport().read(&buffer, 10));
}

test "Scripted: failures are injectable" {
    var scripted: Scripted = .{ .read_failure = error.Unavailable, .write_failure = error.Unavailable };
    var buffer: [1]u8 = undefined;
    try testing.expectError(error.Unavailable, scripted.transport().read(&buffer, 10));
    try testing.expectError(error.Unavailable, scripted.transport().write("x"));
}

test "Scripted: writes are captured and close is observable" {
    var scripted: Scripted = .{};
    const transport = scripted.transport();
    try transport.write("a1 NOOP\r\n");
    try testing.expectEqualStrings("a1 NOOP\r\n", scripted.output_text());
    transport.close();
    try testing.expectEqual(@as(u32, 1), scripted.close_calls);
}

test "Scripted: an overflowing write is refused" {
    var scripted: Scripted = .{};
    const huge: [17 * 1024]u8 = @splat('x');
    try testing.expectError(error.Unavailable, scripted.transport().write(&huge));
}
