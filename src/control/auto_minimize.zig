//! Minimizing EVE clients left inactive, and the hotkey and tray toggle for it.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const config_mod = @import("../config.zig");
const animation = @import("../clients/animation.zig");
const window = @import("../thumbnail/window.zig");
const minimize_rules = @import("minimize_rules.zig");
const log = @import("../log.zig");

const Config = config_mod.Config;
const ThumbnailWindow = window.ThumbnailWindow;
const slog = log.Scoped("auto_minimize");

/// App owns it, so a thumbnail set rebuild keeps it.
pub const AutoMinimizer = struct {
    last_focused_by_monitor: std.AutoHashMap(win32.HMONITOR, win32.HWND),
    /// From the hotkey or tray, never saved; dropped once the setting it overrode changes.
    enabled_override: ?Override = null,

    const Override = struct { is_enabled: bool, was_setting_enabled: bool };

    pub fn init(allocator: std.mem.Allocator) AutoMinimizer {
        return .{ .last_focused_by_monitor = .init(allocator) };
    }

    pub fn deinit(self: *AutoMinimizer) void {
        self.last_focused_by_monitor.deinit();
    }

    /// For another profile, which starts from its own setting with no focus history.
    pub fn reset(self: *AutoMinimizer) void {
        self.last_focused_by_monitor.clearRetainingCapacity();
        self.enabled_override = null;
    }

    /// Temporary, not saved to the profile (hotkey and tray action); returns whether it's now on.
    pub fn toggle(self: *AutoMinimizer, config: *const Config) bool {
        const is_enabled = !self.isEnabled(config);
        self.enabled_override = .{ .is_enabled = is_enabled, .was_setting_enabled = config.autoMinimize.enabled };
        slog.info("Auto-minimize toggled: {s}", .{if (is_enabled) "enabled" else "disabled"});
        return is_enabled;
    }

    /// A monitor with no live recorded last-active client exempts everyone on it rather than minimize clients with no known "last active".
    fn isLastActiveOnItsMonitor(self: *const AutoMinimizer, thumbnails: []const ThumbnailWindow, source_hwnd: win32.HWND) bool {
        const monitor = win32.MonitorFromWindow(source_hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse return true;
        const last_active = self.last_focused_by_monitor.get(monitor) orelse return true;
        if (find(thumbnails, last_active) == null) return true;
        return last_active == source_hwnd;
    }

    pub fn isEnabled(self: *const AutoMinimizer, config: *const Config) bool {
        const setting = config.autoMinimize.enabled;
        const override = self.enabled_override orelse return setting;
        return if (override.was_setting_enabled == setting) override.is_enabled else setting;
    }

    fn dropStaleOverride(self: *AutoMinimizer, config: *const Config) void {
        const override = self.enabled_override orelse return;
        if (override.was_setting_enabled != config.autoMinimize.enabled) self.enabled_override = null;
    }

    /// `source_hwnd` took focus; pass only an EVE client, since focusing a window filter's app counts as EVE losing focus.
    pub fn recordFocus(self: *AutoMinimizer, source_hwnd: win32.HWND) void {
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

    /// Call once per tick, after ThumbnailSet.update, whose updateThumbnailStates sets the was_minimized and active client it reads.
    pub fn check(self: *AutoMinimizer, config: *const Config, thumbnails: []ThumbnailWindow, active_source_hwnd: ?win32.HWND) void {
        const now = win32.Ticks.now();
        // Refreshed even while disabled, so re-enabling doesn't count the disabled stretch as inactivity.
        for (thumbnails) |*thumbnail| {
            if (thumbnail.is_dragged) continue;
            if (thumbnail.isFocused(active_source_hwnd) or thumbnail.was_minimized) {
                thumbnail.auto_minimize.inactive_since = now;
            }
        }

        self.dropStaleOverride(config);
        if (!self.isEnabled(config)) return;
        if (thumbnails.len == 0) return;

        const settings: minimize_rules.Settings = .{
            .delay_ms = config.autoMinimize.delayMs,
            .exempts_last_active_on_focus_loss = config.autoMinimize.exemptLastActiveOnFocusLoss,
        };
        // active_source_hwnd is the literal foreground window, so it's non-null even on a non-EVE app.
        const focused_eve_hwnd: ?win32.HWND = if (active_source_hwnd) |hwnd| (if (isEveClient(thumbnails, hwnd)) hwnd else null) else null;
        const focused_monitor = if (focused_eve_hwnd) |hwnd| win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) else null;
        var has_minimized_any = false;

        for (thumbnails) |*thumbnail| {
            // A minimized window is parked off-screen and reports the wrong monitor, but the rules skip it before reading that.
            const is_on_other_monitor = if (focused_monitor) |monitor|
                win32.MonitorFromWindow(thumbnail.source_hwnd, win32.MONITOR_DEFAULTTONEAREST) != monitor
            else
                false;
            const client: minimize_rules.Client = .{
                .is_eve_client = thumbnail.is_eve_client,
                .is_dragging = thumbnail.is_dragged,
                .is_focused = thumbnail.isFocused(active_source_hwnd),
                .was_minimized = thumbnail.was_minimized,
                .is_excluded = thumbnail.cached_excluded_from_minimize,
                .inactive_ms = now.elapsedSince(thumbnail.auto_minimize.inactive_since),
                .is_on_other_monitor = is_on_other_monitor,
                .is_last_active_on_its_monitor = self.isLastActiveOnItsMonitor(thumbnails, thumbnail.source_hwnd),
            };
            if (!minimize_rules.shouldMinimize(settings, client, focused_eve_hwnd != null)) continue;
            if (!win32.isWindow(thumbnail.source_hwnd)) continue;

            animation.showClient(config, thumbnail.source_hwnd, win32.SW_FORCEMINIMIZE);
            has_minimized_any = true;
            slog.info("Auto-minimized {s} (inactive {}ms)", .{ thumbnail.character_name, client.inactive_ms });
        }

        if (has_minimized_any) {
            for (thumbnails) |*thumbnail| {
                if (thumbnail.isFocused(active_source_hwnd) and win32.isWindow(thumbnail.source_hwnd)) {
                    // Minimizing the other windows can transiently steal focus from the active one.
                    focus_grant.forceSetForegroundWindow(thumbnail.source_hwnd);
                    break;
                }
            }
        }
    }
};

fn find(thumbnails: []const ThumbnailWindow, source_hwnd: win32.HWND) ?*const ThumbnailWindow {
    for (thumbnails) |*thumbnail| {
        if (thumbnail.source_hwnd == source_hwnd) return thumbnail;
    }
    return null;
}

/// Whether `source_hwnd` is a tracked EVE client, not a window filter's window.
fn isEveClient(thumbnails: []const ThumbnailWindow, source_hwnd: win32.HWND) bool {
    const thumbnail = find(thumbnails, source_hwnd) orelse return false;
    return thumbnail.is_eve_client;
}
