//! End-to-end tests: spawn the real `amail` binary.
//!
//! These cover the process boundary that unit tests cannot: argv handling,
//! stdout/stderr, and exit codes. The interactive session is covered separately
//! by driving the binary through a pseudo-terminal.

const std = @import("std");
const core = @import("core");
const meta = core.meta;
const exe_path = @import("build_options").amail_exe;

const testing = std.testing;

const Run = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !Run {
    const result = try std.process.run(gpa, io, .{ .argv = args });
    const code = switch (result.term) {
        .exited => |value| value,
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .code = code };
}

test "--version prints the name and version from build.zig.zon" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = try run(testing.allocator, io, &.{ exe_path, "--version" });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expectEqualStrings("amail 0.1.0\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "--help prints usage and exits 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = try run(testing.allocator, io, &.{ exe_path, "--help" });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Usage: amail") != null);
}

test "an unknown option exits 2 and explains itself on stderr" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = try run(testing.allocator, io, &.{ exe_path, "--nope" });
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 2), result.code);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "unknown option: --nope") != null);
}

test "the product name and version come from the same source of truth" {
    try testing.expectEqualStrings("amail", meta.name);
    var expected: [32]u8 = undefined;
    const version_line = try std.fmt.bufPrint(&expected, "{s} {s}\n", .{ meta.name, meta.version });
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const result = try run(testing.allocator, threaded.io(), &.{ exe_path, "--version" });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings(version_line, result.stdout);
}
