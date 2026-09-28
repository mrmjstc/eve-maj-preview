const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const log = @import("../log.zig");
const slog = log.scoped("activation");
const painter_mod = @import("../painter.zig");
const hotkeys_mod = @import("../hotkeys/manager.zig");

var g_original_animation_setting: ?i32 = null;

fn getMinimizeAnimation() ?i32 {
    var anim_info = win32.ANIMATIONINFO{ .cbSize = @sizeOf(win32.ANIMATIONINFO), .iMinAnimate = 0 };
    if (!win32.toBool(win32.SystemParametersInfoA(win32.SPI_GETANIMATION, @sizeOf(win32.ANIMATIONINFO), &anim_info, 0))) return null;
    return anim_info.iMinAnimate;
}

fn setMinimizeAnimation(value: i32) void {
    var anim_info = win32.ANIMATIONINFO{ .cbSize = @sizeOf(win32.ANIMATIONINFO), .iMinAnimate = value };
    _ = win32.SystemParametersInfoA(win32.SPI_SETANIMATION, @sizeOf(win32.ANIMATIONINFO), &anim_info, 0);
}

/// Temporarily disable Windows minimize/restore animations
fn turnOffAnimation() void {
    const current = getMinimizeAnimation() orelse return;
    if (g_original_animation_setting == null) g_original_animation_setting = current;
    if (current != 0) setMinimizeAnimation(0);
}

/// Restore Windows minimize/restore animations to original setting
fn restoreAnimation() void {
    const original = g_original_animation_setting orelse return;
    const current = getMinimizeAnimation() orelse return;
    if (current != original) setMinimizeAnimation(original);
}

/// Brings an EVE client to the foreground, restoring it if minimized; every thumbnail click and cycle hotkey ends here.
pub fn activate(source_hwnd: win32.HWND) void {
    if (!win32.isWindow(source_hwnd)) return;
    const painter = painter_mod.g_painter_ptr orelse return;

    var placement: win32.WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (!win32.toBool(win32.GetWindowPlacement(source_hwnd, &placement))) {
        slog.err("Failed to get window placement", .{});
        return;
    }
    const was_minimized = placement.showCmd == win32.SW_SHOWMINIMIZED;

    focus_grant.forceSetForegroundWindow(source_hwnd);

    // SW_RESTORE returns a maximized window to maximized, so no need to track was_maximized separately.
    if (was_minimized) {
        switch (painter.config.interaction.animationStyle) {
            .NoAnimation => {
                turnOffAnimation();
                _ = win32.ShowWindowAsync(source_hwnd, win32.SW_RESTORE);
                restoreAnimation();
            },
            .OriginalAnimation => {
                _ = win32.ShowWindowAsync(source_hwnd, win32.SW_RESTORE);
            },
        }
    }

    // Handled now rather than when the foreground hook fires, which can be late, so the active border shows at once.
    _ = painter.onClientFocused(source_hwnd);

    if (painter.getThumbnailBySourceHwnd(source_hwnd)) |thumbnail| {
        thumbnail.last_click_time = win32.Ticks.now();
        // After focus is reconciled above, since that decides which notifications a click dismisses.
        _ = painter.dismissClickSuppressedNotifications(thumbnail);
        // Even if focus hasn't landed yet (a restored client can lag), so rapid cycling moves on from this one.
        hotkeys_mod.syncFocusedCharacter(thumbnail.character_name, source_hwnd);
    }

    // Rendering now avoids hotkey lag; past a few, the rest wait for the timer so a rare bulk update can't block.
    const MAX_IMMEDIATE_RENDERS: usize = 4;
    painter.renderDirtyThumbnails(MAX_IMMEDIATE_RENDERS);
}
