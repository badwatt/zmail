//! The system port: the only four things the session needs from the outside
//! world. Tests drive the session through a fake; the real adapter is `os.zig`.

const std = @import("std");
const assert = std.debug.assert;

pub const Size = struct {
    columns: u16 = 80,
    rows: u16 = 24,
};

pub const Error = error{
    /// stdin reached end-of-file: the terminal went away.
    InputClosed,
    /// Something went wrong with the terminal itself.
    IoError,
    /// The handle is not a terminal (running under a pipe or in CI).
    NotATerminal,
};

pub const read_timeout_ms: u32 = 100;

pub const System = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Reads whatever is available, waiting at most `timeout_ms`. Returns
        /// zero on timeout.
        read: *const fn (context: *anyopaque, buffer: []u8, timeout_ms: u32) Error!usize,
        write: *const fn (context: *anyopaque, bytes: []const u8) Error!void,
        size: *const fn (context: *anyopaque) Error!Size,
        enter_raw: *const fn (context: *anyopaque) Error!void,
        leave_raw: *const fn (context: *anyopaque) Error!void,
    };

    pub fn read(self: System, buffer: []u8, timeout_ms: u32) Error!usize {
        return self.vtable.read(self.context, buffer, timeout_ms);
    }

    pub fn write(self: System, bytes: []const u8) Error!void {
        return self.vtable.write(self.context, bytes);
    }

    pub fn size(self: System) Error!Size {
        return self.vtable.size(self.context);
    }

    pub fn enter_raw(self: System) Error!void {
        return self.vtable.enter_raw(self.context);
    }

    pub fn leave_raw(self: System) Error!void {
        return self.vtable.leave_raw(self.context);
    }
};

/// In-memory system for tests: scripted input, captured output.
pub const Fake = struct {
    input: [4096]u8 = undefined,
    input_len: u32 = 0,
    input_pos: u32 = 0,
    output: [256 * 1024]u8 = undefined,
    output_len: u32 = 0,
    size_value: Size = .{},
    raw: bool = false,
    raw_calls: u32 = 0,
    closed: bool = false,
    read_failure: ?Error = null,
    size_failure: ?Error = null,
    write_failure: ?Error = null,
    raw_failure: ?Error = null,

    pub fn system(self: *Fake) System {
        return .{ .context = self, .vtable = &.{
            .read = readThunk,
            .write = writeThunk,
            .size = sizeThunk,
            .enter_raw = enterRawThunk,
            .leave_raw = leaveRawThunk,
        } };
    }

    pub fn push_input(self: *Fake, bytes: []const u8) void {
        const available = self.input.len - self.input_len;
        const count = @min(available, bytes.len);
        @memcpy(self.input[self.input_len..][0..count], bytes[0..count]);
        self.input_len += @intCast(count);
    }

    pub fn output_text(self: *const Fake) []const u8 {
        return self.output[0..self.output_len];
    }

    fn readThunk(context: *anyopaque, buffer: []u8, timeout_ms: u32) Error!usize {
        _ = timeout_ms;
        const self: *Fake = @ptrCast(@alignCast(context));
        if (self.read_failure) |err| return err;
        if (self.closed) return error.InputClosed;
        if (self.input_pos == self.input_len) return 0;

        const available = self.input_len - self.input_pos;
        const count = @min(@as(u32, @intCast(buffer.len)), available);
        @memcpy(buffer[0..count], self.input[self.input_pos..][0..count]);
        self.input_pos += count;
        return count;
    }

    fn writeThunk(context: *anyopaque, bytes: []const u8) Error!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (self.write_failure) |err| return err;
        if (bytes.len > self.output.len - self.output_len) return error.IoError;
        @memcpy(self.output[self.output_len..][0..bytes.len], bytes);
        self.output_len += @intCast(bytes.len);
    }

    fn sizeThunk(context: *anyopaque) Error!Size {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (self.size_failure) |err| return err;
        return self.size_value;
    }

    fn enterRawThunk(context: *anyopaque) Error!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (self.raw_failure) |err| return err;
        self.raw = true;
        self.raw_calls += 1;
    }

    fn leaveRawThunk(context: *anyopaque) Error!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (self.raw_failure) |err| return err;
        self.raw = false;
        self.raw_calls += 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Fake: reads scripted input in order, then times out" {
    var fake: Fake = .{};
    fake.push_input("ab");
    const system = fake.system();

    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try system.read(&buffer, 10));
    try testing.expectEqualStrings("ab", buffer[0..2]);
    try testing.expectEqual(@as(usize, 0), try system.read(&buffer, 10));
}

test "Fake: read honours the caller's buffer size" {
    var fake: Fake = .{};
    fake.push_input("abcdef");
    var buffer: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try fake.system().read(&buffer, 10));
    try testing.expectEqualStrings("ab", buffer[0..2]);
}

test "Fake: closed input reports InputClosed" {
    var fake: Fake = .{ .closed = true };
    var buffer: [1]u8 = undefined;
    try testing.expectError(error.InputClosed, fake.system().read(&buffer, 10));
}

test "Fake: failures are injectable" {
    var fake: Fake = .{
        .read_failure = error.IoError,
        .size_failure = error.NotATerminal,
        .write_failure = error.IoError,
        .raw_failure = error.IoError,
    };
    var buffer: [1]u8 = undefined;
    try testing.expectError(error.IoError, fake.system().read(&buffer, 10));
    try testing.expectError(error.IoError, fake.system().write("x"));
    try testing.expectError(error.NotATerminal, fake.system().size());
    try testing.expectError(error.IoError, fake.system().enter_raw());
    try testing.expectError(error.IoError, fake.system().leave_raw());
}

test "Fake: writes are captured and bounded" {
    var fake: Fake = .{};
    const system = fake.system();
    try system.write("hello");
    try testing.expectEqualStrings("hello", fake.output_text());
}

test "Fake: raw mode is observable" {
    var fake: Fake = .{};
    const system = fake.system();
    try system.enter_raw();
    try testing.expect(fake.raw);
    try system.leave_raw();
    try testing.expect(!fake.raw);
    try testing.expectEqual(@as(u32, 2), fake.raw_calls);
}

test "Fake: size is configurable" {
    var fake: Fake = .{ .size_value = .{ .columns = 120, .rows = 40 } };
    try testing.expectEqual(Size{ .columns = 120, .rows = 40 }, try fake.system().size());
}

test "Fake: push_input drops bytes past its capacity instead of overflowing" {
    var fake: Fake = .{};
    const huge: [8192]u8 = @splat('x');
    fake.push_input(&huge);
    try testing.expectEqual(@as(u32, fake.input.len), fake.input_len);
    assert(fake.input_len == 4096);
}
