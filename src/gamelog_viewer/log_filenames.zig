const std = @import("std");

/// Parses a chatlog/gamelog filename's embedded timestamp into a single comparable number
/// (YYYYMMDDHHMMSS), or 0 if the filename doesn't match the expected pattern.
/// Chatlogs: Local_YYYYMMDD_HHMMSS_1234567890.txt
/// Gamelogs: YYYYMMDD_HHMMSS_1234567890.txt
pub fn parseLogTimestamp(filename: []const u8, is_chatlog: bool) u64 {
    const name_no_ext = if (std.mem.endsWith(u8, filename, ".txt"))
        filename[0 .. filename.len - 4]
    else
        filename;

    const timestamp_part = if (is_chatlog) blk: {
        if (std.mem.startsWith(u8, name_no_ext, "Local_")) {
            break :blk name_no_ext[6..];
        } else {
            return 0;
        }
    } else name_no_ext;

    // Expected format: YYYYMMDD_HHMMSS (gamelogs may have a _characterid suffix, ignored).
    // Need at least "YYYYMMDD_HHMMSS".
    if (timestamp_part.len < 15) return 0;

    const date_part = timestamp_part[0..8];
    const date = std.fmt.parseInt(u64, date_part, 10) catch return 0;

    if (timestamp_part[8] != '_') return 0;
    const time_part = timestamp_part[9..15];
    const time = std.fmt.parseInt(u64, time_part, 10) catch return 0;

    return date * 1000000 + time;
}

/// Extract character ID from log filename
/// Chatlogs: Local_YYYYMMDD_HHMMSS_1234567890.txt -> "1234567890"
/// Gamelogs: YYYYMMDD_HHMMSS_1234567890.txt -> "1234567890"
/// Returns null if extraction fails
pub fn extractCharacterId(filename: []const u8) ?[]const u8 {
    const name = if (std.mem.endsWith(u8, filename, ".txt"))
        filename[0 .. filename.len - 4]
    else
        filename;

    if (std.mem.lastIndexOf(u8, name, "_")) |last_underscore| {
        const character_id = name[last_underscore + 1 ..];
        if (character_id.len >= 8 and character_id.len <= 13) {
            for (character_id) |c| {
                if (c < '0' or c > '9') return null;
            }
            return character_id;
        }
    }
    return null;
}
