//! Registering hotkeys and dispatching each press to its action.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const vk = @import("../platform/virtual_keys.zig");
const scout = @import("../clients/scout.zig");
const client_actions = @import("../clients/actions.zig");
const auto_minimize = @import("../clients/auto_minimize.zig");
const config_mod = @import("../config.zig");
const protocol = @import("../protocol.zig");
const painter_mod = @import("../painter.zig");
const main = @import("../main.zig");
const mouse_hook = @import("mouse_hook.zig");
const keyboard_hook = @import("keyboard_hook.zig");
const bindings = @import("bindings.zig");
const cycling = @import("cycling.zig");
const membership = @import("membership.zig");
const profile_switch = @import("profile_switch.zig");
const launch = @import("launch.zig");
const log = @import("../log.zig");

const HotkeyAction = bindings.HotkeyAction;
const KeyList = config_mod.KeyList;
const slog = log.scoped("hotkeys");

/// Cycling, exclusions, profile switching and app/URL launching live in their own modules.
pub const HotkeyManager = struct {
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    store: *config_mod.ProfileStore,
    global_settings: *const config_mod.GlobalConfig,
    scout: *scout.Scout,
    painter: *painter_mod.Painter,
    hotkey_map: std.AutoHashMap(c_int, HotkeyAction),
    /// The suspend hotkey itself stays live.
    hotkeys_suspended: bool = false,
    /// Whether the config dialog is recording a new hotkey; kept separate from hotkeys_suspended so the two don't clobber each other.
    dialog_suspended: bool = false,
    cycle: cycling.CycleState,
    exclusions: membership.Exclusions,
    /// Most recent foreground window belonging to neither an EVE client nor this process; ReturnToLastApp's target, recorded by Painter's foreground hook.
    last_non_eve_foreground: ?win32.HWND = null,

    /// Reads the profile's saved copy, since hotkeys only change on Save.
    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, global_settings: *const config_mod.GlobalConfig, scout_ptr: *scout.Scout, painter: *painter_mod.Painter) !HotkeyManager {
        const cfg = &store.saved;
        const group_count = cfg.hotkeyGroups.items.len;
        var cycle = try cycling.CycleState.init(allocator, group_count);
        errdefer cycle.deinit(allocator);
        return HotkeyManager{
            .allocator = allocator,
            .config = cfg,
            .store = store,
            .global_settings = global_settings,
            .scout = scout_ptr,
            .painter = painter,
            .hotkey_map = std.AutoHashMap(c_int, HotkeyAction).init(allocator),
            .cycle = cycle,
            .exclusions = try membership.Exclusions.init(allocator, group_count),
        };
    }

    fn formatKeyName(virtual_key: u32, buffer: []u8) []const u8 {
        var writer: std.Io.Writer = .fixed(buffer);
        vk.writeVirtualKey(&writer, virtual_key) catch |err| {
            slog.warn("Failed to format virtual key 0x{X}: {}", .{ virtual_key, err });
            const fallback = std.fmt.bufPrint(buffer, "VK{X}", .{virtual_key}) catch "VK?";
            return fallback;
        };
        return writer.buffered();
    }

    // Mouse buttons/wheel route through the mouse hook, everything else through the keyboard hook; both re-post a match as WM_HOTKEY.
    fn hookKey(self: *HotkeyManager, hwnd: win32.HWND, id: c_int, virtual_key: u32) !void {
        if (vk.isMouseHookVk(vk.extractVk(virtual_key))) try mouse_hook.register(self.allocator, hwnd, virtual_key, id) else try keyboard_hook.register(self.allocator, hwnd, virtual_key, id);
    }

    fn unhookKey(virtual_key: u32) void {
        if (vk.isMouseHookVk(vk.extractVk(virtual_key))) mouse_hook.unregister(virtual_key) else keyboard_hook.unregister(virtual_key);
    }

    /// Every key posts the same ID, so `action` is tracked once if any key registers.
    /// Returns how many keys failed; failures are logged here, so callers only count them.
    fn registerKeys(self: *HotkeyManager, hwnd: win32.HWND, id: c_int, keys: KeyList, action: HotkeyAction, description: []const u8) usize {
        var key_name_buf: [32]u8 = undefined;
        var registered: KeyList = .empty;
        for (keys.slice()) |virtual_key| {
            self.hookKey(hwnd, id, virtual_key) catch |err| {
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
        return if (binding.in_global_settings) @field(self.global_settings, binding.field) else @field(self.config.hotkeys, binding.field);
    }

    /// Returns how many of the binding's keys failed to register.
    fn registerGlobal(self: *HotkeyManager, hwnd: win32.HWND, comptime binding: bindings.GlobalBinding) usize {
        return self.registerKeys(hwnd, bindings.globalId(binding.action), self.bindingKeys(binding), bindings.actionFor(binding.action), binding.description);
    }

    pub fn registerHotkeys(self: *HotkeyManager, hwnd: win32.HWND) !void {
        keyboard_hook.setExactModifiers(self.config.hotkeys.exactHotkeyModifiers);
        mouse_hook.setExactModifiers(self.config.hotkeys.exactHotkeyModifiers);
        const PerCharacterHotkeyGroup = struct {
            vk: u32,
            indices: std.ArrayList(usize),
        };
        var per_character_groups: std.ArrayList(PerCharacterHotkeyGroup) = .empty;
        defer {
            for (per_character_groups.items) |*group| group.indices.deinit(self.allocator);
            per_character_groups.deinit(self.allocator);
        }
        // Grouped per combo, so characters sharing one cycle through each other while a character's other combos stay its own.
        for (self.config.characters.items, 0..) |*char, char_index| {
            for (char.hotkey.slice()) |char_vk| {
                var existing: ?*PerCharacterHotkeyGroup = null;
                for (per_character_groups.items) |*group| {
                    if (group.vk == char_vk) {
                        existing = group;
                        break;
                    }
                }
                if (existing) |group| {
                    try group.indices.append(self.allocator, char_index);
                } else {
                    var new_group = PerCharacterHotkeyGroup{ .vk = char_vk, .indices = .empty };
                    try new_group.indices.append(self.allocator, char_index);
                    try per_character_groups.append(self.allocator, new_group);
                }
            }
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

        slog.debug("Registering hotkeys: {} group(s), {} global action(s), {} per-character hotkey(s), {} profile-switch hotkey(s), {} app hotkey(s), {} url hotkey(s)...", .{
            self.config.hotkeyGroups.items.len,
            global_count,
            per_character_count,
            profile_switch_count,
            app_hotkey_count,
            url_hotkey_count,
        });

        var failed_count: usize = 0;
        var desc_buf: [160]u8 = undefined;

        // PartialHotkeyRegistrationFailure is a deliberate summary return, not a failure to clean up after; the hotkeys that did register should stay live.
        errdefer |err| if (err != error.PartialHotkeyRegistrationFailure) self.unregisterAll();

        for (self.config.hotkeyGroups.items, 0..) |*group, group_index| {
            const char_name = if (group.characters.items.len > 0)
                group.characters.items[0]
            else
                "(empty)";
            const first_slot = group_index * 3;

            if (!group.forwardKey.isEmpty()) {
                const desc = std.fmt.bufPrint(&desc_buf, "group {} [{s}...] forward", .{ group_index, char_name }) catch "group forward";
                failed_count += self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_CYCLE_GROUP_BASE, first_slot), group.forwardKey, .{ .cycle_group = .{ .group_index = group_index, .forward = true } }, desc);
            }

            if (!group.backwardKey.isEmpty()) {
                const desc = std.fmt.bufPrint(&desc_buf, "group {} [{s}...] backward", .{ group_index, char_name }) catch "group backward";
                failed_count += self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_CYCLE_GROUP_BASE, first_slot + 1), group.backwardKey, .{ .cycle_group = .{ .group_index = group_index, .forward = false } }, desc);
            }

            if (!group.assignKey.isEmpty()) {
                const desc = std.fmt.bufPrint(&desc_buf, "group {} [{s}] assign", .{ group_index, group.name }) catch "group assign";
                failed_count += self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_CYCLE_GROUP_BASE, first_slot + 2), group.assignKey, .{ .assign_group = .{ .group_index = group_index } }, desc);
            }
        }

        for (per_character_groups.items, 0..) |*group, group_index| {
            const first_name = self.config.characters.items[group.indices.items[0]].name;
            const desc = if (group.indices.items.len == 1)
                std.fmt.bufPrint(&desc_buf, "activate character [{s}]", .{first_name}) catch "activate character"
            else
                std.fmt.bufPrint(&desc_buf, "activate character [{s}...] ({} sharing hotkey)", .{ first_name, group.indices.items.len }) catch "activate character group";

            const owned_indices = self.allocator.dupe(usize, group.indices.items) catch |err| {
                slog.err("Failed to copy per-character hotkey group [{s}...]: {}", .{ first_name, err });
                failed_count += 1;
                continue;
            };
            // A single key, so any failure means the action wasn't tracked and the indices are still ours.
            const failed = self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_PER_CHARACTER_BASE, group_index), .one(group.vk), .{ .activate_character = .{ .character_indices = owned_indices } }, desc);
            if (failed > 0) {
                self.allocator.free(owned_indices);
                failed_count += failed;
            }
        }

        for (self.global_settings.profileSwitchHotkeys.items, 0..) |profile_hotkey, index| {
            if (profile_hotkey.hotkey.isEmpty()) continue;
            const desc = std.fmt.bufPrint(&desc_buf, "switch to profile [{s}]", .{profile_hotkey.targetProfile}) catch "switch to profile";
            failed_count += self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_PROFILE_SWITCH_BASE, index), profile_hotkey.hotkey, .{ .switch_to_profile = .{ .profile_index = index } }, desc);
        }

        for (self.global_settings.appHotkeys.items, 0..) |app_hotkey, index| {
            if (app_hotkey.hotkey.isEmpty()) continue;
            const desc = std.fmt.bufPrint(&desc_buf, "activate app [{s}]", .{app_hotkey.executableName}) catch "activate app";
            failed_count += self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_APP_HOTKEY_BASE, index), app_hotkey.hotkey, .{ .activate_app = .{ .app_index = index } }, desc);
        }

        for (self.global_settings.urlHotkeys.items, 0..) |url_hotkey, index| {
            if (url_hotkey.hotkey.isEmpty()) continue;
            const desc = std.fmt.bufPrint(&desc_buf, "open url [{s}]", .{url_hotkey.url}) catch "open url";
            failed_count += self.registerKeys(hwnd, bindings.bandId(bindings.HOTKEY_ID_URL_HOTKEY_BASE, index), url_hotkey.hotkey, .{ .open_url = .{ .url_index = index } }, desc);
        }

        inline for (bindings.GLOBAL_BINDINGS) |binding| {
            failed_count += self.registerGlobal(hwnd, binding);
        }

        const success_count: usize = self.hotkey_map.count();
        if (failed_count > 0) {
            if (success_count == 0) {
                slog.err("Failed to register any hotkeys - all {} key(s) failed", .{failed_count});
                slog.err("Hotkey functionality will be unavailable", .{});
                return error.AllHotkeysFailedToRegister;
            }
            slog.warn("Failed to register {} key(s); {} hotkey(s) still registered", .{ failed_count, success_count });
            slog.warn("Some hotkey groups may not respond to key presses", .{});
            return error.PartialHotkeyRegistrationFailure;
        }

        slog.debug("Successfully registered all {} hotkey(s)", .{success_count});
    }

    pub fn unregisterAll(self: *HotkeyManager) void {
        mouse_hook.unregisterAll();
        keyboard_hook.unregisterAll();

        var action_it = self.hotkey_map.valueIterator();
        while (action_it.next()) |action| {
            if (action.* == .activate_character) {
                self.allocator.free(action.activate_character.character_indices);
            }
        }

        slog.debug("Unregistering {} hotkey(s)...", .{self.hotkey_map.count()});
        self.hotkey_map.clearRetainingCapacity();
    }

    /// Handles a WM_HOTKEY press; lparam is the raw lParam, used only to recover the vk code for release-consumption.
    pub fn handleHotkeyPress(self: *HotkeyManager, hotkey_id: c_int, lparam: win32.LPARAM) void {
        const action = self.hotkey_map.getPtr(hotkey_id) orelse {
            slog.warn("Received unknown hotkey ID: {}", .{hotkey_id});
            return;
        };

        // Auto-repeat while a key is held isn't filtered by the keyboard hook, so this must run before every early return or held keys would re-fire.
        const vk_code = win32.hotkeyVkFromLparam(lparam);
        const is_repeat = !keyboard_hook.trackPress(self.allocator, vk_code);
        if (is_repeat and !self.config.hotkeys.allowHotkeyAutoRepeat) {
            slog.debug("Hotkey {} ignored - key-repeat re-fire while held", .{hotkey_id});
            return;
        }

        if (action.* == .suspend_hotkeys) {
            self.toggleSuspend();
            return;
        }

        if (self.hotkeys_suspended) {
            slog.debug("Hotkey {} ignored - hotkeys suspended", .{hotkey_id});
            return;
        }

        if (self.dialog_suspended) {
            slog.debug("Hotkey {} ignored - config dialog is recording a new hotkey", .{hotkey_id});
            return;
        }

        if (self.config.hotkeys.requireEveFocus and self.foregroundEveWindow() == null) {
            slog.debug("Hotkey {} ignored - EVE window not in focus", .{hotkey_id});
            return;
        }

        // Only swallow the key's release if focus actually moved; a cycle with no eligible target never changes foreground.
        focus_grant.g_focus_switch_requested = false;

        self.runAction(action);

        // Win's release always needs swallowing, focus-change or not - an unmatched keyup still opens the Start Menu.
        if (focus_grant.g_focus_switch_requested or vk_code == win32.VK_LWIN or vk_code == win32.VK_RWIN) {
            keyboard_hook.markSwallowRelease(vk_code);
        }
    }

    /// Runs a global action requested outside a hotkey press (protocol URL, tray menu), bypassing the press-only suspend/focus gating.
    pub fn runGlobalAction(self: *HotkeyManager, action: protocol.GlobalAction) void {
        var hotkey_action = bindings.fromProtocol(action);
        self.runAction(&hotkey_action);
    }

    /// Takes a pointer so per-character hotkeys can advance their cursor in hotkey_map.
    fn runAction(self: *HotkeyManager, action: *HotkeyAction) void {
        switch (action.*) {
            .cycle_group => |cycle_group| {
                if (cycle_group.group_index >= self.config.hotkeyGroups.items.len) {
                    slog.err("Invalid group index {}", .{cycle_group.group_index});
                    return;
                }
                cycling.cycleGroup(self, cycle_group.group_index, cycle_group.forward);
            },
            .activate_character => |*character_group| cycling.activatePerCharacterGroup(self, character_group),
            .assign_group => |assign| membership.assignHoveredToGroup(self, assign.group_index),
            .minimize_all => {
                slog.info("Minimize all hotkey pressed", .{});
                client_actions.minimizeAllClients(self.scout.getWindows(), self.config);
            },
            .close_all => {
                slog.info("Close all hotkey pressed", .{});
                client_actions.closeAllClients(self.scout.getWindows(), self.config);
            },
            .toggle_visibility => {
                slog.info("Toggle visibility hotkey pressed", .{});
                self.painter.toggleAllThumbnailsVisibility();
            },
            .next_profile => profile_switch.cycle(self.allocator, self.config.profile_name, true),
            .previous_profile => profile_switch.cycle(self.allocator, self.config.profile_name, false),
            .switch_to_profile => |switch_to| profile_switch.switchTo(self.global_settings, self.config.profile_name, switch_to.profile_index),
            .toggle_exclusion => self.toggleForegroundExclusion(),
            .next_excluded => cycling.cycleExcluded(self, true),
            .previous_excluded => cycling.cycleExcluded(self, false),
            .suspend_hotkeys => self.toggleSuspend(),
            .toggle_auto_minimize => {
                slog.info("Toggle auto-minimize hotkey pressed", .{});
                auto_minimize.toggle(self.painter);
            },
            .cycle_notified => cycling.cycleNotified(self, true),
            .previous_notified => cycling.cycleNotified(self, false),
            .next_all_clients => cycling.cycleAllClients(self, true),
            .previous_all_clients => cycling.cycleAllClients(self, false),
            .next_not_logged_in => cycling.cycleNotLoggedIn(self, true),
            .previous_not_logged_in => cycling.cycleNotLoggedIn(self, false),
            .move_to_saved_positions => {
                slog.info("Move to saved positions hotkey pressed", .{});
                client_actions.moveAllClientsToSavedPositions(self.scout.getWindows(), self.config, self.painter);
            },
            .return_to_last_app => launch.returnToLastApp(&self.last_non_eve_foreground),
            .activate_app => |activate| launch.activateApp(self.global_settings, activate.app_index),
            .open_url => |open_url| launch.openUrl(self.allocator, self.global_settings, open_url.url_index),
        }
    }

    fn foregroundEveWindow(self: *HotkeyManager) ?scout.EveWindow {
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

    fn toggleSuspend(self: *HotkeyManager) void {
        self.hotkeys_suspended = !self.hotkeys_suspended;
        const state = if (self.hotkeys_suspended) "suspended" else "resumed";
        slog.info("Hotkeys {s}", .{state});

        if (main.g_timer_hwnd) |hwnd| {
            if (self.hotkeys_suspended) {
                // The low-level hooks intercept system-wide, so leaving bindings registered while "suspended" would still block other apps from seeing those keys.
                self.unregisterAll();
                // Pressing it again must still be able to resume everything else.
                _ = self.registerGlobal(hwnd, bindings.SUSPEND_BINDING);
            } else {
                self.registerHotkeys(hwnd) catch |err| {
                    slog.err("Failed to re-register hotkeys after resuming: {}", .{err});
                };
            }
            _ = win32.PostMessageA(hwnd, win32.WM_HOTKEYS_STATE_CHANGED, 0, 0);
        }
    }

    pub fn areHotkeysSuspended(self: *HotkeyManager) bool {
        return self.hotkeys_suspended;
    }

    /// Unregisters every live hotkey (not just gates dispatch) since the low-level hooks swallow matched keys system-wide, so a gate alone would never let the dialog see the keypress.
    pub fn dialogSuspendHotkeys(self: *HotkeyManager) void {
        if (self.dialog_suspended) return;
        slog.debug("Config dialog is recording a hotkey - unregistering live hotkeys", .{});
        self.dialog_suspended = true;
        self.unregisterAll();
        keyboard_hook.armWinKeyCapture();
    }

    /// Re-registers from the same in-memory config unregisterAll left untouched, so this restores exactly what was live before.
    pub fn dialogResumeHotkeys(self: *HotkeyManager, hwnd: win32.HWND) void {
        if (!self.dialog_suspended) return;
        slog.debug("Config dialog finished recording - re-registering hotkeys", .{});
        self.dialog_suspended = false;
        keyboard_hook.disarmWinKeyCapture();
        self.registerHotkeys(hwnd) catch |err| {
            slog.err("Failed to re-register hotkeys after dialog recording: {}", .{err});
        };
    }

    pub fn isCharacterExcluded(self: *HotkeyManager, character_name: []const u8) bool {
        return self.exclusions.contains(self.config, character_name);
    }

    pub fn updateFocusedCharacter(self: *HotkeyManager, character_name: []const u8, hwnd: win32.HWND) void {
        cycling.syncToFocusedCharacter(self, character_name, hwnd);
    }

    pub fn deinit(self: *HotkeyManager) void {
        self.unregisterAll();
        self.cycle.deinit(self.allocator);
        self.exclusions.deinit(self.allocator);
        self.hotkey_map.deinit();
    }
};

/// Set by main.zig for code that can't be handed the manager directly (window procs, Painter, travel).
pub var g_hotkey_manager_ptr: ?*HotkeyManager = null;

/// False before the manager exists.
pub fn isExcludedFromCycle(character_name: []const u8) bool {
    const manager = g_hotkey_manager_ptr orelse return false;
    return manager.isCharacterExcluded(character_name);
}

/// Keeps cycle positions in step when `hwnd` becomes the focused client; no-op before the manager exists.
pub fn syncFocusedCharacter(character_name: []const u8, hwnd: win32.HWND) void {
    if (g_hotkey_manager_ptr) |manager| manager.updateFocusedCharacter(character_name, hwnd);
}

/// The window ReturnToLastApp goes back to.
pub fn recordNonEveForeground(hwnd: win32.HWND) void {
    if (g_hotkey_manager_ptr) |manager| manager.last_non_eve_foreground = hwnd;
}

fn countBound(items: anytype) usize {
    var n: usize = 0;
    for (items) |item| {
        if (!item.hotkey.isEmpty()) n += 1;
    }
    return n;
}
