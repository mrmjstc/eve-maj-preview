//! Calls that act on the running app: window positions, open clients, region selection, hotkey recording, and the window itself.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const patch = @import("../../config/patch.zig");
const main = @import("../../main.zig");
const scout_mod = @import("../../clients/scout.zig");
const painter_mod = @import("../../painter.zig");
const hotkeys = @import("../../hotkeys/manager.zig");
const monitors = @import("../../layout/monitors.zig");
const spaces = @import("../../layout/spaces.zig");
const region_select = @import("../tools/region_select.zig");
const host = @import("../host.zig");
const session = @import("../session.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog");

/// The thumbnail windows a region selection hid, to show again once it ends.
var g_region_select_hidden: std.ArrayList(win32.HWND) = .empty;

pub fn closeDialog(_: std.mem.Allocator) !void {
    host.close();
}

pub fn setAlwaysOnTop(_: std.mem.Allocator, args: struct { enabled: bool }) !void {
    host.setAlwaysOnTop(args.enabled);
}

/// `percent` 0 is "auto"; saved straight away, since it resizes the window rather than waiting for Save.
pub fn setDialogScale(_: std.mem.Allocator, args: struct { percent: u16 }) !struct { scale: f32 } {
    const percent = config.clampValue(config.GlobalConfig, "dialogScale", args.percent);
    const settings = &main.g_global_settings;
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
        if (!window.is_eve_client or scout_mod.isGenericCharacterName(window.character_name)) continue;
        try clients.append(arena, .{ .name = window.character_name, .started = if (win32.processStartTime(window.process_id)) |started| started.toU64() else 0 });
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

/// The first open, non-minimized client's game-area size, which thumbnails stretch to fit; null when there's none.
pub fn getClientSize(_: std.mem.Allocator) !?struct { width: i32, height: i32 } {
    const scout = scout_mod.g_scout_ptr orelse return null;
    for (scout.getWindows()) |window| {
        // A minimized window's client area reads as 0x0.
        if (!window.is_eve_client or win32.isWindowIconic(window.hwnd)) continue;
        var rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetClientRect(window.hwnd, &rect))) {
            slog.debug("Failed to read the client area of '{s}'", .{window.character_name});
            continue;
        }
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        if (width > 0 and height > 0) return .{ .width = width, .height = height };
    }
    return null;
}

/// Saves `name`'s live game-window position as where auto-move puts it.
pub fn setCharacterWindowPosition(_: std.mem.Allocator, args: struct { name: []const u8 }) !config.Position {
    const pos = try liveWindowPosition(args.name);
    try setWindowPositions(args.name, pos);
    return pos;
}

pub fn clearCharacterWindowPosition(_: std.mem.Allocator, args: struct { name: []const u8 }) !void {
    try setWindowPositions(args.name, null);
}

/// Every character gets `name`'s live game-window position.
pub fn setAllCharacterWindowPositions(_: std.mem.Allocator, args: struct { name: []const u8 }) !config.Position {
    const pos = try liveWindowPosition(args.name);
    try setWindowPositions(null, pos);
    return pos;
}

pub fn clearAllCharacterWindowPositions(_: std.mem.Allocator) !void {
    try setWindowPositions(null, null);
}

/// `region` is [x, y, width, height] to adjust, or null for a fresh drag; spaces other than `spaceId` show dashed, and empty labels keep the overlay's English text. The result arrives as a regionSelected event.
pub fn startRegionSelect(arena: std.mem.Allocator, args: struct {
    hide: bool = false,
    region: ?[4]i32 = null,
    spaceId: ?u32 = null,
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
    if (args.region) |region| {
        if (region[2] > 0 and region[3] > 0) request.edit_region = .{ .left = region[0], .top = region[1], .right = region[0] + region[2], .bottom = region[1] + region[3] };
    }
    setLabel(32, &request.labels.save, args.labels.save);
    setLabel(32, &request.labels.cancel, args.labels.cancel);
    setLabel(192, &request.labels.hint_new, args.labels.hintNew);
    setLabel(192, &request.labels.hint_edit, args.labels.hintEdit);
    setLabel(192, &request.labels.hint_confirm, args.labels.hintConfirm);
    comptime std.debug.assert(region_select.MAX_OTHER_REGIONS >= spaces.MAX_SPACES);
    var others: std.ArrayList(win32.RECT) = .empty;
    for (session.profile().thumbnailSpaces.items) |*space| {
        if (args.spaceId) |id| if (space.id == id) continue;
        try others.append(arena, spaces.rect(space) orelse continue);
    }

    if (request.hide_thumbnails) painter.hideVisibleThumbnails(host.allocator(), &g_region_select_hidden);
    const cursor = monitors.cursorMonitorBounds();
    const text_color = painter.config.thumbnail.characterNameColor | 0xFF000000;
    const label_font = painter.font_cache.characterNameFont(&painter.config.thumbnail, monitors.dpiForMonitor(cursor.monitor)) catch |err| blk: {
        slog.err("Failed to get font for region-select label: {}", .{err});
        break :blk null;
    };
    region_select.start(painter.instance, painter.config.accentColor, .{ .font = label_font, .color = text_color }, request.edit_region, others.items, request.labels, onRegionSelectFinished) catch |err| {
        onRegionSelectFinished();
        return err;
    };
    if (label_font) |font| {
        const labels = &request.labels;
        const line1 = region_select.labelText(if (request.edit_region != null) &labels.hint_edit else &labels.hint_new);
        painter.hint_box.show(painter.instance, font, text_color, line1, region_select.labelText(&labels.hint_confirm), cursor.bounds);
    }
}

/// Unregisters the app's hotkeys so the key being recorded doesn't fire; a bare Win press arrives as a winKeyCaptured event.
pub fn suspendHotkeysForRecording(_: std.mem.Allocator) !void {
    const manager = hotkeys.g_hotkey_manager_ptr orelse return;
    manager.dialogSuspendHotkeys();
}

pub fn resumeHotkeysAfterRecording(_: std.mem.Allocator) !void {
    const manager = hotkeys.g_hotkey_manager_ptr orelse return;
    const timer = main.g_timer_hwnd orelse return;
    manager.dialogResumeHotkeys(timer);
}

fn onRegionSelectFinished() void {
    defer {
        g_region_select_hidden.deinit(host.allocator());
        g_region_select_hidden = .empty;
    }
    const painter = painter_mod.g_painter_ptr orelse return;
    painter.showThumbnails(g_region_select_hidden.items);
    painter.hint_box.hide();
}

fn setLabel(comptime n: usize, field: *[n]u8, text: []const u8) void {
    if (text.len > 0) field.* = region_select.fixedText(n, text);
}

fn liveWindowPosition(character_name: []const u8) !config.Position {
    const scout = scout_mod.g_scout_ptr orelse return error.CharacterIsNotOpen;
    const window = scout.getHwndByName(character_name) orelse return error.CharacterIsNotOpen;
    // A minimized window sits at the off-screen parking spot, not a real position.
    if (win32.isWindowIconic(window)) return error.CharacterWindowIsMinimized;
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetWindowRect(window, &rect))) return error.WindowPositionUnavailable;
    return .{ .x = rect.left, .y = rect.top };
}

/// Saved at once for the running profile, like a drag; another profile's draft keeps it until Save.
fn setWindowPositions(character_name: ?[]const u8, pos: ?config.Position) !void {
    if (!session.editsDraft()) return main.g_store.setWindowPosition(character_name, pos);
    const draft = session.profile();
    try config.applyWindowPosition(draft, character_name, pos);
    patch.assignIds(config.Config, draft);
}
