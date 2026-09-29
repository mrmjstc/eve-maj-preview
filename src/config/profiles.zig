//! Profile files on disk: where they live, loading with fallbacks, saving, and creating defaults.
const std = @import("std");
const files = @import("files.zig");
const Config = @import("../config.zig").Config;
const log = @import("../log.zig");

const slog = log.scoped("config");

/// A profile's display name, without ".json"; longer names from older versions still load.
pub const MAX_NAME_LEN: usize = 16;
const BACKUP_DIR = "backup";

/// Caller owns the returned slice.
pub fn path(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ files.PROFILES_DIR, name });
}

/// Only a plain `<name>.json` file name, so a name from the dialog can't reach outside PROFILES_DIR.
pub fn validateName(name: []const u8) !void {
    if (!std.mem.endsWith(u8, name, ".json")) return error.InvalidProfileName;
    const stem = name[0 .. name.len - ".json".len];
    if (stem.len == 0 or stem[0] == '.') return error.InvalidProfileName;
    if (std.mem.indexOfAny(u8, stem, "/\\:*?\"<>|") != null) return error.InvalidProfileName;
    if (std.mem.eql(u8, name, std.fs.path.basename(files.GLOBAL_SETTINGS_FILE))) return error.InvalidProfileName;
}

/// "<name>.json" for a display name typed by the user; caller owns the result.
pub fn fileNameFor(allocator: std.mem.Allocator, display_name: []const u8) ![]u8 {
    if (display_name.len == 0 or display_name.len > MAX_NAME_LEN) return error.InvalidProfileName;
    const name = try std.fmt.allocPrint(allocator, "{s}.json", .{display_name});
    errdefer allocator.free(name);
    try validateName(name);
    return name;
}

/// A new default profile; fails with ProfileAlreadyExists rather than overwriting one.
pub fn create(allocator: std.mem.Allocator, name: []const u8, accent_color: ?u32) !void {
    try validateName(name);
    const profile_path = try path(allocator, name);
    defer allocator.free(profile_path);
    // Claims the name first, so two creates of the same name can't both succeed.
    const file = std.Io.Dir.cwd().createFile(files.g_io, profile_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ProfileAlreadyExists,
        else => return err,
    };
    file.close(files.g_io);
    try writeDefault(allocator, name, accent_color);
}

/// Copies `source` to a new profile `target`, optionally with its own accent colour; never overwrites.
pub fn copy(allocator: std.mem.Allocator, source: []const u8, target: []const u8, accent_color: ?u32) !void {
    try validateName(source);
    const source_path = try path(allocator, source);
    defer allocator.free(source_path);
    try copyFrom(allocator, source_path, target, accent_color);
}

/// Restores a file from PROFILES_DIR/backup (see deleteToBackup) as the new profile `target`.
pub fn restoreBackup(allocator: std.mem.Allocator, backup: []const u8, target: []const u8, accent_color: ?u32) !void {
    try validateName(backup);
    const source_path = try std.fs.path.join(allocator, &.{ files.PROFILES_DIR, BACKUP_DIR, backup });
    defer allocator.free(source_path);
    try copyFrom(allocator, source_path, target, accent_color);
}

fn copyFrom(allocator: std.mem.Allocator, source_path: []const u8, target: []const u8, accent_color: ?u32) !void {
    try validateName(target);
    const target_path = try path(allocator, target);
    defer allocator.free(target_path);

    const cwd = std.Io.Dir.cwd();
    cwd.copyFile(source_path, cwd, target_path, files.g_io, .{ .replace = false }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ProfileAlreadyExists,
        else => return err,
    };

    const color = accent_color orelse return;
    var cfg = try load(allocator, target);
    defer cfg.deinit();
    cfg.accentColor = color;
    try save(&cfg, allocator, target_path);
}

/// Any profile but the default one, which the app falls back to.
pub fn checkDeletable(name: []const u8) !void {
    try validateName(name);
    if (std.mem.eql(u8, name, files.DEFAULT_PROFILE)) return error.CannotDeleteDefaultProfile;
}

/// Moves the profile into PROFILES_DIR/backup, named `<unix time>_<name>` so the newest sorts first.
pub fn deleteToBackup(allocator: std.mem.Allocator, name: []const u8) !void {
    try checkDeletable(name);

    const profile_path = try path(allocator, name);
    defer allocator.free(profile_path);
    const backup_dir = try path(allocator, BACKUP_DIR);
    defer allocator.free(backup_dir);

    const cwd = std.Io.Dir.cwd();
    cwd.createDir(files.g_io, backup_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const backup_path = try std.fmt.allocPrint(allocator, "{s}{c}{d}_{s}", .{ backup_dir, std.fs.path.sep, std.Io.Clock.real.now(files.g_io).toSeconds(), name });
    defer allocator.free(backup_path);
    try cwd.rename(profile_path, cwd, backup_path, files.g_io);
    slog.info("Moved profile '{s}' to {s}", .{ name, backup_path });
}

/// Backed-up profile file names, newest first; caller owns the list and its strings.
pub fn listBackups(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    const backup_dir = try path(allocator, BACKUP_DIR);
    defer allocator.free(backup_dir);
    var dir = std.Io.Dir.cwd().openDir(files.g_io, backup_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names,
        else => return err,
    };
    defer dir.close(files.g_io);

    var iter = dir.iterate();
    while (try iter.next(files.g_io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try names.append(allocator, name);
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn newerFirst(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.newerFirst);
    return names;
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

/// The profile file names in PROFILES_DIR, e.g. "default.json"; caller owns the list and its strings.
pub fn list(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(files.g_io, files.PROFILES_DIR, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            slog.debug("Profiles directory not found", .{});
            return names;
        }
        return err;
    };
    defer dir.close(files.g_io);

    const global_settings_name = std.fs.path.basename(files.GLOBAL_SETTINGS_FILE);
    var iter = dir.iterate();
    while (try iter.next(files.g_io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.eql(u8, entry.name, global_settings_name)) continue;

        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try names.append(allocator, name);
    }

    slog.debug("Found {} profile(s)", .{names.items.len});
    return names;
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

const testing = std.testing;

test "validateName accepts only a plain <name>.json" {
    try validateName("Main.json");
    try validateName("My Alts.json");
    try testing.expectError(error.InvalidProfileName, validateName("Main"));
    try testing.expectError(error.InvalidProfileName, validateName(".json"));
    try testing.expectError(error.InvalidProfileName, validateName(".hidden.json"));
    try testing.expectError(error.InvalidProfileName, validateName("../Main.json"));
    try testing.expectError(error.InvalidProfileName, validateName("a:b.json"));
    try testing.expectError(error.InvalidProfileName, validateName("what?.json"));
}

test "validateName refuses the global settings file" {
    try testing.expectError(error.InvalidProfileName, validateName("global.settings.json"));
}

test "fileNameFor appends .json and rejects empty, long or unsafe names" {
    const name = try fileNameFor(testing.allocator, "Main");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("Main.json", name);

    try testing.expectError(error.InvalidProfileName, fileNameFor(testing.allocator, ""));
    try testing.expectError(error.InvalidProfileName, fileNameFor(testing.allocator, "a" ** (MAX_NAME_LEN + 1)));
    try testing.expectError(error.InvalidProfileName, fileNameFor(testing.allocator, "a*b"));
}

test "checkDeletable refuses the default profile" {
    try checkDeletable("Main.json");
    try testing.expectError(error.CannotDeleteDefaultProfile, checkDeletable(files.DEFAULT_PROFILE));
    try testing.expectError(error.InvalidProfileName, checkDeletable("Main"));
}
