//! Minimizing EVE clients left inactive, and the hotkey and tray toggle for it.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const config_mod = @import("../config.zig");
const animation = @import("../clients/animation.zig");
const roster = @import("../clients/roster.zig");
const minimize_rules = @import("minimize_rules.zig");
const log = @import("../log.zig");

const Config = config_mod.Config;
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

    /// Also true when the monitor has no live recorded client, sparing everyone there.
    fn isLastActiveOnItsMonitor(self: *const AutoMinimizer, clients: []const roster.Client, source_hwnd: win32.HWND) bool {
        const monitor = win32.MonitorFromWindow(source_hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse return true;
        const last_active = self.last_focused_by_monitor.get(monitor) orelse return true;
        if (find(clients, last_active) == null) return true;
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

    /// Call once per tick, after Roster.refreshMinimized and setActive; `dragged_hwnd`'s client is never minimized or timed.
    pub fn check(self: *AutoMinimizer, config: *const Config, clients: []roster.Client, active_source_hwnd: ?win32.HWND, dragged_hwnd: ?win32.HWND) void {
        const now = win32.Ticks.now();
        // Refreshed even while disabled, so re-enabling doesn't count the disabled stretch as inactivity.
        for (clients) |*client| {
            if (client.hwnd == dragged_hwnd) continue;
            if (client.hwnd == active_source_hwnd or client.was_minimized) client.inactive_since = now;
        }

        self.dropStaleOverride(config);
        if (!self.isEnabled(config)) return;
        if (clients.len == 0) return;

        const settings: minimize_rules.Settings = .{
            .delay_ms = config.autoMinimize.delayMs,
            .exempts_last_active_on_focus_loss = config.autoMinimize.exemptLastActiveOnFocusLoss,
        };
        // active_source_hwnd is the literal foreground window, so it's non-null even on a non-EVE app.
        const focused_eve_hwnd: ?win32.HWND = if (active_source_hwnd) |hwnd| (if (isEveClient(clients, hwnd)) hwnd else null) else null;
        const focused_monitor = if (focused_eve_hwnd) |hwnd| win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) else null;
        var has_minimized_any = false;

        for (clients) |*client| {
            // A minimized window is parked off-screen and reports the wrong monitor, but the rules skip it before reading that.
            const is_on_other_monitor = if (focused_monitor) |monitor|
                win32.MonitorFromWindow(client.hwnd, win32.MONITOR_DEFAULTTONEAREST) != monitor
            else
                false;
            const facts: minimize_rules.Client = .{
                .is_eve_client = client.is_eve_client,
                .is_dragging = client.hwnd == dragged_hwnd,
                .is_focused = client.hwnd == active_source_hwnd,
                .was_minimized = client.was_minimized,
                .is_excluded = client.is_excluded_from_minimize,
                .inactive_ms = now.elapsedSince(client.inactive_since),
                .is_on_other_monitor = is_on_other_monitor,
                .is_last_active_on_its_monitor = self.isLastActiveOnItsMonitor(clients, client.hwnd),
            };
            if (!minimize_rules.shouldMinimize(settings, facts, focused_eve_hwnd != null)) continue;
            if (!win32.isWindow(client.hwnd)) continue;

            animation.showClient(config, client.hwnd, win32.SW_FORCEMINIMIZE);
            has_minimized_any = true;
            slog.info("Auto-minimized {s} (inactive {}ms)", .{ client.character_name, facts.inactive_ms });
        }

        // Minimizing the other windows can transiently steal focus from the active one.
        if (has_minimized_any) {
            const active = active_source_hwnd orelse return;
            if (find(clients, active) != null and win32.isWindow(active)) focus_grant.forceSetForegroundWindow(active);
        }
    }
};

fn find(clients: []const roster.Client, hwnd: win32.HWND) ?*const roster.Client {
    for (clients) |*client| {
        if (client.hwnd == hwnd) return client;
    }
    return null;
}

/// Whether `hwnd` is a tracked EVE client, not a window filter's window.
fn isEveClient(clients: []const roster.Client, hwnd: win32.HWND) bool {
    const client = find(clients, hwnd) orelse return false;
    return client.is_eve_client;
}
