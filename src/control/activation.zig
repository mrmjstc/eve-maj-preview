//! Bringing an EVE client to the foreground, where every thumbnail click and cycle hotkey ends up.
const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const app_mod = @import("../app.zig");
const animation = @import("../clients/animation.zig");
const focus = @import("focus.zig");
const log = @import("../log.zig");

const App = app_mod.App;
const slog = log.Scoped("activation");

/// Restores the client first if it's minimized.
pub fn activate(app: *App, source_hwnd: win32.HWND) void {
    if (!win32.isWindow(source_hwnd)) return;
    const thumbnail_set = app.rebuilt.thumbnail_set orelse return;

    var placement: win32.WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (!win32.toBool(win32.GetWindowPlacement(source_hwnd, &placement))) {
        slog.err("Failed to get the placement of window {*}", .{source_hwnd});
        return;
    }
    const was_minimized = placement.showCmd == win32.SW_SHOWMINIMIZED;

    focus_grant.forceSetForegroundWindow(source_hwnd);

    // SW_RESTORE returns a maximized window to maximized, so no need to track was_maximized separately.
    if (was_minimized) animation.showClient(thumbnail_set.config, source_hwnd, win32.SW_RESTORE);

    // Handled now rather than when the foreground hook fires, which can be late, so the active border shows at once.
    _ = focus.onClientFocused(app, source_hwnd);

    // After focus is reconciled above, since that decides which notifications a click dismisses.
    app.persistent.roster.recordClick(source_hwnd, win32.Ticks.now());

    // Rendering now avoids hotkey lag; past a few, the rest wait for the timer so a rare bulk update can't block.
    const max_immediate_renders: usize = 4;
    thumbnail_set.renderDirtyThumbnails(max_immediate_renders);
}
