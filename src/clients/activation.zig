const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const log = @import("../log.zig");
const slog = log.scoped("activation");
const painter_mod = @import("../painter.zig");
const hotkeys_mod = @import("../hotkeys/manager.zig");
const Painter = painter_mod.Painter;

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

    // Update thumbnail states immediately so the active border shows without waiting for the event hook.
    updateThumbnailStatesAfterFocus(painter, source_hwnd);

    const thumbnail = painter.getThumbnailBySourceHwnd(source_hwnd) orelse return;
    thumbnail.last_click_time = win32.Ticks.now();

    // Dismiss any active notification with suppress_when_clicked set; must run after state is reconciled above.
    if (painter.dismissClickSuppressedNotifications(thumbnail)) {
        painter.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail after click-suppress clear: {}", .{err});
        };
        thumbnail.needs_render = false;
    }

    hotkeys_mod.syncFocusedCharacter(thumbnail.character_name, source_hwnd);
}

/// Updates thumbnail states immediately after focus change, since the Windows event hook may fire late.
fn updateThumbnailStatesAfterFocus(painter: *Painter, focused_hwnd: win32.HWND) void {
    // Bail if focus already changed, to avoid races during rapid cycling
    const current_foreground = win32.GetForegroundWindow();
    if (current_foreground != focused_hwnd) {
        slog.debug("Skipping updateThumbnailStatesAfterFocus - focus already changed (target={*}, current={*})", .{
            focused_hwnd,
            current_foreground,
        });
        return;
    }

    // Ensures only one thumbnail ends up active
    painter.reconcileThumbnailStates(focused_hwnd);

    // Rendering immediately avoids hotkey lag, but defers to the timer above a threshold to avoid blocking on rare bulk updates.
    const MAX_IMMEDIATE_RENDERS: usize = 4;
    painter.renderDirtyThumbnails(MAX_IMMEDIATE_RENDERS);
}
