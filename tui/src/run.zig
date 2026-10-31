//! Process entry: read argv, pick an intent, hand off.
//!
//! This file is deliberately boring. It owns no policy, so the only thing it
//! can get wrong is the plumbing, which the end-to-end tests exercise against
//! the real binary.

const std = @import("std");
const cli = @import("cli.zig");
const session = @import("session.zig");

pub fn main(init: std.process.Init) !u8 {
    var arg_buffer: [cli.args_max][]const u8 = undefined;
    const args = cli.collect_args(init.minimal.args, &arg_buffer) catch {
        try writeStderr(init.io, "amail: too many arguments\n");
        return 2;
    };

    switch (cli.parse(args)) {
        .print_version => {
            var buffer: [64]u8 = undefined;
            try writeStdout(init.io, cli.render_version(&buffer));
            return 0;
        },
        .print_help => {
            var buffer: [1024]u8 = undefined;
            try writeStdout(init.io, cli.render_help(&buffer));
            return 0;
        },
        .usage_error => |err| {
            var buffer: [256]u8 = undefined;
            try writeStderr(init.io, cli.render_usage_error(&buffer, err));
            return 2;
        },
        .launch => return session.launch(init),
    }
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}
