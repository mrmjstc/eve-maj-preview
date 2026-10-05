//! Pushes app-side changes into the open configuration window; each is a no-op while it's closed. Main thread only.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const region_select = @import("tools/region_select.zig");
const host = @import("host.zig");
const log = @import("../log.zig");

const slog = log.scoped("dialog");

/// A region-select drag finished, was cancelled, or was too small to use.
pub fn regionSelected(status: region_select.Status, rect: win32.RECT) void {
    emit("regionSelected", .{
        .cancelled = status != .success,
        .tooSmall = status == .too_small,
        .x = rect.left,
        .y = rect.top,
        .width = win32.rectWidth(rect),
        .height = win32.rectHeight(rect),
    });
}

/// A bare Win key was pressed while the dialog was recording a hotkey, with these modifiers held.
pub fn winKeyCaptured(modifiers: u32) void {
    emit("winKeyCaptured", .{
        .ctrl = modifiers & vk.MOD_CONTROL != 0,
        .alt = modifiers & vk.MOD_ALT != 0,
        .shift = modifiers & vk.MOD_SHIFT != 0,
    });
}

/// The app changed the running profile itself (a drag, the tray, an assign key), as edit ops (see config/patch.zig).
/// Wired up as config/store.zig's g_on_runtime_change.
pub fn liveProfileChanged(ops_json: []const u8) void {
    if (!host.isOpen() or !host.editsLiveProfile()) return;
    emitJson("liveProfileChanged", ops_json);
}

/// The app now runs `profile_name`, so previews target it.
pub fn profileSwitched(profile_name: []const u8) void {
    emit("profileSwitched", .{ .name = profile_name });
}

fn emit(comptime name: []const u8, payload: anytype) void {
    if (!host.isOpen()) return;
    const allocator = host.allocator();
    const json = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch |err| {
        slog.err("Failed to serialize {s} event: {}", .{ name, err });
        return;
    };
    defer allocator.free(json);
    emitJson(name, json);
}

fn emitJson(comptime name: []const u8, json: []const u8) void {
    const allocator = host.allocator();
    const script = allocator.printSentinel("window.onAppEvent && window.onAppEvent(\"" ++ name ++ "\", {s});", .{json}, 0) catch |err| {
        slog.err("Failed to build {s} event script: {}", .{ name, err });
        return;
    };
    defer allocator.free(script);
    host.runScript(script);
}
