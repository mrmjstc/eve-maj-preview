//! UTC calendar times as Unix seconds.
const std = @import("std");

/// Proleptic Gregorian; the caller has checked each field's range.
pub const UtcTime = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64 = 0,
    minute: i64 = 0,
    second: i64 = 0,
};

pub fn unixSeconds(time: UtcTime) i64 {
    return daysFromCivil(time.year, time.month, time.day) * std.time.s_per_day + time.hour * std.time.s_per_hour + time.minute * std.time.s_per_min + time.second;
}

/// Days since 1970-01-01, by Howard Hinnant's published days_from_civil.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const march_year = if (month <= 2) year - 1 else year;
    const era = @divFloor(march_year, 400);
    const year_of_era = march_year - era * 400;
    const day_of_year = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

const testing = std.testing;

test "unixSeconds counts from the 1970 epoch" {
    try testing.expectEqual(0, unixSeconds(.{ .year = 1970, .month = 1, .day = 1 }));
    try testing.expectEqual(-1, unixSeconds(.{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 }));
}

test "unixSeconds counts leap days, including 2000's" {
    try testing.expectEqual(951825600, unixSeconds(.{ .year = 2000, .month = 2, .day = 29, .hour = 12 }));
    try testing.expectEqual(1735689599, unixSeconds(.{ .year = 2024, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 }));
}
