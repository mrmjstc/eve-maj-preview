//! Process-wide I/O handles and the on-disk layout of the app's profile and data files.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("config");

pub const PROFILES_DIR = "profiles";
pub const DEFAULT_PROFILE = "default.json";
pub const GLOBAL_SETTINGS_FILE = "profiles/global.settings.json";
pub const MAX_CONFIG_FILE_SIZE: u64 = 300 * 1024;

/// App state that isn't a setting, kept out of PROFILES_DIR so copying profiles doesn't carry it along.
pub const DATA_DIR = "data";
pub const AUTO_COLORS_FILE = DATA_DIR ++ "/colors.json";
pub const CHARACTER_IDS_FILE = DATA_DIR ++ "/character_ids.json";

/// Files older versions kept beside the exe, and where they live now.
const LEGACY_FILES = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "eve-maj.log", .to = log.LOG_FILE_NAME },
    .{ .from = "eve-maj.log.old", .to = log.LOG_FILE_NAME_OLD },
    .{ .from = "eve-maj-crash.dmp", .to = log.MINIDUMP_FILE_NAME },
    .{ .from = "colors.json", .to = AUTO_COLORS_FILE },
    .{ .from = "character_ids.json", .to = CHARACTER_IDS_FILE },
};

pub var g_io: std.Io = undefined;
pub var g_environ_map: *const std.process.Environ.Map = undefined;

/// Must be called once before any Config/GlobalConfig load/save function is used.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

/// Must be called once before any function that reads environment variables (path %VAR% expansion, USERPROFILE fallback).
pub fn setEnvironMap(environ_map: *const std.process.Environ.Map) void {
    g_environ_map = environ_map;
}

pub fn environMap() *const std.process.Environ.Map {
    return g_environ_map;
}

/// Creates DATA_DIR and log.LOG_DIR, then moves files older versions kept beside the exe into them; never replaces one already there.
/// Call once the cwd is the exe folder and before anything logs, so the old log can still be moved.
pub fn migrateLegacyLayout() void {
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ DATA_DIR, log.LOG_DIR }) |dir| {
        cwd.createDir(g_io, dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => slog.err("Failed to create folder '{s}': {}", .{ dir, err }),
        };
    }

    // Log files come first in LEGACY_FILES, so the old log is moved before these messages reopen it.
    for (LEGACY_FILES) |file| {
        cwd.access(g_io, file.from, .{}) catch continue;
        const target_exists = if (cwd.access(g_io, file.to, .{})) |_| true else |_| false;
        if (target_exists) {
            slog.debug("Left '{s}' in place: '{s}' already exists", .{ file.from, file.to });
            continue;
        }
        cwd.rename(file.from, cwd, file.to, g_io) catch |err| {
            slog.warn("Failed to move '{s}' to '{s}': {}", .{ file.from, file.to, err });
            continue;
        };
        slog.info("Moved '{s}' to '{s}'", .{ file.from, file.to });
    }
}

/// Writes via a temp file + rename so a failed write can't corrupt the destination file.
pub fn atomicWriteFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    // Unique per call so overlapping saves of the same path can't share a temp file.
    const unique = blk: {
        var rand_bytes: [8]u8 = undefined;
        io.random(&rand_bytes);
        break :blk std.mem.readInt(u64, &rand_bytes, .little);
    };
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, unique });
    defer allocator.free(temp_path);

    const temp_file = std.Io.Dir.cwd().createFile(io, temp_path, .{}) catch |err| {
        slog.err("Failed to create temp file '{s}' ({} bytes): {}", .{ temp_path, content.len, err });
        return err;
    };
    defer temp_file.close(io);

    temp_file.writeStreamingAll(io, content) catch |err| {
        slog.err("Failed to write {} bytes to temp file '{s}': {}", .{ content.len, temp_path, err });
        std.Io.Dir.cwd().deleteFile(io, temp_path) catch |cleanup_err| {
            slog.err("Failed to cleanup temp file '{s}' after write failure (original error: {}): {}", .{ temp_path, err, cleanup_err });
        };
        return err;
    };

    std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), path, io) catch |err| {
        slog.err("Failed to rename temp file '{s}' to '{s}' ({} bytes): {}", .{ temp_path, path, content.len, err });
        std.Io.Dir.cwd().deleteFile(io, temp_path) catch |cleanup_err| {
            slog.err("Failed to cleanup temp file '{s}' after rename failure (original error: {}): {}", .{ temp_path, err, cleanup_err });
        };
        return err;
    };
}

/// Expand %VAR% patterns in a path string. Caller owns the returned slice.
pub fn expandEnvironmentVariables(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, path, '%') == null) {
        return allocator.dupe(u8, path);
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '%') {
            const start = i + 1;
            const end = std.mem.indexOfScalarPos(u8, path, start, '%') orelse {
                try result.append(allocator, '%');
                i += 1;
                continue;
            };

            const var_name = path[start..end];
            if (var_name.len == 0) {
                try result.append(allocator, '%');
                i += 1;
                continue;
            }

            const var_value = g_environ_map.get(var_name) orelse {
                slog.warn("Environment variable '{s}' not found", .{var_name});
                try result.appendSlice(allocator, path[i .. end + 1]);
                i = end + 1;
                continue;
            };

            for (var_value) |c| {
                try result.append(allocator, if (c == '\\') '/' else c);
            }

            i = end + 1;
        } else {
            try result.append(allocator, path[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}
