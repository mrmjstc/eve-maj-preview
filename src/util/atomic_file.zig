//! Crash-safe file writes through a temp file renamed over the target, and recognising the temp files a cut-short write leaves.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.Scoped("atomic_file");

const TEMP_FILE_EXTENSION = ".tmp";
/// A u64 in hex, unpadded.
const TEMP_FILE_MAX_HEX_DIGITS = 16;

/// Logs every failure itself.
pub fn write(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    // Unique per call so overlapping saves of the same path can't share a temp file.
    const unique = blk: {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        break :blk std.mem.readInt(u64, &random_bytes, .little);
    };
    const temp_path = allocator.print("{s}.{x}" ++ TEMP_FILE_EXTENSION, .{ path, unique }) catch |err| {
        slog.err("Failed to build a temp file name for '{s}': {}", .{ path, err });
        return err;
    };
    defer allocator.free(temp_path);

    const cwd = std.Io.Dir.cwd();
    const temp_file = cwd.createFile(io, temp_path, .{}) catch |err| {
        slog.err("Failed to create temp file '{s}' ({} bytes): {}", .{ temp_path, content.len, err });
        return err;
    };
    writeAndSync(io, temp_file, temp_path, content) catch |err| {
        temp_file.close(io);
        deleteTemp(io, temp_path, err);
        return err;
    };
    temp_file.close(io);

    cwd.rename(temp_path, cwd, path, io) catch |err| {
        slog.err("Failed to rename temp file '{s}' to '{s}' ({} bytes): {}", .{ temp_path, path, content.len, err });
        deleteTemp(io, temp_path, err);
        return err;
    };
}

/// The file a temp file named exactly as `write` names one was for, borrowed from `name`; null for any other name.
pub fn tempTarget(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, TEMP_FILE_EXTENSION)) return null;
    const stem = name[0 .. name.len - TEMP_FILE_EXTENSION.len];
    const dot_index = std.mem.findScalarLast(u8, stem, '.') orelse return null;
    const unique = stem[dot_index + 1 ..];
    if (unique.len == 0 or unique.len > TEMP_FILE_MAX_HEX_DIGITS) return null;
    for (unique) |char| {
        if (!std.ascii.isDigit(char) and (char < 'a' or char > 'f')) return null;
    }
    return stem[0..dot_index];
}

/// Flushed before the rename, so a crash can't leave the renamed file empty; logs its own failures.
fn writeAndSync(io: std.Io, file: std.Io.File, temp_path: []const u8, content: []const u8) !void {
    file.writeStreamingAll(io, content) catch |err| {
        slog.err("Failed to write {} bytes to temp file '{s}': {}", .{ content.len, temp_path, err });
        return err;
    };
    file.sync(io) catch |err| {
        slog.err("Failed to flush temp file '{s}' to disk: {}", .{ temp_path, err });
        return err;
    };
}

fn deleteTemp(io: std.Io, temp_path: []const u8, original_err: anyerror) void {
    std.Io.Dir.cwd().deleteFile(io, temp_path) catch |err| {
        slog.err("Failed to clean up temp file '{s}' (original error: {}): {}", .{ temp_path, original_err, err });
    };
}

const testing = std.testing;

test "tempTarget names the file a temp file from write was for" {
    try testing.expectEqualStrings("default.json", tempTarget("default.json.9862892f425a8fc0.tmp").?);
    try testing.expectEqualStrings("global.settings.json", tempTarget("global.settings.json.a.tmp").?);
    try testing.expectEqualStrings("2112625428.jpg", tempTarget("2112625428.jpg.0123456789abcdef.tmp").?);
}

test "tempTarget refuses a .tmp not named exactly as write names one" {
    try testing.expectEqual(null, tempTarget("default.json"));
    try testing.expectEqual(null, tempTarget("notes.tmp"));
    try testing.expectEqual(null, tempTarget("default.json..tmp"));
    try testing.expectEqual(null, tempTarget("default.json.notahex.tmp"));
    try testing.expectEqual(null, tempTarget("default.json.9862892F425A8FC0.tmp"));
    try testing.expectEqual(null, tempTarget("default.json.123456789abcdef01.tmp"));
    try testing.expectEqual(null, tempTarget("default.json.9862892f.tmp.bak"));
}
