//! Registering hotkeys and dispatching each press to its action; what only App can do is handed back to it as an Outcome.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const scout_mod = @import("../clients/scout.zig");
const actions = @import("../clients/actions.zig");
const exclusions_mod = @import("../clients/exclusions.zig");
const config_mod = @import("../config.zig");
const url = @import("../protocol/url.zig");
const set = @import("../thumbnail/set.zig");
const alert_effects = @import("../notifications/alert_effects.zig");
const notified_queue_mod = @import("../notifications/notified_queue.zig");
const keyboard_hook = @import("keyboard_hook.zig");
const hooks = @import("hooks.zig");
const hook_bindings = @import("hook_bindings.zig");
const bindings = @import("bindings.zig");
const plan_mod = @import("plan.zig");
const cycling = @import("cycling.zig");
const cycle_order = @import("cycle_order.zig");
const membership = @import("membership.zig");
const launch = @import("launch.zig");
const log = @import("../log.zig");

const GlobalConfig = config_mod.GlobalConfig;
const HotkeyAction = bindings.HotkeyAction;
const ThumbnailSet = set.ThumbnailSet;
const slog = log.Scoped("hotkeys");

const KEY_NAME_SIZE = 32;

/// What a hotkey asks of App, which sits above hotkeys/.
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
    exit,
};

/// What's left for App to do once a press or action returns; by value, as the action it came from may be gone by then.
pub const Outcome = union(enum) {
    none,
    /// The client to bring to the front.
    activate: win32.HWND,
    /// Borrows from the global settings; App copies it before they can change.
    switch_profile: []const u8,
    app: AppCommand,
};

/// What the manager borrows from App, which outlives it and keeps these across the Save that recreates it.
pub const Borrowed = struct {
    store: *config_mod.ProfileStore,
    global_settings: *const GlobalConfig,
    /// A function rather than a pointer, since the config window's draft it may return comes and goes.
    live_global: *const fn () *const GlobalConfig,
    scout: *scout_mod.Scout,
    exclusions: *exclusions_mod.Exclusions,
    notified_queue: *const notified_queue_mod.NotifiedQueue,
    /// The hidden window hotkeys post to.
    timer_hwnd: win32.HWND,
};

pub const HotkeyManager = struct {
    allocator: std.mem.Allocator,
    /// The saved copy, for the bindings and the groups and characters their ids index into; other settings read live().
    config: *const config_mod.Config,
    /// Borrowed; outlives the manager.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the manager.
    global_settings: *const GlobalConfig,
    /// See Borrowed.live_global.
    live_global: *const fn () *const GlobalConfig,
    /// Borrowed; outlives the manager.
    scout: *scout_mod.Scout,
    /// See Borrowed.timer_hwnd.
    timer_hwnd: win32.HWND,
    hotkey_map: std.AutoHashMap(c_int, HotkeyAction),
    /// What the registered actions' index slices borrow from; null while none are registered.
    plan: ?plan_mod.Plan = null,
    /// The suspend hotkey itself stays live.
    are_hotkeys_suspended: bool = false,
    /// Whether the config dialog is recording a new hotkey; kept separate from are_hotkeys_suspended so the two don't clobber each other.
    is_dialog_suspended: bool = false,
    /// Whether a text box outside the config dialog has the keyboard.
    is_typing_suspended: bool = false,
    cycle: cycling.CycleState,
    /// Borrowed; outlives the manager.
    exclusions: *exclusions_mod.Exclusions,
    /// Borrowed; outlives the manager.
    notified_queue: *const notified_queue_mod.NotifiedQueue,
    /// What syncFocusFilter last handed the hook thread; null until it first does, so a recreated manager sends it again.
    sent_focus_filter: ?hook_bindings.FocusFilter = null,

    /// Registers from the profile's saved copy, since bindings only change on Save.
    pub fn init(allocator: std.mem.Allocator, borrowed: Borrowed) !HotkeyManager {
        const config = &borrowed.store.saved;
        return .{
            .allocator = allocator,
            .config = config,
            .store = borrowed.store,
            .global_settings = borrowed.global_settings,
            .live_global = borrowed.live_global,
            .scout = borrowed.scout,
            .timer_hwnd = borrowed.timer_hwnd,
            .hotkey_map = .init(allocator),
            .cycle = try .init(allocator, config.hotkeyGroups.items.len),
            .exclusions = borrowed.exclusions,
            .notified_queue = borrowed.notified_queue,
        };
    }

    /// The running copy, including the dialog's unsaved edits.
    pub fn live(self: *const HotkeyManager) *const config_mod.Config {
        return &self.store.live;
    }

    /// Like live(), for the global settings; `global_settings` stays the saved copy the bindings came from.
    pub fn liveGlobal(self: *const HotkeyManager) *const GlobalConfig {
        return self.live_global();
    }

    fn planSettings(self: *const HotkeyManager) plan_mod.Settings {
        return .{ .characters = self.config.characters.items, .groups = self.config.hotkeyGroups.items, .hotkeys = &self.config.hotkeys, .global = self.global_settings };
    }

    fn formatKeyName(virtual_key: u32, buffer: *[KEY_NAME_SIZE]u8) []const u8 {
        var writer: std.Io.Writer = .fixed(buffer);
        vk.writeVirtualKey(&writer, virtual_key) catch |err| {
            slog.warn("Failed to format virtual key 0x{X}: {}", .{ virtual_key, err });
            // "VK" and at most 8 hex digits always fit.
            return std.mem.print(buffer, "VK{X}", .{virtual_key}) catch unreachable;
        };
        return writer.buffered();
    }

    /// Tracks the entry's action once if any key registers, since they all post one ID; logs each failure itself and returns how many failed.
    fn registerKeys(self: *HotkeyManager, hwnd: win32.HWND, entry: plan_mod.Entry) usize {
        var key_name_buf: [KEY_NAME_SIZE]u8 = undefined;
        var registered: config_mod.KeyList = .empty;
        for (entry.keys.slice()) |virtual_key| {
            hooks.register(hwnd, virtual_key, entry.id) catch |err| {
                slog.err("Failed to register hotkey {s} ({s}): {}", .{ formatKeyName(virtual_key, &key_name_buf), entry.description, err });
                continue;
            };
            _ = registered.append(virtual_key);
            slog.debug("Registered hotkey: {s} -> {s}", .{ formatKeyName(virtual_key, &key_name_buf), entry.description });
        }
        if (registered.isEmpty()) return entry.keys.len;

        self.hotkey_map.put(entry.id, entry.action) catch |err| {
            slog.err("Failed to track hotkey ({s}): {}", .{ entry.description, err });
            for (registered.slice()) |virtual_key| hooks.unregister(virtual_key);
            return entry.keys.len;
        };
        return entry.keys.len - registered.len;
    }

    /// Replaces whatever is registered, so resuming restores exactly the saved bindings.
    pub fn registerHotkeys(self: *HotkeyManager, hwnd: win32.HWND) !void {
        self.unregisterAll();
        hooks.setExactModifiers(self.config.hotkeys.exactHotkeyModifiers);

        var built = try plan_mod.build(self.allocator, self.planSettings());
        if (built.isEmpty()) {
            built.deinit();
            slog.debug("No hotkeys configured", .{});
            return;
        }
        self.plan = built;
        const planned = &self.plan.?;

        const counts = planned.counts;
        slog.debug("Registering hotkeys: {} group(s), {} global action(s), {} per-character hotkey(s), {} profile-switch hotkey(s), {} app hotkey(s), {} url hotkey(s)", .{ counts.groups, counts.globals, counts.character_combos, counts.profile_switches, counts.apps, counts.urls });

        var failed_count: usize = 0;
        for (planned.overflows.items) |overflow| {
            slog.err("Failed to register hotkey group '{s}' {s}: too many group cycle keys", .{ overflow.group_name, cycle_order.directionName(overflow.is_forward) });
            failed_count += 1;
        }
        for (planned.entries.items) |entry| failed_count += self.registerKeys(hwnd, entry);

        const success_count: usize = self.hotkey_map.count();
        if (failed_count > 0) {
            if (success_count == 0) {
                slog.err("Failed to register any hotkeys ({} key(s) failed), so none will work", .{failed_count});
                self.unregisterAll();
                return error.RegisterHotkeysFailed;
            }
            // The hotkeys that did register stay live.
            slog.warn("Failed to register {} key(s); the other {} hotkey(s) still work", .{ failed_count, success_count });
            return error.RegisterHotkeysFailed;
        }

        slog.debug("Successfully registered all {} hotkey(s)", .{success_count});
    }

    pub fn unregisterAll(self: *HotkeyManager) void {
        hooks.unregisterAll();
        slog.debug("Unregistering {} hotkey(s)", .{self.hotkey_map.count()});
        self.hotkey_map.clearRetainingCapacity();
        if (self.plan) |*planned| planned.deinit();
        self.plan = null;
    }

    /// Handles a WM_HOTKEY press; `lParam` says whether it's a held key's auto-repeat, and `thumbnail_set` is App's current one, null while it's rebuilt.
    pub fn handleHotkeyPress(self: *HotkeyManager, hotkey_id: c_int, lParam: win32.LPARAM, thumbnail_set: ?*ThumbnailSet) Outcome {
        const action = self.hotkey_map.getPtr(hotkey_id) orelse {
            slog.warn("Received unknown hotkey ID: {}", .{hotkey_id});
            return .none;
        };

        const verdict = plan_mod.pressVerdict(.{
            .is_repeat = hook_bindings.isRepeat(lParam),
            .allows_repeat = self.live().hotkeys.allowHotkeyAutoRepeat,
            .is_suspend_key = action.* == .suspend_hotkeys,
            .are_hotkeys_suspended = self.are_hotkeys_suspended,
            .is_dialog_recording = self.is_dialog_suspended,
            .requires_eve_focus = self.live().hotkeys.requireEveFocus,
            // Checked again after the hook's check, since focus can move before this message arrives.
            .has_eve_focus = self.foregroundEveWindow() != null,
        });
        switch (verdict) {
            .run => return self.runAction(action, thumbnail_set),
            .toggle_suspend => self.toggleSuspend(),
            .ignore_repeat => slog.debug("Hotkey {} ignored - key-repeat re-fire while held", .{hotkey_id}),
            .ignore_suspended => slog.debug("Hotkey {} ignored - hotkeys suspended", .{hotkey_id}),
            .ignore_recording => slog.debug("Hotkey {} ignored - config dialog is recording a new hotkey", .{hotkey_id}),
            .ignore_unfocused => slog.debug("Hotkey {} ignored - EVE window not in focus", .{hotkey_id}),
        }
        return .none;
    }

    /// Per tick: hands the hook thread the windows and setting the require-EVE-focus check needs, whenever they change, so it can let keys through to other apps.
    pub fn syncFocusFilter(self: *HotkeyManager, windows: []const scout_mod.EveWindow) void {
        var filter: hook_bindings.FocusFilter = .{
            .is_required = self.live().hotkeys.requireEveFocus,
            .exempt_id = bindings.globalId(.suspend_hotkeys),
        };
        const is_complete = for (windows) |eve_window| {
            if (!filter.add(eve_window.hwnd)) break false;
        } else true;
        if (self.sent_focus_filter) |*sent| {
            if (sent.eql(&filter)) return;
        }
        if (!is_complete) slog.warn("Failed to pass every window to the require-EVE-focus check: over {} tracked, so hotkeys pass through in the rest", .{filter.window_count});
        if (hook_bindings.setFocusFilter(filter)) self.sent_focus_filter = filter;
    }

    /// Runs a global action requested outside a hotkey press (protocol URL, tray menu), bypassing the press-only suspend/focus gating.
    pub fn runGlobalAction(self: *HotkeyManager, action: url.GlobalAction, thumbnail_set: ?*ThumbnailSet) Outcome {
        var hotkey_action = bindings.fromProtocol(action);
        return self.runAction(&hotkey_action, thumbnail_set);
    }

    /// Like runGlobalAction, for the hotkey group named `group_name`; a cycle runs that group alone, even if its key is shared.
    pub fn runGroupAction(self: *HotkeyManager, action: url.GroupAction, group_name: []const u8, thumbnail_set: ?*ThumbnailSet) Outcome {
        const group_index = self.config.hotkeyGroupIndex(group_name) orelse {
            slog.warn("Failed to run group '{s}': no hotkey group named '{s}'", .{ @tagName(action), group_name });
            return .none;
        };
        const group_indices = [_]usize{group_index};
        var hotkey_action: HotkeyAction = switch (action) {
            .next => .{ .cycle_group = .{ .group_indices = &group_indices, .is_forward = true } },
            .previous => .{ .cycle_group = .{ .group_indices = &group_indices, .is_forward = false } },
            .assign => .{ .assign_group = .{ .group_index = group_index } },
            .minimize => .{ .minimize_group = .{ .group_index = group_index } },
            .close => .{ .close_group = .{ .group_index = group_index } },
        };
        return self.runAction(&hotkey_action, thumbnail_set);
    }

    /// Takes a pointer so per-character hotkeys can advance their cursor in hotkey_map.
    fn runAction(self: *HotkeyManager, action: *HotkeyAction, thumbnail_set: ?*ThumbnailSet) Outcome {
        switch (action.*) {
            .cycle_group => |chain| return activating(cycling.cycleGroups(self, chain.group_indices, chain.is_forward)),
            .activate_character => |*character_group| return activating(cycling.activatePerCharacterGroup(self, character_group)),
            .assign_group => |assign| if (thumbnail_set) |active_set| membership.assignHoveredToGroup(self, active_set, assign.group_index),
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
                if (thumbnail_set) |active_set| active_set.toggleAllThumbnailsVisibility();
            },
            .next_profile => return .{ .app = .next_profile },
            .previous_profile => return .{ .app = .previous_profile },
            .switch_to_profile => |switch_to| return self.profileSwitchTarget(switch_to.profile_index),
            .toggle_exclusion => self.toggleForegroundExclusion(thumbnail_set),
            .next_excluded => return activating(cycling.cycleExcluded(self, true)),
            .previous_excluded => return activating(cycling.cycleExcluded(self, false)),
            .suspend_hotkeys => self.toggleSuspend(),
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
                const active_set = thumbnail_set orelse return .none;
                actions.moveAllClientsToSavedPositions(self.scout.getWindows(), self.live(), active_set);
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

    fn profileSwitchTarget(self: *const HotkeyManager, profile_index: usize) Outcome {
        const profile_hotkeys = self.global_settings.profileSwitchHotkeys.items;
        if (profile_index >= profile_hotkeys.len) {
            slog.err("Failed to switch profile: hotkey index {} is out of range", .{profile_index});
            return .none;
        }
        const target_profile = profile_hotkeys[profile_index].targetProfile;
        slog.info("Switch to profile hotkey pressed: {s} -> {s}", .{ self.config.profile_name, target_profile });
        return .{ .switch_profile = target_profile };
    }

    pub fn foregroundEveWindow(self: *const HotkeyManager) ?scout_mod.EveWindow {
        const foreground_hwnd = win32.GetForegroundWindow() orelse return null;
        for (self.scout.getWindows()) |eve_window| {
            if (eve_window.hwnd == foreground_hwnd) return eve_window;
        }
        return null;
    }

    fn toggleForegroundExclusion(self: *HotkeyManager, thumbnail_set: ?*ThumbnailSet) void {
        const eve_window = self.foregroundEveWindow() orelse {
            slog.debug("Focused window is not an EVE client, exclusion toggle ignored", .{});
            return;
        };
        slog.info("Toggle exclusion hotkey pressed for: {s}", .{eve_window.character_name});
        membership.toggleThumbnailExclusion(self, thumbnail_set orelse return, eve_window.hwnd);
    }

    fn closeForegroundClient(self: *const HotkeyManager) void {
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

    fn toggleSuspend(self: *HotkeyManager) void {
        self.are_hotkeys_suspended = !self.are_hotkeys_suspended;
        const state = if (self.are_hotkeys_suspended) "suspended" else "resumed";
        slog.info("Hotkeys {s}", .{state});

        const hwnd = self.timer_hwnd;
        if (self.are_hotkeys_suspended) {
            // Unbound, since the hooks would otherwise keep swallowing these keys system-wide.
            self.unregisterAll();
            // Pressing it again must still be able to resume everything else.
            if (plan_mod.globalEntry(self.planSettings(), bindings.SUSPEND_BINDING)) |entry| _ = self.registerKeys(hwnd, entry);
        } else {
            self.registerHotkeys(hwnd) catch |err| {
                slog.err("Failed to re-register hotkeys after resuming: {}", .{err});
            };
        }
        if (!win32.toBool(win32.PostMessageA(hwnd, win32.WM_HOTKEYS_STATE_CHANGED, 0, 0))) {
            slog.warn("Failed to show that hotkeys were {s}: error {d}", .{ state, win32.GetLastError() });
        }
    }

    pub fn areHotkeysSuspended(self: *const HotkeyManager) bool {
        return self.are_hotkeys_suspended;
    }

    /// Unbinds rather than gates, since the hooks would otherwise swallow the key the dialog is recording.
    pub fn dialogSuspendHotkeys(self: *HotkeyManager) void {
        if (self.is_dialog_suspended) return;
        slog.debug("Config dialog is recording a hotkey - unregistering live hotkeys", .{});
        self.is_dialog_suspended = true;
        self.unregisterAll();
        keyboard_hook.armWinKeyCapture(self.timer_hwnd);
    }

    /// Re-registers from the same in-memory config unregisterAll left untouched, so this restores exactly what was live before.
    pub fn dialogResumeHotkeys(self: *HotkeyManager, hwnd: win32.HWND) void {
        if (!self.is_dialog_suspended) return;
        slog.debug("Config dialog finished recording - re-registering hotkeys", .{});
        self.is_dialog_suspended = false;
        keyboard_hook.disarmWinKeyCapture();
        self.registerHotkeys(hwnd) catch |err| {
            slog.err("Failed to re-register hotkeys after dialog recording: {}", .{err});
        };
    }

    /// Unbinds rather than gates, since the hooks would otherwise swallow the letters typed; hotkeys already suspended stay as they are.
    pub fn typingSuspendHotkeys(self: *HotkeyManager) void {
        if (self.are_hotkeys_suspended or self.is_dialog_suspended or self.is_typing_suspended) return;
        self.is_typing_suspended = true;
        self.unregisterAll();
    }

    pub fn typingResumeHotkeys(self: *HotkeyManager, hwnd: win32.HWND) void {
        if (!self.is_typing_suspended) return;
        self.is_typing_suspended = false;
        self.registerHotkeys(hwnd) catch |err| {
            slog.err("Failed to re-register hotkeys after typing: {}", .{err});
        };
    }

    pub fn updateFocusedCharacter(self: *HotkeyManager, character_name: []const u8, hwnd: win32.HWND) void {
        cycling.syncToFocusedCharacter(self, character_name, hwnd);
    }

    pub fn clearLoggedOutExclusion(self: *HotkeyManager, character_name: []const u8) void {
        membership.clearLoggedOutExclusion(self, character_name);
    }

    pub fn deinit(self: *HotkeyManager) void {
        self.unregisterAll();
        self.cycle.deinit(self.allocator);
        self.hotkey_map.deinit();
    }
};

fn activating(client: ?win32.HWND) Outcome {
    return if (client) |hwnd| .{ .activate = hwnd } else .none;
}
