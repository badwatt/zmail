//! Reads kcov's merged report and enforces 100% line coverage.
//!
//! kcov's JSON is not uniform: line counts are numbers in a single-run report
//! and strings in a merged report. Both are accepted, and anything else is a
//! hard failure: a report we cannot understand must never pass the gate.

const std = @import("std");

pub const report_path = "coverage/kcov-merged/coverage.json";

pub const FileCoverage = struct {
    path: []const u8,
    covered: u64,
    total: u64,

    pub fn isComplete(self: FileCoverage) bool {
        return self.covered == self.total;
    }
};

pub const Report = struct {
    files: []FileCoverage,
    covered: u64,
    total: u64,

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        for (self.files) |file| gpa.free(file.path);
        gpa.free(self.files);
        self.* = undefined;
    }

    pub fn incompleteCount(self: *const Report) u32 {
        var count: u32 = 0;
        for (self.files) |file| {
            if (!file.isComplete()) count += 1;
        }
        return count;
    }

    /// The gate: every measured line covered, and the report is not empty.
    pub fn isComplete(self: *const Report) bool {
        if (self.files.len == 0) return false;
        if (self.total == 0) return false;
        return self.covered == self.total;
    }

    /// Basis points, so 100.00% is printed without floating point.
    pub fn percentBasisPoints(self: *const Report) u32 {
        if (self.total == 0) return 0;
        const scaled = self.covered * 10_000;
        return @intCast(scaled / self.total);
    }
};

/// Error set is inferred: `std.json`'s error set is generic over the target type,
/// and naming it here would couple this helper to a std internal.
pub fn parseReport(gpa: std.mem.Allocator, json: []const u8) !Report {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedReport,
    };
    const files_value = root.get("files") orelse return error.MalformedReport;
    const items = switch (files_value) {
        .array => |array| array.items,
        else => return error.MalformedReport,
    };

    const files = try gpa.alloc(FileCoverage, items.len);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |file| gpa.free(file.path);
        gpa.free(files);
    }

    var covered: u64 = 0;
    var total: u64 = 0;
    for (items, 0..) |item, index| {
        const entry = switch (item) {
            .object => |object| object,
            else => return error.MalformedReport,
        };
        const path = switch (entry.get("file") orelse return error.MalformedReport) {
            .string => |string| string,
            else => return error.MalformedReport,
        };
        const file_covered = try countValue(entry.get("covered_lines") orelse return error.MalformedReport);
        const file_total = try countValue(entry.get("total_lines") orelse return error.MalformedReport);
        if (file_covered > file_total) return error.MalformedReport;
        // The JSON tree owns `path`; dupe it so the report outlives the parse.
        files[index] = .{ .path = try gpa.dupe(u8, path), .covered = file_covered, .total = file_total };
        initialized += 1;
        covered += file_covered;
        total += file_total;
    }

    return .{ .files = files, .covered = covered, .total = total };
}

fn countValue(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |number| if (number < 0) error.MalformedReport else @intCast(number),
        .string => |text| std.fmt.parseInt(u64, text, 10) catch error.MalformedReport,
        else => error.MalformedReport,
    };
}

/// Writes the per-file table and the summary. Only the summary verdict matters
/// to the gate, but the table is what tells a human where the gap is.
pub fn printReport(report: *const Report, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (report.files) |file| {
        if (file.isComplete()) {
            try writer.print("  ok    {s} ({d} lines)\n", .{ file.path, file.total });
        } else {
            try writer.print("  GAP   {s} ({d}/{d} lines)\n", .{ file.path, file.covered, file.total });
        }
    }
    const basis_points = report.percentBasisPoints();
    try writer.print(
        "coverage: {d}.{d:0>2}% ({d}/{d} lines), {d} file(s) with gaps\n",
        .{
            basis_points / 100,
            basis_points % 100,
            report.covered,
            report.total,
            report.incompleteCount(),
        },
    );
}

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buffer: [8 * 1024 * 1024]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(io, report_path, .{}) catch |err| {
        std.debug.print("coverage: cannot open {s}: {t}\n", .{ report_path, err });
        return 1;
    };
    defer file.close(io);

    const bytes_read = file.readPositionalAll(io, &buffer, 0) catch |err| {
        std.debug.print("coverage: cannot read {s}: {t}\n", .{ report_path, err });
        return 1;
    };

    var report = parseReport(gpa, buffer[0..bytes_read]) catch |err| {
        std.debug.print("coverage: cannot parse {s}: {t}\n", .{ report_path, err });
        return 1;
    };
    defer report.deinit(gpa);

    var output_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);
    printReport(&report, &writer) catch {};
    std.debug.print("{s}", .{writer.buffered()});

    return if (report.isComplete()) 0 else 1;
}
