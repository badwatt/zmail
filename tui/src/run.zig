//! Process entry: argv in, intent out.
//!
//! The decision table is pure and fully tested. `main` is the only function
//! here that touches the process, and it only writes and picks an exit code.

const std = @import("std");
const cli = @import("cli.zig");
const launch_mod = @import("launch.zig");

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    args: std.process.Args,
};

pub const Hooks = struct {
    launch: *const fn (std.mem.Allocator, std.Io, cli.Launch) anyerror!u8 = launch_mod.run,
};

pub const Outcome = union(enum) {
    print_stdout: []const u8,
    print_stderr: struct { text: []const u8, exit: u8 },
    launch: cli.Launch,
};

pub fn decide(args: []const []const u8, stdout_buffer: []u8, stderr_buffer: []u8) Outcome {
    switch (cli.parse(args)) {
        .print_version => return .{ .print_stdout = cli.render_version(stdout_buffer) },
        .print_help => return .{ .print_stdout = cli.render_help(stdout_buffer) },
        .usage_error => |failure| return .{ .print_stderr = .{
            .text = cli.render_usage_error(stderr_buffer, failure),
            .exit = 2,
        } },
        .launch => |options| return .{ .launch = options },
    }
}

/// Process adapter: `main.zig` calls this and nothing else.
pub fn main(init: std.process.Init) !u8 {
    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);

    const code = try main_with(.{
        .gpa = init.gpa,
        .io = init.io,
        .args = init.minimal.args,
    }, .{}, &stdout.interface, &stderr.interface);

    try stdout.flush();
    try stderr.flush();
    return code;
}

/// Everything except the process plumbing. Output goes to the given writers,
/// which is why the tests do not have to pollute the test runner's stdout.
pub fn main_with(context: Context, hooks: Hooks, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    var arg_buffer: [cli.args_max][]const u8 = undefined;
    const args = cli.collect_args(context.args, &arg_buffer) catch {
        try stderr.writeAll("amail: too many arguments\n");
        return 2;
    };

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [256]u8 = undefined;
    switch (decide(args, &stdout_buffer, &stderr_buffer)) {
        .print_stdout => |text| {
            try stdout.writeAll(text);
            return 0;
        },
        .print_stderr => |failure| {
            try stderr.writeAll(failure.text);
            return failure.exit;
        },
        .launch => |options| return hooks.launch(context.gpa, context.io, options),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "decide: --version prints the version and exits 0" {
    var out: [1024]u8 = undefined;
    var err: [256]u8 = undefined;
    const outcome = decide(&[_][]const u8{ "amail", "--version" }, &out, &err);
    try testing.expectEqualStrings("amail 0.1.0\n", outcome.print_stdout);
}

test "decide: --help prints usage" {
    var out: [1024]u8 = undefined;
    var err: [256]u8 = undefined;
    const outcome = decide(&[_][]const u8{ "amail", "--help" }, &out, &err);
    try testing.expect(std.mem.startsWith(u8, outcome.print_stdout, "amail 0.1.0"));
}

test "decide: a bad flag prints to stderr and exits 2" {
    var out: [1024]u8 = undefined;
    var err: [256]u8 = undefined;
    const outcome = decide(&[_][]const u8{ "amail", "--nope" }, &out, &err);
    try testing.expectEqual(@as(u8, 2), outcome.print_stderr.exit);
    try testing.expect(std.mem.indexOf(u8, outcome.print_stderr.text, "--nope") != null);
}

test "decide: no arguments launches the client" {
    var out: [1024]u8 = undefined;
    var err: [256]u8 = undefined;
    const outcome = decide(&[_][]const u8{"amail"}, &out, &err);
    try testing.expectEqual(cli.Mode.demo, outcome.launch.mode);
}

fn stub_launch(gpa: std.mem.Allocator, io: std.Io, options: cli.Launch) anyerror!u8 {
    _ = gpa;
    _ = io;
    return switch (options.mode) {
        .demo => 7,
        .live => 8,
    };
}

test "main_with routes every outcome, including launch" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [256]u8 = undefined;

    const launch_args = [_][*:0]const u8{"amail"};
    var out = std.Io.Writer.fixed(&out_buffer);
    var err = std.Io.Writer.fixed(&err_buffer);
    const launched = try main_with(.{
        .gpa = testing.allocator,
        .io = io,
        .args = .{ .vector = &launch_args },
    }, .{ .launch = stub_launch }, &out, &err);
    try testing.expectEqual(@as(u8, 7), launched);

    const version_args = [_][*:0]const u8{ "amail", "--version" };
    out = std.Io.Writer.fixed(&out_buffer);
    err = std.Io.Writer.fixed(&err_buffer);
    try testing.expectEqual(@as(u8, 0), try main_with(.{
        .gpa = testing.allocator,
        .io = io,
        .args = .{ .vector = &version_args },
    }, .{ .launch = stub_launch }, &out, &err));
    try testing.expectEqualStrings("amail 0.1.0\n", out.buffered());

    const bad_args = [_][*:0]const u8{ "amail", "--nope" };
    out = std.Io.Writer.fixed(&out_buffer);
    err = std.Io.Writer.fixed(&err_buffer);
    try testing.expectEqual(@as(u8, 2), try main_with(.{
        .gpa = testing.allocator,
        .io = io,
        .args = .{ .vector = &bad_args },
    }, .{ .launch = stub_launch }, &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "unknown option: --nope") != null);
}

test "main_with rejects too many arguments" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out_buffer: [64]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var err = std.Io.Writer.fixed(&err_buffer);

    var vector: [cli.args_max + 1][*:0]const u8 = undefined;
    for (&vector) |*argument| argument.* = "x";
    try testing.expectEqual(@as(u8, 2), try main_with(.{
        .gpa = testing.allocator,
        .io = io,
        .args = .{ .vector = &vector },
    }, .{ .launch = stub_launch }, &out, &err));
    try testing.expectEqualStrings("amail: too many arguments\n", err.buffered());
}
