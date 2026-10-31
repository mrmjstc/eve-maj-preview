//! Registering hotkeys and dispatching each press to its action.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const scout = @import("../clients/scout.zig");
const actions = @import("../clients/actions.zig");
const exclusions_mod = @import("../clients/exclusions.zig");
const config_mod = @import("../config.zig");
const url = @import("../protocol/url.zig");
const app_mod = @import("../app.zig");
const alert_effects = @import("../notifications/alert_effects.zig");
const notified_queue_mod = @import("../notifications/notified_queue.zig");
const mouse_hook = @import("mouse_hook.zig");
const keyboard_hook = @import("keyboard_hook.zig");
const hook_bindings = @import("hook_bindings.zig");
const bindings = @import("bindings.zig");
const cycling = @import("cycling.zig");
const cycle_order = @import("cycle_order.zig");
const membership = @import("membership.zig");
const profile_switch = @import("profile_switch.zig");
const launch = @import("launch.zig");
const log = @import("../log.zig");

const HotkeyAction = bindings.HotkeyAction;
const KeyList = config_mod.KeyList;
const slog = log.Scoped("hotkeys");

const KEY_NAME_SIZE = 32;
const DESCRIPTION_SIZE = 160;

/// The characters or hotkey groups bound to one key combo, in config order.
const ComboSharers = struct {
    virtual_key: u32,
    indices: std.ArrayList(usize),
};

pub const HotkeyManager = struct {
    allocator: std.mem.Allocator,
    /// Outlives the manager; for app-level actions, and its thumbnail set, read from here each time since a rebuild replaces it.
    app: *app_mod.App,
    /// The saved copy, for the bindings and the groups and characters their ids index into; other settings read live().
    config: *const config_mod.Config,
    /// Borrowed; outlives the manager.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the manager.
    global_settings: *const config_mod.GlobalConfig,
    /// A function rather than a pointer, since the config window's draft it may return comes and goes.
    live_global: *const fn () *const config_mod.GlobalConfig,
    /// Borrowed from `app`.
    scout: *scout.Scout,
    hotkey_map: std.AutoHashMap(c_int, HotkeyAction),
    /// The suspend hotkey itself stays live.
    are_hotkeys_suspended: bool = false,
    /// Whether the config dialog is recording a new hotkey; kept separate from are_hotkeys_suspended so the two don't clobber each other.
    is_dialog_suspended: bool = false,
    cycle: cycling.CycleState,
    /// Borrowed from `app`, which keeps them across the Save that recreates the manager.
    exclusions: *exclusions_mod.Exclusions,
    /// Borrowed from `app`, which keeps it across the Save that recreates the manager.
    notified_queue: *const notified_queue_mod.NotifiedQueue,
    /// Borrowed from `app`'s focus tracker, which keeps it across the Save that recreates the manager.
    last_non_eve_foreground: *?win32.HWND,
    /// What syncFocusFilter last handed the hook thread; null until it first does, so a recreated manager sends it again.
    sent_focus_filter: ?hook_bindings.FocusFilter = null,

    /// Registers from the profile's saved copy, since bindings only change on Save.
    pub fn init(allocator: std.mem.Allocator, app: *app_mod.App, live_global: *const fn () *const config_mod.GlobalConfig) !HotkeyManager {
        const config = &app.store.saved;
        return .{
            .allocator = allocator,
            .app = app,
            .config = config,
            .store = &app.store,
            .global_settings = &app.global_settings,
            .live_global = live_global,
            .scout = &app.scout,
            .hotkey_map = .init(allocator),
            .cycle = try cycling.CycleState.init(allocator, config.hotkeyGroups.items.len),
            .exclusions = &app.exclusions,
            .notified_queue = &app.notifications.notified_queue,
            .last_non_eve_foreground = &app.focus.last_non_eve_foreground,
        };
    }

    /// The running copy, including the dialog's unsaved edits.
    pub fn live(self: *const HotkeyManager) *const config_mod.Config {
        return &self.store.live;
    }

    /// Like live(), for the global settings; `global_settings` stays the saved copy the bindings came from.
    pub fn liveGlobal(self: *const HotkeyManager) *const config_mod.GlobalConfig {
        return self.live_global();
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

    /// Either hook re-posts a match to `hwnd` as WM_HOTKEY.
    fn hookKey(hwnd: win32.HWND, id: c_int, virtual_key: u32) !void {
        if (vk.isMouseHookVk(vk.extractVk(virtual_key))) try mouse_hook.register(hwnd, virtual_key, id) else try keyboard_hook.register(hwnd, virtual_key, id);
    }

    fn unhookKey(virtual_key: u32) void {
        if (vk.isMouseHookVk(vk.extractVk(virtual_key))) mouse_hook.unregister(virtual_key) else keyboard_hook.unregister(virtual_key);
    }

    /// Tracks `action` once if any key registers, since they all post one ID; logs each failure itself and returns how many failed.
    fn registerKeys(self: *HotkeyManager, hwnd: win32.HWND, id: c_int, keys: KeyList, action: HotkeyAction, description: []const u8) usize {
        var key_name_buf: [KEY_NAME_SIZE]u8 = undefined;
        var registered: KeyList = .empty;
        for (keys.slice()) |virtual_key| {
            hookKey(hwnd, id, virtual_key) catch |err| {
                slog.err("Failed to register hotkey {s} ({s}): {}", .{ formatKeyName(virtual_key, &key_name_buf), description, err });
                continue;
            };
            _ = registered.append(virtual_key);
            slog.debug("Registered hotkey: {s} -> {s}", .{ formatKeyName(virtual_key, &key_name_buf), description });
        }
        if (registered.isEmpty()) return keys.len;

        self.hotkey_map.put(id, action) catch |err| {
            slog.err("Failed to track hotkey ({s}): {}", .{ description, err });
            for (registered.slice()) |virtual_key| unhookKey(virtual_key);
            return keys.len;
        };
        return keys.len - registered.len;
    }

    fn bindingKeys(self: *const HotkeyManager, comptime binding: bindings.GlobalBinding) KeyList {
        return if (binding.is_global_setting) @field(self.global_settings, binding.field) else @field(self.config.hotkeys, binding.field);
    }

    /// Returns how many keys failed to register; groups sharing a combo cycle as one list.
    fn registerGroupChains(self: *HotkeyManager, hwnd: win32.HWND, chains: []const ComboSharers, is_forward: bool) usize {
        var failed_count: usize = 0;
        var description_buf: [DESCRIPTION_SIZE]u8 = undefined;
        for (chains, 0..) |chain, chain_index| {
            const first_name = self.config.hotkeyGroups.items[chain.indices.items[0]].name;
            const slot = chain_index * 2 + @intFromBool(!is_forward);
            if (slot >= bindings.CYCLE_GROUP_SLOT_COUNT) {
                slog.err("Failed to register hotkey group '{s}' {s}: too many group cycle keys", .{ first_name, cycle_order.directionName(is_forward) });
                failed_count += 1;
                continue;
            }

            const description = if (chain.indices.items.len == 1)
                formatDescription(&description_buf, "group [{s}] {s}", .{ first_name, cycle_order.directionName(is_forward) }, "group cycle")
            else
                formatDescription(&description_buf, "groups [{s}...] {s} ({} sharing hotkey)", .{ first_name, cycle_order.directionName(is_forward), chain.indices.items.len }, "shared group cycle");

            const owned_indices = self.allocator.dupe(usize, chain.indices.items) catch |err| {
                slog.err("Failed to copy hotkey group chain '{s}': {}", .{ first_name, err });
                failed_count += 1;
                continue;
            };
            // A single key, so any failure means the action wasn't tracked and the indices are still ours.
            const failed = self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_CYCLE_GROUP_BASE, slot), .one(chain.virtual_key), .{ .cycle_group = .{ .group_indices = owned_indices, .is_forward = is_forward } }, description);
            if (failed > 0) {
                self.allocator.free(owned_indices);
                failed_count += failed;
            }
        }
        return failed_count;
    }

    /// Returns how many of the group's `keys` failed to register.
    fn registerGroupKey(self: *HotkeyManager, hwnd: win32.HWND, base: c_int, group_index: usize, keys: KeyList, action: HotkeyAction, comptime verb: []const u8) usize {
        if (keys.isEmpty()) return 0;
        var description_buf: [DESCRIPTION_SIZE]u8 = undefined;
        const description = formatDescription(&description_buf, "group {} [{s}] " ++ verb, .{ group_index, self.config.hotkeyGroups.items[group_index].name }, "group " ++ verb);
        return self.registerKeys(hwnd, bindings.bandId(base, group_index), keys, action, description);
    }

    /// Returns how many of the binding's keys failed to register.
    fn registerGlobal(self: *HotkeyManager, hwnd: win32.HWND, comptime binding: bindings.GlobalBinding) usize {
        return self.registerKeys(hwnd, bindings.globalId(binding.action), self.bindingKeys(binding), bindings.actionFor(binding.action), binding.description);
    }

    pub fn registerHotkeys(self: *HotkeyManager, hwnd: win32.HWND) !void {
        keyboard_hook.setExactModifiers(self.config.hotkeys.exactHotkeyModifiers);
        mouse_hook.setExactModifiers(self.config.hotkeys.exactHotkeyModifiers);
        // Grouped per combo, so characters (or groups) sharing one cycle through each other while their other combos stay their own.
        var per_character_groups: std.ArrayList(ComboSharers) = .empty;
        defer deinitComboSharers(self.allocator, &per_character_groups);
        for (self.config.characters.items, 0..) |*character, character_index| {
            for (character.hotkey.slice()) |hotkey_vk| try addComboSharer(self.allocator, &per_character_groups, hotkey_vk, character_index);
        }
        var forward_chains: std.ArrayList(ComboSharers) = .empty;
        defer deinitComboSharers(self.allocator, &forward_chains);
        var backward_chains: std.ArrayList(ComboSharers) = .empty;
        defer deinitComboSharers(self.allocator, &backward_chains);
        for (self.config.hotkeyGroups.items, 0..) |*group, group_index| {
            for (group.forwardKey.slice()) |group_vk| try addComboSharer(self.allocator, &forward_chains, group_vk, group_index);
            for (group.backwardKey.slice()) |group_vk| try addComboSharer(self.allocator, &backward_chains, group_vk, group_index);
        }
        const per_character_count = per_character_groups.items.len;
        const profile_switch_count = countBound(self.global_settings.profileSwitchHotkeys.items);
        const app_hotkey_count = countBound(self.global_settings.appHotkeys.items);
        const url_hotkey_count = countBound(self.global_settings.urlHotkeys.items);
        var global_count: usize = 0;
        inline for (bindings.GLOBAL_BINDINGS) |binding| {
            if (!self.bindingKeys(binding).isEmpty()) global_count += 1;
        }

        if (self.config.hotkeyGroups.items.len == 0 and global_count == 0 and per_character_count == 0 and profile_switch_count == 0 and app_hotkey_count == 0 and url_hotkey_count == 0) {
            slog.debug("No hotkeys configured", .{});
            return;
        }

        slog.debug("Registering hotkeys: {} group(s), {} global action(s), {} per-character hotkey(s), {} profile-switch hotkey(s), {} app hotkey(s), {} url hotkey(s)", .{
            self.config.hotkeyGroups.items.len,
            global_count,
            per_character_count,
            profile_switch_count,
            app_hotkey_count,
            url_hotkey_count,
        });

        var failed_count: usize = 0;
        var description_buf: [DESCRIPTION_SIZE]u8 = undefined;

        // First, since a combo bound twice stays with whoever registers it first, and suspend and exit must keep theirs.
        inline for (bindings.GLOBAL_BINDINGS) |binding| {
            failed_count += self.registerGlobal(hwnd, binding);
        }

        failed_count += self.registerGroupChains(hwnd, forward_chains.items, true);
        failed_count += self.registerGroupChains(hwnd, backward_chains.items, false);

        for (self.config.hotkeyGroups.items, 0..) |*group, group_index| {
            failed_count += self.registerGroupKey(hwnd, bindings.HOTKEY_ID_ASSIGN_GROUP_BASE, group_index, group.assignKey, .{ .assign_group = .{ .group_index = group_index } }, "assign");
            failed_count += self.registerGroupKey(hwnd, bindings.HOTKEY_ID_MINIMIZE_GROUP_BASE, group_index, group.minimizeKey, .{ .minimize_group = .{ .group_index = group_index } }, "minimize");
            failed_count += self.registerGroupKey(hwnd, bindings.HOTKEY_ID_CLOSE_GROUP_BASE, group_index, group.closeKey, .{ .close_group = .{ .group_index = group_index } }, "close");
        }

        for (per_character_groups.items, 0..) |*group, group_index| {
            const first_name = self.config.characters.items[group.indices.items[0]].name;
            const description = if (group.indices.items.len == 1)
                formatDescription(&description_buf, "activate character [{s}]", .{first_name}, "activate character")
            else
                formatDescription(&description_buf, "activate character [{s}...] ({} sharing hotkey)", .{ first_name, group.indices.items.len }, "activate character group");

            const owned_indices = self.allocator.dupe(usize, group.indices.items) catch |err| {
                slog.err("Failed to copy the hotkey group starting with '{s}': {}", .{ first_name, err });
                failed_count += 1;
                continue;
            };
            // A single key, so any failure means the action wasn't tracked and the indices are still ours.
            const failed = self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_PER_CHARACTER_BASE, group_index), .one(group.virtual_key), .{ .activate_character = .{ .character_indices = owned_indices } }, description);
            if (failed > 0) {
                self.allocator.free(owned_indices);
                failed_count += failed;
            }
        }

        for (self.global_settings.profileSwitchHotkeys.items, 0..) |profile_hotkey, index| {
            if (profile_hotkey.hotkey.isEmpty()) continue;
            const description = formatDescription(&description_buf, "switch to profile [{s}]", .{profile_hotkey.targetProfile}, "switch to profile");
            failed_count += self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_PROFILE_SWITCH_BASE, index), profile_hotkey.hotkey, .{ .switch_to_profile = .{ .profile_index = index } }, description);
        }

        for (self.global_settings.appHotkeys.items, 0..) |app_hotkey, index| {
            if (app_hotkey.hotkey.isEmpty()) continue;
            const description = formatDescription(&description_buf, "activate app [{s}]", .{app_hotkey.executableName}, "activate app");
            failed_count += self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_APP_HOTKEY_BASE, index), app_hotkey.hotkey, .{ .activate_app = .{ .app_index = index } }, description);
        }

        for (self.global_settings.urlHotkeys.items, 0..) |url_hotkey, index| {
            if (url_hotkey.hotkey.isEmpty()) continue;
            const description = formatDescription(&description_buf, "open url [{s}]", .{url_hotkey.url}, "open url");
            failed_count += self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_URL_HOTKEY_BASE, index), url_hotkey.hotkey, .{ .open_url = .{ .url_index = index } }, description);
        }

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
        mouse_hook.unregisterAll();
        keyboard_hook.unregisterAll();

        var it = self.hotkey_map.valueIterator();
        while (it.next()) |action| {
            if (action.* == .activate_character) self.allocator.free(action.activate_character.character_indices);
            if (action.* == .cycle_group) self.allocator.free(action.cycle_group.group_indices);
        }

        slog.debug("Unregistering {} hotkey(s)", .{self.hotkey_map.count()});
        self.hotkey_map.clearRetainingCapacity();
    }

    /// Handles a WM_HOTKEY press; `lParam` says whether it's a held key's auto-repeat.
    pub fn handleHotkeyPress(self: *HotkeyManager, hotkey_id: c_int, lParam: win32.LPARAM) void {
        const action = self.hotkey_map.getPtr(hotkey_id) orelse {
            slog.warn("Received unknown hotkey ID: {}", .{hotkey_id});
            return;
        };

        if (hook_bindings.isRepeat(lParam) and !self.live().hotkeys.allowHotkeyAutoRepeat) {
            slog.debug("Hotkey {} ignored - key-repeat re-fire while held", .{hotkey_id});
            return;
        }

        if (action.* == .suspend_hotkeys) {
            self.toggleSuspend();
            return;
        }

        if (self.are_hotkeys_suspended) {
            slog.debug("Hotkey {} ignored - hotkeys suspended", .{hotkey_id});
            return;
        }

        if (self.is_dialog_suspended) {
            slog.debug("Hotkey {} ignored - config dialog is recording a new hotkey", .{hotkey_id});
            return;
        }

        // Checked again after the hook's check, since focus can move before this message arrives.
        if (self.live().hotkeys.requireEveFocus and self.foregroundEveWindow() == null) {
            slog.debug("Hotkey {} ignored - EVE window not in focus", .{hotkey_id});
            return;
        }

        self.runAction(action);
    }

    /// Per tick: hands the hook thread the windows and setting the require-EVE-focus check needs, whenever they change, so it can let keys through to other apps.
    pub fn syncFocusFilter(self: *HotkeyManager, windows: []const scout.EveWindow) void {
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
    pub fn runGlobalAction(self: *HotkeyManager, action: url.GlobalAction) void {
        var hotkey_action = bindings.fromProtocol(action);
        self.runAction(&hotkey_action);
    }

    /// Like runGlobalAction, for the hotkey group named `group_name`; a cycle runs that group alone, even if its key is shared.
    pub fn runGroupAction(self: *HotkeyManager, action: url.GroupAction, group_name: []const u8) void {
        const group_index = self.config.hotkeyGroupIndex(group_name) orelse {
            slog.warn("Failed to run group '{s}': no hotkey group named '{s}'", .{ @tagName(action), group_name });
            return;
        };
        const group_indices = [_]usize{group_index};
        var hotkey_action: HotkeyAction = switch (action) {
            .next => .{ .cycle_group = .{ .group_indices = &group_indices, .is_forward = true } },
            .previous => .{ .cycle_group = .{ .group_indices = &group_indices, .is_forward = false } },
            .assign => .{ .assign_group = .{ .group_index = group_index } },
            .minimize => .{ .minimize_group = .{ .group_index = group_index } },
            .close => .{ .close_group = .{ .group_index = group_index } },
        };
        self.runAction(&hotkey_action);
    }

    /// Takes a pointer so per-character hotkeys can advance their cursor in hotkey_map.
    fn runAction(self: *HotkeyManager, action: *HotkeyAction) void {
        switch (action.*) {
            .cycle_group => |chain| cycling.cycleGroups(self, chain.group_indices, chain.is_forward),
            .activate_character => |*character_group| cycling.activatePerCharacterGroup(self, character_group),
            .assign_group => |assign| membership.assignHoveredToGroup(self, assign.group_index),
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
                if (self.app.thumbnail_set) |thumbnail_set| thumbnail_set.toggleAllThumbnailsVisibility();
            },
            .next_profile => profile_switch.cycle(self.app, self.config.profile_name, true),
            .previous_profile => profile_switch.cycle(self.app, self.config.profile_name, false),
            .switch_to_profile => |switch_to| profile_switch.switchTo(self.app, self.config.profile_name, switch_to.profile_index),
            .toggle_exclusion => self.toggleForegroundExclusion(),
            .next_excluded => cycling.cycleExcluded(self, true),
            .previous_excluded => cycling.cycleExcluded(self, false),
            .suspend_hotkeys => self.toggleSuspend(),
            .toggle_auto_minimize => {
                slog.info("Toggle auto-minimize hotkey pressed", .{});
                self.app.toggleAutoMinimize();
            },
            .toggle_alert_mute => alert_effects.toggleMuted(),
            .cycle_notified => cycling.cycleNotified(self, true),
            .previous_notified => cycling.cycleNotified(self, false),
            .next_all_clients => cycling.cycleAllClients(self, true),
            .previous_all_clients => cycling.cycleAllClients(self, false),
            .next_not_logged_in => cycling.cycleNotLoggedIn(self, true),
            .previous_not_logged_in => cycling.cycleNotLoggedIn(self, false),
            .move_to_saved_positions => {
                slog.info("Move to saved positions hotkey pressed", .{});
                const thumbnail_set = self.app.thumbnail_set orelse return;
                actions.moveAllClientsToSavedPositions(self.scout.getWindows(), self.live(), thumbnail_set);
            },
            .return_to_last_app => launch.returnToLastApp(self.last_non_eve_foreground),
            .next_app => launch.cycleApps(self.global_settings, true),
            .previous_app => launch.cycleApps(self.global_settings, false),
            .exit_app => {
                slog.info("Exit hotkey pressed", .{});
                app_mod.requestExit();
            },
            .close_active => self.closeForegroundClient(),
            .toggle_dragging => self.app.toggleDragging(),
            .toggle_travel_mode => self.app.toggleTravelMode(),
            .toggle_notification_history => self.app.toggleNotificationHistory(),
            .clear_notification_history => {
                slog.info("Clear notification history hotkey pressed", .{});
                self.app.notifications.clearHistories();
            },
            .toggle_map_panel => self.app.toggleMapPanel(),
            .toggle_intel_panel => self.app.toggleIntelPanel(),
            .activate_app => |activate| launch.activateApp(self.global_settings, activate.app_index),
            .open_url => |open_url| launch.openUrl(self.allocator, self.global_settings, open_url.url_index),
        }
    }

    pub fn foregroundEveWindow(self: *const HotkeyManager) ?scout.EveWindow {
        const foreground_hwnd = win32.GetForegroundWindow() orelse return null;
        for (self.scout.getWindows()) |eve_window| {
            if (eve_window.hwnd == foreground_hwnd) return eve_window;
        }
        return null;
    }

    fn toggleForegroundExclusion(self: *HotkeyManager) void {
        const eve_window = self.foregroundEveWindow() orelse {
            slog.debug("Focused window is not an EVE client, exclusion toggle ignored", .{});
            return;
        };
        slog.info("Toggle exclusion hotkey pressed for: {s}", .{eve_window.character_name});
        membership.toggleThumbnailExclusion(self, eve_window.hwnd);
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

        if (self.app.timer_hwnd) |hwnd| {
            if (self.are_hotkeys_suspended) {
                // Unbound, since the hooks would otherwise keep swallowing these keys system-wide.
                self.unregisterAll();
                // Pressing it again must still be able to resume everything else.
                _ = self.registerGlobal(hwnd, bindings.SUSPEND_BINDING);
            } else {
                self.registerHotkeys(hwnd) catch |err| {
                    slog.err("Failed to re-register hotkeys after resuming: {}", .{err});
                };
            }
            if (!win32.toBool(win32.PostMessageA(hwnd, win32.WM_HOTKEYS_STATE_CHANGED, 0, 0))) {
                slog.warn("Failed to show that hotkeys were {s}: error {d}", .{ state, win32.GetLastError() });
            }
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
        if (self.app.timer_hwnd) |hwnd| keyboard_hook.armWinKeyCapture(hwnd);
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

fn addComboSharer(allocator: std.mem.Allocator, list: *std.ArrayList(ComboSharers), combo_vk: u32, index: usize) !void {
    for (list.items) |*sharers| {
        if (sharers.virtual_key == combo_vk) return sharers.indices.append(allocator, index);
    }
    var sharers: ComboSharers = .{ .virtual_key = combo_vk, .indices = .empty };
    errdefer sharers.indices.deinit(allocator);
    try sharers.indices.append(allocator, index);
    try list.append(allocator, sharers);
}

fn deinitComboSharers(allocator: std.mem.Allocator, list: *std.ArrayList(ComboSharers)) void {
    for (list.items) |*sharers| sharers.indices.deinit(allocator);
    list.deinit(allocator);
}

/// `items` is a slice of configs with a `hotkey: KeyList` field.
fn countBound(items: anytype) usize {
    var bound_count: usize = 0;
    for (items) |item| {
        if (!item.hotkey.isEmpty()) bound_count += 1;
    }
    return bound_count;
}

/// Falls back to `fallback`, logged, when a long name doesn't fit `buffer`.
fn formatDescription(buffer: []u8, comptime format: []const u8, args: anytype, fallback: []const u8) []const u8 {
    return std.mem.print(buffer, format, args) catch |err| blk: {
        slog.warn("Failed to describe hotkey '{s}': {}", .{ fallback, err });
        break :blk fallback;
    };
}
