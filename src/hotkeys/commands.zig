//! Every user command, whether a hotkey, the tray or an evemajpreview:// link asked for it; runs with or without a hotkey manager.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const scout_mod = @import("../clients/scout.zig");
const actions = @import("../clients/actions.zig");
const exclusions_mod = @import("../clients/exclusions.zig");
const roster_mod = @import("../clients/roster.zig");
const config_mod = @import("../config.zig");
const url = @import("../protocol/url.zig");
const set = @import("../thumbnail/set.zig");
const alert_effects = @import("../notifications/alert_effects.zig");
const notified_queue_mod = @import("../notifications/notified_queue.zig");
const notifier_mod = @import("../notifications/notifier.zig");
const bindings = @import("bindings.zig");
const cycling = @import("cycling.zig");
const membership = @import("membership.zig");
const launch = @import("launch.zig");
const log = @import("../log.zig");

const GlobalConfig = config_mod.GlobalConfig;
const HotkeyAction = bindings.HotkeyAction;
const ThumbnailSet = set.ThumbnailSet;
const slog = log.Scoped("hotkeys");

/// What a command asks of App, which sits above hotkeys/.
pub const AppCommand = enum {
    next_profile,
    previous_profile,
    toggle_auto_minimize,
    toggle_dragging,
    toggle_travel_mode,
    toggle_notification_history,
    clear_notification_history,
    toggle_map_panel,
    toggle_intel_panel,
    return_to_last_app,
    /// Needs the hotkey manager, which App may be rebuilding.
    suspend_hotkeys,
    exit,
};

/// What's left for App to do once a command returns; by value, as the action it came from may be gone by then.
pub const Outcome = union(enum) {
    none,
    /// The client to bring to the front.
    activate: win32.HWND,
    /// Borrows from the global settings; App copies it before they can change.
    switch_profile: []const u8,
    app: AppCommand,
};

/// App.commands makes one per call; it's only pointers into App, which outlives it. Main thread only.
pub const Commands = struct {
    /// For the scratch lists the cycle and launch commands build; Commands itself owns nothing.
    allocator: std.mem.Allocator,
    /// The saved profile, which the bindings and the groups and characters their ids index into come from; other settings read live().
    config: *const config_mod.Config,
    /// Borrowed from App.
    store: *config_mod.ProfileStore,
    /// Borrowed from App: the saved copy.
    global_settings: *const GlobalConfig,
    /// Borrowed from App: the config window's draft while it's open, else the saved copy.
    live_global: *const GlobalConfig,
    /// Borrowed from App.
    scout: *scout_mod.Scout,
    /// Borrowed from App.
    exclusions: *exclusions_mod.Exclusions,
    /// Borrowed from App.
    notified_queue: *const notified_queue_mod.NotifiedQueue,
    /// Shows the alerts for membership changes and saved-position moves.
    notifier: notifier_mod.Notifier,
    /// Borrowed from App.
    roster: *roster_mod.Roster,
    /// Borrowed from App, which resets it whenever it recreates the hotkey manager.
    cycle: *cycling.CycleState,

    /// The running copy, including the dialog's unsaved edits.
    pub fn live(self: *const Commands) *const config_mod.Config {
        return &self.store.live;
    }

    pub fn liveGlobal(self: *const Commands) *const GlobalConfig {
        return self.live_global;
    }

    /// For a protocol link or the tray, which skip the press-only suspend and focus gates.
    pub fn runGlobal(self: *const Commands, action: url.GlobalAction, thumbnail_set: ?*ThumbnailSet) Outcome {
        var hotkey_action = bindings.fromProtocol(action);
        return self.run(&hotkey_action, thumbnail_set);
    }

    /// Like runGlobal, for the hotkey group named `group_name`; a cycle runs that group alone, even if its key is shared.
    pub fn runGroup(self: *const Commands, action: url.GroupAction, group_name: []const u8, thumbnail_set: ?*ThumbnailSet) Outcome {
        const group_index = self.config.hotkeyGroupIndex(group_name) orelse {
            slog.warn("Failed to run group '{s}': no hotkey group named '{s}'", .{ @tagName(action), group_name });
            return .none;
        };
        return self.runGroupAt(action, group_index, thumbnail_set);
    }

    /// runGroup by index into the saved groups, which an unnamed group needs; the tray's group menus list them.
    pub fn runGroupAt(self: *const Commands, action: url.GroupAction, group_index: usize, thumbnail_set: ?*ThumbnailSet) Outcome {
        const group_indices = [_]usize{group_index};
        var hotkey_action: HotkeyAction = switch (action) {
            .next => .{ .cycle_group = .{ .group_indices = &group_indices, .is_forward = true } },
            .previous => .{ .cycle_group = .{ .group_indices = &group_indices, .is_forward = false } },
            .assign => .{ .assign_group = .{ .group_index = group_index } },
            .minimize => .{ .minimize_group = .{ .group_index = group_index } },
            .close => .{ .close_group = .{ .group_index = group_index } },
        };
        return self.run(&hotkey_action, thumbnail_set);
    }

    /// Takes a pointer so per-character hotkeys can advance their cursor in the hotkey manager's map.
    pub fn run(self: *const Commands, action: *HotkeyAction, thumbnail_set: ?*ThumbnailSet) Outcome {
        switch (action.*) {
            .cycle_group => |chain| return activating(cycling.cycleGroups(self, chain.group_indices, chain.is_forward)),
            .activate_character => |*character_group| return activating(cycling.activatePerCharacterGroup(self, character_group)),
            .assign_group => |assign| {
                const active_set = thumbnail_set orelse {
                    slog.info("Group assign needs a thumbnail under the cursor, and no thumbnails are shown", .{});
                    return .none;
                };
                membership.assignHoveredToGroup(self, active_set, assign.group_index);
            },
            .minimize_group => |minimize| {
                slog.info("Minimize group hotkey pressed", .{});
                actions.applyToGroup(self.scout.getWindows(), self.live(), self.config.hotkeyGroups.items, minimize.group_index, .minimize);
            },
            .close_group => |close| {
                slog.info("Close group hotkey pressed", .{});
                actions.applyToGroup(self.scout.getWindows(), self.live(), self.config.hotkeyGroups.items, close.group_index, .close);
            },
            .minimize_all => {
                slog.info("Minimize all hotkey pressed", .{});
                actions.minimizeAllClients(self.scout.getWindows(), self.live());
            },
            .close_all => {
                slog.info("Close all hotkey pressed", .{});
                actions.closeAllClients(self.scout.getWindows(), self.live(), self.exclusions);
            },
            .toggle_visibility => {
                slog.info("Toggle visibility hotkey pressed", .{});
                const active_set = thumbnail_set orelse {
                    slog.info("No thumbnails to show or hide while they're rebuilt", .{});
                    return .none;
                };
                active_set.toggleAllThumbnailsVisibility();
            },
            .next_profile => return .{ .app = .next_profile },
            .previous_profile => return .{ .app = .previous_profile },
            .switch_to_profile => |switch_to| return self.profileSwitchTarget(switch_to.profile_index),
            .toggle_exclusion => self.toggleForegroundExclusion(thumbnail_set),
            .next_excluded => return activating(cycling.cycleExcluded(self, true)),
            .previous_excluded => return activating(cycling.cycleExcluded(self, false)),
            .suspend_hotkeys => return .{ .app = .suspend_hotkeys },
            .toggle_auto_minimize => {
                slog.info("Toggle auto-minimize hotkey pressed", .{});
                return .{ .app = .toggle_auto_minimize };
            },
            .toggle_alert_mute => alert_effects.toggleMuted(),
            .cycle_notified => return activating(cycling.cycleNotified(self, true)),
            .previous_notified => return activating(cycling.cycleNotified(self, false)),
            .next_all_clients => return activating(cycling.cycleAllClients(self, true)),
            .previous_all_clients => return activating(cycling.cycleAllClients(self, false)),
            .next_not_logged_in => return activating(cycling.cycleNotLoggedIn(self, true)),
            .previous_not_logged_in => return activating(cycling.cycleNotLoggedIn(self, false)),
            .move_to_saved_positions => {
                slog.info("Move to saved positions hotkey pressed", .{});
                actions.moveAllClientsToSavedPositions(self.scout.getWindows(), self.live(), &self.notifier);
            },
            .return_to_last_app => return .{ .app = .return_to_last_app },
            .next_app => launch.cycleApps(self.global_settings, true),
            .previous_app => launch.cycleApps(self.global_settings, false),
            .exit_app => {
                slog.info("Exit hotkey pressed", .{});
                return .{ .app = .exit };
            },
            .close_active => self.closeForegroundClient(),
            .toggle_dragging => return .{ .app = .toggle_dragging },
            .toggle_travel_mode => return .{ .app = .toggle_travel_mode },
            .toggle_notification_history => return .{ .app = .toggle_notification_history },
            .clear_notification_history => {
                slog.info("Clear notification history hotkey pressed", .{});
                return .{ .app = .clear_notification_history };
            },
            .toggle_map_panel => return .{ .app = .toggle_map_panel },
            .toggle_intel_panel => return .{ .app = .toggle_intel_panel },
            .activate_app => |activate| launch.activateApp(self.global_settings, activate.app_index),
            .open_url => |open_url| launch.openUrl(self.allocator, self.global_settings, open_url.url_index),
        }
        return .none;
    }

    pub fn foregroundEveWindow(self: *const Commands) ?scout_mod.EveWindow {
        const foreground_hwnd = win32.GetForegroundWindow() orelse return null;
        for (self.scout.getWindows()) |eve_window| {
            if (eve_window.hwnd == foreground_hwnd) return eve_window;
        }
        return null;
    }

    fn profileSwitchTarget(self: *const Commands, profile_index: usize) Outcome {
        const profile_hotkeys = self.global_settings.profileSwitchHotkeys.items;
        if (profile_index >= profile_hotkeys.len) {
            slog.err("Failed to switch profile: hotkey index {} is out of range", .{profile_index});
            return .none;
        }
        const target_profile = profile_hotkeys[profile_index].targetProfile;
        slog.info("Switch to profile hotkey pressed: {s} -> {s}", .{ self.config.profile_name, target_profile });
        return .{ .switch_profile = target_profile };
    }

    fn toggleForegroundExclusion(self: *const Commands, thumbnail_set: ?*ThumbnailSet) void {
        const eve_window = self.foregroundEveWindow() orelse {
            slog.debug("Focused window is not an EVE client, exclusion toggle ignored", .{});
            return;
        };
        slog.info("Toggle exclusion hotkey pressed for: {s}", .{eve_window.character_name});
        membership.toggleExclusion(self, eve_window.hwnd);
        // Now rather than on the next tick, so the exclusion shows at once.
        if (thumbnail_set) |active_set| active_set.renderDirtyThumbnails(null);
    }

    fn closeForegroundClient(self: *const Commands) void {
        const eve_window = self.foregroundEveWindow() orelse {
            slog.debug("Focused window is not an EVE client, close ignored", .{});
            return;
        };
        // Window-filter matches belong to other apps, which this hotkey must never close.
        if (!eve_window.is_eve_client) {
            slog.debug("Focused window is a filtered non-EVE window, close ignored", .{});
            return;
        }
        slog.info("Close active hotkey pressed for: {s}", .{eve_window.character_name});
        _ = actions.closeClient(eve_window);
    }
};

fn activating(client: ?win32.HWND) Outcome {
    return if (client) |hwnd| .{ .activate = hwnd } else .none;
}
