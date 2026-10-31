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
    missing_value: []const u8,
    duplicate_flag: []const u8,
};

pub const Mode = enum { demo, live };

/// What to start, and with which config.
pub const Launch = struct {
    mode: Mode = .demo,
    /// Null means "the default path", resolved at launch time.
    config_path: ?[]const u8 = null,
};

pub const Action = union(enum) {
    launch: Launch,
    print_version,
    print_help,
    usage_error: UsageError,
};

/// Parses `argv`, including the program name at index 0.
pub fn parse(args: []const []const u8) Action {
    var launch = Launch{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .print_help;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .print_version;

        if (std.mem.eql(u8, arg, "--demo")) {
            launch.mode = .demo;
            continue;
        }
        if (std.mem.eql(u8, arg, "--live")) {
            launch.mode = .live;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            if (launch.config_path != null) return .{ .usage_error = .{ .duplicate_flag = arg } };
            index += 1;
            if (index == args.len) return .{ .usage_error = .{ .missing_value = arg } };
            launch.config_path = args[index];
            launch.mode = .live;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            if (launch.config_path != null) return .{ .usage_error = .{ .duplicate_flag = "--config" } };
            const value = arg["--config=".len..];
            if (value.len == 0) return .{ .usage_error = .{ .missing_value = "--config" } };
            launch.config_path = value;
            launch.mode = .live;
            continue;
        }
        if (is_flag(arg)) return .{ .usage_error = .{ .unknown_flag = arg } };
        return .{ .usage_error = .{ .unexpected_argument = arg } };
    }
    return .{ .launch = launch };
}

/// `$XDG_CONFIG_HOME/amail/config`, or `$HOME/.config/amail/config`. Empty when
/// neither variable is set, which the launcher reports.
pub fn default_config_path(buffer: []u8, xdg_config_home: ?[]const u8, home: ?[]const u8) []const u8 {
    if (xdg_config_home) |xdg| {
        if (xdg.len > 0) return std.fmt.bufPrint(buffer, "{s}/amail/config", .{xdg}) catch "";
    }
    if (home) |base| {
        if (base.len > 0) return std.fmt.bufPrint(buffer, "{s}/.config/amail/config", .{base}) catch "";
    }
    return "";
}

fn is_flag(arg: []const u8) bool {
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
        \\      --live       Connect to the account in the config file
        \\      --config P   Use config file P (implies --live)
        \\
        \\The password is read from AMAIL_PASSWORD, never from the config.
        \\Inside amail, press ? for the key map.
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
        .missing_value => |flag| writer.print("option needs a value: {s}\n", .{flag}) catch return "",
        .duplicate_flag => |flag| writer.print("option given twice: {s}\n", .{flag}) catch return "",
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
    const action = parse(&no_args);
    try testing.expectEqual(Mode.demo, action.launch.mode);
    try testing.expect(action.launch.config_path == null);
}

test "--demo launches the demo client" {
    try testing.expectEqual(Mode.demo, parse(&demo_args).launch.mode);
}

test "--live launches with a config, without a path" {
    const action = parse(&[_][]const u8{ meta.name, "--live" });
    try testing.expectEqual(Mode.live, action.launch.mode);
    try testing.expect(action.launch.config_path == null);
}

test "--config takes the next argument and implies live" {
    const action = parse(&[_][]const u8{ meta.name, "--config", "/tmp/amail.conf" });
    try testing.expectEqual(Mode.live, action.launch.mode);
    try testing.expectEqualStrings("/tmp/amail.conf", action.launch.config_path.?);
}

test "--config=path works too" {
    const action = parse(&[_][]const u8{ meta.name, "--config=/tmp/amail.conf" });
    try testing.expectEqualStrings("/tmp/amail.conf", action.launch.config_path.?);
}

test "--demo after --live returns to the demo" {
    const action = parse(&[_][]const u8{ meta.name, "--live", "--demo" });
    try testing.expectEqual(Mode.demo, action.launch.mode);
}

test "--config without a value and repeated --config are usage errors" {
    const missing = parse(&[_][]const u8{ meta.name, "--config" });
    try testing.expectEqualStrings("--config", missing.usage_error.missing_value);

    const repeated = parse(&[_][]const u8{ meta.name, "--config", "a", "--config", "b" });
    try testing.expectEqualStrings("--config", repeated.usage_error.duplicate_flag);

    const repeated_equals = parse(&[_][]const u8{ meta.name, "--config=a", "--config=b" });
    try testing.expectEqualStrings("--config", repeated_equals.usage_error.duplicate_flag);

    const empty = parse(&[_][]const u8{ meta.name, "--config=" });
    try testing.expectEqualStrings("--config", empty.usage_error.missing_value);
}

test "default config path follows XDG, then HOME" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "/xdg/amail/config",
        default_config_path(&buffer, "/xdg", "/home/me"),
    );
    try testing.expectEqualStrings(
        "/home/me/.config/amail/config",
        default_config_path(&buffer, null, "/home/me"),
    );
    try testing.expectEqualStrings(
        "/home/me/.config/amail/config",
        default_config_path(&buffer, "", "/home/me"),
    );
    try testing.expectEqualStrings("", default_config_path(&buffer, null, null));
    try testing.expectEqualStrings("", default_config_path(&buffer, null, ""));
}

test "default config path degrades to empty when the buffer is too small" {
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("", default_config_path(&buffer, "/xdg", null));
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

test "repeated --demo and --live are harmless" {
    try testing.expectEqual(Mode.demo, parse(&[_][]const u8{ meta.name, "--demo", "--demo" }).launch.mode);
    try testing.expectEqual(Mode.live, parse(&[_][]const u8{ meta.name, "--live", "--live" }).launch.mode);
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
    try testing.expectEqualStrings(
        "option needs a value: --config\nRun 'amail --help' for usage.\n",
        render_usage_error(&buffer, .{ .missing_value = "--config" }),
    );
    try testing.expectEqualStrings(
        "option given twice: --config\nRun 'amail --help' for usage.\n",
        render_usage_error(&buffer, .{ .duplicate_flag = "--config" }),
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
