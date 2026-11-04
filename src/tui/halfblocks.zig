//! Drawing a picture in a terminal that knows no graphics protocol.
//!
//! yazi's trick: one character cell is two pixels, because the upper half block
//! "▀" paints its top half with the foreground colour and its bottom half with
//! the background. With 24-bit colour that is a real picture, in any terminal
//! that can do colour at all — no kitty, no sixel, no external program.

const std = @import("std");
const assert = std.debug.assert;
const png = @import("core").png;
const system_mod = @import("system.zig");
const System = system_mod.System;

pub const half_block = "\u{2580}";
/// The bottom half: what is left when only the lower pixel of a cell has colour.
pub const lower_half_block = "\u{2584}";
/// A cell, or half of one, with nothing in it. Anything this transparent is the
/// page behind it, and the terminal already knows what colour that is.
pub const transparent: u32 = 0xFFFF_FFFE;

/// Paints `image` with its top-left corner at (x, y), `columns` by `rows` cells.
/// The picture is sampled, not scaled with a filter: a mail logo is a few dozen
/// pixels wide on screen, and nearest-neighbour keeps text crisp.
pub fn draw(
    system: System,
    image: png.Image,
    x: u16,
    y: u16,
    columns: u16,
    rows: u16,
) bool {
    if (image.width == 0 or image.height == 0 or columns == 0 or rows == 0) return false;

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var position: [32]u8 = undefined;
        const at = std.fmt.bufPrint(&position, "\x1b[{d};{d}H", .{
            y + row + 1,
            x + 1,
        }) catch return false;
        system.write(at) catch return false;

        var last_top: u32 = 0xFFFFFFFF;
        var last_bottom: u32 = 0xFFFFFFFF;

        var column: u16 = 0;
        while (column < columns) : (column += 1) {
            const top = sample(image, column, row * 2, columns, rows);
            const bottom = sample(image, column, row * 2 + 1, columns, rows);
            const glyph: []const u8 = if (top == transparent and bottom == transparent)
                " "
            else if (top == transparent)
                lower_half_block
            else
                half_block;

            // Two colours per cell: the terminal is told only when they change,
            // which is what keeps a picture from being thousands of escapes. A half
            // with nothing in it says "default", which is the terminal's own colour
            // -- that is what makes a logo with a transparent background sit on the
            // reader instead of on a white card.
            if (top != last_top or bottom != last_bottom) {
                // A half with nothing in it says "default", which is the terminal's
                // own colour. Writing the sentinel's bits instead is how a transparent
                // background became a white card: 0xFFFFFFFE is nearly white.
                var escape: [64]u8 = undefined;
                var writer = std.Io.Writer.fixed(&escape);
                if (top == transparent) {
                    writer.writeAll("\x1b[39m") catch return false;
                } else {
                    writer.print("\x1b[38;2;{d};{d};{d}m", .{ red(top), green(top), blue(top) }) catch return false;
                }
                if (bottom == transparent) {
                    writer.writeAll("\x1b[49m") catch return false;
                } else {
                    writer.print("\x1b[48;2;{d};{d};{d}m", .{ red(bottom), green(bottom), blue(bottom) }) catch return false;
                }
                system.write(writer.buffered()) catch return false;
                last_top = top;
                last_bottom = bottom;
            }
            system.write(glyph) catch return false;
        }
        system.write("\x1b[0m") catch return false;
    }
    return true;
}

/// The colour a cell stands for: the average of the pixels it covers, flattened
/// over white. Averaging is what keeps a picture from turning into a staircase
/// when it is far bigger than the cells it has to fit in.
fn sample(image: png.Image, column: u16, pixel_row: u16, columns: u16, rows: u16) u32 {
    // Wide arithmetic: a cell count times a pixel count is bigger than a u32 once either
    // side is large, and the picture is untrusted bytes either way.
    const target_rows: u64 = @max(1, @as(u64, rows) * 2);
    const from_x = (@as(u64, column) * image.width) / @max(1, columns);
    const to_x = @max(from_x + 1, ((@as(u64, column) + 1) * image.width) / @max(1, columns));
    const from_y = (@as(u64, pixel_row) * image.height) / target_rows;
    const to_y = @max(from_y + 1, ((@as(u64, pixel_row) + 1) * image.height) / target_rows);

    var red_total: u32 = 0;
    var green_total: u32 = 0;
    var blue_total: u32 = 0;
    var alpha_total: u32 = 0;
    var count: u32 = 0;

    var y = @min(from_y, image.height - 1);
    while (y < @min(to_y, image.height)) : (y += 1) {
        var x = @min(from_x, image.width - 1);
        while (x < @min(to_x, image.width)) : (x += 1) {
            const index = (@as(usize, y) * image.width + x) * 4;
            // No blending: a picture sits on whatever colour the reader is, and
            // flattening over white is what put a white card behind every logo.
            alpha_total += image.rgba[index + 3];
            red_total += image.rgba[index];
            green_total += image.rgba[index + 1];
            blue_total += image.rgba[index + 2];
            count += 1;
        }
    }
    if (count == 0) return transparent;
    if (alpha_total / count < 16) return transparent;
    return ((red_total / count) << 16) | ((green_total / count) << 8) | (blue_total / count);
}

fn red(colour: u32) u32 {
    return (colour >> 16) & 0xff;
}

fn green(colour: u32) u32 {
    return (colour >> 8) & 0xff;
}

fn blue(colour: u32) u32 {
    return colour & 0xff;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn two_by_two() png.Image {
    const rgba = [_]u8{
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 0, 255, 255, // blue
        255, 255, 255, 255, // white
    };
    return .{ .width = 2, .height = 2, .rgba = &rgba };
}

test "a picture is drawn with two pixels per cell" {
    var fake: system_mod.Fake = .{};
    const drawn = draw(fake.system(), two_by_two(), 0, 0, 2, 1);
    const written = fake.output_text();
    try testing.expect(drawn);
    // The four pixels become two cells on one row, with their colours.
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[1;1H") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[38;2;255;0;0m\x1b[48;2;0;0;255m") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[38;2;0;255;0m\x1b[48;2;255;255;255m") != null);
    try testing.expect(std.mem.count(u8, written, half_block) == 2);
    try testing.expect(std.mem.endsWith(u8, written, "\x1b[0m"));
}

test "the same colour twice is not sent twice" {
    const rgba = [16]u8{ 9, 9, 9, 255, 9, 9, 9, 255, 9, 9, 9, 255, 9, 9, 9, 255 };
    const image = png.Image{ .width = 2, .height = 2, .rgba = &rgba };

    var fake: system_mod.Fake = .{};
    const drawn = draw(fake.system(), image, 0, 0, 2, 1);
    const written = fake.output_text();
    try testing.expect(drawn);
    // One colour pair for the whole row.
    try testing.expect(std.mem.count(u8, written, "\x1b[38;2;") == 1);
}

test "a picture with nothing in its background shows the reader through it" {
    // Left column: fully transparent. Right column: opaque red.
    const rgba = [_]u8{
        0, 0, 0, 0, 255, 0, 0, 255,
        0, 0, 0, 0, 255, 0, 0, 255,
    };
    const image = png.Image{ .width = 2, .height = 2, .rgba = &rgba };

    var fake: system_mod.Fake = .{};
    try testing.expect(draw(fake.system(), image, 0, 0, 2, 1));
    const written = fake.output_text();
    // The first cell is a space with the terminal's own colours, not a white one:
    // the transparent sentinel is nearly white, and writing its bits made a card.
    try testing.expect(std.mem.indexOf(u8, written, " ") != null);
    try testing.expect(std.mem.startsWith(u8, written, "\x1b[1;1H\x1b[39m\x1b[49m "));
    // The second is the picture, and nothing was blended towards white.
    try testing.expect(std.mem.indexOf(u8, written, "38;2;255;0;0") != null);
    try testing.expect(std.mem.indexOf(u8, written, "38;2;255;255;255") == null);
}

test "a cell with only its lower half painted uses the lower block" {
    const rgba = [_]u8{ 0, 0, 0, 0, 9, 9, 9, 255 };
    const image = png.Image{ .width = 1, .height = 2, .rgba = &rgba };

    var fake: system_mod.Fake = .{};
    try testing.expect(draw(fake.system(), image, 0, 0, 1, 1));
    try testing.expect(std.mem.indexOf(u8, fake.output_text(), lower_half_block) != null);
}

test "nothing to draw is not drawn" {
    var fake: system_mod.Fake = .{};
    var empty = two_by_two();
    empty.width = 0;
    try testing.expect(!draw(fake.system(), empty, 0, 0, 4, 4));
    try testing.expect(!draw(fake.system(), two_by_two(), 0, 0, 0, 4));
    try testing.expectEqualStrings("", fake.output_text());
}
