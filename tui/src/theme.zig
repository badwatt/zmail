//! Color palettes.
//!
//! Default backgrounds, never a black box: zmail inherits the terminal's own
//! background and only tints foregrounds, so it looks at home in light and dark
//! themes alike. `NO_COLOR` degrades to attributes only.

const std = @import("std");
const screen = @import("screen.zig");
const core = @import("core");
const oklch = core.oklch;
const Style = screen.Style;

pub const Theme = struct {
    accent: Style = .{},
    text: Style = .{},
    dim: Style = .{},
    selection: Style = .{},
    border: Style = .{},
    flagged: Style = .{},
    alert: Style = .{},
    /// One hue per account, so the unified list says who a row belongs to at a
    /// glance even before reading the label.
    account_colors: [4]screen.Color = @splat(screen.Color.default),
    colored: bool = false,

    /// Muted blue accent, warm amber for stars, dim gray for metadata.
    pub fn dark() Theme {
        const accent = (Style{}).with_fg(.{ .ansi256 = 74 });
        return .{
            .accent = accent,
            .text = .{},
            .dim = (Style{}).with_fg(.{ .ansi256 = 245 }),
            .selection = (Style{}).with_bg(.{ .ansi256 = 237 }).with_bold(),
            .border = (Style{}).with_fg(.{ .ansi256 = 238 }),
            .flagged = (Style{}).with_fg(.{ .ansi256 = 179 }),
            .alert = (Style{}).with_fg(.{ .ansi256 = 167 }),
            .account_colors = .{
                .{ .ansi256 = 74 },
                .{ .ansi256 = 180 },
                .{ .ansi256 = 141 },
                .{ .ansi256 = 108 },
            },
            .colored = true,
        };
    }

    /// No color: hierarchy comes from bold, dim, and reverse video.
    pub fn mono() Theme {
        return .{
            .accent = (Style{}).with_bold(),
            .text = .{},
            .dim = (Style{}).with_dim(),
            .selection = (Style{}).with_reverse(),
            .border = .{},
            .flagged = (Style{}).with_bold(),
            .alert = (Style{}).with_bold().with_underline(),
            .account_colors = @splat(screen.Color.default),
            .colored = false,
        };
    }

    pub fn detect(no_color: bool, background: ?oklch.Rgb) Theme {
        if (no_color) return mono();
        // The terminal told us what it paints on: derive everything from that
        // instead of asking a human to pick a palette that matches it.
        if (background) |ground| return from_background(ground);
        return dark();
    }

    /// A palette computed from the colour the terminal paints behind the text.
    ///
    /// Lightness decides the direction; the rest is one hue family at depths a
    /// step apart, in OKLCH, so "quieter" and "one shade lighter" are arithmetic
    /// and the contrast of the result is a number rather than a hope. Hue carries
    /// meaning: the accent is a muted periwinkle, alerts lean red-orange, stars
    /// amber, and the four account hues are spaced a quarter turn apart from the
    /// accent so a label is a hue and never a shade.
    pub fn from_background(background: oklch.Rgb) Theme {
        const ground = oklch.from_rgb(background);
        const on_dark = ground.l < oklch.dark_threshold;

        const accent_hue: f32 = 285;
        const accent = tinted(accent_hue, 0.06, if (on_dark) 0.80 else 0.45);
        const dim = tinted(accent_hue, 0.02, if (on_dark) 0.64 else 0.52);
        const border = tinted(accent_hue, 0.015, if (on_dark) ground.l + 0.16 else ground.l - 0.16);

        return .{
            .accent = style_of(accent),
            .text = .{},
            .dim = style_of(dim),
            .selection = (Style{}).with_bg(rgb_color(tinted(accent_hue, 0.02, if (on_dark) ground.l + 0.10 else ground.l - 0.10))).with_bold(),
            .border = style_of(border),
            .flagged = style_of(tinted(80, 0.10, if (on_dark) 0.84 else 0.52)),
            .alert = style_of(tinted(25, 0.15, if (on_dark) 0.72 else 0.48)),
            .account_colors = .{
                rgb_color(accent),
                rgb_color(tinted(accent_hue + 120, 0.055, if (on_dark) 0.82 else 0.47)),
                rgb_color(tinted(accent_hue + 240, 0.055, if (on_dark) 0.78 else 0.44)),
                rgb_color(tinted(accent_hue + 60, 0.05, if (on_dark) 0.80 else 0.46)),
            },
            .colored = true,
        };
    }
};

/// One colour of the generated family: a hue, a chroma and a lightness, kept
/// inside the sRGB gamut by `oklch.to_rgb`.
fn tinted(hue: f32, chroma: f32, lightness: f32) oklch.Oklch {
    return .{
        .l = std.math.clamp(lightness, 0.0, 1.0),
        .c = chroma,
        .h = @mod(hue, 360.0),
    };
}

fn style_of(colour: oklch.Oklch) Style {
    return (Style{}).with_fg(rgb_color(colour));
}

fn rgb_color(colour: oklch.Oklch) screen.Color {
    const value = oklch.to_rgb(colour);
    return .{ .rgb = .{ .r = value.r, .g = value.g, .b = value.b } };
}

/// The 8-bit colour behind a style, or null when it is the terminal's own.
fn rgb_of(colour: screen.Color) ?oklch.Rgb {
    return switch (colour) {
        .rgb => |c| .{ .r = c.r, .g = c.g, .b = c.b },
        else => null,
    };
}

/// The colour behind a style, or null when it is the terminal's own.
fn background_of(theme: Theme) ?oklch.Rgb {
    return rgb_of(theme.selection.bg);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a generated theme goes light on a dark terminal and dark on a light one" {
    const on_dark = Theme.from_background(.{ .r = 25, .g = 25, .b = 37 });
    const on_light = Theme.from_background(.{ .r = 250, .g = 250, .b = 250 });

    const accent_dark = oklch.from_rgb(rgb_of(on_dark.accent.fg).?).l;
    const accent_light = oklch.from_rgb(rgb_of(on_light.accent.fg).?).l;
    try testing.expect(accent_dark > 0.6);
    try testing.expect(accent_light < 0.6);

    // The text colour is the terminal's own: it is already tuned to its ground.
    try testing.expect(on_dark.text.eql(.{}));
    try testing.expect(on_dark.colored);
}

test "generated colors are readable on the ground they were made for" {
    const grounds = [_]oklch.Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 25, .g = 25, .b = 37 },
        .{ .r = 40, .g = 44, .b = 52 },
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 248, .g = 246, .b = 240 },
        .{ .r = 230, .g = 230, .b = 235 },
    };
    for (grounds) |ground| {
        const theme = Theme.from_background(ground);
        const accent = rgb_of(theme.accent.fg).?;
        const ratio = oklch.contrast(accent, ground);
        try testing.expect(ratio >= 4.5);

        // Metadata may be quieter, but not invisible.
        try testing.expect(oklch.contrast(rgb_of(theme.dim.fg).?, ground) >= 3.0);
        // The selection is a ground of its own: the terminal's text must still
        // read on it, so it stays near the background, not at the far end.
        const selection_ground = background_of(theme).?;
        try testing.expect(oklch.contrast(selection_ground, ground) < 3.0);
    }
}

test "the generated hues carry meaning: alert, star, and four accounts" {
    const theme = Theme.from_background(.{ .r = 25, .g = 25, .b = 37 });

    const alert_hue = oklch.from_rgb(rgb_of(theme.alert.fg).?).h;
    const flagged_hue = oklch.from_rgb(rgb_of(theme.flagged.fg).?).h;
    const accent_hue = oklch.from_rgb(rgb_of(theme.accent.fg).?).h;
    try testing.expect(@abs(alert_hue - 25) < 12);
    try testing.expect(@abs(flagged_hue - 80) < 12);
    try testing.expect(@abs(accent_hue - 285) < 12);

    // Four account colours, four different hues, all at the accent's lightness.
    var seen: [4]f32 = undefined;
    const accent_lightness = oklch.from_rgb(rgb_of(theme.accent.fg).?).l;
    for (theme.account_colors, 0..) |colour, index| {
        seen[index] = oklch.from_rgb(rgb_of(colour).?).h;
        try testing.expect(@abs(oklch.from_rgb(rgb_of(colour).?).l - accent_lightness) < 0.15);
    }
    try testing.expect(@abs(seen[0] - seen[1]) > 45);
}

test "detect prefers no-color, then the terminal's ground, then the built-in dark" {
    const ground = oklch.Rgb{ .r = 25, .g = 25, .b = 37 };
    try testing.expect(Theme.detect(true, ground).colored == false);
    try testing.expect(std.meta.eql(
        rgb_of(Theme.detect(false, ground).accent.fg).?,
        rgb_of(Theme.from_background(ground).accent.fg).?,
    ));
    try testing.expect(Theme.detect(false, null).accent.eql(Theme.dark().accent));
}

test "dark uses colors and inherits the background" {
    const theme = Theme.dark();
    try testing.expect(theme.colored);
    try testing.expect(theme.text.eql(.{}));
    try testing.expectEqual(screen.Color{ .ansi256 = 237 }, theme.selection.bg);
    try testing.expect(theme.selection.attrs.bold);
}

test "mono uses attributes instead of colors" {
    const theme = Theme.mono();
    try testing.expect(!theme.colored);
    try testing.expectEqual(screen.Color.default, theme.accent.fg);
    try testing.expect(theme.accent.attrs.bold);
    try testing.expect(theme.dim.attrs.dim);
    try testing.expect(theme.selection.attrs.reverse);
    try testing.expect(theme.alert.attrs.underline);
}

test "detect maps NO_COLOR onto the mono theme" {
    try testing.expect(!Theme.detect(true, null).colored);
    try testing.expect(Theme.detect(false, null).colored);
}
