const std = @import("std");
const log = @import("log.zig");

const slog = log.scoped("ultra_potato");

/// Keys in EVE's core_public__.yaml `device:` section that Ultra Potato Mode forces to -300 (the client's lowest-quality sentinel value).
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

pub const Profile = struct {
    path: []const u8,
    label: []const u8,
};

pub fn freeProfiles(allocator: std.mem.Allocator, profiles: []Profile) void {
    for (profiles) |p| {
        allocator.free(p.path);
        allocator.free(p.label);
    }
    allocator.free(profiles);
}

/// Scans %LOCALAPPDATA%\CCP\EVE\*\settings*\ for core_public__.yaml files - EVE's shared graphics settings, one per client install / settings profile (multiboxers keep several, e.g. settings_Default, settings_<CharName>).
pub fn scanProfiles(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) ![]Profile {
    var profiles = std.ArrayList(Profile).empty;
    errdefer {
        for (profiles.items) |p| {
            allocator.free(p.path);
            allocator.free(p.label);
        }
        profiles.deinit(allocator);
    }

    const local_app_data = environ_map.get("LOCALAPPDATA") orelse {
        slog.warn("LOCALAPPDATA environment variable not found", .{});
        return try profiles.toOwnedSlice(allocator);
    };

    const eve_root = try std.fs.path.join(allocator, &[_][]const u8{ local_app_data, "CCP", "EVE" });
    defer allocator.free(eve_root);

    var eve_dir = std.Io.Dir.cwd().openDir(io, eve_root, .{ .iterate = true }) catch |err| {
        slog.info("No EVE settings directory found at '{s}': {}", .{ eve_root, err });
        return try profiles.toOwnedSlice(allocator);
    };
    defer eve_dir.close(io);

    var install_iter = eve_dir.iterate();
    while (install_iter.next(io) catch null) |install_entry| {
        if (install_entry.kind != .directory) continue;

        const install_path = try std.fs.path.join(allocator, &[_][]const u8{ eve_root, install_entry.name });
        defer allocator.free(install_path);

        var install_dir = std.Io.Dir.cwd().openDir(io, install_path, .{ .iterate = true }) catch continue;
        defer install_dir.close(io);

        var settings_iter = install_dir.iterate();
        while (settings_iter.next(io) catch null) |settings_entry| {
            if (settings_entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, settings_entry.name, "settings")) continue;

            const yaml_path = try std.fs.path.join(allocator, &[_][]const u8{ install_path, settings_entry.name, "core_public__.yaml" });
            errdefer allocator.free(yaml_path);

            const probe = std.Io.Dir.cwd().openFile(io, yaml_path, .{}) catch {
                allocator.free(yaml_path);
                continue;
            };
            probe.close(io);

            const label = try std.fmt.allocPrint(allocator, "{s} / {s}", .{ install_entry.name, settings_entry.name });
            errdefer allocator.free(label);

            try profiles.append(allocator, .{ .path = yaml_path, .label = label });
        }
    }

    return try profiles.toOwnedSlice(allocator);
}

pub const ApplyResult = struct {
    path: []const u8,
    success: bool,
    changed: bool,
    error_message: ?[:0]const u8,
};

pub fn freeApplyResults(allocator: std.mem.Allocator, results: []ApplyResult) void {
    for (results) |r| allocator.free(r.path);
    allocator.free(results);
}

pub fn applyToFiles(allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8) ![]ApplyResult {
    var results = try allocator.alloc(ApplyResult, paths.len);
    errdefer allocator.free(results);

    for (paths, 0..) |path, i| {
        results[i] = try applyToOneFile(allocator, io, path);
    }

    return results;
}

fn applyToOneFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ApplyResult {
    const path_copy = try allocator.dupe(u8, path);

    const original = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
        return .{ .path = path_copy, .success = false, .changed = false, .error_message = @errorName(err) };
    };
    defer allocator.free(original);

    if (!backupExists(io, path, allocator) and !makeBackup(io, path, allocator)) {
        return .{ .path = path_copy, .success = false, .changed = false, .error_message = "Failed to write backup" };
    }

    const outcome = patchYamlText(allocator, original) catch |err| {
        return .{ .path = path_copy, .success = false, .changed = false, .error_message = @errorName(err) };
    };
    defer allocator.free(outcome.text);

    if (!outcome.changed) {
        return .{ .path = path_copy, .success = true, .changed = false, .error_message = null };
    }

    atomicOverwrite(allocator, io, path, outcome.text) catch |err| {
        return .{ .path = path_copy, .success = false, .changed = false, .error_message = @errorName(err) };
    };

    return .{ .path = path_copy, .success = true, .changed = true, .error_message = null };
}

fn backupExists(io: std.Io, path: []const u8, allocator: std.mem.Allocator) bool {
    const backup_path = std.fmt.allocPrint(allocator, "{s}.bak", .{path}) catch return false;
    defer allocator.free(backup_path);

    const file = std.Io.Dir.cwd().openFile(io, backup_path, .{}) catch return false;
    file.close(io);
    return true;
}

fn makeBackup(io: std.Io, path: []const u8, allocator: std.mem.Allocator) bool {
    const backup_path = std.fmt.allocPrint(allocator, "{s}.bak", .{path}) catch return false;
    defer allocator.free(backup_path);

    std.Io.Dir.cwd().copyFile(path, std.Io.Dir.cwd(), backup_path, io, .{}) catch |err| {
        slog.err("Failed to back up '{s}' to '{s}': {}", .{ path, backup_path, err });
        return false;
    };
    return true;
}

fn atomicOverwrite(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const unique = std.mem.readInt(u64, &rand_bytes, .little);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, unique });
    defer allocator.free(temp_path);

    const temp_file = try std.Io.Dir.cwd().createFile(io, temp_path, .{});
    defer temp_file.close(io);

    temp_file.writeStreamingAll(io, content) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
        return err;
    };

    std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), path, io) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
        return err;
    };
}

const PatchOutcome = struct {
    text: []u8,
    changed: bool,
};

/// Line-oriented text patch rather than a full YAML parse/re-serialize, so untouched keys, comments, and formatting survive byte-for-byte.
fn patchYamlText(allocator: std.mem.Allocator, original: []const u8) !PatchOutcome {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var any_changed = false;
    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;

        const patched = try patchLine(allocator, line);
        defer allocator.free(patched.text);
        if (patched.changed) any_changed = true;
        try out.appendSlice(allocator, patched.text);
    }

    return .{ .text = try out.toOwnedSlice(allocator), .changed = any_changed };
}

const PatchedLine = struct {
    text: []const u8,
    changed: bool,
};

/// Matches lines shaped like `  keyName: [connectionId, value]` for a key in TARGET_KEYS and rewrites `value` to -300 if it isn't already.
fn patchLine(allocator: std.mem.Allocator, line: []const u8) !PatchedLine {
    var body = line;
    var cr: []const u8 = "";
    if (body.len > 0 and body[body.len - 1] == '\r') {
        cr = "\r";
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
        const close_idx = std.mem.indexOfScalar(u8, after_bracket, ']') orelse continue;
        const content = after_bracket[0..close_idx];
        const comma_idx = std.mem.indexOfScalar(u8, content, ',') orelse continue;
        const id_str = std.mem.trim(u8, content[0..comma_idx], " ");
        const val_str = std.mem.trim(u8, content[comma_idx + 1 ..], " ");

        if (std.mem.eql(u8, val_str, "-300")) break;

        const new_line = try std.fmt.allocPrint(allocator, "{s}{s}: [{s}, -300]{s}", .{ body[0..indent_len], key, id_str, cr });
        return .{ .text = new_line, .changed = true };
    }

    return .{ .text = try allocator.dupe(u8, line), .changed = false };
}
