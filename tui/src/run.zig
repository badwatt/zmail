//! Process entry: argv in, intent out.
//!
//! The decision table is pure and fully tested. `main` is the only function
//! here that touches the process, and it only writes and picks an exit code.

const std = @import("std");
const cli = @import("cli.zig");
const launch_mod = @import("launch.zig");
const meta = @import("core").meta;

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
        try stderr.print("{s}: too many arguments\n", .{meta.name});
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
        .launch => |options| return hooks.launch(context.gpa, context.io, options) catch |err| switch (err) {
            // A full-screen client on a pipe is a mistake, not a crash: say so
            // once instead of printing a stack trace.
            error.NotATerminal => {
                try stderr.print("{s}: this client needs a terminal\n", .{meta.name});
                return 1;
            },
            else => return err,
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "decide: --version prints the version and exits 0" {
    var out: [1024]u8 = undefined;
    var err: [256]u8 = undefined;
    const outcome = decide(&[_][]const u8{ meta.name, "--version" }, &out, &err);
    var expected_buffer: [64]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buffer, "{s} {s}\n", .{
        meta.name, meta.version,
    }) catch unreachable;
    try testing.expectEqualStrings(expected, outcome.print_stdout);
}

test "decide: --help prints usage" {
    var out: [1024]u8 = undefined;
    var err: [256]u8 = undefined;
    const outcome = decide(&[_][]const u8{ meta.name, "--help" }, &out, &err);
    var expected_buffer: [64]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buffer, "{s} {s}", .{
        meta.name, meta.version,
    }) catch unreachable;
    try testing.expect(std.mem.startsWith(u8, outcome.print_stdout, expected));
}

test "decide: a bad flag prints to stderr and exits 2" {
    var out: [1024]u8 = undefined;
    var err: [256]u8 = undefined;
    const outcome = decide(&[_][]const u8{ meta.name, "--nope" }, &out, &err);
    try testing.expectEqual(@as(u8, 2), outcome.print_stderr.exit);
    try testing.expect(std.mem.indexOf(u8, outcome.print_stderr.text, "--nope") != null);
}

test "decide: no arguments launches the client" {
    var out: [1024]u8 = undefined;
    var err: [256]u8 = undefined;
    const outcome = decide(&[_][]const u8{meta.name}, &out, &err);
    try testing.expectEqual(cli.Mode.live, outcome.launch.mode);
}

fn stub_launch(gpa: std.mem.Allocator, io: std.Io, options: cli.Launch) anyerror!u8 {
    _ = gpa;
    _ = io;
    return switch (options.mode) {
        .demo => 7,
        .live => 8,
    };
}

test "main_with reports a missing terminal without a stack trace" {
    var out_buffer: [512]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var err = std.Io.Writer.fixed(&err_buffer);

    const args = [_][*:0]const u8{meta.name ++ "\x00"};
    const code = try main_with(.{
        .gpa = testing.allocator,
        .io = testing.io,
        .args = .{ .vector = &args },
    }, .{ .launch = stub_no_terminal }, &out, &err);

    try testing.expectEqual(@as(u8, 1), code);
    try testing.expectEqualStrings(meta.name ++ ": this client needs a terminal\n", err.buffered());

    // Anything else keeps propagating: this is not a catch-all.
    out = std.Io.Writer.fixed(&out_buffer);
    err = std.Io.Writer.fixed(&err_buffer);
    try testing.expectError(error.Boom, main_with(.{
        .gpa = testing.allocator,
        .io = testing.io,
        .args = .{ .vector = &args },
    }, .{ .launch = stub_boom }, &out, &err));
}

fn stub_boom(_: std.mem.Allocator, _: std.Io, _: cli.Launch) !u8 {
    return error.Boom;
}

fn stub_no_terminal(_: std.mem.Allocator, _: std.Io, _: cli.Launch) !u8 {
    return error.NotATerminal;
}

test "main_with routes every outcome, including launch" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [256]u8 = undefined;

    // No arguments means live, which is the default.
    const live_args = [_][*:0]const u8{meta.name ++ "\x00"};
    var out = std.Io.Writer.fixed(&out_buffer);
    var err = std.Io.Writer.fixed(&err_buffer);
    const launched = try main_with(.{
        .gpa = testing.allocator,
        .io = io,
        .args = .{ .vector = &live_args },
    }, .{ .launch = stub_launch }, &out, &err);
    try testing.expectEqual(@as(u8, 8), launched);

    const demo_args = [_][*:0]const u8{ meta.name ++ "\x00", "--demo" };
    out = std.Io.Writer.fixed(&out_buffer);
    err = std.Io.Writer.fixed(&err_buffer);
    try testing.expectEqual(@as(u8, 7), try main_with(.{
        .gpa = testing.allocator,
        .io = io,
        .args = .{ .vector = &demo_args },
    }, .{ .launch = stub_launch }, &out, &err));

    const version_args = [_][*:0]const u8{ meta.name ++ "\x00", "--version" };
    out = std.Io.Writer.fixed(&out_buffer);
    err = std.Io.Writer.fixed(&err_buffer);
    try testing.expectEqual(@as(u8, 0), try main_with(.{
        .gpa = testing.allocator,
        .io = io,
        .args = .{ .vector = &version_args },
    }, .{ .launch = stub_launch }, &out, &err));
    var version_buffer: [64]u8 = undefined;
    const version_text = std.fmt.bufPrint(&version_buffer, "{s} {s}\n", .{
        meta.name, meta.version,
    }) catch unreachable;
    try testing.expectEqualStrings(version_text, out.buffered());

    const bad_args = [_][*:0]const u8{ meta.name ++ "\x00", "--nope" };
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
    try testing.expectEqualStrings(meta.name ++ ": too many arguments\n", err.buffered());
}
