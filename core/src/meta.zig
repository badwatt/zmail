//! Application metadata, read from `build.zig.zon`.
//!
//! There is exactly one place where the product name and version live: the
//! package manifest. Build scripts, the TUI header, `--version`, and the docs
//! generator all read them from here.

const std = @import("std");
const zon = @import("app_meta");

/// Product name, taken from `build.zig.zon` (e.g. "amail").
pub const name: []const u8 = @tagName(zon.name);

/// Product version, taken from `build.zig.zon` (e.g. "0.1.0").
pub const version: []const u8 = zon.version;

test "name is non-empty and contains no whitespace" {
    try std.testing.expect(name.len > 0);
    for (name) |byte| {
        try std.testing.expect(!std.ascii.isWhitespace(byte));
    }
}

test "version parses as semantic versioning" {
    const parsed = try std.SemanticVersion.parse(version);
    try std.testing.expect(parsed.major >= 0);
    try std.testing.expect(parsed.minor >= 0);
    try std.testing.expect(parsed.patch >= 0);
}
