//! Process entry point. Wiring only: everything testable lives in `lib.zig`.

const std = @import("std");
const tui = @import("lib.zig");

/// A panic lands here before it lands on the terminal.
///
/// The reader holds the terminal in raw mode with the alternate screen up, so the
/// message goes to a file the user can send: "signal ABRT" and a stack trace are not a
/// diagnosis, and the line that says *what* failed is the first one, which the screen
/// has already scrolled away.
pub const panic = std.debug.FullPanic(zmailPanic);

fn zmailPanic(message: []const u8, first_trace_address: ?usize) noreturn {
    writePanicLog(message, first_trace_address);
    std.debug.defaultPanic(message, first_trace_address);
}

fn writePanicLog(message: []const u8, first_trace_address: ?usize) void {
    // Nothing here may allocate, wait, or use the event loop: the process is already
    // in a state it did not plan for. Three syscalls, and the file is the diagnosis.
    const fd = std.c.open(panic_log_path(), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "zmail panic: {s}\ntrace address: {?d}\n", .{
        message, first_trace_address,
    }) catch message;
    _ = std.c.write(fd, text.ptr, text.len);
}

/// Where the log goes: the cache directory, which every system this builds for has.
fn panic_log_path() [*:0]const u8 {
    return "/tmp/zmail-panic.log";
}

pub fn main(init: std.process.Init) !u8 {
    return tui.run.main(init);
}
