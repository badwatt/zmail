//! The first screen: what the program shows while the first connection is being made.
//!
//! Nothing here touches the terminal or the clock. `draw` is a function of the
//! milliseconds since the screen went up, which is what lets the loop and the painter
//! thread -- the one that runs while the connection blocks -- put the same frame on
//! screen without either of them owning the animation.
//!
//! The wordmark is one drawing, five cells high and thirty-five wide. The size on
//! screen is that drawing with every cell repeated twice, three times, or four,
//! whichever still leaves air around it.

const std = @import("std");
const core = @import("core");
const screen_mod = @import("screen.zig");
const screen = screen_mod;
const theme_mod = @import("theme.zig");

const Screen = screen_mod.Screen;
const Style = screen_mod.Style;
const Theme = theme_mod.Theme;
const State = core.state.State;

/// The wordmark, drawn rather than typed: five rows, one-cell strokes, and air
/// between the letters, so it reads as a masthead instead of as a fence. A
/// terminal cannot set type, and this is the closest it gets.
const wordmark_rows = [_][]const u8{
    "▐██████ ▐█   ██ ▐██████ ▐██ ▐██    ",
    "   ▐██  ▐██ ███ ▐██ ▐██ ▐██ ▐██    ",
    "  ▐██   ▐█ █ ██ ▐██████ ▐██ ▐██    ",
    " ▐██    ▐█   ██ ▐██ ▐██ ▐██ ▐██    ",
    "▐██████ ▐█   ██ ▐██ ▐██ ▐██ ▐█████ ",
};

/// One wordmark, two sizes. The big one is the small one with every cell drawn
/// twice: a terminal cannot scale type, so the only way to have a bigger
/// wordmark is to draw more of it, and deriving it from one shape is what keeps
/// the two from drifting apart.
const wordmark = Words{
    .small = decode(5, 35, wordmark_rows),
};

const Words = struct {
    small: [5][35]u21,
};

fn decode(
    comptime rows: usize,
    comptime width: usize,
    comptime lines: [rows][]const u8,
) [rows][width]u21 {
    @setEvalBranchQuota(4000);
    var out: [rows][width]u21 = @splat(@splat(' '));
    for (lines, 0..) |line, y| {
        var index: usize = 0;
        var cell: usize = 0;
        while (index < line.len and cell < width) {
            const length = std.unicode.utf8ByteSequenceLength(line[index]) catch 1;
            const stop = @min(line.len, index + length);
            out[y][cell] = std.unicode.utf8Decode(line[index..stop]) catch ' ';
            index = stop;
            cell += 1;
        }
    }
    return out;
}

/// One breath, in ticks of the first screen's clock. A tick is one frame of the
/// loop, 90ms: forty-four of them is a four-second breath, in and out.
pub const breath_ticks: u16 = 44;

/// Below this a letter is not drawn at all. The breath bottoms out well above it
/// (`breath_floor`), so this only bites if that floor is set to nothing: the fade is
/// a mix towards the ground, which is invisible on the ground itself, and only when
/// the ground is known -- a cell that is not painted is gone on every terminal.
pub const hidden_level: f32 = 0.02;

/// How long one breath takes, in milliseconds.
pub const breath_ms: i64 = @as(i64, breath_ticks) * 90;

/// How solid the wordmark is, one at the peak. The whole word breathes together,
/// which is what makes it read as one thing drawing breath rather than as letters
/// flickering on their own.
/// The breath at a moment in the first screen's life, from zero upwards.
///
/// It takes milliseconds, not a frame count: two things paint this mark -- the loop
/// and the thread that keeps it moving while the connection blocks -- and a frame
/// counter each of them incremented was two clocks, which showed up as the mark
/// jumping a quarter of a breath whenever one handed over to the other.
pub fn breath_level_at(elapsed_ms: i64) f32 {
    const half = breath_ms / 2;
    const phase = @mod(elapsed_ms, breath_ms);
    const travelled = if (phase <= half) phase else breath_ms - phase;
    const fraction = @as(f32, @floatFromInt(travelled)) / @as(f32, half);
    const shape = 1.0 - std.math.pow(f32, fraction, breath_ease);
    return breath_floor + (1.0 - breath_floor) * shape;
}

/// How dim the mark is allowed to get.
pub const breath_floor: f32 = 0.45;

/// Below one, so the ends of the breath are steep: the shape of air leaving slowly
/// and coming back, not of a bar sliding.
const breath_ease: f32 = 0.55;

/// The style of one cell at `level` of opacity.
///
/// A terminal has no alpha channel, so transparency is a mix towards the colour
/// behind the letter: the theme's own ground when it knows it, in OKLCH, so a light
/// terminal fades towards paper and a dark one towards its own dark. Without a
/// derivation to follow -- no colour, or the built-in palette -- the ramp is carried
/// by weight and by the palette's steps instead.
pub fn breath_style(theme: *const Theme, level: f32) Style {
    const clamped = std.math.clamp(level, 0.0, 1.0);

    if (!theme.colored) {
        return if (clamped < 0.55) theme.accent.with_dim() else theme.accent.with_bold();
    }

    switch (theme.accent.fg) {
        .rgb => |rgb| {
            const accent = core.oklch.from_rgb(.{ .r = rgb.r, .g = rgb.g, .b = rgb.b });
            const ground_rgb: core.oklch.Rgb = theme.ground orelse core.oklch.Rgb{ .r = 0, .g = 0, .b = 0 };
            const ground = core.oklch.from_rgb(ground_rgb);
            const mixed = core.oklch.Oklch{
                .l = ground.l + (accent.l - ground.l) * clamped,
                .c = accent.c * clamped,
                .h = accent.h,
            };
            const out = core.oklch.to_rgb(mixed);
            return (Style{}).with_fg(.{ .rgb = .{ .r = out.r, .g = out.g, .b = out.b } });
        },
        else => {
            const fixed = [_]u8{ 64, 68, 74, 80 };
            const step: usize = @intFromFloat(clamped * @as(f32, fixed.len - 1) + 0.5);
            return (Style{}).with_fg(.{ .ansi256 = fixed[@min(step, fixed.len - 1)] }).with_bold();
        },
    }
}

fn draw_wordmark(out: *Screen, placement: MarkPlacement, elapsed_ms: i64, theme: *const Theme) void {
    const level = breath_level_at(elapsed_ms);
    if (level < hidden_level) return;

    var row: u16 = 0;
    while (row < placement.height) : (row += 1) {
        const y = placement.top +| row;
        if (y >= out.rows) return;
        var column: u16 = 0;
        while (column < placement.width) : (column += 1) {
            const cell = mark_cell(placement.scale, row, column);
            if (cell == ' ') continue;
            out.put(placement.left +| column, y, cell, breath_style(theme, level));
        }
    }
}

/// The welcome screen: the wordmark breathing, and what is happening. It stays
/// up while the first connection blocks, so it is built to be looked at while
/// still: the light is the only thing that moves, and a frozen frame of it is
/// still a lit wordmark.
/// Where the mark sits, for the one other place that has to know: the thread that
/// keeps it breathing while the first connection blocks. Same arithmetic, one source.
pub const MarkPlacement = struct {
    left: u16,
    top: u16,
    height: u16,
    width: u16,
    /// 1, 2 or 3: how many cells of the drawing each stroke is worth.
    scale: u8,
};

/// The largest scale the drawing is ever asked for.
pub const mark_max_scale: u16 = 4;

pub fn splash_mark(columns: u16, rows: u16) MarkPlacement {
    const scale: u8 = if (fits(mark_max_scale, columns, rows))
        4
    else if (fits(3, columns, rows))
        3
    else if (fits(2, columns, rows))
        2
    else
        1;
    const height: u16 = @intCast(wordmark.small.len * scale);
    const width: u16 = @intCast(wordmark.small[0].len * scale);
    const middle = rows / 2;
    return .{
        .left = (columns -| width) / 2,
        .top = middle -| (height / 2) -| 2,
        .height = height,
        .width = width,
        .scale = scale,
    };
}

/// Whether the drawing at `scale` fits with room to breathe: three columns of air
/// each side, and the sentence, the version and the footer under it.
fn fits(scale: u8, columns: u16, rows: u16) bool {
    const width: u16 = @intCast(wordmark.small[0].len * scale);
    const height: u16 = @intCast(wordmark.small.len * scale);
    return columns >= width + 6 and rows >= height + 8;
}

/// One cell of the mark, for the places that draw it themselves.
pub fn mark_cell(scale: u8, row: u16, column: u16) u21 {
    const source = wordmark.small[row / scale][column / scale];
    if (source == ' ') return ' ';
    if (source == spine_block) {
        if (scale == 1) return spine_block;
        const half: u16 = (@as(u16, scale) + 1) / 2;
        return if (column % scale < half) ' ' else solid_block;
    }
    return if (scale == 1) source else solid_block;
}

/// The two glyphs the drawing is made of: a full cell, and the left half of one.
const solid_block: u21 = 0x2588;
const spine_block: u21 = 0x2590;

/// The first screen: the wordmark breathing, the version, the account, and the two
/// corners of the last row. Everything here is a pure function of the clock since the
/// screen went up, so the loop and the painter thread can draw the same frame.
pub fn draw(
    out: *Screen,
    state: *const State,
    theme: *const Theme,
    elapsed_ms: i64,
    reduced_motion: bool,
) void {
    out.clear();
    const elapsed: i64 = if (reduced_motion) 0 else elapsed_ms;

    const placement = splash_mark(out.columns, out.rows);
    const mark_rows = placement.height;
    const mark_top = placement.top;
    draw_wordmark(out, placement, elapsed, theme);

    var version_buffer: [64]u8 = undefined;
    if (std.fmt.bufPrint(&version_buffer, "version: {s}", .{core.meta.version})) |text| {
        const width = screen.text_columns(text);
        const right_edge = placement.left +| placement.width;
        const x = right_edge -| width;
        _ = out.put_text(x, mark_top +| mark_rows +| 1, text, out.columns -| x, theme.border);
    } else |_| {}

    var label_buffer: [96]u8 = undefined;
    const labels = account_labels(state, &label_buffer);

    var line_buffer: [160]u8 = undefined;
    const status = splash_line(out.rows, labels, &line_buffer);

    const address_row = mark_top +| mark_rows +| 2;
    const footer_row = out.rows -| 1;
    if (state.accounts.len == 1 and address_row < footer_row) {
        var address_buffer: [core.limits.address_max]u8 = undefined;
        const address = state.accounts.items[0].address.addr_spec(&address_buffer);
        if (address.len > 0) {
            const width = screen.text_columns(address);
            const x = if (status.left +| width <= out.columns) status.left else (out.columns -| width) / 2;
            _ = out.put_text(x, address_row, address, out.columns -| x, theme.dim);
        }
    }

    var right_buffer: [32]u8 = undefined;
    const corner = splash_right(out.columns, out.rows, &right_buffer);
    _ = draw_shimmer(out, corner.left, corner.row, corner.text, elapsed, theme);

    const line_width = screen.text_columns(status.text);
    const before_right: u16 = corner.left -| 1;
    if (status.left +| line_width <= before_right) {
        _ = draw_shimmer(out, status.left, status.row, status.text, elapsed, theme);
    }
}

/// The shimmer: a band of light of one fixed width, travelling across a line of
/// text from the left and wrapping round, the way Pi marks work that is still
/// happening.
///
/// This is the one shape a "pulse" can take inside a terminal: the terminal's own
/// progress bar (`OSC 9;4`) is a fill from zero to a percentage of the width, so a
/// band that keeps its size and moves has to be drawn here. Fixed width, fixed
/// speed, and the band never grows -- what travels is the light, not the amount of
/// text it covers.
pub const shimmer_width: u16 = 6;
/// Cells per second. Pi uses ten on a line of prose; a splash is read from further
/// away, so this is quicker without being a blur.
pub const shimmer_speed: u16 = 18;

/// Draws `text` with the band at `elapsed_ms`. Returns the columns used.
pub fn draw_shimmer(
    out: *Screen,
    x: u16,
    y: u16,
    text: []const u8,
    elapsed_ms: i64,
    theme: *const Theme,
) u16 {
    if (y >= out.rows or x >= out.columns) return 0;
    const width: u16 = @intCast(@min(screen.text_columns(text), out.columns -| x));
    if (width == 0) return 0;

    var cells: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |codepoint| {
        if (cells >= width) break;
        const level = shimmer_level(@intCast(cells), width, elapsed_ms);
        out.put(x +| cells, y, codepoint, shimmer_style(theme, level));
        cells += screen.cell_width(codepoint);
    }
    return cells;
}

/// How lit the cell at `cell` is: three levels, because a terminal has no alpha and
/// the band needs an edge. One function, so the screen and the painter thread cannot
/// disagree about where the light is.
pub const shimmer_bright = 2;
pub const shimmer_soft = 1;
pub const shimmer_dim = 0;

pub fn shimmer_level(cell: u16, width: u16, elapsed_ms: i64) u8 {
    const span: i64 = @as(i64, width) + shimmer_width;
    const travelled: i64 = @divTrunc(elapsed_ms * @as(i64, shimmer_speed), 1000);
    const offset: i64 = @mod(travelled, span);
    const band_start = offset - @as(i64, shimmer_width);
    const band_end = offset;

    const here: i64 = cell;
    if (here >= band_start and here < band_end) return shimmer_bright;
    if ((here >= band_start - 1 and here < band_start) or (here >= band_end and here < band_end + 1)) {
        return shimmer_soft;
    }
    return shimmer_dim;
}

/// The right corner of the footer, and where it sits: `Ctrl+C quits`, against the edge.
pub fn splash_right(columns: u16, rows: u16, buffer: []u8) SplashLine {
    const text = copy_into("Ctrl+C quits", buffer);
    return .{
        .row = rows -| 1,
        .left = columns -| 2 -| screen.text_columns(text),
        .text = text,
    };
}

/// `text` in `buffer`, truncated to fit: the splash copies every sentence it shows,
/// because the caller's may be a temporary.
fn copy_into(text: []const u8, buffer: []u8) []const u8 {
    const length = @min(text.len, buffer.len);
    @memcpy(buffer[0..length], text[0..length]);
    return buffer[0..length];
}

pub fn shimmer_style(theme: *const Theme, level: u8) Style {
    return switch (level) {
        shimmer_bright => theme.accent.with_bold(),
        shimmer_soft => theme.text,
        else => theme.dim,
    };
}

/// The line under the mark, and where it sits: `connecting to <accounts>`.
pub const SplashLine = struct {
    row: u16,
    left: u16,
    text: []const u8,
};

pub fn splash_line(rows: u16, labels: []const u8, buffer: []u8) SplashLine {
    var line: [160]u8 = undefined;
    const full = std.fmt.bufPrint(&line, "connecting to {s}", .{labels}) catch labels;
    return .{
        .row = rows -| 1,
        .left = 1,
        .text = copy_into(full, buffer),
    };
}

pub fn account_labels(state: *const State, buffer: []u8) []const u8 {
    if (state.accounts.len == 0) return "mail";
    if (state.account_filter) |filter| {
        const label = state.accounts.label_for(filter);
        if (label.len > 0) return label;
    }

    var writer = std.Io.Writer.fixed(buffer);
    var index: u8 = 0;
    while (index < state.accounts.len) : (index += 1) {
        const account = state.accounts.at(index) orelse continue;
        if (index > 0) writer.writeAll(", ") catch break;
        writer.writeAll(account.label.slice()) catch break;
    }
    return writer.buffered();
}
