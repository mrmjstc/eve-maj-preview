//! Minimizing EVE clients left inactive, and the hotkey and tray toggle for it.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const thumbnail_drag = @import("../drag/thumbnail.zig");
const painter_mod = @import("../painter.zig");
const animation = @import("animation.zig");
const log = @import("../log.zig");

const Painter = painter_mod.Painter;
const slog = log.scoped("auto_minimize");

/// Per-thumbnail auto-minimize state; only AutoMinimizer.check writes it after creation.
pub const AutoMinimizeState = struct {
    /// When check's delay counts from; refreshed every tick the thumbnail is Active or Minimized, left untouched otherwise so its frozen value is the moment it last became eligible.
    inactive_since: win32.Ticks,
};

/// Minimizes EVE clients that stay inactive past autoMinimize.delayMs, sparing each monitor's last-active client when focus is elsewhere.
pub const AutoMinimizer = struct {
    /// Last EVE client hwnd that held focus on each monitor; lets check's exemptLastActiveOnFocusLoss option spare one client per monitor once EVE itself has no window focused.
    last_focused_by_monitor: std.AutoHashMap(win32.HMONITOR, win32.HWND),
    /// From the hotkey or tray, never saved; dropped once the setting it overrode changes.
    enabled_override: ?Override = null,

    const Override = struct { enabled: bool, overridden_setting: bool };

    pub fn init(allocator: std.mem.Allocator) AutoMinimizer {
        return .{ .last_focused_by_monitor = std.AutoHashMap(win32.HMONITOR, win32.HWND).init(allocator) };
    }

    pub fn deinit(self: *AutoMinimizer) void {
        self.last_focused_by_monitor.deinit();
    }

    /// A monitor with no live recorded last-active client exempts everyone on it rather than minimize clients with no known "last active".
    fn isLastActiveOnItsMonitor(self: *const AutoMinimizer, painter: *const Painter, source_hwnd: win32.HWND) bool {
        const monitor = win32.MonitorFromWindow(source_hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse return true;
        const last_active = self.last_focused_by_monitor.get(monitor) orelse return true;
        if (!painter.hasThumbnail(last_active)) return true;
        return last_active == source_hwnd;
    }

    pub fn isEnabled(self: *const AutoMinimizer, painter: *const Painter) bool {
        const setting = painter.config.autoMinimize.enabled;
        const override = self.enabled_override orelse return setting;
        return if (override.overridden_setting == setting) override.enabled else setting;
    }

    fn dropStaleOverride(self: *AutoMinimizer, painter: *const Painter) void {
        const override = self.enabled_override orelse return;
        if (override.overridden_setting != painter.config.autoMinimize.enabled) self.enabled_override = null;
    }

    /// Ignores windows that aren't EVE clients, so focusing a window filter's app counts as EVE losing focus.
    pub fn recordFocus(self: *AutoMinimizer, painter: *const Painter, source_hwnd: win32.HWND) void {
        if (!painter.hasEveClient(source_hwnd)) return;
        const monitor = win32.MonitorFromWindow(source_hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse return;

        // A window that moved monitors must not stay recorded under its old one.
        var stale: ?win32.HMONITOR = null;
        var it = self.last_focused_by_monitor.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == source_hwnd and entry.key_ptr.* != monitor) {
                stale = entry.key_ptr.*;
                break;
            }
        }
        if (stale) |old_monitor| _ = self.last_focused_by_monitor.remove(old_monitor);

        self.last_focused_by_monitor.put(monitor, source_hwnd) catch |err| {
            slog.err("Failed to record last-focused client for monitor: {}", .{err});
        };
    }

    /// Call once per tick, right after focus is reconciled.
    pub fn check(self: *AutoMinimizer, painter: *Painter) void {
        const now = win32.Ticks.now();
        // Refreshed even while disabled, so re-enabling doesn't count the disabled stretch as inactivity.
        for (painter.thumbnails.items) |*thumbnail| {
            if (thumbnail_drag.isDragging(thumbnail)) continue;
            if (thumbnail.isFocused(painter.active_source_hwnd) or win32.isWindowIconic(thumbnail.source_hwnd)) {
                thumbnail.auto_minimize.inactive_since = now;
            }
        }

        self.dropStaleOverride(painter);
        if (!self.isEnabled(painter)) return;
        if (painter.thumbnails.items.len == 0) return;

        const delay_ms: u64 = painter.config.autoMinimize.delayMs;
        var minimized_any = false;

        // active_source_hwnd is the literal foreground window, so it's non-null even on a non-EVE app.
        const eve_has_focus = if (painter.active_source_hwnd) |hwnd| painter.hasEveClient(hwnd) else false;
        const focused_monitor = if (eve_has_focus) win32.MonitorFromWindow(painter.active_source_hwnd.?, win32.MONITOR_DEFAULTTONEAREST) else null;

        for (painter.thumbnails.items) |*thumbnail| {
            if (!thumbnail.is_eve_client) continue;
            if (thumbnail_drag.isDragging(thumbnail)) continue;
            if (thumbnail.isFocused(painter.active_source_hwnd)) continue;
            if (win32.isWindowIconic(thumbnail.source_hwnd)) continue;
            // Checked after the iconic skip: a minimized window is parked off-screen and reports the wrong monitor.
            const on_other_monitor = if (focused_monitor) |monitor|
                win32.MonitorFromWindow(thumbnail.source_hwnd, win32.MONITOR_DEFAULTTONEAREST) != monitor
            else
                false;
            const spared_by_focus_loss = painter.config.autoMinimize.exemptLastActiveOnFocusLoss and !eve_has_focus;
            if ((on_other_monitor or spared_by_focus_loss) and self.isLastActiveOnItsMonitor(painter, thumbnail.source_hwnd)) continue;
            if (now.elapsedSince(thumbnail.auto_minimize.inactive_since) < delay_ms) continue;
            if (thumbnail.cached_excluded_from_minimize) continue;
            if (!win32.isWindow(thumbnail.source_hwnd)) continue;

            animation.showClient(painter.config, thumbnail.source_hwnd, win32.SW_FORCEMINIMIZE);
            minimized_any = true;
            slog.info("Auto-minimized {s} (inactive {}ms)", .{ thumbnail.character_name, now.elapsedSince(thumbnail.auto_minimize.inactive_since) });
        }

        if (minimized_any) {
            for (painter.thumbnails.items) |*thumbnail| {
                if (thumbnail.isFocused(painter.active_source_hwnd) and win32.isWindow(thumbnail.source_hwnd)) {
                    // Minimizing the other windows can transiently steal focus from the active one.
                    focus_grant.forceSetForegroundWindow(thumbnail.source_hwnd);
                    break;
                }
            }
        }
    }
};

/// Temporary, not saved to the profile (hotkey and tray action).
pub fn toggle(painter: *Painter) void {
    const enabled = !painter.auto_minimize.isEnabled(painter);
    painter.auto_minimize.enabled_override = .{ .enabled = enabled, .overridden_setting = painter.config.autoMinimize.enabled };
    slog.info("Auto-minimize toggled: {s}", .{if (enabled) "enabled" else "disabled"});
    painter.notifyAll(.{ .ntype = .AutoMinimizeToggle, .state = if (enabled) .on else .off });
}
