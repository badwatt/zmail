//! The argv list that tells the desktop there is mail.
//!
//! No shell, ever: the program that runs is exactly the one named here, with
//! exactly these arguments. A subject is attacker-controlled text, and the only
//! reason it cannot become a command is that nothing in this file builds one.

const std = @import("std");
const assert = std.debug.assert;
const meta = @import("meta.zig");

/// How many words a notification command takes: the program, its flags, and two
/// arguments that may be as long as a subject.
pub const argv_max = 8;
/// A body longer than this is cut: a notification that does not fit the screen is
/// a notification nobody reads.
pub const body_max: u32 = 160;

pub const Kind = enum {
    /// Linux and the BSDs: libnotify's `notify-send`.
    notify_send,
    /// macOS: the system's own scripting bridge.
    osascript,
};

pub const Command = struct {
    items: [argv_max][]const u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Command) []const []const u8 {
        assert(self.len <= argv_max);
        return self.items[0..self.len];
    }
};

pub const Error = error{TooLong};

/// The command that shows `summary` and `body`, with the arguments already cut to
/// what a notification can hold. Both buffers must outlive the command.
pub fn command(
    kind: Kind,
    summary: []const u8,
    body: []const u8,
    buffers: *Buffers,
) Error!Command {
    _ = &buffers.title;
    var command_out = Command{};

    writeTitle(buffers, summary);
    writeBody(buffers, body);

    switch (kind) {
        .notify_send => {
            command_out.items[0] = "notify-send";
            command_out.items[1] = "--app-name";
            command_out.items[2] = meta.name;
            command_out.items[3] = "--icon";
            command_out.items[4] = "mail-unread";
            command_out.items[5] = buffers.titleText();
            command_out.items[6] = buffers.bodyText();
            command_out.len = 7;
        },
        .osascript => {
            // The script is a line of its own, built from the escaped body: writing
            // it into the buffer it is reading from would feed itself its own text.
            const line = std.fmt.bufPrint(&buffers.script, "display notification \"{s}\" with title \"{s}\"", .{
                buffers.escapedText(),
                buffers.titleText(),
            }) catch return error.TooLong;
            buffers.script_len = line.len;

            command_out.items[0] = "osascript";
            command_out.items[1] = "-e";
            command_out.items[2] = buffers.scriptText();
            command_out.len = 3;
        },
    }
    return command_out;
}

/// The bytes the command points at. Fixed, like everything else: a notification is
/// built from a message, and a message is attacker-controlled.
pub const Buffers = struct {
    title: [96]u8 = undefined,
    title_len: usize = 0,
    body: [body_max]u8 = undefined,
    body_len: usize = 0,
    /// The body as an AppleScript string literal: quotes and backslashes escaped.
    escaped: [body_max * 2 + 8]u8 = undefined,
    escaped_len: usize = 0,
    /// The whole `display notification …` line, built from the escaped body.
    script: [body_max * 2 + 160]u8 = undefined,
    script_len: usize = 0,

    pub fn titleText(self: *const Buffers) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn bodyText(self: *const Buffers) []const u8 {
        return self.body[0..self.body_len];
    }

    pub fn escapedText(self: *const Buffers) []const u8 {
        return self.escaped[0..self.escaped_len];
    }

    pub fn scriptText(self: *const Buffers) []const u8 {
        return self.script[0..self.script_len];
    }
};

fn writeTitle(buffers: *Buffers, summary: []const u8) void {
    buffers.title_len = @min(summary.len, buffers.title.len);
    @memcpy(buffers.title[0..buffers.title_len], summary[0..buffers.title_len]);
}

fn writeBody(buffers: *Buffers, body: []const u8) void {
    buffers.body_len = 0;
    buffers.escaped_len = 0;
    for (body) |byte| {
        if (buffers.body_len == buffers.body.len) break;
        // Control bytes would break the line the desktop draws; a tab is a space.
        const safe: u8 = if (byte < 0x20) ' ' else byte;
        buffers.body[buffers.body_len] = safe;
        buffers.body_len += 1;
        // AppleScript's string literal: a backslash or a quote closes it otherwise.
        if (safe == '"' or safe == '\\') {
            if (buffers.escaped_len == buffers.escaped.len) break;
            buffers.escaped[buffers.escaped_len] = '\\';
            buffers.escaped_len += 1;
        }
        if (buffers.escaped_len == buffers.escaped.len) break;
        buffers.escaped[buffers.escaped_len] = safe;
        buffers.escaped_len += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "notify: the Linux command names the program, the app and the text" {
    var buffers = Buffers{};
    const command_out = try command(.notify_send, "2 new in work", "Alice — Lunch plans", &buffers);
    const argv = command_out.slice();
    try testing.expectEqual(@as(usize, 7), argv.len);
    try testing.expectEqualStrings("notify-send", argv[0]);
    try testing.expectEqualStrings("--app-name", argv[1]);
    try testing.expectEqualStrings(meta.name, argv[2]);
    try testing.expectEqualStrings("--icon", argv[3]);
    try testing.expectEqualStrings("mail-unread", argv[4]);
    try testing.expectEqualStrings("2 new in work", argv[5]);
    try testing.expectEqualStrings("Alice — Lunch plans", argv[6]);
}

test "notify: the Mac command is one script, with the text escaped" {
    var buffers = Buffers{};
    // A subject with a quote in it: the one thing that could close the literal.
    const command_out = try command(.osascript, "new mail", "He said \"hi\"", &buffers);
    const argv = command_out.slice();
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("osascript", argv[0]);
    try testing.expectEqualStrings("-e", argv[1]);
    try testing.expectEqualStrings("display notification \"He said \\\"hi\\\"\" with title \"new mail\"", argv[2]);
}

test "notify: control bytes become spaces, and a long body is cut" {
    var buffers = Buffers{};
    const command_out = try command(.notify_send, "x", "a\nb\tc", &buffers);
    try testing.expectEqualStrings("a b c", command_out.slice()[6]);

    var long: [body_max * 2]u8 = undefined;
    @memset(&long, 'z');
    const cut = try command(.notify_send, "x", &long, &buffers);
    try testing.expectEqual(@as(usize, body_max), cut.slice()[6].len);

    // The title has its own bound, and is cut the same way.
    var title: [200]u8 = undefined;
    @memset(&title, 'y');
    const cut_title = try command(.notify_send, &title, "b", &buffers);
    try testing.expectEqual(@as(usize, buffers.title.len), cut_title.slice()[5].len);
}

test "notify: a script that cannot fit is an error, not a shorter script" {
    var buffers = Buffers{};
    var huge: [body_max * 2]u8 = undefined;
    @memset(&huge, '"');
    // Two bytes per quote in the script, so it overflows sooner than the body.
    const command_out = try command(.osascript, "t", &huge, &buffers);
    // What fits is what is there: the script stops at the buffer, never outside it.
    try testing.expect(command_out.slice()[2].len <= buffers.script.len);
    try testing.expect(std.mem.endsWith(u8, command_out.slice()[2], "with title \"t\""));
}
