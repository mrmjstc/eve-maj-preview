//! Ultra Potato Mode: forces EVE's graphics settings files to their lowest quality, keeping a backup of each.
const std = @import("std");
const config = @import("../../config.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("ultra_potato");

/// The client's lowest-quality sentinel value.
const LOWEST_QUALITY = "-300";
const MAX_SETTINGS_FILE_SIZE = 4 * 1024 * 1024;

/// Keys in EVE's core_public__.yaml `device:` section that Ultra Potato Mode forces to LOWEST_QUALITY.
pub const TARGET_KEYS = [_][]const u8{
    "aoQuality",
    "charClothSimulation",
    "charTextureQuality",
    "postProcessingQuality",
    "reflectionQuality",
    "shaderQuality",
    "shadowQuality",
    "textureQuality",
    "volumetricQuality",
};

/// Strings come from scanProfiles' allocator, which the caller frees.
pub const Profile = struct {
    path: []const u8,
    label: []const u8,
};

/// path comes from applyToFiles' allocator, which the caller frees; error_message is static.
pub const ApplyResult = struct {
    path: []const u8,
    succeeded: bool,
    changed: bool,
    error_message: ?[:0]const u8,
};

const PatchOutcome = struct {
    text: []u8,
    changed: bool,
};

const PatchedLine = struct {
    text: []const u8,
    changed: bool,
};

/// Scans %LOCALAPPDATA%\CCP\EVE\*\settings*\ for core_public__.yaml files - EVE's shared graphics settings, one per client install / settings profile (multiboxers keep several, e.g. settings_Default, settings_<CharName>).
pub fn scanProfiles(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) ![]Profile {
    var profiles: std.ArrayList(Profile) = .empty;
    errdefer {
        for (profiles.items) |profile| {
            allocator.free(profile.path);
            allocator.free(profile.label);
        }
        profiles.deinit(allocator);
    }

    const local_app_data = environ_map.get("LOCALAPPDATA") orelse {
        slog.warn("Failed to read LOCALAPPDATA", .{});
        return try profiles.toOwnedSlice(allocator);
    };

    const eve_root = try std.Io.Dir.path.join(allocator, &[_][]const u8{ local_app_data, "CCP", "EVE" });
    defer allocator.free(eve_root);

    var eve_dir = std.Io.Dir.cwd().openDir(io, eve_root, .{ .iterate = true }) catch |err| {
        slog.info("No EVE settings directory found at '{s}': {}", .{ eve_root, err });
        return try profiles.toOwnedSlice(allocator);
    };
    defer eve_dir.close(io);

    var install_iter = eve_dir.iterate();
    while (true) {
        const install_entry = install_iter.next(io) catch |err| {
            slog.warn("Failed to enumerate EVE install directory: {}", .{err});
            break;
        } orelse break;
        if (install_entry.kind != .directory) continue;

        const install_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ eve_root, install_entry.name });
        defer allocator.free(install_path);

        var install_dir = std.Io.Dir.cwd().openDir(io, install_path, .{ .iterate = true }) catch |err| {
            slog.warn("Failed to open EVE install directory '{s}': {}", .{ install_path, err });
            continue;
        };
        defer install_dir.close(io);

        var settings_iter = install_dir.iterate();
        while (true) {
            const settings_entry = settings_iter.next(io) catch |err| {
                slog.warn("Failed to enumerate EVE settings directory: {}", .{err});
                break;
            } orelse break;
            if (settings_entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, settings_entry.name, "settings")) continue;

            const yaml_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ install_path, settings_entry.name, "core_public__.yaml" });
            errdefer allocator.free(yaml_path);

            // Not every settings folder has one.
            const probe = std.Io.Dir.cwd().openFile(io, yaml_path, .{}) catch |err| {
                if (err != error.FileNotFound) slog.warn("Failed to open '{s}': {}", .{ yaml_path, err });
                allocator.free(yaml_path);
                continue;
            };
            probe.close(io);

            const label = try allocator.print("{s} / {s}", .{ install_entry.name, settings_entry.name });
            errdefer allocator.free(label);

            try profiles.append(allocator, .{ .path = yaml_path, .label = label });
        }
    }

    return try profiles.toOwnedSlice(allocator);
}

/// Caller frees the slice and each path.
pub fn applyToFiles(allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8) ![]ApplyResult {
    const results = try allocator.alloc(ApplyResult, paths.len);
    errdefer allocator.free(results);
    var done_count: usize = 0;
    errdefer for (results[0..done_count]) |result| allocator.free(result.path);

    for (paths, results) |path, *result| {
        result.* = try applyToOneFile(allocator, io, path);
        done_count += 1;
        if (!result.succeeded) slog.warn("Failed to apply Ultra Potato Mode to '{s}': {s}", .{ path, result.error_message orelse "unknown error" });
    }

    return results;
}

fn applyToOneFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ApplyResult {
    const path_copy = try allocator.dupe(u8, path);

    const original = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_SETTINGS_FILE_SIZE)) catch |err| {
        return .{ .path = path_copy, .succeeded = false, .changed = false, .error_message = @errorName(err) };
    };
    defer allocator.free(original);

    if (!backupExists(allocator, io, path) and !makeBackup(allocator, io, path)) {
        return .{ .path = path_copy, .succeeded = false, .changed = false, .error_message = "Failed to write backup" };
    }

    const outcome = patchYamlText(allocator, original) catch |err| {
        return .{ .path = path_copy, .succeeded = false, .changed = false, .error_message = @errorName(err) };
    };
    defer allocator.free(outcome.text);

    if (!outcome.changed) {
        return .{ .path = path_copy, .succeeded = true, .changed = false, .error_message = null };
    }

    config.atomicWriteFile(allocator, io, path, outcome.text) catch |err| {
        return .{ .path = path_copy, .succeeded = false, .changed = false, .error_message = @errorName(err) };
    };

    return .{ .path = path_copy, .succeeded = true, .changed = true, .error_message = null };
}

fn backupExists(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const backup_path = allocator.print("{s}.bak", .{path}) catch |err| {
        slog.err("Failed to build the backup path for '{s}': {}", .{ path, err });
        return false;
    };
    defer allocator.free(backup_path);

    const file = std.Io.Dir.cwd().openFile(io, backup_path, .{}) catch return false;
    file.close(io);
    return true;
}

fn makeBackup(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const backup_path = allocator.print("{s}.bak", .{path}) catch |err| {
        slog.err("Failed to build the backup path for '{s}': {}", .{ path, err });
        return false;
    };
    defer allocator.free(backup_path);

    std.Io.Dir.cwd().copyFile(path, std.Io.Dir.cwd(), backup_path, io, .{}) catch |err| {
        slog.err("Failed to back up '{s}' to '{s}': {}", .{ path, backup_path, err });
        return false;
    };
    return true;
}

/// Line-oriented text patch rather than a full YAML parse/re-serialize, so untouched keys, comments, and formatting survive byte-for-byte.
fn patchYamlText(allocator: std.mem.Allocator, original: []const u8) !PatchOutcome {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var any_changed = false;
    var it = std.mem.splitScalar(u8, original, '\n');
    var is_first = true;
    while (it.next()) |line| {
        if (!is_first) try out.append(allocator, '\n');
        is_first = false;

        const patched = try patchLine(allocator, line);
        defer allocator.free(patched.text);
        if (patched.changed) any_changed = true;
        try out.appendSlice(allocator, patched.text);
    }

    return .{ .text = try out.toOwnedSlice(allocator), .changed = any_changed };
}

/// Matches lines shaped like `  keyName: [connectionId, value]` for a key in TARGET_KEYS and rewrites `value` to LOWEST_QUALITY if it isn't already.
fn patchLine(allocator: std.mem.Allocator, line: []const u8) !PatchedLine {
    var body = line;
    var line_ending: []const u8 = "";
    if (body.len > 0 and body[body.len - 1] == '\r') {
        line_ending = "\r";
        body = body[0 .. body.len - 1];
    }

    var indent_len: usize = 0;
    while (indent_len < body.len and body[indent_len] == ' ') indent_len += 1;
    const rest = body[indent_len..];

    for (TARGET_KEYS) |key| {
        if (!std.mem.startsWith(u8, rest, key)) continue;
        const after_key = rest[key.len..];
        if (!std.mem.startsWith(u8, after_key, ": [")) continue;

        const after_bracket = after_key[": [".len..];
        const close_index = std.mem.findScalar(u8, after_bracket, ']') orelse continue;
        const content = after_bracket[0..close_index];
        const comma_index = std.mem.findScalar(u8, content, ',') orelse continue;
        const id_text = std.mem.trim(u8, content[0..comma_index], " ");
        const value_text = std.mem.trim(u8, content[comma_index + 1 ..], " ");

        if (std.mem.eql(u8, value_text, LOWEST_QUALITY)) break;

        const new_line = try allocator.print("{s}{s}: [{s}, " ++ LOWEST_QUALITY ++ "]{s}", .{ body[0..indent_len], key, id_text, line_ending });
        return .{ .text = new_line, .changed = true };
    }

    return .{ .text = try allocator.dupe(u8, line), .changed = false };
}

const testing = std.testing;

test "patchLine rewrites a target key's value and keeps its indent and CRLF" {
    const patched = try patchLine(testing.allocator, "  shadowQuality: [0, 2]\r");
    defer testing.allocator.free(patched.text);
    try testing.expect(patched.changed);
    try testing.expectEqualStrings("  shadowQuality: [0, -300]\r", patched.text);
}

test "patchLine leaves other keys and already-lowest values unchanged" {
    const other = try patchLine(testing.allocator, "  windowMode: [0, 2]");
    defer testing.allocator.free(other.text);
    try testing.expect(!other.changed);
    try testing.expectEqualStrings("  windowMode: [0, 2]", other.text);

    const lowest = try patchLine(testing.allocator, "  aoQuality: [1, -300]");
    defer testing.allocator.free(lowest.text);
    try testing.expect(!lowest.changed);
}

test "patchYamlText keeps untouched lines byte for byte" {
    const outcome = try patchYamlText(testing.allocator, "device:\n  textureQuality: [0, 1]\n  # comment\n");
    defer testing.allocator.free(outcome.text);
    try testing.expect(outcome.changed);
    try testing.expectEqualStrings("device:\n  textureQuality: [0, -300]\n  # comment\n", outcome.text);
}
