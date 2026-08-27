const std = @import("std");
const win32 = @import("win32.zig");
const types = @import("types.zig");
const log = @import("log.zig");
const slog = log.scoped("input");
const painter_mod = @import("painter.zig");
const ThumbnailWindow = painter_mod.ThumbnailWindow;
const Painter = painter_mod.Painter;
const main_mod = @import("main.zig");

pub var g_painter_ptr: ?*Painter = null;

// Click state for mouse-up triggered clicks (left-click only; right-click uses DragState)
const ClickState = struct {
    pending: bool = false,
    hwnd: ?win32.HWND = null,
    source_hwnd: ?win32.HWND = null,
    shift_pressed: bool = false,
};

var g_click_state: ClickState = .{};

const DragState = struct {
    is_dragging: bool = false,
    hwnd: ?win32.HWND = null,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
};

var g_drag_state: DragState = .{};

/// Whether this thumbnail (by either its overlay or text-overlay hwnd) is the one currently being dragged.
pub fn isThumbnailDragging(thumbnail: *const ThumbnailWindow) bool {
    return g_drag_state.is_dragging and (g_drag_state.hwnd == thumbnail.hwnd or g_drag_state.hwnd == thumbnail.text_hwnd);
}

const SnapPosition = struct { x: i32, y: i32 };

var g_original_animation_setting: ?i32 = null;

/// Temporarily disable Windows minimize/restore animations
fn turnOffAnimation() void {
    var anim_info = win32.ANIMATIONINFO{
        .cbSize = @sizeOf(win32.ANIMATIONINFO),
        .iMinAnimate = 0,
    };

    if (win32.toBool(win32.SystemParametersInfoA(
        win32.SPI_GETANIMATION,
        @sizeOf(win32.ANIMATIONINFO),
        &anim_info,
        0,
    ))) {
        if (g_original_animation_setting == null) {
            g_original_animation_setting = anim_info.iMinAnimate;
        }

        if (anim_info.iMinAnimate != 0) {
            anim_info.iMinAnimate = 0;
            _ = win32.SystemParametersInfoA(
                win32.SPI_SETANIMATION,
                @sizeOf(win32.ANIMATIONINFO),
                &anim_info,
                0,
            );
        }
    }
}

/// Restore Windows minimize/restore animations to original setting
fn restoreAnimation() void {
    if (g_original_animation_setting) |original| {
        var anim_info = win32.ANIMATIONINFO{
            .cbSize = @sizeOf(win32.ANIMATIONINFO),
            .iMinAnimate = 0,
        };

        if (win32.toBool(win32.SystemParametersInfoA(
            win32.SPI_GETANIMATION,
            @sizeOf(win32.ANIMATIONINFO),
            &anim_info,
            0,
        ))) {
            if (anim_info.iMinAnimate != original) {
                anim_info.iMinAnimate = original;
                _ = win32.SystemParametersInfoA(
                    win32.SPI_SETANIMATION,
                    @sizeOf(win32.ANIMATIONINFO),
                    &anim_info,
                    0,
                );
            }
        }
    }
}

pub fn forceSetForegroundWindow(target_hwnd: win32.HWND) void {
    _ = win32.SetForegroundWindow(target_hwnd);
    _ = win32.SetFocus(target_hwnd);
}

/// Activates and focuses the EVE client window when its thumbnail is clicked, handling minimized/maximized states.
pub fn handleThumbnailClick(source_hwnd: win32.HWND) void {
    const config = &main_mod.g_config;
    handleThumbnailClickWithAnimation(source_hwnd, config.interaction.animationStyle);
}

fn handleThumbnailClickWithAnimation(source_hwnd: win32.HWND, animation_style: types.AnimationStyle) void {
    if (!win32.isWindow(source_hwnd)) {
        return;
    }

    // Get the current window placement to preserve maximized state
    var placement: win32.WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (!win32.toBool(win32.GetWindowPlacement(source_hwnd, &placement))) {
        slog.err("Failed to get window placement", .{});
        return;
    }

    const was_minimized = (placement.showCmd == win32.SW_SHOWMINIMIZED);

    forceSetForegroundWindow(source_hwnd);

    // SW_RESTORE returns a maximized window to maximized, so no need to track was_maximized separately.
    if (was_minimized) {
        switch (animation_style) {
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
    updateThumbnailStatesAfterFocus(source_hwnd);

    // Dismiss any active notification with suppress_when_clicked set; must run after state is reconciled above.
    if (g_painter_ptr) |painter| {
        if (painter.getThumbnailBySourceHwnd(source_hwnd)) |thumbnail| {
            thumbnail.last_click_time = win32.GetTickCount64();

            if (painter.dismissClickSuppressedNotifications(thumbnail)) {
                painter.renderThumbnail(thumbnail) catch |err| {
                    slog.err("Failed to render thumbnail after click-suppress clear: {}", .{err});
                };
                thumbnail.needs_render = false;
            }
        }
    }

    updateHotkeyCyclePosition(source_hwnd);
}

const TrackedHotkey = struct {
    swallow_release: bool,
    synthetic: bool,
    hotkey_id: c_int,
    repeat_while_held: bool,
    first_press_tick: u64,
    last_repeat_tick: u64,
};

const HOLD_POLL_TIMER_ID: usize = 2;
const HOLD_POLL_INTERVAL_MS: win32.UINT = 50;
const HOLD_REPEAT_DELAY_MS: u64 = 400;
const HOLD_REPEAT_INTERVAL_MS: u64 = 50;

var g_hotkey_tracked: std.AutoHashMap(u32, TrackedHotkey) = undefined;
var g_hotkey_tracking_initialized = false;
var g_hotkey_release_hook: ?win32.HHOOK = null;
var g_hold_poll_timer_armed = false;
var g_synthetic_down: [256]bool = [_]bool{false} ** 256;

fn ensureHotkeyTrackingInit(allocator: std.mem.Allocator) void {
    if (g_hotkey_tracking_initialized) return;
    g_hotkey_tracked = std.AutoHashMap(u32, TrackedHotkey).init(allocator);
    g_hotkey_tracking_initialized = true;
}

fn setSyntheticDown(vk_code: u32, down: bool) void {
    if (vk_code > 0 and vk_code < g_synthetic_down.len) {
        g_synthetic_down[vk_code] = down;
    }
}

fn wasSyntheticDown(vk_code: u32) bool {
    if (vk_code > 0 and vk_code < g_synthetic_down.len) return g_synthetic_down[vk_code];
    return false;
}

fn anySyntheticRepeatTracked() bool {
    var it = g_hotkey_tracked.valueIterator();
    while (it.next()) |tracked| {
        if (tracked.synthetic and tracked.repeat_while_held) return true;
    }
    return false;
}

fn holdPollTimerProc(hwnd: win32.HWND, msg: win32.UINT, id_event: usize, dw_time: win32.DWORD) callconv(.c) void {
    _ = msg;
    _ = id_event;
    _ = dw_time;
    pollHeldHotkeys(hwnd);
}

fn startHoldPollTimer() void {
    if (g_hold_poll_timer_armed) return;
    const hwnd = main_mod.g_timer_hwnd orelse return;
    if (win32.SetTimer(hwnd, HOLD_POLL_TIMER_ID, HOLD_POLL_INTERVAL_MS, @ptrCast(&holdPollTimerProc)) == 0) {
        slog.warn("Failed to start synthetic-hotkey hold poll timer", .{});
        return;
    }
    g_hold_poll_timer_armed = true;
}

fn stopHoldPollTimer() void {
    if (!g_hold_poll_timer_armed) return;
    if (main_mod.g_timer_hwnd) |hwnd| {
        _ = win32.KillTimer(hwnd, HOLD_POLL_TIMER_ID);
    }
    g_hold_poll_timer_armed = false;
}

fn stopHoldPollTimerIfIdle() void {
    if (!anySyntheticRepeatTracked()) stopHoldPollTimer();
}

/// Re-fires held synthetic hotkeys, which get no OS auto-repeat WM_HOTKEY the way physical keys do.
fn pollHeldHotkeys(hwnd: win32.HWND) void {
    if (!g_hotkey_tracking_initialized) return;
    if (g_hotkey_tracked.count() == 0) {
        stopHoldPollTimer();
        return;
    }

    const now = win32.GetTickCount64();
    // Hashmap removal mid-iteration is unsafe, so releases are batched and applied after the loop.
    var remove_buf: [32]u32 = undefined;
    var remove_n: usize = 0;

    var it = g_hotkey_tracked.iterator();
    while (it.next()) |kv| {
        const vk = kv.key_ptr.*;
        const tracked = kv.value_ptr;

        if (!win32.isKeyDown(@intCast(vk))) {
            if (remove_n < remove_buf.len) {
                remove_buf[remove_n] = vk;
                remove_n += 1;
            }
            continue;
        }

        if (!tracked.synthetic or !tracked.repeat_while_held) continue;
        if (now - tracked.first_press_tick < HOLD_REPEAT_DELAY_MS) continue;
        if (tracked.last_repeat_tick != 0 and now - tracked.last_repeat_tick < HOLD_REPEAT_INTERVAL_MS) continue;

        tracked.last_repeat_tick = now;
        _ = win32.PostMessageA(hwnd, win32.WM_HOTKEY, @intCast(tracked.hotkey_id), win32.hotkeyLparamFromVk(vk));
    }

    for (remove_buf[0..remove_n]) |vk| {
        setSyntheticDown(vk, false);
        _ = g_hotkey_tracked.remove(vk);
    }
    stopHoldPollTimerIfIdle();
}

/// Marks vk_code down to distinguish a repeat WM_HOTKEY from a new press; swallow-on-release is decided later in markHotkeySwallowRelease.
pub fn trackHotkeyPress(allocator: std.mem.Allocator, vk_code: u32, hotkey_id: c_int, repeat_while_held: bool) bool {
    // Mouse-button hotkeys route through here with lparam=0.
    if (vk_code == 0) return true;
    ensureHotkeyTrackingInit(allocator);

    const gop = g_hotkey_tracked.getOrPut(vk_code) catch |err| {
        slog.warn("Failed to track hotkey press for vk 0x{X}: {}", .{ vk_code, err });
        return true;
    };
    if (gop.found_existing) return false;

    const synthetic = wasSyntheticDown(vk_code);
    gop.value_ptr.* = .{
        .swallow_release = false,
        .synthetic = synthetic,
        .hotkey_id = hotkey_id,
        .repeat_while_held = repeat_while_held,
        .first_press_tick = win32.GetTickCount64(),
        .last_repeat_tick = 0,
    };
    if (g_hotkey_release_hook == null) installHotkeyReleaseHook();
    if (synthetic and repeat_while_held) startHoldPollTimer();
    return true;
}

/// Arms release-swallowing for vk_code once its action has moved focus, so the previously-focused client still believes the key is held.
pub fn markHotkeySwallowRelease(vk_code: u32) void {
    if (vk_code == 0) return;
    if (!g_hotkey_tracking_initialized) return;
    if (g_hotkey_tracked.getPtr(vk_code)) |tracked| tracked.swallow_release = true;
}

fn installHotkeyReleaseHook() void {
    const hmod = win32.GetModuleHandleA(null);
    g_hotkey_release_hook = win32.SetWindowsHookExA(win32.WH_KEYBOARD_LL, lowLevelHotkeyProc, hmod, 0);
    if (g_hotkey_release_hook == null) {
        slog.err("Failed to install low-level keyboard release hook", .{});
        return;
    }
    slog.debug("Low-level keyboard release hook installed", .{});
}

/// Clear all tracked keys and uninstall the hook. Safe to call even if nothing was tracked.
pub fn uninstallHotkeyReleaseHook() void {
    if (!g_hotkey_tracking_initialized) return;
    g_hotkey_tracked.clearRetainingCapacity();
    @memset(&g_synthetic_down, false);
    stopHoldPollTimer();
    if (g_hotkey_release_hook) |hook| {
        _ = win32.UnhookWindowsHookEx(hook);
        g_hotkey_release_hook = null;
        slog.debug("Low-level keyboard release hook removed", .{});
    }
}

/// Frees g_hotkey_tracked; call only once at true process shutdown, never from a reload path that may track again.
pub fn deinitHotkeyTracking() void {
    if (!g_hotkey_tracking_initialized) return;
    stopHoldPollTimer();
    g_hotkey_tracked.deinit();
    g_hotkey_tracking_initialized = false;
}

fn lowLevelHotkeyProc(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    if (nCode == win32.HC_ACTION) {
        const info = win32.lparamToPtr(win32.KBDLLHOOKSTRUCT, lParam);
        const synthetic = (info.flags & win32.LLKHF_INJECTED) != 0;

        if (wParam == win32.WM_KEYDOWN or wParam == win32.WM_SYSKEYDOWN) {
            setSyntheticDown(info.vkCode, synthetic);
        } else if (wParam == win32.WM_KEYUP or wParam == win32.WM_SYSKEYUP) {
            setSyntheticDown(info.vkCode, false);
            // Synthetic key-ups must clear tracking too, or the hotkey stays stuck "held".
            if (g_hotkey_tracking_initialized) {
                if (g_hotkey_tracked.fetchRemove(info.vkCode)) |entry| {
                    stopHoldPollTimerIfIdle();
                    if (entry.value.swallow_release) {
                        return 1;
                    }
                }
            }
        }
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}

/// Resolves the thumbnail under the cursor, polled on demand since hotkey presses carry no SOURCE_HWND message.
pub fn resolveThumbnailUnderCursor() ?*ThumbnailWindow {
    const painter = g_painter_ptr orelse return null;

    var pt: win32.POINT = undefined;
    if (!win32.toBool(win32.GetCursorPos(&pt))) return null;

    const hwnd_at_cursor = win32.WindowFromPoint(pt) orelse return null;
    const source_hwnd = win32.GetPropA(hwnd_at_cursor, "SOURCE_HWND") orelse return null;

    return painter.getThumbnailBySourceHwnd(source_hwnd);
}

/// Toggles character exclusion from hotkey cycling on Shift+Click, with visual feedback via a semi-transparent overlay.
pub fn handleThumbnailShiftClick(source_hwnd: win32.HWND) void {
    const painter = g_painter_ptr orelse return;
    const hotkey_manager = painter_mod.g_hotkey_manager_ptr orelse return;

    if (!painter.config.exclusion.enableShiftClickExclude) {
        // Exclusion disabled: fall back to a plain click instead of swallowing the input
        handleThumbnailClick(source_hwnd);
        return;
    }

    if (painter.getThumbnailBySourceHwnd(source_hwnd)) |thumbnail| {
        const char_name = thumbnail.character_name;

        // Toggles exclusion in every group containing this character, or a group-independent list if it's in none.
        hotkey_manager.toggleCharacterExclusion(char_name);

        thumbnail.is_excluded_from_cycle = hotkey_manager.isCharacterExcluded(char_name);

        if (thumbnail.is_excluded_from_cycle and painter.config.exclusion.autoMinimizeExcluded) {
            _ = win32.ShowWindowAsync(source_hwnd, win32.SW_FORCEMINIMIZE);
        }

        const notification_text = if (thumbnail.is_excluded_from_cycle) "Excluded" else "Included";

        painter.pushNotification(thumbnail, .{
            .text = painter.allocator.dupe(u8, notification_text) catch {
                slog.err("Failed to allocate notification text", .{});
                return;
            },
            .notification_type = .Generic,
            .start_time = win32.GetTickCount64(),
            .duration_ms = 5000,
            .suppress_when_focused = false,
            .suppress_when_clicked = false,
        });

        painter.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail after exclusion toggle: {}", .{err});
        };

        slog.info("Toggled cycle exclusion for {s}: {s}", .{
            char_name,
            if (thumbnail.is_excluded_from_cycle) "Excluded" else "Included",
        });
    }
}

/// Lets cycling resume from a manually-selected character's position
fn updateHotkeyCyclePosition(focused_hwnd: win32.HWND) void {
    const painter = g_painter_ptr orelse return;
    const hotkey_manager = painter_mod.g_hotkey_manager_ptr orelse return;

    // Painter's lookup helper is O(1) and includes safety checks
    if (painter.getThumbnailBySourceHwnd(focused_hwnd)) |thumbnail| {
        hotkey_manager.updateFocusedCharacter(thumbnail.character_name);
    }
}

/// Updates thumbnail states immediately after focus change, since the Windows event hook may fire late.
fn updateThumbnailStatesAfterFocus(focused_hwnd: win32.HWND) void {
    const painter = g_painter_ptr orelse return;

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

/// Start dragging a window (thumbnail or text overlay)
fn startDrag(hwnd: win32.HWND, lParam: win32.LPARAM) void {
    if (g_painter_ptr) |painter| {
        if (!painter.config.interaction.enableDragging) {
            return;
        }
    }

    const x = @as(i16, @truncate(lParam & 0xFFFF));
    const y = @as(i16, @truncate((lParam >> 16) & 0xFFFF));

    g_drag_state.is_dragging = true;
    g_drag_state.hwnd = hwnd;
    g_drag_state.offset_x = x;
    g_drag_state.offset_y = y;

    if (g_painter_ptr) |painter| {
        if (painter.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| {
            painter.renderThumbnail(thumbnail) catch |err| {
                slog.err("Failed to render dragging thumbnail for {s}: {}", .{ thumbnail.character_name, err });
            };
            painter.showGhostOverlay(thumbnail.character_name);
        }
    }

    _ = win32.SetCapture(hwnd);
}

/// End dragging and save the thumbnail position
fn endDrag(hwnd: win32.HWND, thumbnail_hwnd: win32.HWND) void {
    if (g_drag_state.is_dragging and g_drag_state.hwnd == hwnd) {
        // Cleared before rendering so effectiveRenderState sees the drag as already over.
        g_drag_state.is_dragging = false;
        g_drag_state.hwnd = null;
        _ = win32.ReleaseCapture();

        if (g_painter_ptr) |painter| {
            if (painter.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| {
                painter.renderThumbnail(thumbnail) catch |err| {
                    slog.err("Failed to render thumbnail after drag for {s}: {}", .{ thumbnail.character_name, err });
                };
            }

            painter.hideGhostOverlay();

            // Ctrl held during drag means all thumbnails moved together
            const ctrl_pressed = win32.isCtrlPressed();
            if (ctrl_pressed) {
                for (painter.thumbnails.items) |*saved_thumbnail| {
                    painter.saveThumbnailPosition(saved_thumbnail.hwnd);
                }
            } else {
                painter.saveThumbnailPosition(thumbnail_hwnd);
            }
        }
    }
}

/// Handles mouse move during drag; thumbnail and text-overlay windows are linked and moved together.
fn handleDrag(hwnd: win32.HWND, lParam: win32.LPARAM) void {
    if (!g_drag_state.is_dragging or g_drag_state.hwnd != hwnd) return;

    if (!win32.isWindow(hwnd)) {
        slog.warn("Window {*} became invalid during drag operation, canceling drag", .{hwnd});
        g_drag_state.is_dragging = false;
        g_drag_state.hwnd = null;
        _ = win32.ReleaseCapture();

        if (g_painter_ptr) |painter| {
            painter.hideGhostOverlay();
        }
        return;
    }

    const cursor_x = @as(i16, @truncate(lParam & 0xFFFF));
    const cursor_y = @as(i16, @truncate((lParam >> 16) & 0xFFFF));

    var rect: win32.RECT = undefined;
    _ = win32.GetWindowRect(hwnd, &rect);

    const new_x = rect.left + cursor_x - g_drag_state.offset_x;
    const new_y = rect.top + cursor_y - g_drag_state.offset_y;

    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;

    const ctrl_pressed = win32.isCtrlPressed();

    if (ctrl_pressed) {
        // Disable snapping when moving all thumbnails - use raw delta
        const delta_x = new_x - rect.left;
        const delta_y = new_y - rect.top;

        if (g_painter_ptr) |painter| {
            for (painter.thumbnails.items) |thumbnail| {
                if (!win32.isWindow(thumbnail.hwnd) or !win32.isWindow(thumbnail.text_hwnd)) {
                    continue;
                }

                var thumb_rect: win32.RECT = undefined;
                _ = win32.GetWindowRect(thumbnail.hwnd, &thumb_rect);

                const thumb_width = thumb_rect.right - thumb_rect.left;
                const thumb_height = thumb_rect.bottom - thumb_rect.top;
                const new_thumb_x = thumb_rect.left + delta_x;
                const new_thumb_y = thumb_rect.top + delta_y;

                _ = win32.SetWindowPos(thumbnail.hwnd, win32.HWND_NOTOPMOST, new_thumb_x, new_thumb_y, thumb_width, thumb_height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                _ = win32.SetWindowPos(thumbnail.text_hwnd, win32.HWND_TOPMOST, new_thumb_x, new_thumb_y, thumb_width, thumb_height, win32.SWP_NOACTIVATE);
            }
        }
    } else {
        // Apply snapping only when dragging single thumbnail
        const snapped = applySnapping(new_x, new_y, width, height, hwnd);

        if (getLinkedWindow(hwnd)) |other_hwnd| {
            // Z-order is keyed by identity (text overlay always TOPMOST above thumbnail), not by which window was grabbed, or the live thumbnail could hide the name/border until refocus.
            const dragged = if (g_painter_ptr) |painter| painter.getThumbnailByOverlayHwnd(hwnd) else null;
            const thumb_hwnd = if (dragged) |t| t.hwnd else hwnd;
            const text_hwnd = if (dragged) |t| t.text_hwnd else other_hwnd;
            _ = win32.SetWindowPos(thumb_hwnd, win32.HWND_NOTOPMOST, snapped.x, snapped.y, width, height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
            _ = win32.SetWindowPos(text_hwnd, win32.HWND_TOPMOST, snapped.x, snapped.y, width, height, win32.SWP_NOACTIVATE);
        }
    }
}

/// Returns the linked window stored in GWLP_USERDATA, or null if none is valid.
fn getLinkedWindow(hwnd: win32.HWND) ?win32.HWND {
    const linked_ptr = win32.GetWindowLongPtrA(hwnd, win32.GWLP_USERDATA);
    const linked_hwnd = win32.userDataToHwnd(linked_ptr);

    if (linked_hwnd) |hwnd_val| {
        if (win32.isWindow(hwnd_val)) {
            return hwnd_val;
        }
        slog.debug("Linked window handle {*} is no longer valid", .{hwnd_val});
    }

    return null;
}

fn applyScreenEdgeSnapping(x: i32, y: i32, width: i32, height: i32, threshold: i32, dragging_hwnd: win32.HWND) SnapPosition {
    var snapped_x = x;
    var snapped_y = y;

    const right = x + width;
    const bottom = y + height;

    // GetSystemMetrics(SM_CXSCREEN/CYSCREEN) only reports the primary monitor, so snapping uses the bounds of the monitor nearest the dragged window instead, falling back to primary metrics if that lookup fails.
    var bounds = win32.RECT{
        .left = 0,
        .top = 0,
        .right = win32.GetSystemMetrics(win32.SM_CXSCREEN),
        .bottom = win32.GetSystemMetrics(win32.SM_CYSCREEN),
    };
    if (win32.MonitorFromWindow(dragging_hwnd, win32.MONITOR_DEFAULTTONEAREST)) |monitor| {
        var info = win32.MONITORINFO{ .cbSize = @sizeOf(win32.MONITORINFO), .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
        if (win32.GetMonitorInfoA(monitor, &info) != win32.FALSE) {
            bounds = info.rcMonitor;
        }
    }

    if (@abs(x - bounds.left) < threshold) {
        snapped_x = bounds.left;
    }
    if (@abs(right - bounds.right) < threshold) {
        snapped_x = bounds.right - width;
    }
    if (@abs(y - bounds.top) < threshold) {
        snapped_y = bounds.top;
    }
    if (@abs(bottom - bounds.bottom) < threshold) {
        snapped_y = bounds.bottom - height;
    }

    return .{ .x = snapped_x, .y = snapped_y };
}

/// Updates `snapped_x`/`snapped_y` toward the nearest edge of `other_rect` if closer than the current best (`min_x_dist`/`min_y_dist`), which callers seed with the threshold. Shared by live-thumbnail and ghost-position edge snapping.
fn snapAxesToRect(snapped_x: *i32, snapped_y: *i32, width: i32, height: i32, other_rect: win32.RECT, min_x_dist: *i32, min_y_dist: *i32) void {
    // Recalculated per call, since snapped_x/y may have changed on a prior call in the same loop.
    const snapped_right = snapped_x.* + width;
    const snapped_bottom = snapped_y.* + height;

    // Snapshot the pre-update position so all four candidates measure from the actual window, not one already overwritten this call.
    const orig_x = snapped_x.*;
    const orig_y = snapped_y.*;

    const other_left = other_rect.left;
    const other_right = other_rect.right;
    const other_top = other_rect.top;
    const other_bottom = other_rect.bottom;

    // Check vertical alignment (for horizontal snapping)
    const v_overlap = !(snapped_bottom < other_top or snapped_y.* > other_bottom);
    if (v_overlap) {
        const dist_ll: i32 = @intCast(@abs(orig_x - other_left));
        if (dist_ll <= min_x_dist.*) {
            min_x_dist.* = dist_ll;
            snapped_x.* = other_left;
        }
        const dist_lr: i32 = @intCast(@abs(orig_x - other_right));
        if (dist_lr <= min_x_dist.*) {
            min_x_dist.* = dist_lr;
            snapped_x.* = other_right;
        }
        const dist_rl: i32 = @intCast(@abs(snapped_right - other_left));
        if (dist_rl <= min_x_dist.*) {
            min_x_dist.* = dist_rl;
            snapped_x.* = other_left - width;
        }
        const dist_rr: i32 = @intCast(@abs(snapped_right - other_right));
        if (dist_rr <= min_x_dist.*) {
            min_x_dist.* = dist_rr;
            snapped_x.* = other_right - width;
        }
    }

    // Recompute right edge for vertical-snap check: horizontal snapping above may have moved snapped_x.
    const snapped_right_now = snapped_x.* + width;
    const h_overlap = !(snapped_right_now < other_left or snapped_x.* > other_right);
    if (h_overlap) {
        const dist_tt: i32 = @intCast(@abs(orig_y - other_top));
        if (dist_tt <= min_y_dist.*) {
            min_y_dist.* = dist_tt;
            snapped_y.* = other_top;
        }
        const dist_tb: i32 = @intCast(@abs(orig_y - other_bottom));
        if (dist_tb <= min_y_dist.*) {
            min_y_dist.* = dist_tb;
            snapped_y.* = other_bottom;
        }
        const dist_bt: i32 = @intCast(@abs(snapped_bottom - other_top));
        if (dist_bt <= min_y_dist.*) {
            min_y_dist.* = dist_bt;
            snapped_y.* = other_top - height;
        }
        const dist_bb: i32 = @intCast(@abs(snapped_bottom - other_bottom));
        if (dist_bb <= min_y_dist.*) {
            min_y_dist.* = dist_bb;
            snapped_y.* = other_bottom - height;
        }
    }
}

fn applyThumbnailEdgeSnapping(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    threshold: i32,
    dragging_hwnd: win32.HWND,
    painter: *const Painter,
) SnapPosition {
    var snapped_x = x;
    var snapped_y = y;
    var min_x_dist: i32 = threshold;
    var min_y_dist: i32 = threshold;

    for (painter.thumbnails.items) |thumbnail| {
        if (thumbnail.hwnd == dragging_hwnd or thumbnail.text_hwnd == dragging_hwnd) {
            continue;
        }

        if (!win32.isWindow(thumbnail.hwnd)) {
            continue;
        }

        var other_rect: win32.RECT = undefined;
        _ = win32.GetWindowRect(thumbnail.hwnd, &other_rect);

        snapAxesToRect(&snapped_x, &snapped_y, width, height, other_rect, &min_x_dist, &min_y_dist);
    }

    return .{ .x = snapped_x, .y = snapped_y };
}

/// Snaps to a ghost's exact saved position when within `threshold` px (Chebyshev distance), else aligns edges against ghost rects like applyThumbnailEdgeSnapping does for live thumbnails.
fn applyGhostSnapping(x: i32, y: i32, width: i32, height: i32, threshold: i32, dragging_hwnd: win32.HWND, painter: *Painter) SnapPosition {
    // Non-thumbnail draggers (e.g. the notification history panel) own no character, so nothing is excluded from the ghost set.
    const character_name = if (painter.getThumbnailByOverlayHwnd(dragging_hwnd)) |t| t.character_name else "";

    const groups = painter.collectGhostGroups(painter.allocator, character_name) catch return .{ .x = x, .y = y };
    defer {
        for (groups) |g| painter.allocator.free(g.names);
        painter.allocator.free(groups);
    }

    var dock_x = x;
    var dock_y = y;
    var best_dist: i32 = threshold;

    for (groups) |group| {
        const dx: i32 = @intCast(@abs(x - group.rect.left));
        const dy: i32 = @intCast(@abs(y - group.rect.top));
        const dist = @max(dx, dy);
        if (dist <= best_dist) {
            best_dist = dist;
            dock_x = group.rect.left;
            dock_y = group.rect.top;
        }
    }

    var snapped_x = dock_x;
    var snapped_y = dock_y;
    var min_x_dist: i32 = threshold;
    var min_y_dist: i32 = threshold;

    for (groups) |group| {
        snapAxesToRect(&snapped_x, &snapped_y, width, height, group.rect, &min_x_dist, &min_y_dist);
    }

    return .{ .x = snapped_x, .y = snapped_y };
}

/// Applies screen-edge, thumbnail-edge, and saved-ghost-position snapping to a dragged window's position
pub fn applySnapping(x: i32, y: i32, width: i32, height: i32, dragging_hwnd: win32.HWND) SnapPosition {
    const painter = g_painter_ptr orelse return .{ .x = x, .y = y };

    if (!painter.config.snapping.enabled) {
        return .{ .x = x, .y = y };
    }

    const threshold = painter.config.snapping.threshold;
    var result = SnapPosition{ .x = x, .y = y };

    if (painter.config.snapping.screenEdges) {
        result = applyScreenEdgeSnapping(result.x, result.y, width, height, threshold, dragging_hwnd);
    }

    // Chains off the screen-snapped result so both snaps compose.
    if (painter.config.snapping.thumbnailEdges) {
        result = applyThumbnailEdgeSnapping(result.x, result.y, width, height, threshold, dragging_hwnd, painter);
    }

    if (painter.config.snapping.ghostPositions) {
        result = applyGhostSnapping(result.x, result.y, width, height, threshold, dragging_hwnd, painter);
    }

    return result;
}

const HIDE_DEBOUNCE_TIMER_ID: usize = 1;

/// Window procedure for thumbnail windows: handles input events and the auto-hide timer when no EVE window has focus.
fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_TIMER => {
            if (wParam == HIDE_DEBOUNCE_TIMER_ID) {
                if (g_painter_ptr) |painter| {
                    _ = win32.KillTimer(hwnd, HIDE_DEBOUNCE_TIMER_ID);
                    painter.hide_debounce_timer_hwnd = null;

                    slog.debug("Hide debounce timer fired, hiding all thumbnails", .{});

                    // Hide all thumbnails automatically (can be auto-shown when EVE gets focus)
                    for (painter.thumbnails.items) |*thumbnail| {
                        if (thumbnail.visibility_state == .Visible) {
                            thumbnail.setVisibility(.HiddenAutomatic);
                            painter.renderThumbnail(thumbnail) catch |err| {
                                slog.err("Failed to hide thumbnail: {}", .{err});
                            };
                        }
                    }
                }
                return 0;
            }
            return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
        },
        win32.WM_LBUTTONDOWN => {
            if (win32.GetPropA(hwnd, "SOURCE_HWND")) |source_hwnd| {
                const config = &main_mod.g_config;
                const shift_pressed = win32.isShiftPressed();

                if (config.interaction.clickTrigger == .MouseDown) {
                    if (shift_pressed) {
                        handleThumbnailShiftClick(source_hwnd);
                    } else {
                        handleThumbnailClick(source_hwnd);
                    }
                } else {
                    g_click_state = .{
                        .pending = true,
                        .hwnd = hwnd,
                        .source_hwnd = source_hwnd,
                        .shift_pressed = shift_pressed,
                    };
                }
            }
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const config = &main_mod.g_config;

            if (config.interaction.clickTrigger == .MouseUp and g_click_state.pending) {
                if (g_click_state.hwnd == hwnd) {
                    if (g_click_state.source_hwnd) |source_hwnd| {
                        if (g_click_state.shift_pressed) {
                            handleThumbnailShiftClick(source_hwnd);
                        } else {
                            handleThumbnailClick(source_hwnd);
                        }
                    }
                }
            }
            g_click_state = .{};
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            startDrag(hwnd, lParam);
            return 0;
        },
        win32.WM_RBUTTONUP => {
            endDrag(hwnd, hwnd);
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            handleDrag(hwnd, lParam);
            return 0;
        },
        win32.WM_ACTIVATE => {
            if (getLinkedWindow(hwnd)) |text_hwnd| {
                _ = win32.SetWindowPos(text_hwnd, win32.HWND_TOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
            }
            return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
        },
        win32.WM_DPICHANGED => {
            // Position only; resizeThumbnailIfNeeded below re-derives size from our own scale formula.
            const suggested = win32.lparamToPtr(win32.RECT, lParam);
            _ = win32.SetWindowPos(hwnd, win32.HWND_NOTOPMOST, suggested.left, suggested.top, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);

            if (g_painter_ptr) |painter| {
                if (painter.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| {
                    painter.resizeThumbnailIfNeeded(thumbnail);

                    if (getLinkedWindow(hwnd)) |text_hwnd| {
                        var rect: win32.RECT = undefined;
                        _ = win32.GetWindowRect(hwnd, &rect);
                        _ = win32.SetWindowPos(text_hwnd, win32.HWND_TOPMOST, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, win32.SWP_NOACTIVATE);
                    }

                    painter.renderThumbnail(thumbnail) catch |err| {
                        slog.err("Failed to render thumbnail after DPI change for {s}: {}", .{ thumbnail.character_name, err });
                    };
                }
            }
            return 0;
        },
        win32.WM_CLOSE => {
            _ = win32.DestroyWindow(hwnd);
            return 0;
        },
        win32.WM_DESTROY => {
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

/// Window procedure for text overlay windows: handles clicks and dragging
fn textWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_LBUTTONDOWN => {
            if (win32.GetPropA(hwnd, "SOURCE_HWND")) |source_hwnd| {
                const config = &main_mod.g_config;
                const shift_pressed = win32.isShiftPressed();

                if (config.interaction.clickTrigger == .MouseDown) {
                    if (shift_pressed) {
                        handleThumbnailShiftClick(source_hwnd);
                    } else {
                        handleThumbnailClick(source_hwnd);
                    }
                } else {
                    g_click_state = .{
                        .pending = true,
                        .hwnd = hwnd,
                        .source_hwnd = source_hwnd,
                        .shift_pressed = shift_pressed,
                    };
                }
            }
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const config = &main_mod.g_config;

            if (config.interaction.clickTrigger == .MouseUp and g_click_state.pending) {
                if (g_click_state.hwnd == hwnd) {
                    if (g_click_state.source_hwnd) |source_hwnd| {
                        if (g_click_state.shift_pressed) {
                            handleThumbnailShiftClick(source_hwnd);
                        } else {
                            handleThumbnailClick(source_hwnd);
                        }
                    }
                }
            }
            g_click_state = .{};
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            startDrag(hwnd, lParam);
            return 0;
        },
        win32.WM_RBUTTONUP => {
            if (getLinkedWindow(hwnd)) |thumb_hwnd| {
                endDrag(hwnd, thumb_hwnd);
            }
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            handleDrag(hwnd, lParam);
            return 0;
        },
        win32.WM_CLOSE => {
            _ = win32.DestroyWindow(hwnd);
            return 0;
        },
        win32.WM_DESTROY => {
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

/// Used by Painter during window class registration.
pub fn getWindowProc() *const fn (win32.HWND, win32.UINT, win32.WPARAM, win32.LPARAM) callconv(.c) win32.LRESULT {
    return windowProc;
}

/// Used by Painter during window class registration.
pub fn getTextWindowProc() *const fn (win32.HWND, win32.UINT, win32.WPARAM, win32.LPARAM) callconv(.c) win32.LRESULT {
    return textWindowProc;
}
