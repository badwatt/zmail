//! Breathing while the loop is blocked.
//!
//! The first connection is one blocking call -- DNS, TLS, login, FETCH -- and nothing
//! in this program paints inside it. On a real server that is seconds of a still
//! frame, which is exactly what a splash screen is not for.
//!
//! So the mark gets its own painter for that window, and nothing else: it draws the
//! wordmark's own cells, with the colour of the next step of the breath, at absolute
//! coordinates. It is started immediately before the blocking call and joined
//! immediately after, so the two threads never write at the same time, and what it
//! draws is the same mark in the same place -- writing it twice changes nothing.

const std = @import("std");
const core = @import("core");
const render = @import("render.zig");
const screen = @import("screen.zig");
const system_mod = @import("system.zig");
const theme_mod = @import("theme.zig");
const System = system_mod.System;

/// Frames per second while the loop is away. Ten is what the loop itself manages;
/// more only makes the terminal busier at a time when nobody is typing.
pub const frame_ms: u64 = 90;

pub const Painter = struct {
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    system: System = undefined,
    placement: render.MarkPlacement = .{ .left = 0, .top = 0, .height = 0, .width = 0, .large = false },
    theme: theme_mod.Theme = theme_mod.Theme.dark(),
    reduced_motion: bool = false,
    tick: u16 = 0,

    /// Starts painting the mark where it already is. Nothing happens when the splash
    /// is not on screen.
    pub fn start(
        self: *Painter,
        system: System,
        size: system_mod.Size,
        theme: theme_mod.Theme,
        reduced_motion: bool,
        from_tick: u16,
    ) void {
        if (self.thread != null) return;
        if (size.columns == 0 or size.rows == 0) return;
        self.system = system;
        self.placement = render.splash_mark(size.columns, size.rows);
        self.theme = theme;
        self.reduced_motion = reduced_motion;
        self.tick = from_tick;
        self.stop.store(false, .release);
        self.thread = std.Thread.spawn(.{}, Painter.run, .{self}) catch null;
    }

    /// Stops and waits: the caller is about to write to the terminal itself.
    pub fn finish(self: *Painter) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn run(self: *Painter) void {
        while (!self.stop.load(.acquire)) {
            var waited: u64 = 0;
            while (waited < frame_ms and !self.stop.load(.acquire)) : (waited += 10) {
                _ = std.c.nanosleep(&std.posix.timespec{
                    .sec = 0,
                    .nsec = 10 * std.time.ns_per_ms,
                }, null);
            }
            if (self.stop.load(.acquire)) return;
            self.paint();
        }
    }

    /// One frame of the mark, and nothing else: rows of absolute cursor moves, the
    /// glyphs they already have, and the colour this step of the breath asks for.
    fn paint(self: *Painter) void {
        const placement = self.placement;
        if (placement.height == 0 or placement.width == 0) return;

        const level = if (self.reduced_motion) 1.0 else render.breath_level(self.tick);
        self.tick +%= 1;
        if (level < render.hidden_level) return;

        // The colour first, then the rows: the style stays set across the moves, so
        // one sequence per frame is enough.
        var sequence: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&sequence);
        write_sgr(&writer, self.theme, level) catch return;
        self.system.write(writer.buffered()) catch return;

        // Simple and idempotent: every row, its address, its glyphs.
        var row: u16 = 0;
        while (row < placement.height) : (row += 1) {
            var row_text: [128]u8 = undefined;
            var length: usize = 0;
            var column: u16 = 0;
            while (column < placement.width) : (column += 1) {
                const cell = render.mark_cell(placement.large, row, column);
                if (cell == ' ') {
                    row_text[length] = ' ';
                    length += 1;
                    continue;
                }
                const encoded = std.unicode.utf8Encode(cell, row_text[length..][0..4]) catch continue;
                length += encoded;
            }
            var text: [64]u8 = undefined;
            const move = std.fmt.bufPrint(&text, "\x1b[{d};{d}H", .{
                placement.top + row + 1,
                placement.left + 1,
            }) catch return;
            self.system.write(move) catch return;
            self.system.write(row_text[0..length]) catch return;
        }
    }
};

fn write_sgr(writer: *std.Io.Writer, theme: theme_mod.Theme, level: f32) std.Io.Writer.Error!void {
    const style = render.breath_style(&theme, level);
    try writer.writeAll("\x1b[0m");
    switch (style.fg) {
        .rgb => |rgb| try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
        .ansi256 => |index| try writer.print("\x1b[38;5;{d}m", .{index}),
        .default => {},
    }
    if (style.attrs.bold) try writer.writeAll("\x1b[1m");
}

const testing = std.testing;

test "the painter draws the mark where the splash put it, and stops" {
    var fake: system_mod.Fake = .{};
    var painter = Painter{};

    painter.start(fake.system(), .{ .columns = 100, .rows = 30 }, theme_mod.Theme.dark(), false, 0);
    // Long enough for at least one frame, short enough not to slow the suite.
    _ = std.c.nanosleep(&std.posix.timespec{ .sec = 0, .nsec = 120 * std.time.ns_per_ms }, null);
    painter.finish();

    const written = fake.output_text();
    // A cursor move to the mark's first row, and the mark's own glyphs.
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, written, "█") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[38;") != null);
    try testing.expect(painter.thread == null);
}

test "with no room for a mark, nothing is painted" {
    var fake: system_mod.Fake = .{};
    var painter = Painter{};
    painter.start(fake.system(), .{ .columns = 0, .rows = 0 }, theme_mod.Theme.dark(), false, 0);
    painter.finish();
    try testing.expectEqualStrings("", fake.output_text());
}

test "the colour of one frame: truecolor, a palette index, or nothing at all" {
    var buffer: [64]u8 = undefined;

    var writer = std.Io.Writer.fixed(&buffer);
    try write_sgr(&writer, theme_mod.Theme.from_background(.{ .r = 20, .g = 20, .b = 24 }), 1.0);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "38;2;") != null);

    writer = std.Io.Writer.fixed(&buffer);
    try write_sgr(&writer, theme_mod.Theme.dark(), 1.0);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "38;5;") != null);

    // Monochrome: no colour at all, and the weight carries the change.
    writer = std.Io.Writer.fixed(&buffer);
    try write_sgr(&writer, theme_mod.Theme.mono(), 1.0);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "38;") == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[1m") != null);
}
