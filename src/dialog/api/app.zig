//! Calls that act on the running app: window positions, open clients, region selection, hotkey recording, and the window itself.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config_mod = @import("../../config.zig");
const main_mod = @import("../../main.zig");
const scout_mod = @import("../../clients/scout.zig");
const painter_mod = @import("../../painter.zig");
const hotkeys_mod = @import("../../hotkeys/manager.zig");
const region_select = @import("../../region_select.zig");
const host = @import("../host.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog");

pub fn closeDialog(_: std.mem.Allocator) !void {
    host.close();
}

pub fn setAlwaysOnTop(_: std.mem.Allocator, args: struct { enabled: bool }) !void {
    host.setAlwaysOnTop(args.enabled);
}

/// `percent` 0 is "auto"; saved straight away, since it resizes the window rather than waiting for Save.
pub fn setDialogScale(_: std.mem.Allocator, args: struct { percent: u16 }) !struct { scale: f32 } {
    const percent = config_mod.clampValue(config_mod.GlobalConfig, "dialogScale", args.percent);
    const settings = &main_mod.g_global_settings;
    settings.dialogScale = percent;
    settings.save() catch |err| slog.warn("Failed to save the dialog scale: {}", .{err});
    return .{ .scale = host.applyScale(percent) };
}

/// Logged-in clients, oldest process first, for populating characters and group members.
pub fn getOpenClients(arena: std.mem.Allocator) ![]const []const u8 {
    const scout = scout_mod.g_scout_ptr orelse return &.{};
    const Client = struct { name: []const u8, started: u64 };

    var clients: std.ArrayList(Client) = .empty;
    for (scout.getWindows()) |window| {
        if (scout_mod.isGenericCharacterName(window.character_name)) continue;
        try clients.append(arena, .{ .name = window.character_name, .started = processStartTime(window.hwnd) });
    }
    std.sort.pdq(Client, clients.items, {}, struct {
        /// An unknown start time (0) sorts last.
        fn lessThan(_: void, a: Client, b: Client) bool {
            if (a.started == 0) return false;
            if (b.started == 0) return true;
            return a.started < b.started;
        }
    }.lessThan);

    const names = try arena.alloc([]const u8, clients.items.len);
    for (clients.items, names) |client, *name| name.* = try arena.dupe(u8, client.name);
    return names;
}

/// Saves `name`'s live game-window position as where auto-move puts it.
pub fn setCharacterWindowPosition(arena: std.mem.Allocator, args: struct { name: []const u8 }) !config_mod.Position {
    const pos = try liveWindowPosition(args.name);
    try setWindowPositions(arena, args.name, pos);
    return pos;
}

pub fn clearCharacterWindowPosition(arena: std.mem.Allocator, args: struct { name: []const u8 }) !void {
    try setWindowPositions(arena, args.name, null);
}

/// Every character gets `name`'s live game-window position.
pub fn setAllCharacterWindowPositions(arena: std.mem.Allocator, args: struct { name: []const u8 }) !config_mod.Position {
    const pos = try liveWindowPosition(args.name);
    try setWindowPositions(arena, null, pos);
    return pos;
}

pub fn clearAllCharacterWindowPositions(arena: std.mem.Allocator) !void {
    try setWindowPositions(arena, null, null);
}

/// `region` is [x, y, width, height] to adjust, or null for a fresh drag; empty labels keep the overlay's English text.
/// The result arrives as a regionSelected event.
pub fn startRegionSelect(_: std.mem.Allocator, args: struct {
    hide: bool = false,
    region: ?[4]i32 = null,
    labels: struct {
        save: []const u8 = "",
        cancel: []const u8 = "",
        hintNew: []const u8 = "",
        hintEdit: []const u8 = "",
        hintConfirm: []const u8 = "",
    } = .{},
}) !void {
    const painter = painter_mod.g_painter_ptr orelse return error.AppNotReady;
    var request = region_select.Request{ .hide_thumbnails = args.hide };
    if (args.region) |r| {
        if (r[2] > 0 and r[3] > 0) request.edit_region = .{ .left = r[0], .top = r[1], .right = r[0] + r[2], .bottom = r[1] + r[3] };
    }
    setLabel(32, &request.labels.save, args.labels.save);
    setLabel(32, &request.labels.cancel, args.labels.cancel);
    setLabel(192, &request.labels.hint_new, args.labels.hintNew);
    setLabel(192, &request.labels.hint_edit, args.labels.hintEdit);
    setLabel(192, &request.labels.hint_confirm, args.labels.hintConfirm);
    painter.startRegionSelect(request);
}

/// Unregisters the app's hotkeys so the key being recorded doesn't fire; a bare Win press arrives as a winKeyCaptured event.
pub fn suspendHotkeysForRecording(_: std.mem.Allocator) !void {
    const manager = hotkeys_mod.g_hotkey_manager_ptr orelse return;
    manager.dialogSuspendHotkeys();
}

pub fn resumeHotkeysAfterRecording(_: std.mem.Allocator) !void {
    resumeHotkeys();
}

fn resumeHotkeys() void {
    const manager = hotkeys_mod.g_hotkey_manager_ptr orelse return;
    const timer = main_mod.g_timer_hwnd orelse return;
    manager.dialogResumeHotkeys(timer);
}

fn setLabel(comptime n: usize, field: *[n]u8, text: []const u8) void {
    if (text.len > 0) field.* = region_select.fixedText(n, text);
}

fn liveWindowPosition(character_name: []const u8) !config_mod.Position {
    const scout = scout_mod.g_scout_ptr orelse return error.CharacterIsNotOpen;
    const window = scout.getHwndByName(character_name) orelse return error.CharacterIsNotOpen;
    // A minimized window sits at the off-screen parking spot, not a real position.
    if (win32.isWindowIconic(window)) return error.CharacterWindowIsMinimized;
    var rect: win32.RECT = undefined;
    if (win32.GetWindowRect(window, &rect) == 0) return error.WindowPositionUnavailable;
    return .{ .x = rect.left, .y = rect.top };
}

fn setWindowPositions(arena: std.mem.Allocator, character_name: ?[]const u8, pos: ?config_mod.Position) !void {
    if (host.editsLiveProfile()) return main_mod.g_store.setWindowPosition(character_name, pos);
    // A profile the app isn't running only exists on disk.
    const name = host.editingProfile();
    var cfg = try config_mod.loadProfile(arena, name);
    try config_mod.applyWindowPosition(&cfg, character_name, pos);
    try config_mod.saveProfile(&cfg, arena, try config_mod.profilePath(arena, name));
}

/// 0 if it can't be read.
fn processStartTime(window: win32.HWND) u64 {
    var process_id: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(window, &process_id);
    if (process_id == 0) return 0;
    const process = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, process_id) orelse return 0;
    defer _ = win32.CloseHandle(process);
    var created: win32.FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 };
    var unused: win32.FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 };
    if (win32.GetProcessTimes(process, &created, &unused, &unused, &unused) == win32.FALSE) return 0;
    return created.toU64();
}
