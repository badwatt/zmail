//! Color palettes.
//!
//! Default backgrounds, never a black box: amail inherits the terminal's own
//! background and only tints foregrounds, so it looks at home in light and dark
//! themes alike. `NO_COLOR` degrades to attributes only.

const std = @import("std");
const screen = @import("screen.zig");
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

    pub fn detect(no_color: bool) Theme {
        if (no_color) return mono();
        return dark();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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
    try testing.expect(!Theme.detect(true).colored);
    try testing.expect(Theme.detect(false).colored);
}
