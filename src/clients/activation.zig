//! Bringing an EVE client to the foreground, where every thumbnail click and cycle hotkey ends up.
const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const painter_mod = @import("../painter.zig");
const hotkeys = @import("../hotkeys/manager.zig");
const log = @import("../log.zig");

const slog = log.scoped("activation");

fn getMinimizeAnimation() ?i32 {
    var anim_info = win32.ANIMATIONINFO{ .cbSize = @sizeOf(win32.ANIMATIONINFO), .iMinAnimate = 0 };
    if (!win32.toBool(win32.SystemParametersInfoA(win32.SPI_GETANIMATION, @sizeOf(win32.ANIMATIONINFO), &anim_info, 0))) return null;
    return anim_info.iMinAnimate;
}

fn setMinimizeAnimation(value: i32) void {
    var anim_info = win32.ANIMATIONINFO{ .cbSize = @sizeOf(win32.ANIMATIONINFO), .iMinAnimate = value };
    _ = win32.SystemParametersInfoA(win32.SPI_SETANIMATION, @sizeOf(win32.ANIMATIONINFO), &anim_info, 0);
}

/// Restores the client first if it's minimized.
pub fn activate(source_hwnd: win32.HWND) void {
    if (!win32.isWindow(source_hwnd)) return;
    const painter = painter_mod.g_painter_ptr orelse return;

    var placement: win32.WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (!win32.toBool(win32.GetWindowPlacement(source_hwnd, &placement))) {
        slog.err("Failed to get the placement of window {*}", .{source_hwnd});
        return;
    }
    const was_minimized = placement.showCmd == win32.SW_SHOWMINIMIZED;

    focus_grant.forceSetForegroundWindow(source_hwnd);

    // SW_RESTORE returns a maximized window to maximized, so no need to track was_maximized separately.
    if (was_minimized) {
        switch (painter.config.interaction.animationStyle) {
            .NoAnimation => {
                const user_setting = getMinimizeAnimation() orelse 0;
                if (user_setting != 0) setMinimizeAnimation(0);
                _ = win32.ShowWindowAsync(source_hwnd, win32.SW_RESTORE);
                if (user_setting != 0) setMinimizeAnimation(user_setting);
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
        hotkeys.syncFocusedCharacter(thumbnail.character_name, source_hwnd);
    }

    // Rendering now avoids hotkey lag; past a few, the rest wait for the timer so a rare bulk update can't block.
    const max_immediate_renders: usize = 4;
    painter.renderDirtyThumbnails(max_immediate_renders);
}
