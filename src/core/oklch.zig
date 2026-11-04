//! Perceptual colour, so a theme can be derived instead of configured.
//!
//! OKLab (Björn Ottosson, 2020) is a colour space where the distance between
//! two colours is close to how different they look. OKLCH is the same space in
//! polar form: lightness, chroma, hue. Working here means "a little lighter",
//! "less saturated", "the same hue" are arithmetic, and a palette built from a
//! terminal's background colour has a contrast you can reason about instead of
//! a table of hex codes someone has to maintain.
//!
//! No I/O, no allocation: 8-bit RGB in, 8-bit RGB out.

const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Oklch = struct {
    /// 0 is black, 1 is white.
    l: f32,
    /// 0 is grey; above ~0.37 the colour leaves the sRGB gamut at some hues.
    c: f32,
    /// Degrees, 0 at red, 90 at yellow-green, 180 at cyan, 270 at blue-violet.
    h: f32,
};

/// Below this, a background is dark and text on it has to be light.
pub const dark_threshold: f32 = 0.5;

/// sRGB transfer function, both ways. The piecewise curve is the standard's,
/// not an approximation: a theme that is off by a gamma step has the wrong
/// contrast at exactly the lightnesses that matter.
fn to_linear(channel: f32) f32 {
    if (channel <= 0.04045) return channel / 12.92;
    return std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
}

fn to_gamma(channel: f32) f32 {
    if (channel <= 0.0031308) return channel * 12.92;
    return 1.055 * std.math.pow(f32, channel, 1.0 / 2.4) - 0.055;
}

fn byteToUnit(byte: u8) f32 {
    return @as(f32, @floatFromInt(byte)) / 255.0;
}

fn unitToByte(unit: f32) u8 {
    const clamped = std.math.clamp(unit, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

/// The colour of an 8-bit sRGB triplet as the eye sees it.
pub fn from_rgb(rgb: Rgb) Oklch {
    const r = to_linear(byteToUnit(rgb.r));
    const g = to_linear(byteToUnit(rgb.g));
    const b = to_linear(byteToUnit(rgb.b));

    const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

    const l_ = std.math.cbrt(l);
    const m_ = std.math.cbrt(m);
    const s_ = std.math.cbrt(s);

    const lightness = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    const a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    const bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

    var hue = std.math.atan2(bb, a) * 180.0 / std.math.pi;
    if (hue < 0) hue += 360.0;

    return .{
        .l = std.math.clamp(lightness, 0.0, 1.0),
        .c = @sqrt(a * a + bb * bb),
        .h = hue,
    };
}

/// Linear sRGB for a lightness, chroma and hue, before any gamut work.
fn to_linear_rgb(colour: Oklch) [3]f32 {
    const radians = colour.h * std.math.pi / 180.0;
    const a = colour.c * @cos(radians);
    const b = colour.c * @sin(radians);

    const l_ = colour.l + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = colour.l - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = colour.l - 0.0894841775 * a - 1.2914855480 * b;

    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    return .{
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    };
}

fn in_gamut(rgb: [3]f32) bool {
    for (rgb) |channel| {
        if (channel < -0.0001 or channel > 1.0001) return false;
    }
    return true;
}

/// The closest sRGB colour: at high chroma the requested colour has no 8-bit
/// representation, so the chroma is pulled in until it does. Lightness and hue
/// survive, which is what keeps a generated theme's contrast predictable.
pub fn to_rgb(colour: Oklch) Rgb {
    var candidate = colour;
    if (!in_gamut(to_linear_rgb(candidate))) {
        var low: f32 = 0.0;
        var high: f32 = colour.c;
        var step: u8 = 0;
        while (step < 24) : (step += 1) {
            candidate.c = (low + high) / 2.0;
            if (in_gamut(to_linear_rgb(candidate))) {
                low = candidate.c;
            } else {
                high = candidate.c;
            }
        }
        candidate.c = low;
    }

    const linear = to_linear_rgb(candidate);
    return .{
        .r = unitToByte(to_gamma(linear[0])),
        .g = unitToByte(to_gamma(linear[1])),
        .b = unitToByte(to_gamma(linear[2])),
    };
}

/// The same colour at another lightness. The hue is kept, because a theme is
/// one family of colours at different depths.
pub fn with_lightness(colour: Oklch, lightness: f32) Oklch {
    var result = colour;
    result.l = std.math.clamp(lightness, 0.0, 1.0);
    return result;
}

/// The same colour with another chroma, for "quieter" and "louder" variants.
pub fn with_chroma(colour: Oklch, chroma: f32) Oklch {
    var result = colour;
    result.c = @max(0.0, chroma);
    return result;
}

/// WCAG relative luminance of the encoded colour, 0..1. Used to decide which
/// way round a generated theme goes and to keep text readable on it.
pub fn luminance(rgb: Rgb) f32 {
    const r = to_linear(byteToUnit(rgb.r));
    const g = to_linear(byteToUnit(rgb.g));
    const b = to_linear(byteToUnit(rgb.b));
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG contrast ratio between two colours, 1..21. 4.5 is the usual target for
/// body text; this is here so a generated theme can be checked, not guessed.
pub fn contrast(a: Rgb, b: Rgb) f32 {
    const first = luminance(a);
    const second = luminance(b);
    const lighter = @max(first, second);
    const darker = @min(first, second);
    return (lighter + 0.05) / (darker + 0.05);
}

const testing = std.testing;

fn expectNear(expected: f32, actual: f32, tolerance: f32) !void {
    try testing.expect(@abs(expected - actual) <= tolerance);
}

test "oklch: the corners of sRGB land where the space says they do" {
    const white = from_rgb(.{ .r = 255, .g = 255, .b = 255 });
    try expectNear(1.0, white.l, 0.01);
    try expectNear(0.0, white.c, 0.005);

    const black = from_rgb(.{ .r = 0, .g = 0, .b = 0 });
    try expectNear(0.0, black.l, 0.01);

    const red = from_rgb(.{ .r = 255, .g = 0, .b = 0 });
    try expectNear(0.628, red.l, 0.01);
    try expectNear(0.258, red.c, 0.01);
    try expectNear(29.2, red.h, 1.0);

    const grey = from_rgb(.{ .r = 128, .g = 128, .b = 128 });
    try expectNear(0.0, grey.c, 0.005);
}

test "oklch: a round trip through the space returns the same 8-bit colour" {
    const samples = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 156, .g = 162, .b = 200 },
        .{ .r = 74, .g = 120, .b = 180 },
        .{ .r = 200, .g = 30, .b = 30 },
        .{ .r = 25, .g = 25, .b = 37 },
    };
    for (samples) |sample| {
        const back = to_rgb(from_rgb(sample));
        try testing.expect(@abs(@as(i32, back.r) - @as(i32, sample.r)) <= 1);
        try testing.expect(@abs(@as(i32, back.g) - @as(i32, sample.g)) <= 1);
        try testing.expect(@abs(@as(i32, back.b) - @as(i32, sample.b)) <= 1);
    }
}

test "oklch: a colour outside the gamut comes back as the nearest one inside" {
    const impossible = Oklch{ .l = 0.7, .c = 0.4, .h = 300 };
    const rgb = to_rgb(impossible);
    try expectNear(0.7, from_rgb(rgb).l, 0.02);

    const fitted = from_rgb(rgb);
    try testing.expect(fitted.c < impossible.c);
    try testing.expect(fitted.c > 0.0);
    try expectNear(300, fitted.h, 8.0);
}

test "oklch: lightness and chroma can be moved without touching the hue" {
    const base = from_rgb(.{ .r = 90, .g = 110, .b = 200 });
    const lighter = with_lightness(base, 0.9);
    try expectNear(0.9, lighter.l, 0.001);
    try expectNear(base.h, lighter.h, 0.001);

    const quieter = with_chroma(base, 0.01);
    try expectNear(0.01, quieter.c, 0.001);

    try expectNear(1.0, with_lightness(base, 4.0).l, 0.001);
    try expectNear(0.0, with_lightness(base, -4.0).l, 0.001);
}

test "contrast: the WCAG ratios a generated theme must clear" {
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    const black = Rgb{ .r = 0, .g = 0, .b = 0 };
    try expectNear(21.0, contrast(white, black), 0.1);
    try expectNear(1.0, contrast(white, white), 0.001);

    const periwinkle = Rgb{ .r = 156, .g = 162, .b = 200 };
    const ground = Rgb{ .r = 25, .g = 25, .b = 37 };
    try testing.expect(contrast(periwinkle, ground) > 4.5);
}
