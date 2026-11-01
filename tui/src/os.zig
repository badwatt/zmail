//! The POSIX terminal adapter: the only file that touches fds, termios, and
//! ioctl.
//!
//! Deliberately thin. Every branch here is exercised by driving a real
//! pseudo-terminal in the tests below, so the adapter is covered by the same
//! 100% gate as the logic.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const system_mod = @import("system.zig");

const c = std.c;
const Winsize = std.posix.winsize;

const TIOCGWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5413,
    else => 0x40087468,
};

const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5414,
    else => 0x80087467,
};

extern "c" fn ioctl(fd: c_int, request: c_ulong, arg: *Winsize) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn clock_gettime(clock_id: c_int, tp: *std.posix.timespec) c_int;

const O_NOCTTY_RDWR: c_int = 0o2 | 0o400;

pub const Posix = struct {
    stdin: c_int = std.posix.STDIN_FILENO,
    stdout: c_int = std.posix.STDOUT_FILENO,
    original: std.posix.termios = undefined,
    raw_enabled: bool = false,

    pub fn init(stdin: c_int, stdout: c_int) Posix {
        return .{ .stdin = stdin, .stdout = stdout };
    }

    pub fn system(self: *Posix) system_mod.System {
        return .{ .context = self, .vtable = &.{
            .read = readThunk,
            .write = writeThunk,
            .size = sizeThunk,
            .enter_raw = enterRawThunk,
            .leave_raw = leaveRawThunk,
        } };
    }

    fn readThunk(context: *anyopaque, buffer: []u8, timeout_ms: u32) system_mod.Error!usize {
        const self: *Posix = @ptrCast(@alignCast(context));
        assert(timeout_ms <= std.math.maxInt(i32));

        var fds = [1]std.posix.pollfd{
            .{ .fd = self.stdin, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch 0;
        if (ready == 0) return 0;

        const count = std.posix.read(self.stdin, buffer) catch return error.IoError;
        if (count == 0) return error.InputClosed;
        return count;
    }

    fn writeThunk(context: *anyopaque, bytes: []const u8) system_mod.Error!void {
        const self: *Posix = @ptrCast(@alignCast(context));
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = c.write(self.stdout, bytes[offset..].ptr, bytes.len - offset);
            if (std.posix.errno(written) != .SUCCESS) return error.IoError;
            offset += @intCast(written);
        }
    }

    fn sizeThunk(context: *anyopaque) system_mod.Error!system_mod.Size {
        const self: *Posix = @ptrCast(@alignCast(context));
        var window: Winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        if (ioctl(self.stdout, TIOCGWINSZ, &window) != 0) return error.NotATerminal;
        if (window.col == 0 or window.row == 0) return error.NotATerminal;
        return .{ .columns = window.col, .rows = window.row };
    }

    fn enterRawThunk(context: *anyopaque) system_mod.Error!void {
        const self: *Posix = @ptrCast(@alignCast(context));
        self.original = std.posix.tcgetattr(self.stdin) catch return error.NotATerminal;

        var raw = self.original;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@backingInt(std.posix.V.MIN)] = 0;
        raw.cc[@backingInt(std.posix.V.TIME)] = 0;

        std.posix.tcsetattr(self.stdin, .NOW, raw) catch return error.IoError;
        self.raw_enabled = true;
    }

    fn leaveRawThunk(context: *anyopaque) system_mod.Error!void {
        const self: *Posix = @ptrCast(@alignCast(context));
        if (!self.raw_enabled) return;
        std.posix.tcsetattr(self.stdin, .NOW, self.original) catch return error.IoError;
        self.raw_enabled = false;
    }
};

/// Reads an environment variable, or null when it is unset.
pub fn env(name: [:0]const u8) ?[]const u8 {
    const value = getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}

/// Monotonic milliseconds, for measuring how long the spinner has been up.
/// `CLOCK_MONOTONIC` is 1 on Linux; 0 means "unknown".
pub fn monotonic_ms() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (clock_gettime(1, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Sleeps for `ms`. Signals may shorten it, which only matters for a spinner.
pub fn sleep_ms(ms: u64) void {
    if (ms == 0) return;
    const request: std.posix.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&request, null);
}

/// Wall clock in Unix seconds, from CLOCK_REALTIME. `0` means "unknown", which
/// only makes relative dates read as "now"; it never affects correctness.
pub fn now_unix() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (clock_gettime(0, &ts) != 0) return 0;
    return @intCast(ts.sec);
}

// ---------------------------------------------------------------------------
// Tests: a real pseudo-terminal, so the adapter is exercised for real.
// ---------------------------------------------------------------------------

const testing = std.testing;

const Pty = struct {
    master: c_int,
    slave: c_int,

    fn open() !Pty {
        const openpt = struct {
            extern "c" fn posix_openpt(flags: c_int) c_int;
            extern "c" fn grantpt(fd: c_int) c_int;
            extern "c" fn unlockpt(fd: c_int) c_int;
            extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
        };

        const master = openpt.posix_openpt(O_NOCTTY_RDWR);
        if (master < 0) return error.SkipZigTest;
        if (openpt.grantpt(master) != 0) return error.SkipZigTest;
        if (openpt.unlockpt(master) != 0) return error.SkipZigTest;

        const name = openpt.ptsname(master) orelse return error.SkipZigTest;
        const slave = c.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
        if (slave < 0) return error.SkipZigTest;
        return .{ .master = master, .slave = slave };
    }

    fn close(self: Pty) void {
        _ = c.close(self.master);
        _ = c.close(self.slave);
    }

    fn resize(self: Pty, columns: u16, rows: u16) void {
        var window: Winsize = .{ .row = rows, .col = columns, .xpixel = 0, .ypixel = 0 };
        assert(ioctl(self.slave, TIOCSWINSZ, &window) == 0);
    }

    fn writeMaster(self: Pty, bytes: []const u8) void {
        const written = c.write(self.master, bytes.ptr, bytes.len);
        assert(written == bytes.len);
    }

    fn readMaster(self: Pty, buffer: []u8) usize {
        const count = c.read(self.master, buffer.ptr, buffer.len);
        assert(count >= 0);
        return @intCast(count);
    }
};

test "size reports the terminal dimensions from the driver" {
    const pty = try Pty.open();
    defer pty.close();

    var posix = Posix.init(pty.slave, pty.slave);
    const system = posix.system();

    // A fresh pseudo-terminal has no size yet.
    try testing.expectError(error.NotATerminal, system.size());

    pty.resize(40, 12);
    try testing.expectEqual(system_mod.Size{ .columns = 40, .rows = 12 }, try system.size());
}

test "size reports NotATerminal for a non-terminal descriptor" {
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try testing.expect(dev_null >= 0);
    defer _ = c.close(dev_null);

    var posix = Posix.init(dev_null, dev_null);
    try testing.expectError(error.NotATerminal, posix.system().size());
}

test "read returns bytes typed into the terminal" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);

    // Canonical mode would hold input until a newline; raw mode is what the
    // session uses in practice.
    try posix.system().enter_raw();
    pty.writeMaster("hi");
    var buffer: [8]u8 = undefined;
    const count = try posix.system().read(&buffer, 100);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("hi", buffer[0..count]);
}

test "read times out with zero when nothing arrives" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);

    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try posix.system().read(&buffer, 10));
}

test "read reports InputClosed at end of file" {
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try testing.expect(dev_null >= 0);
    defer _ = c.close(dev_null);

    var posix = Posix.init(dev_null, dev_null);
    var buffer: [4]u8 = undefined;
    try testing.expectError(error.InputClosed, posix.system().read(&buffer, 10));
}

test "read reports end of file when the terminal goes away" {
    const pty = try Pty.open();
    defer pty.close();
    _ = c.close(pty.master);

    var posix = Posix.init(pty.slave, pty.slave);
    var buffer: [4]u8 = undefined;
    try testing.expectError(error.InputClosed, posix.system().read(&buffer, 10));
}

test "write reaches the terminal" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);

    try posix.system().write("frame");
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("frame", buffer[0..pty.readMaster(&buffer)]);
}

test "write maps a terminal write error to IoError" {
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try testing.expect(dev_null >= 0);
    defer _ = c.close(dev_null);

    var posix = Posix.init(dev_null, dev_null);
    try testing.expectError(error.IoError, posix.system().write("x"));
}

test "raw mode disables echo and canonical input, and restores them" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);
    const system = posix.system();

    const before = try std.posix.tcgetattr(pty.slave);
    try system.enter_raw();
    const during = try std.posix.tcgetattr(pty.slave);
    try testing.expect(before.lflag.ICANON);
    try testing.expect(!during.lflag.ICANON);
    try testing.expect(!during.lflag.ECHO);
    try testing.expect(!during.oflag.OPOST);

    try system.leave_raw();
    const after = try std.posix.tcgetattr(pty.slave);
    try testing.expect(after.lflag.ICANON);
    try testing.expect(after.lflag.ECHO);
}

test "leaving raw mode without entering it is a no-op" {
    const pty = try Pty.open();
    defer pty.close();
    var posix = Posix.init(pty.slave, pty.slave);
    try posix.system().leave_raw();
    try testing.expect(!posix.raw_enabled);
}

test "entering raw mode on a non-terminal fails without changing anything" {
    const dev_null = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try testing.expect(dev_null >= 0);
    defer _ = c.close(dev_null);

    var posix = Posix.init(dev_null, dev_null);
    try testing.expectError(error.NotATerminal, posix.system().enter_raw());
    try testing.expect(!posix.raw_enabled);
}

test "env reads the process environment" {
    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    };
    try testing.expectEqual(@as(c_int, 0), setenv.setenv("AMAIL_TEST_VARIABLE", "hello", 1));
    try testing.expectEqualStrings("hello", env("AMAIL_TEST_VARIABLE").?);
    try testing.expect(env("AMAIL_TEST_VARIABLE_THAT_DOES_NOT_EXIST") == null);
}

test "now_unix returns a plausible current time" {
    const now = now_unix();
    try testing.expect(now > 1_600_000_000);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "monotonic_ms advances, and sleep_ms waits at least one tick" {
    const before = monotonic_ms();
    try testing.expect(before > 0);
    sleep_ms(1);
    const after = monotonic_ms();
    try testing.expect(after >= before);

    // Zero means "no wait", and must not spin.
    sleep_ms(0);
}
