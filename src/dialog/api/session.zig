//! Loading, saving and previewing the profile and global settings the window edits.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config_mod = @import("../../config.zig");
const main_mod = @import("../../main.zig");
const host = @import("../host.zig");
const rpc = @import("../rpc.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog");

/// What's saved rather than what's previewed, so reloading the form drops unsaved edits.
pub fn loadConfig(arena: std.mem.Allocator) !rpc.RawJson {
    if (host.editsLiveProfile()) return .{ .text = try main_mod.g_store.saved.toJsonString(arena) };
    const cfg = try config_mod.loadProfile(arena, host.editingProfile());
    return .{ .text = try cfg.toJsonString(arena) };
}

/// The built-in defaults, for "Clear to Default".
pub fn getDefaultConfig(arena: std.mem.Allocator) !rpc.RawJson {
    const cfg = try config_mod.Config.getDefaultsWithProfile(arena, host.editingProfile());
    return .{ .text = try cfg.toJsonString(arena) };
}

/// Validated and clamped before it's written, then made the running profile.
pub fn saveConfig(arena: std.mem.Allocator, args: struct { json: []const u8 }) !void {
    // Copied, since the reload below replaces what editingProfile() may point into.
    const name = try arena.dupe(u8, host.editingProfile());
    const cfg = try config_mod.Config.buildConfigFromJson(arena, args.json, name);
    const path = try config_mod.profilePath(arena, name);
    try config_mod.saveProfile(&cfg, arena, path);
    main_mod.switchProfile(name);
}

pub fn getValidationRanges(arena: std.mem.Allocator) !rpc.RawJson {
    return .{ .text = try config_mod.Config.buildValidationRangesJson(arena) };
}

/// GlobalConfig only saves a price per ore; this adds the built-in name, category and volume the ore table shows.
pub fn loadGlobalSettings(arena: std.mem.Allocator) !std.json.Value {
    const settings = &main_mod.g_global_settings;
    var value = try std.json.parseFromSliceLeaky(std.json.Value, arena, try settings.toJsonString(arena), .{});
    if (value != .object) return error.InvalidGlobalSettings;

    var rows = std.json.Array.init(arena);
    for (config_mod.DEFAULT_ORE_TABLE) |entry| {
        var row: std.json.ObjectMap = .empty;
        try row.put(arena, "name", .{ .string = entry.name });
        try row.put(arena, "category", .{ .string = entry.category });
        try row.put(arena, "volumeM3", .{ .float = entry.volumeM3 });
        try row.put(arena, "price", .{ .float = settings.orePrice(entry.name) orelse entry.price });
        try rows.append(.{ .object = row });
    }
    try value.object.put(arena, "oreTable", .{ .array = rows });
    return value;
}

/// The running app reloads these with the profile Save that follows.
pub fn saveGlobalSettings(arena: std.mem.Allocator, args: struct { json: []const u8 }) !void {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, args.json, .{});
    // Unknown fields include the ore table's display-only name, category and volume.
    const saved = try std.json.parseFromValueLeaky(config_mod.GlobalConfig.Wire, arena, value, .{ .ignore_unknown_fields = true });
    var settings = try config_mod.GlobalConfig.fromWire(saved, host.allocator());
    defer settings.deinit();

    // Changed by the app while the window was open, not by this form.
    const running = &main_mod.g_global_settings;
    settings.dialogX = running.dialogX;
    settings.dialogY = running.dialogY;
    try settings.mergeCharacterIds(running);

    try settings.save();
    applyRunOnStartup(settings.runOnStartup);
}

/// Previews only reach the running profile; editing another one waits for Save.
pub fn previewThumbnailConfig(_: std.mem.Allocator, args: struct { json: []const u8 }) !void {
    if (!host.editsLiveProfile()) return;
    try main_mod.applyThumbnailPreview(args.json);
}

pub fn testNotification(_: std.mem.Allocator, args: struct { json: []const u8 }) !void {
    try main_mod.showTestNotification(args.json);
}

const STARTUP_RUN_KEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const STARTUP_RUN_VALUE_NAME = "EVE-Maj Preview";

fn applyRunOnStartup(enabled: bool) void {
    if (!enabled) {
        var key: win32.HKEY = undefined;
        const open_result = win32.RegOpenKeyExA(win32.HKEY_CURRENT_USER, STARTUP_RUN_KEY, 0, win32.KEY_WRITE, &key);
        // Nothing to remove if the Run key can't even be opened.
        if (open_result != win32.ERROR_SUCCESS) return;
        defer _ = win32.RegCloseKey(key);
        const delete_result = win32.RegDeleteValueA(key, STARTUP_RUN_VALUE_NAME);
        if (delete_result != win32.ERROR_SUCCESS and delete_result != win32.ERROR_FILE_NOT_FOUND) {
            slog.warn("Failed to remove the startup registry value: error {}", .{delete_result});
        }
        return;
    }

    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = win32.selfExeDirPath(&exe_path_buf) catch |err| {
        slog.err("Failed to find the executable directory for startup registration: {}", .{err});
        return;
    };
    var command_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const command = std.fmt.bufPrintZ(&command_buf, "\"{s}\\eve-maj-preview.exe\"", .{exe_dir}) catch |err| {
        slog.err("Failed to build the startup command: {}", .{err});
        return;
    };

    var key: win32.HKEY = undefined;
    var disposition: win32.DWORD = undefined;
    const create_result = win32.RegCreateKeyExA(win32.HKEY_CURRENT_USER, STARTUP_RUN_KEY, 0, null, win32.REG_OPTION_NON_VOLATILE, win32.KEY_WRITE, null, &key, &disposition);
    if (create_result != win32.ERROR_SUCCESS) {
        slog.err("Failed to open the startup registry key: error {}", .{create_result});
        return;
    }
    defer _ = win32.RegCloseKey(key);

    const set_result = win32.RegSetValueExA(key, STARTUP_RUN_VALUE_NAME, 0, win32.REG_SZ, command.ptr, @intCast(command.len + 1));
    if (set_result != win32.ERROR_SUCCESS) {
        slog.err("Failed to set the startup registry value: error {}", .{set_result});
    }
}
