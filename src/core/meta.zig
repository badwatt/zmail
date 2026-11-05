//! Application metadata, read from `build.zig.zon`.
//!
//! There is exactly one place where the product name and version live: the
//! package manifest. Build scripts, the TUI header, `--version`, and the docs
//! generator all read them from here.

const std = @import("std");
const testing = std.testing;
const zon = @import("app_meta");

/// Product name, taken from `build.zig.zon`.
pub const name: []const u8 = @tagName(zon.name);

/// Product version, taken from `build.zig.zon` (e.g. "0.1.0").
pub const version: []const u8 = zon.version;

/// The Zig version the manifest asks for. Docs and CI quote this, so the number
/// still lives in exactly one place.
pub const minimum_zig_version: []const u8 = zon.minimum_zig_version;

/// A file format tag: the product name and a format number. Reading an old file
/// is refused rather than misread, so a rename invalidates caches on purpose.
pub const cache_header = name ++ "-cache 2";

test "name is non-empty and contains no whitespace" {
    try std.testing.expect(name.len > 0);
    for (name) |byte| {
        try std.testing.expect(!std.ascii.isWhitespace(byte));
    }
}

test "the manifest's minimum Zig version is valid, and this build meets it" {
    const builtin = @import("builtin");
    const required = try std.SemanticVersion.parse(minimum_zig_version);
    try testing.expect(minimum_zig_version.len > 0);
    // The same rule build.zig enforces before compiling anything.
    try testing.expect(builtin.zig_version.order(required) != .lt);
}

test "version parses as semantic versioning" {
    const parsed = try std.SemanticVersion.parse(version);
    try std.testing.expect(parsed.major >= 0);
    try std.testing.expect(parsed.minor >= 0);
    try std.testing.expect(parsed.patch >= 0);
}
