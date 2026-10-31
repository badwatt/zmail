//! Human time for the message list: "now", "14m", "3h", "2d", then a calendar
//! date. Pure: the caller passes `now`, so tests never depend on the clock.

const std = @import("std");
const assert = std.debug.assert;

pub const CivilDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

pub const seconds_per_minute = 60;
pub const seconds_per_hour = 3600;
pub const seconds_per_day = 86_400;
pub const days_per_week = 7;

/// Writes a short relative stamp into `buffer` (8 bytes is enough: "12/31").
pub fn relative(buffer: []u8, now_unix: i64, timestamp_unix: i64) []const u8 {
    const age = now_unix - timestamp_unix;
    if (age < seconds_per_minute) return "now";
    if (age < seconds_per_hour) {
        const minutes = @divFloor(age, seconds_per_minute);
        return std.fmt.bufPrint(buffer, "{d}m", .{minutes}) catch "now";
    }
    if (age < seconds_per_day) {
        const hours = @divFloor(age, seconds_per_hour);
        return std.fmt.bufPrint(buffer, "{d}h", .{hours}) catch "now";
    }
    if (age < days_per_week * seconds_per_day) {
        const days = @divFloor(age, seconds_per_day);
        return std.fmt.bufPrint(buffer, "{d}d", .{days}) catch "now";
    }

    const date = civil_from_unix(timestamp_unix);
    return std.fmt.bufPrint(buffer, "{d}/{d}", .{ date.month, date.day }) catch "now";
}

/// Abbreviated month name for `full_date` and the reader header.
pub fn month_abbrev(month: u8) []const u8 {
    const names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    assert(month >= 1);
    assert(month <= 12);
    return names[month - 1];
}

/// Writes "14 Nov 2023" into `buffer` (12 bytes is enough).
pub fn full_date(buffer: []u8, timestamp_unix: i64) []const u8 {
    const date = civil_from_unix(timestamp_unix);
    return std.fmt.bufPrint(buffer, "{d} {s} {d}", .{ date.day, month_abbrev(date.month), date.year }) catch "";
}

/// Converts a Unix timestamp to a UTC calendar date.
///
/// Uses Howard Hinnant's `civil_from_days`, which is exact for all positive and
/// negative 64-bit day counts, so dates before 1970 also work.
pub fn civil_from_unix(timestamp_unix: i64) CivilDate {
    return civil_from_days(@divFloor(timestamp_unix, seconds_per_day));
}

pub fn civil_from_days(days_since_epoch: i64) CivilDate {
    const z = days_since_epoch + 719_468;
    const era = @divFloor(z, 146_097);
    const day_of_era = z - era * 146_097; // [0, 146096]
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096),
        365,
    ); // [0, 399]
    const year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153); // [0, 11]
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = if (month_prime < 10) month_prime + 3 else month_prime - 9;
    const civil_year = if (month <= 2) year + 1 else year;

    return .{
        .year = civil_year,
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expect_date(timestamp_unix: i64, year: i64, month: u8, day: u8) !void {
    const date = civil_from_unix(timestamp_unix);
    try testing.expectEqual(year, date.year);
    try testing.expectEqual(month, date.month);
    try testing.expectEqual(day, date.day);
}

test "civil_from_unix: the epoch" {
    try expect_date(0, 1970, 1, 1);
}

test "civil_from_unix: a known modern timestamp" {
    // 1700000000 = 2023-11-14T22:13:20Z.
    try expect_date(1_700_000_000, 2023, 11, 14);
}

test "civil_from_unix: a leap day" {
    // 951782400 = 2000-02-29T00:00:00Z.
    try expect_date(951_782_400, 2000, 2, 29);
}

test "civil_from_unix: the day after a non-leap February" {
    // 1583020800 = 2020-03-01T00:00:00Z.
    try expect_date(1_583_020_800, 2020, 3, 1);
}

test "civil_from_unix: a date before the epoch" {
    // -86400 = 1969-12-31.
    try expect_date(-86_400, 1969, 12, 31);
}

test "month_abbrev names every month" {
    var month: u8 = 1;
    while (month <= 12) : (month += 1) {
        try testing.expectEqual(@as(usize, 3), month_abbrev(month).len);
    }
    try testing.expectEqualStrings("Jan", month_abbrev(1));
    try testing.expectEqualStrings("Dec", month_abbrev(12));
}

test "full_date renders a readable date" {
    var buffer: [16]u8 = undefined;
    // 2023-11-14T22:13:20Z.
    try testing.expectEqualStrings("14 Nov 2023", full_date(&buffer, 1_700_000_000));
}

test "full_date degrades to empty when the buffer is too small" {
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("", full_date(&buffer, 1_700_000_000));
}

test "relative: under a minute is now" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("now", relative(&buffer, 1000, 1000));
    try testing.expectEqualStrings("now", relative(&buffer, 1000, 941));
}

test "relative: a future timestamp (clock skew) is now, not negative" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("now", relative(&buffer, 1000, 2000));
}

test "relative: minutes" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("1m", relative(&buffer, 1000, 940));
    try testing.expectEqualStrings("59m", relative(&buffer, 1000, 1000 - 59 * 60));
}

test "relative: hours" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("1h", relative(&buffer, 10_000, 10_000 - 3600));
    try testing.expectEqualStrings("23h", relative(&buffer, 100_000, 100_000 - 23 * 3600));
}

test "relative: days" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("1d", relative(&buffer, 100_000, 100_000 - 86_400));
    try testing.expectEqualStrings("6d", relative(&buffer, 1_000_000, 1_000_000 - 6 * 86_400));
}

test "relative: a week or older shows the calendar date" {
    var buffer: [8]u8 = undefined;
    // 2023-11-14T22:13:20Z, read 30 days later.
    const timestamp = 1_700_000_000;
    const now = timestamp + 30 * 86_400;
    try testing.expectEqualStrings("11/14", relative(&buffer, now, timestamp));
}

test "relative: an impossible format degrades to now instead of crashing" {
    var tiny: [1]u8 = undefined;
    // The buffer is deliberately too small for "59m"; the fallback keeps the
    // list rendering even if a caller passes a bad buffer.
    try testing.expectEqualStrings("now", relative(&tiny, 100_000, 100_000 - 59 * 60));
}
