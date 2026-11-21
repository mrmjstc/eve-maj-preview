//! The process environment and the on-disk layout of the app's profile and data files.
const std = @import("std");
const atomic_file = @import("../util/atomic_file.zig");
const log = @import("../log.zig");

const slog = log.Scoped("config");

pub const PROFILES_DIR = "profiles";
pub const DEFAULT_PROFILE = "default.json";
pub const GLOBAL_SETTINGS_FILE = "profiles/global.settings.json";
pub const MAX_CONFIG_FILE_SIZE: u64 = 300 * 1024;
/// A locked file is often freed within moments, e.g. once an antivirus scan or sync lets go of it.
const READ_ATTEMPTS = 5;
const READ_RETRY_MS = 100;

/// App state that isn't a setting, kept out of PROFILES_DIR so copying profiles doesn't carry it along.
const DATA_DIR = "data";
pub const AUTO_COLORS_FILE = DATA_DIR ++ "/colors.json";
pub const CHARACTER_IDS_FILE = DATA_DIR ++ "/character_ids.json";
/// Downloaded character portraits, one `{id}.jpg` each, kept for good.
pub const PORTRAITS_DIR = DATA_DIR ++ "/portraits";
/// The colour picked from each sovereignty-holding alliance's logo, so a logo is fetched once.
pub const LOGO_COLORS_FILE = DATA_DIR ++ "/logo_colors.json";
/// The folders the app's own files are written into; their subfolders aren't swept.
const TEMP_FILE_DIRS = [_][]const u8{ PROFILES_DIR, DATA_DIR, PORTRAITS_DIR };
/// What the app writes in TEMP_FILE_DIRS, so a temp file for anything else isn't the app's.
const TEMP_FILE_TARGET_EXTENSIONS = [_][]const u8{ ".json", ".jpg" };

const LEGACY_FILES = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "eve-maj.log", .to = log.LOG_FILE_NAME },
    .{ .from = "eve-maj.log.old", .to = log.LOG_FILE_NAME_OLD },
    .{ .from = "eve-maj-crash.dmp", .to = log.MINIDUMP_FILE_NAME },
    .{ .from = "colors.json", .to = AUTO_COLORS_FILE },
    .{ .from = "character_ids.json", .to = CHARACTER_IDS_FILE },
};

var g_environ_map: ?*const std.process.Environ.Map = null;

/// Call once before anything that reads environment variables.
pub fn setEnvironMap(environ_map: *const std.process.Environ.Map) void {
    g_environ_map = environ_map;
}

/// Null before setEnvironMap.
pub fn environMap() ?*const std.process.Environ.Map {
    return g_environ_map;
}

/// Null when the variable is unset, or before setEnvironMap.
pub fn environmentVariable(name: []const u8) ?[]const u8 {
    const environ_map = g_environ_map orelse return null;
    return environ_map.get(name);
}

/// Into DATA_DIR and log.LOG_DIR, never replacing a file; call once the cwd is the exe folder, before anything logs.
pub fn migrateLegacyLayout(io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ DATA_DIR, log.LOG_DIR }) |dir| {
        createDirIfMissing(io, dir) catch |err| slog.err("Failed to create folder '{s}': {}", .{ dir, err });
    }

    // Log files come first in LEGACY_FILES, so the old log is moved before these messages reopen it.
    for (LEGACY_FILES) |file| {
        cwd.access(io, file.from, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                slog.warn("Failed to check for legacy file '{s}': {}", .{ file.from, err });
                continue;
            },
        };
        if (cwd.access(io, file.to, .{})) |_| {
            slog.debug("Left '{s}' in place: '{s}' already exists", .{ file.from, file.to });
            continue;
        } else |err| switch (err) {
            error.FileNotFound => {},
            // Unknown, so it's left alone rather than risk moving over it.
            else => {
                slog.warn("Failed to move '{s}': couldn't check for '{s}': {}", .{ file.from, file.to, err });
                continue;
            },
        }
        cwd.rename(file.from, cwd, file.to, io) catch |err| {
            slog.warn("Failed to move '{s}' to '{s}': {}", .{ file.from, file.to, err });
            continue;
        };
        slog.info("Moved '{s}' to '{s}'", .{ file.from, file.to });
    }
}

/// Deletes the temp files a save cut short by the process ending left behind; call once this is the only instance, before anything saves.
pub fn sweepTempFiles(io: std.Io) void {
    for (TEMP_FILE_DIRS) |dir_path| {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                slog.warn("Failed to open folder '{s}' to clean up temp files: {}", .{ dir_path, err });
                continue;
            },
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (true) {
            const entry = it.next(io) catch |err| {
                slog.warn("Failed to list folder '{s}' to clean up temp files: {}", .{ dir_path, err });
                break;
            } orelse break;
            if (entry.kind != .file or !isTempFileName(entry.name)) continue;
            dir.deleteFile(io, entry.name) catch |err| {
                slog.warn("Failed to delete leftover temp file '{s}/{s}': {}", .{ dir_path, entry.name, err });
                continue;
            };
            slog.info("Deleted leftover temp file '{s}/{s}'", .{ dir_path, entry.name });
        }
    }
}

/// Doesn't log.
pub fn createDirIfMissing(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Up to MAX_CONFIG_FILE_SIZE, retried briefly while another program holds it; caller owns the result and logs.
pub fn readSettingsFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_CONFIG_FILE_SIZE)) catch |err| {
            if (err == error.FileNotFound or attempt == READ_ATTEMPTS) return err;
            // The read's error is the one worth reporting, not the wait's.
            std.Io.sleep(io, .fromMilliseconds(READ_RETRY_MS), .awake) catch return err;
            continue;
        };
    }
}

/// Caller owns the result.
pub fn expandEnvironmentVariables(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.findScalar(u8, path, '%') == null) {
        return allocator.dupe(u8, path);
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var index: usize = 0;
    while (index < path.len) {
        if (path[index] == '%') {
            const start = index + 1;
            const end = std.mem.findScalarPos(u8, path, start, '%') orelse {
                try result.append(allocator, '%');
                index += 1;
                continue;
            };

            const variable_name = path[start..end];
            if (variable_name.len == 0) {
                try result.append(allocator, '%');
                index += 1;
                continue;
            }

            const variable_value = environmentVariable(variable_name) orelse {
                slog.warn("Failed to read environment variable '{s}'", .{variable_name});
                try result.appendSlice(allocator, path[index .. end + 1]);
                index = end + 1;
                continue;
            };

            try result.appendSlice(allocator, variable_value);

            index = end + 1;
        } else {
            try result.append(allocator, path[index]);
            index += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// A temp file atomic_file.write left for one of the app's file types, so no file of anyone else's matches.
fn isTempFileName(name: []const u8) bool {
    const target = atomic_file.tempTarget(name) orelse return false;
    for (TEMP_FILE_TARGET_EXTENSIONS) |extension| {
        if (target.len > extension.len and std.mem.endsWith(u8, target, extension)) return true;
    }
    return false;
}

test "a temp file is swept only for the app's file types" {
    try std.testing.expect(isTempFileName("default.json.9862892f425a8fc0.tmp"));
    try std.testing.expect(isTempFileName("2112625428.jpg.0123456789abcdef.tmp"));
    try std.testing.expect(!isTempFileName("notes.txt.9862892f.tmp"));
    try std.testing.expect(!isTempFileName("default.9862892f.tmp"));
    try std.testing.expect(!isTempFileName(".json.9862892f.tmp"));
    try std.testing.expect(!isTempFileName("default.json.notahex.tmp"));
}
