//! Process-wide I/O handles and the profile files config reads and writes.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("config");

pub const PROFILES_DIR = "profiles";
pub const DEFAULT_PROFILE = "default.json";
pub const GLOBAL_SETTINGS_FILE = "profiles/global.settings.json";
pub const MAX_CONFIG_FILE_SIZE: u64 = 300 * 1024;

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
