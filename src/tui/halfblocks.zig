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
/// Both halves the same colour: one cell, one escape, no texture that is not there.
pub const full_block = "\u{2588}";
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
    /// What the terminal paints behind the text. A picture that is half transparent is
    /// half that colour: compositing it over white is what put a card behind a logo.
    ground: u32,
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
        var last_solid: bool = false;

        var column: u16 = 0;
        while (column < columns) : (column += 1) {
            const top = sample(image, column, row * 2, columns, rows, ground);
            const bottom = sample(image, column, row * 2 + 1, columns, rows, ground);
            const solid = top == bottom and top != transparent;
            const glyph: []const u8 = if (top == transparent and bottom == transparent)
                " "
            else if (top == transparent)
                lower_half_block
            else if (solid)
                full_block
            else
                half_block;

            if (top != last_top or bottom != last_bottom or solid != last_solid) {
                var escape: [64]u8 = undefined;
                var writer = std.Io.Writer.fixed(&escape);
                if (top == transparent) {
                    writer.writeAll("\x1b[39m") catch return false;
                } else {
                    writer.print("\x1b[38;2;{d};{d};{d}m", .{ red(top), green(top), blue(top) }) catch return false;
                }
                if (bottom == transparent or solid) {
                    writer.writeAll("\x1b[49m") catch return false;
                } else {
                    writer.print("\x1b[48;2;{d};{d};{d}m", .{ red(bottom), green(bottom), blue(bottom) }) catch return false;
                }
                system.write(writer.buffered()) catch return false;
                last_top = top;
                last_bottom = bottom;
                last_solid = solid;
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
fn sample(image: png.Image, column: u16, pixel_row: u16, columns: u16, rows: u16, ground: u32) u32 {
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
            const alpha: u32 = image.rgba[index + 3];
            const over_red: u32 = (@as(u32, image.rgba[index]) * alpha + red(ground) * (255 - alpha)) / 255;
            const over_green: u32 = (@as(u32, image.rgba[index + 1]) * alpha + green(ground) * (255 - alpha)) / 255;
            const over_blue: u32 = (@as(u32, image.rgba[index + 2]) * alpha + blue(ground) * (255 - alpha)) / 255;
            alpha_total += alpha;
            red_total += over_red;
            green_total += over_green;
            blue_total += over_blue;
            count += 1;
        }
    }
    if (count == 0) return transparent;
    if (alpha_total / count < 40) return transparent;
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

const testing = std.testing;

fn two_by_two() png.Image {
    const rgba = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    return .{ .width = 2, .height = 2, .rgba = &rgba };
}

test "a picture is drawn with two pixels per cell" {
    var fake: system_mod.Fake = .{};
    const drawn = draw(fake.system(), two_by_two(), 0, 0, 2, 1, 0x101018);
    const written = fake.output_text();
    try testing.expect(drawn);
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
    const drawn = draw(fake.system(), image, 0, 0, 2, 1, 0x101018);
    const written = fake.output_text();
    try testing.expect(drawn);
    try testing.expect(std.mem.count(u8, written, "\x1b[38;2;") == 1);
}

test "a picture with nothing in its background shows the reader through it" {
    const rgba = [_]u8{
        0, 0, 0, 0, 255, 0, 0, 255,
        0, 0, 0, 0, 255, 0, 0, 255,
    };
    const image = png.Image{ .width = 2, .height = 2, .rgba = &rgba };

    var fake: system_mod.Fake = .{};
    try testing.expect(draw(fake.system(), image, 0, 0, 2, 1, 0x101018));
    const written = fake.output_text();
    try testing.expect(std.mem.indexOf(u8, written, " ") != null);
    try testing.expect(std.mem.startsWith(u8, written, "\x1b[1;1H\x1b[39m\x1b[49m "));
    try testing.expect(std.mem.indexOf(u8, written, "38;2;255;0;0") != null);
    try testing.expect(std.mem.indexOf(u8, written, "38;2;255;255;255") == null);
}

test "a cell with only its lower half painted uses the lower block" {
    const rgba = [_]u8{ 0, 0, 0, 0, 9, 9, 9, 255 };
    const image = png.Image{ .width = 1, .height = 2, .rgba = &rgba };

    var fake: system_mod.Fake = .{};
    try testing.expect(draw(fake.system(), image, 0, 0, 1, 1, 0x101018));
    try testing.expect(std.mem.indexOf(u8, fake.output_text(), lower_half_block) != null);
}

test "nothing to draw is not drawn" {
    var fake: system_mod.Fake = .{};
    var empty = two_by_two();
    empty.width = 0;
    try testing.expect(!draw(fake.system(), empty, 0, 0, 4, 4, 0x101018));
    try testing.expect(!draw(fake.system(), two_by_two(), 0, 0, 0, 4, 0x101018));
    try testing.expectEqualStrings("", fake.output_text());
}

test "a cell that is one colour is drawn as one block" {
    const rgba = [_]u8{
        9, 9, 9, 255, 9, 9, 9, 255,
        9, 9, 9, 255, 9, 9, 9, 255,
    };
    const image = png.Image{ .width = 2, .height = 2, .rgba = &rgba };

    var fake: system_mod.Fake = .{};
    try testing.expect(draw(fake.system(), image, 0, 0, 2, 1, 0x101018));
    const written = fake.output_text();
    try testing.expect(std.mem.indexOf(u8, written, full_block) != null);
    try testing.expect(std.mem.indexOf(u8, written, half_block) == null);
}

test "a half transparent picture is composited over the reader, not over a card" {
    const rgba = [_]u8{
        255, 255, 255, 128,
        255, 255, 255, 128,
    };
    const image = png.Image{ .width = 1, .height = 2, .rgba = &rgba };

    var fake: system_mod.Fake = .{};
    try testing.expect(draw(fake.system(), image, 0, 0, 1, 1, 0x000000));
    const written = fake.output_text();
    try testing.expect(std.mem.indexOf(u8, written, "38;2;128;128;128") != null);

    var other: system_mod.Fake = .{};
    try testing.expect(draw(other.system(), image, 0, 0, 1, 1, 0xFFFFFF));
    try testing.expect(std.mem.indexOf(u8, other.output_text(), "38;2;255;255;255") != null);
}
