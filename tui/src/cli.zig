//! Command-line parsing. Pure: argv in, intent out.
//!
//! The product name and version come from `build.zig.zon` through `core.meta`,
//! so `--version` can never drift from the package manifest.

const std = @import("std");
const core = @import("core");
const meta = core.meta;

pub const UsageError = union(enum) {
    unknown_flag: []const u8,
    unexpected_argument: []const u8,
};

pub const Action = union(enum) {
    /// Start the mail client. Today this is always the built-in demo account.
    launch,
    print_version,
    print_help,
    usage_error: UsageError,
};

/// Parses `argv`, including the program name at index 0.
pub fn parse(args: []const []const u8) Action {
    if (args.len <= 1) return .launch;

    var seen_demo = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .print_help;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .print_version;
        if (std.mem.eql(u8, arg, "--demo")) {
            if (seen_demo) return .{ .usage_error = .{ .unexpected_argument = arg } };
            seen_demo = true;
            continue;
        }
        if (isFlag(arg)) return .{ .usage_error = .{ .unknown_flag = arg } };
        return .{ .usage_error = .{ .unexpected_argument = arg } };
    }
    return .launch;
}

fn isFlag(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

/// Maximum arguments amail accepts. A mail client has no use for more.
pub const args_max: u32 = 16;

/// Copies the process arguments into `buffer`, so the rest of the program works
/// with plain slices instead of the platform's sentinel-pointer vector.
pub fn collect_args(vector: std.process.Args, buffer: [][]const u8) error{TooManyArguments}![]const []const u8 {
    var iterator = vector.iterate();
    defer iterator.deinit();

    var count: u32 = 0;
    while (iterator.next()) |arg| {
        if (count == buffer.len) return error.TooManyArguments;
        buffer[count] = arg;
        count += 1;
    }
    return buffer[0..count];
}

/// Writes the `--version` output. Returns the bytes written.
pub fn render_version(buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}\n", .{ meta.name, meta.version }) catch "";
}

/// Writes the `--help` output. Returns the bytes written.
pub fn render_help(buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writer.print(
        \\{s} {s} - a calm terminal mail client
        \\
        \\Usage: {s} [options]
        \\
        \\Options:
        \\  -h, --help       Show this help and exit
        \\  -V, --version    Show the version and exit
        \\      --demo       Open the built-in demo mailbox (default)
        \\
        \\Inside amail, press ? for the key map. Nothing is sent anywhere:
        \\the demo account is local and offline.
        \\
    ,
        .{ meta.name, meta.version, meta.name },
    ) catch return "";
    return writer.buffered();
}

/// Writes the message shown for a bad invocation. Returns the bytes written.
pub fn render_usage_error(buffer: []u8, err: UsageError) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    switch (err) {
        .unknown_flag => |flag| writer.print("unknown option: {s}\n", .{flag}) catch return "",
        .unexpected_argument => |arg| writer.print("unexpected argument: {s}\n", .{arg}) catch return "",
    }
    writer.print("Run '{s} --help' for usage.\n", .{meta.name}) catch return "";
    return writer.buffered();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const no_args = [_][]const u8{meta.name};
const demo_args = [_][]const u8{ meta.name, "--demo" };

test "no arguments launches the demo client" {
    try testing.expectEqual(Action.launch, parse(&no_args));
}

test "--demo launches the demo client" {
    try testing.expectEqual(Action.launch, parse(&demo_args));
}

test "--help and -h print help" {
    try testing.expectEqual(Action.print_help, parse(&[_][]const u8{ meta.name, "--help" }));
    try testing.expectEqual(Action.print_help, parse(&[_][]const u8{ meta.name, "-h" }));
}

test "--version and -V print the version" {
    try testing.expectEqual(Action.print_version, parse(&[_][]const u8{ meta.name, "--version" }));
    try testing.expectEqual(Action.print_version, parse(&[_][]const u8{ meta.name, "-V" }));
}

test "help and version win over other flags, in either order" {
    try testing.expectEqual(Action.print_help, parse(&[_][]const u8{ meta.name, "--demo", "--help" }));
    try testing.expectEqual(Action.print_version, parse(&[_][]const u8{ meta.name, "-V", "--demo" }));
}

test "an unknown flag is a usage error naming the flag" {
    const action = parse(&[_][]const u8{ meta.name, "--nope" });
    const err = action.usage_error;
    try testing.expectEqualStrings("--nope", err.unknown_flag);
}

test "a lone dash is treated as a positional argument, not a flag" {
    const action = parse(&[_][]const u8{ meta.name, "-" });
    try testing.expectEqualStrings("-", action.usage_error.unexpected_argument);
}

test "a positional argument is a usage error" {
    const action = parse(&[_][]const u8{ meta.name, "inbox" });
    try testing.expectEqualStrings("inbox", action.usage_error.unexpected_argument);
}

test "a repeated --demo is a usage error" {
    const action = parse(&[_][]const u8{ meta.name, "--demo", "--demo" });
    try testing.expectEqualStrings("--demo", action.usage_error.unexpected_argument);
}

test "render_version names the product and its semver" {
    var buffer: [64]u8 = undefined;
    const output = render_version(&buffer);
    try testing.expectEqualStrings("amail 0.1.0\n", output);
    try testing.expectEqualStrings(meta.name, output[0..meta.name.len]);
}

test "render_help documents every option and the demo default" {
    var buffer: [1024]u8 = undefined;
    const output = render_help(&buffer);
    try testing.expect(std.mem.startsWith(u8, output, "amail 0.1.0 - a calm terminal mail client"));
    try testing.expect(std.mem.indexOf(u8, output, "--help") != null);
    try testing.expect(std.mem.indexOf(u8, output, "--version") != null);
    try testing.expect(std.mem.indexOf(u8, output, "--demo") != null);
}

test "render_help degrades to empty output when the buffer cannot hold it" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("", render_help(&buffer));
}

test "render_usage_error names the offending value and points at help" {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "unknown option: --nope\nRun 'amail --help' for usage.\n",
        render_usage_error(&buffer, .{ .unknown_flag = "--nope" }),
    );
    try testing.expectEqualStrings(
        "unexpected argument: inbox\nRun 'amail --help' for usage.\n",
        render_usage_error(&buffer, .{ .unexpected_argument = "inbox" }),
    );
}

test "render_usage_error degrades to empty output when the buffer cannot hold it" {
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("", render_usage_error(&buffer, .{ .unknown_flag = "--nope" }));
}

test "collect_args copies the process vector into plain slices" {
    const vector = [_][*:0]const u8{ "amail", "--version" };
    var buffer: [args_max][]const u8 = undefined;
    const args = try collect_args(.{ .vector = &vector }, &buffer);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("amail", args[0]);
    try testing.expectEqualStrings("--version", args[1]);
}

test "collect_args refuses more arguments than the buffer holds" {
    const vector = [_][*:0]const u8{ "a", "b", "c" };
    var buffer: [2][]const u8 = undefined;
    try testing.expectError(error.TooManyArguments, collect_args(.{ .vector = &vector }, &buffer));
}
