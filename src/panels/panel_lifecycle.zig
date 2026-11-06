//! When the History, Map and Intel panels have a window: their `show` setting makes one, and the tray, a hotkey or the window's close button turns that off; main thread only.
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const panel_host = @import("panel_host.zig");
const log = @import("../log.zig");

const slog = log.Scoped("panel_lifecycle");

/// Creates or destroys the window to match the settings; `panel` points at a panel with `window` and `visibility` fields and `wantsWindow`, `createWindow` and `destroyWindow` methods.
pub fn sync(panel: anytype, context: panel_host.Context) void {
    const is_wanted = panel.wantsWindow(&context.store.live);
    if (is_wanted and panel.window == null) {
        panel.createWindow(context);
    } else if (!is_wanted and panel.window != null) {
        panel.destroyWindow();
        panel.visibility.release();
    }
}

/// Turns a visible panel off, else on and past its auto-hide; `panel` as for sync, with a `setShown` method too.
pub fn toggle(panel: anytype, context: panel_host.Context, is_visible: bool) void {
    if (is_visible) return close(panel, context.store);
    panel.setShown(context.store, true);
    panel.visibility.force();
    sync(panel, context);
}

/// Turns the panel's `show` setting off, as the window's close button does; `panel` as for toggle.
pub fn close(panel: anytype, store: *config_mod.ProfileStore) void {
    panel.setShown(store, false);
    panel.visibility.release();
    if (panel.window != null) panel.destroyWindow();
}

/// Keeps `created` in `slot`, its window linked to `owner`, or to itself where `slot` keeps it when null; logs a failure, naming the panel by `name`, and leaves `slot` null.
pub fn install(comptime Window: type, slot: *?Window, created: anyerror!Window, owner: ?*anyopaque, name: []const u8) void {
    slot.* = created catch |err| {
        slog.err("Failed to create the {s} window: {}", .{ name, err });
        return;
    };
    const window = &slot.*.?;
    window.panel.attachOwner(owner orelse window) catch |err| {
        slog.err("Failed to link the {s} window to its panel: {}", .{ name, err });
        window.deinit();
        slot.* = null;
    };
}

/// Where a panel's settings section, with x, y, width and height, puts its window.
pub fn windowRect(settings: anytype) win32.RECT {
    return .{ .left = settings.x, .top = settings.y, .right = settings.x + settings.width, .bottom = settings.y + settings.height };
}
