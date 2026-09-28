//! Profile files on disk: where they live, loading with fallbacks, saving, and creating defaults.
const std = @import("std");
const log = @import("../log.zig");
const files = @import("files.zig");
const Config = @import("../config.zig").Config;

const slog = log.scoped("config");

/// Caller owns the returned slice.
pub fn path(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ files.PROFILES_DIR, name });
}

/// A missing profile falls back to DEFAULT_PROFILE, and a malformed one to its defaults.
pub fn load(allocator: std.mem.Allocator, name: []const u8) !Config {
    try ensureDir(allocator);

    const profile_path = try path(allocator, name);
    defer allocator.free(profile_path);

    slog.info("Loading JSON config from: {s}", .{profile_path});
    return loadFile(allocator, profile_path, name) catch |err| {
        // ensureDir() above guarantees DEFAULT_PROFILE exists, so this can't recurse forever.
        if (err == error.FileNotFound and !std.mem.eql(u8, name, files.DEFAULT_PROFILE)) {
            slog.warn("Profile '{s}' not found, falling back to default profile", .{name});
            return load(allocator, files.DEFAULT_PROFILE);
        }
        return err;
    };
}

fn loadFile(allocator: std.mem.Allocator, profile_path: []const u8, name: []const u8) !Config {
    const content = std.Io.Dir.cwd().readFileAlloc(files.g_io, profile_path, allocator, .limited(files.MAX_CONFIG_FILE_SIZE)) catch |err| {
        if (err != error.FileNotFound) slog.err("Failed to read config file '{s}': {}", .{ profile_path, err });
        return err;
    };
    defer allocator.free(content);

    return Config.buildConfigFromJson(allocator, content, name) catch |err| {
        slog.err("Failed to parse config file '{s}' ({}), falling back to defaults", .{ profile_path, err });
        return Config.getDefaultsWithProfile(allocator, name);
    };
}

pub fn save(cfg: *const Config, allocator: std.mem.Allocator, file_path: []const u8) !void {
    const json = try cfg.toJsonString(allocator);
    defer allocator.free(json);

    try files.atomicWriteFile(allocator, files.g_io, file_path, json);
    slog.info("Saved JSON config to: {s}", .{file_path});
}

/// Writes a fresh default profile named `name`, optionally with its own accent colour.
pub fn writeDefault(allocator: std.mem.Allocator, name: []const u8, accent_color: ?u32) !void {
    var cfg = try Config.getDefaultsWithProfile(allocator, name);
    defer cfg.deinit();
    if (accent_color) |c| cfg.accentColor = c;

    const profile_path = try path(allocator, name);
    defer allocator.free(profile_path);
    try save(&cfg, allocator, profile_path);
}

fn ensureDir(allocator: std.mem.Allocator) !void {
    const cwd = std.Io.Dir.cwd();

    cwd.createDir(files.g_io, files.PROFILES_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const default_path = try path(allocator, files.DEFAULT_PROFILE);
    defer allocator.free(default_path);

    cwd.access(files.g_io, default_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            slog.debug("Default profile not found, creating: {s}", .{default_path});
            try writeDefault(allocator, files.DEFAULT_PROFILE, null);
            slog.info("Created default profile: {s}", .{default_path});
        },
        else => return err,
    };
}
