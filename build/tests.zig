//! Tests for the build-time coverage gate. The gate itself must be tested, or a
//! bug in it would let a regression through silently.

const std = @import("std");
const coverage = @import("coverage.zig");

const testing = std.testing;

fn parse(input: []const u8) !coverage.Report {
    return coverage.parse_report(testing.allocator, input);
}

test "parse_report reads kcov's merged report, where counts are strings" {
    const json =
        \\{
        \\  "files": [
        \\    {"file": "/src/a.zig", "percent_covered": "100.00",
        \\     "covered_lines": "120", "total_lines": "120"},
        \\    {"file": "/src/b.zig", "percent_covered": "50.00",
        \\     "covered_lines": "5", "total_lines": "10"}
        \\  ],
        \\  "percent_covered": "96.15"
        \\}
    ;
    var report = try parse(json);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.files.len);
    try testing.expectEqualStrings("/src/a.zig", report.files[0].path);
    try testing.expectEqual(@as(u64, 120), report.files[0].covered);
    try testing.expectEqual(@as(u64, 125), report.covered);
    try testing.expectEqual(@as(u64, 130), report.total);
    try testing.expectEqual(@as(u32, 1), report.incomplete_count());
    try testing.expect(!report.is_complete());
}

test "parse_report accepts numeric counts, as in a single-run report" {
    const json =
        \\{"files": [{"file": "src/a.zig", "covered_lines": 7, "total_lines": 7}]}
    ;
    var report = try parse(json);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 7), report.files[0].covered);
    try testing.expect(report.is_complete());
}

test "parse_report: a report with no files is not complete" {
    var report = try parse("{\"files\": []}");
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), report.files.len);
    try testing.expect(!report.is_complete());
    try testing.expectEqual(@as(u32, 0), report.percent_basis_points());
}

test "parse_report rejects malformed JSON" {
    try testing.expectError(error.SyntaxError, parse("{not json"));
}

test "parse_report rejects a non-object root" {
    try testing.expectError(error.MalformedReport, parse("[]"));
}

test "parse_report rejects a missing files key" {
    try testing.expectError(error.MalformedReport, parse("{}"));
}

test "parse_report rejects a non-array files value" {
    try testing.expectError(error.MalformedReport, parse("{\"files\": 3}"));
}

test "parse_report rejects a non-object file entry" {
    try testing.expectError(error.MalformedReport, parse("{\"files\": [3]}"));
}

test "parse_report rejects a missing path" {
    try testing.expectError(
        error.MalformedReport,
        parse("{\"files\": [{\"covered_lines\": 1, \"total_lines\": 1}]}"),
    );
}

test "parse_report rejects a non-string path" {
    try testing.expectError(
        error.MalformedReport,
        parse("{\"files\": [{\"file\": 1, \"covered_lines\": 1, \"total_lines\": 1}]}"),
    );
}

test "parse_report rejects missing counts" {
    try testing.expectError(
        error.MalformedReport,
        parse("{\"files\": [{\"file\": \"a\", \"covered_lines\": 1}]}"),
    );
}

test "parse_report rejects a non-numeric count" {
    try testing.expectError(
        error.MalformedReport,
        parse("{\"files\": [{\"file\": \"a\", \"covered_lines\": true, \"total_lines\": 1}]}"),
    );
}

test "parse_report rejects a negative count" {
    try testing.expectError(
        error.MalformedReport,
        parse("{\"files\": [{\"file\": \"a\", \"covered_lines\": -1, \"total_lines\": 1}]}"),
    );
}

test "parse_report rejects a non-numeric string count" {
    try testing.expectError(
        error.MalformedReport,
        parse("{\"files\": [{\"file\": \"a\", \"covered_lines\": \"x\", \"total_lines\": \"1\"}]}"),
    );
}

test "parse_report rejects covered greater than total" {
    try testing.expectError(
        error.MalformedReport,
        parse("{\"files\": [{\"file\": \"a\", \"covered_lines\": 2, \"total_lines\": 1}]}"),
    );
}

test "percent_basis_points is exact at the edges" {
    var report = try parse(
        \\{"files": [{"file": "a", "covered_lines": 1, "total_lines": 3}]}
    );
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3333), report.percent_basis_points());
}

test "print_report writes one line per file plus a summary" {
    var report = try parse(
        \\{"files": [
        \\  {"file": "core/src/a.zig", "covered_lines": 10, "total_lines": 10},
        \\  {"file": "tui/src/b.zig", "covered_lines": 9, "total_lines": 10}
        \\]}
    );
    defer report.deinit(testing.allocator);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try coverage.print_report(&report, &writer);

    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "ok    core/src/a.zig (10 lines)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "GAP   tui/src/b.zig (9/10 lines)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "coverage: 95.00% (19/20 lines), 1 file(s) with gaps") != null);
}

test "print_report reports a perfect score" {
    var report = try parse(
        \\{"files": [{"file": "a", "covered_lines": 20, "total_lines": 20}]}
    );
    defer report.deinit(testing.allocator);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try coverage.print_report(&report, &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "coverage: 100.00% (20/20 lines)") != null);
}

test "a complete report passes, and a report with gaps does not" {
    try testing.expectEqual(@as(u8, 0), coverage.check(testing.allocator,
        \\{"files": [{"file": "core/src/a.zig", "covered_lines": "10", "total_lines": "10"}]}
    ));
    try testing.expectEqual(@as(u8, 1), coverage.check(testing.allocator,
        \\{"files": [{"file": "core/src/a.zig", "covered_lines": "9", "total_lines": "10"}]}
    ));
}

test "an empty or malformed report never passes" {
    try testing.expectEqual(@as(u8, 1), coverage.check(testing.allocator, ""));
    try testing.expectEqual(@as(u8, 1), coverage.check(testing.allocator, "{\"files\": []}"));
    try testing.expectEqual(@as(u8, 1), coverage.check(testing.allocator, "{\"nope\": 1}"));
}
