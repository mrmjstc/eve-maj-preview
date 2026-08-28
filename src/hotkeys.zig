const std = @import("std");
const win32 = @import("win32.zig");
const input = @import("input.zig");
const scout = @import("scout.zig");
const config_mod = @import("config.zig");
const vk = @import("virtual_keys.zig");
const mouse_hook = @import("mouse_hook.zig");
const log = @import("log.zig");
const slog = log.scoped("hotkeys");
const painter_mod = @import("painter.zig");
const tray_mod = @import("tray.zig");
const main_mod = @import("main.zig");

// Static buffers for profile names; must stay valid until the async WM_SWITCH_PROFILE handler runs.
var g_profile_cycle_buffer: [256]u8 = undefined;
var g_profile_switch_buffer: [256]u8 = undefined;

var g_hotkey_tracked: std.AutoHashMap(u32, bool) = undefined;
var g_hotkey_tracking_initialized = false;
var g_hotkey_release_hook: ?win32.HHOOK = null;

fn ensureHotkeyTrackingInit(allocator: std.mem.Allocator) void {
    if (g_hotkey_tracking_initialized) return;
    g_hotkey_tracked = std.AutoHashMap(u32, bool).init(allocator);
    g_hotkey_tracking_initialized = true;
}

/// Marks vk_code down to distinguish a repeat WM_HOTKEY from a new press; swallow-on-release is decided later in markHotkeySwallowRelease.
pub fn trackHotkeyPress(allocator: std.mem.Allocator, vk_code: u32) bool {
    // Mouse-button hotkeys route through here with lparam=0.
    if (vk_code == 0) return true;
    ensureHotkeyTrackingInit(allocator);

    const gop = g_hotkey_tracked.getOrPut(vk_code) catch |err| {
        slog.warn("Failed to track hotkey press for vk 0x{X}: {}", .{ vk_code, err });
        return true;
    };
    if (gop.found_existing) return false;

    gop.value_ptr.* = false;
    if (g_hotkey_release_hook == null) installHotkeyReleaseHook();
    return true;
}

/// Arms release-swallowing for vk_code once its action has moved focus, so the previously-focused client still believes the key is held.
pub fn markHotkeySwallowRelease(vk_code: u32) void {
    if (vk_code == 0) return;
    if (!g_hotkey_tracking_initialized) return;
    if (g_hotkey_tracked.getPtr(vk_code)) |swallow| swallow.* = true;
}

fn installHotkeyReleaseHook() void {
    const hmod = win32.GetModuleHandleA(null);
    g_hotkey_release_hook = win32.SetWindowsHookExA(win32.WH_KEYBOARD_LL, lowLevelHotkeyReleaseProc, hmod, 0);
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
    if (g_hotkey_release_hook) |hook| {
        _ = win32.UnhookWindowsHookEx(hook);
        g_hotkey_release_hook = null;
        slog.debug("Low-level keyboard release hook removed", .{});
    }
}

/// Frees g_hotkey_tracked; call only once at true process shutdown, never from a reload path that may track again.
pub fn deinitHotkeyTracking() void {
    if (!g_hotkey_tracking_initialized) return;
    g_hotkey_tracked.deinit();
    g_hotkey_tracking_initialized = false;
}

fn lowLevelHotkeyReleaseProc(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    if (nCode == win32.HC_ACTION and (wParam == win32.WM_KEYUP or wParam == win32.WM_SYSKEYUP)) {
        const info = win32.lparamToPtr(win32.KBDLLHOOKSTRUCT, lParam);

        if ((info.flags & win32.LLKHF_INJECTED) == 0) {
            if (g_hotkey_tracked.fetchRemove(info.vkCode)) |entry| {
                if (entry.value) {
                    return 1;
                }
            }
        }
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}

// Hotkey IDs are banded to avoid collisions: 0-999 groups, 1000s global, 2000s per-character, 3000s profile switch, 4000s+ quick groups.
const HOTKEY_ID_CYCLE_GROUP_BASE: c_int = 0;
const HOTKEY_ID_GLOBAL_ACTION_BASE: c_int = 1000;
const HOTKEY_ID_PER_CHARACTER_BASE: c_int = 2000;
const HOTKEY_ID_PROFILE_SWITCH_BASE: c_int = 3000;
const HOTKEY_ID_QUICK_GROUP_BASE: c_int = 4000;

const GlobalActionId = enum(c_int) {
    MinimizeAll = HOTKEY_ID_GLOBAL_ACTION_BASE + 0,
    CloseAll = HOTKEY_ID_GLOBAL_ACTION_BASE + 1,
    ToggleVisibility = HOTKEY_ID_GLOBAL_ACTION_BASE + 2,
    NextProfile = HOTKEY_ID_GLOBAL_ACTION_BASE + 3,
    PreviousProfile = HOTKEY_ID_GLOBAL_ACTION_BASE + 4,
    ToggleExclusion = HOTKEY_ID_GLOBAL_ACTION_BASE + 5,
    NextExcluded = HOTKEY_ID_GLOBAL_ACTION_BASE + 6,
    PreviousExcluded = HOTKEY_ID_GLOBAL_ACTION_BASE + 7,
    SuspendHotkeys = HOTKEY_ID_GLOBAL_ACTION_BASE + 8,
    ToggleAutoMinimize = HOTKEY_ID_GLOBAL_ACTION_BASE + 9,
    CycleNotified = HOTKEY_ID_GLOBAL_ACTION_BASE + 10,
    PreviousNotified = HOTKEY_ID_GLOBAL_ACTION_BASE + 11,
    NextAllClients = HOTKEY_ID_GLOBAL_ACTION_BASE + 12,
    PreviousAllClients = HOTKEY_ID_GLOBAL_ACTION_BASE + 13,
    NextNotLoggedIn = HOTKEY_ID_GLOBAL_ACTION_BASE + 14,
    PreviousNotLoggedIn = HOTKEY_ID_GLOBAL_ACTION_BASE + 15,
    MoveToSavedPositions = HOTKEY_ID_GLOBAL_ACTION_BASE + 16,
    _,
};

pub const HotkeyActionType = enum {
    CycleGroup,
    ActivateCharacter,
    AssignQuickGroup,
    CycleQuickGroup,
    MinimizeAll,
    CloseAll,
    ToggleVisibility,
    NextProfile,
    PreviousProfile,
    SwitchToProfile,
    ToggleExclusion,
    NextExcluded,
    PreviousExcluded,
    SuspendHotkeys,
    ToggleAutoMinimize,
    CycleNotified,
    PreviousNotified,
    NextAllClients,
    PreviousAllClients,
    NextNotLoggedIn,
    PreviousNotLoggedIn,
    MoveToSavedPositions,
};

pub const HotkeyAction = union(HotkeyActionType) {
    CycleGroup: struct {
        group_index: usize,
        forward: bool,
    },
    ActivateCharacter: struct {
        character_indices: []const usize,
        current_index: ?usize = null,
    },
    AssignQuickGroup: struct {
        group_index: usize,
    },
    CycleQuickGroup: struct {
        group_index: usize,
        forward: bool,
    },
    MinimizeAll: void,
    CloseAll: void,
    ToggleVisibility: void,
    NextProfile: void,
    PreviousProfile: void,
    SwitchToProfile: struct {
        profile_index: usize,
    },
    ToggleExclusion: void,
    NextExcluded: void,
    PreviousExcluded: void,
    SuspendHotkeys: void,
    ToggleAutoMinimize: void,
    CycleNotified: void,
    PreviousNotified: void,
    NextAllClients: void,
    PreviousAllClients: void,
    NextNotLoggedIn: void,
    PreviousNotLoggedIn: void,
    MoveToSavedPositions: void,
};

/// Manages system-wide hotkey registration and character cycling
pub const HotkeyManager = struct {
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    global_settings: *const config_mod.GlobalSettings,
    scout: *scout.Scout,
    painter: *painter_mod.Painter,
    hotkey_map: std.AutoHashMap(c_int, HotkeyAction),
    /// List of successfully registered hotkey IDs for cleanup
    registered_ids: std.ArrayList(c_int),
    /// Current index for cycling through excluded characters (global across all groups); null = not yet cycled, see cycleExcluded
    excluded_cycle_index: ?usize = null,
    /// Whether hotkeys are currently suspended (except suspend hotkey itself)
    hotkeys_suspended: bool = false,
    /// Whether the config dialog is recording a new hotkey; kept separate from hotkeys_suspended so the two don't clobber each other.
    dialog_suspended: bool = false,
    /// Owned name of the character cycleNotified() last jumped to; used as cursor since notified_queue mutates between presses.
    last_notified_cycle_name: ?[]const u8 = null,
    /// Owned name cycleAllClients() last jumped to; same rationale as last_notified_cycle_name, since Scout.windows mutates between presses.
    last_all_clients_cycle_name: ?[]const u8 = null,
    /// HWND (not name) cycleNotLoggedIn() last jumped to; every not-logged-in window shares the name "EVE" so name can't disambiguate.
    last_not_logged_in_cycle_hwnd: ?win32.HWND = null,
    /// Fallback exclusion list for shift-click-excluded characters that belong to no hotkey group; checked by isCharacterExcluded().
    manually_excluded_characters: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config_mod.Config, gs: *const config_mod.GlobalSettings, s: *scout.Scout, p: *painter_mod.Painter) !HotkeyManager {
        return HotkeyManager{
            .allocator = allocator,
            .config = cfg,
            .global_settings = gs,
            .scout = s,
            .painter = p,
            .hotkey_map = std.AutoHashMap(c_int, HotkeyAction).init(allocator),
            .registered_ids = std.ArrayList(c_int).empty,
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

    /// Layered errdefer: each step's cleanup only runs if a later step in registration fails.
    fn registerAndTrackHotkey(self: *HotkeyManager, hwnd: win32.HWND, id: c_int, virtual_key: u32, action: HotkeyAction, description: []const u8) !void {
        // RegisterHotKey can't see mouse buttons; route those through the mouse hook, which re-posts WM_HOTKEY on a match.
        if (vk.isMouseHookVk(vk.extractVk(virtual_key))) {
            try mouse_hook.register(self.allocator, hwnd, virtual_key, id);
            errdefer mouse_hook.unregister(virtual_key);

            try self.hotkey_map.put(id, action);
            errdefer _ = self.hotkey_map.remove(id);

            try self.registered_ids.append(self.allocator, id);
            return;
        }

        try self.registerSingleHotkey(hwnd, id, virtual_key, description);
        errdefer _ = win32.UnregisterHotKey(hwnd, id);

        try self.hotkey_map.put(id, action);
        errdefer _ = self.hotkey_map.remove(id);

        try self.registered_ids.append(self.allocator, id);
    }

    pub fn registerHotkeys(self: *HotkeyManager, hwnd: win32.HWND) !void {
        const has_groups = self.config.hotkeyGroups.items.len > 0;
        const has_quick_groups = self.config.quickGroups.items.len > 0;
        const has_minimize = self.config.hotkeyMinimizeAll != null;
        const has_close = self.config.hotkeyCloseAll != null;
        const has_toggle_vis = self.config.hotkeyToggleVisibility != null;
        const has_toggle_auto_min = self.config.hotkeyToggleAutoMinimize != null;
        const has_next_profile = self.global_settings.hotkeyNextProfile != null;
        const has_previous_profile = self.global_settings.hotkeyPreviousProfile != null;
        const has_toggle_exclusion = self.config.hotkeyToggleExclusion != null;
        const has_next_excluded = self.config.hotkeyNextExcluded != null;
        const has_previous_excluded = self.config.hotkeyPreviousExcluded != null;
        const has_suspend = self.config.hotkeySuspend != null;
        const has_cycle_notified = self.config.hotkeyCycleNotified != null;
        const has_previous_notified = self.config.hotkeyPreviousNotified != null;
        const has_next_all_clients = self.global_settings.hotkeyCycleAllClientsForward != null;
        const has_previous_all_clients = self.global_settings.hotkeyCycleAllClientsBackward != null;
        const has_next_not_logged_in = self.global_settings.hotkeyCycleNotLoggedInForward != null;
        const has_previous_not_logged_in = self.global_settings.hotkeyCycleNotLoggedInBackward != null;
        const has_move_to_saved = self.config.hotkeyMoveToSavedPositions != null;
        const PerCharacterHotkeyGroup = struct {
            vk: u32,
            indices: std.ArrayList(usize),
        };
        var per_character_groups: std.ArrayList(PerCharacterHotkeyGroup) = .empty;
        defer {
            for (per_character_groups.items) |*group| group.indices.deinit(self.allocator);
            per_character_groups.deinit(self.allocator);
        }
        for (self.config.characters.items, 0..) |char, char_index| {
            const char_vk = char.hotkey orelse continue;
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
        const has_per_character_hotkeys = per_character_groups.items.len > 0;
        var has_profile_switch_hotkeys = false;
        for (self.global_settings.profileSwitchHotkeys.items) |psh| {
            if (psh.hotkey != null) {
                has_profile_switch_hotkeys = true;
                break;
            }
        }

        if (!has_groups and !has_quick_groups and !has_minimize and !has_close and !has_toggle_vis and !has_toggle_auto_min and !has_next_profile and !has_previous_profile and !has_toggle_exclusion and !has_next_excluded and !has_previous_excluded and !has_suspend and !has_cycle_notified and !has_previous_notified and !has_next_all_clients and !has_previous_all_clients and !has_next_not_logged_in and !has_previous_not_logged_in and !has_move_to_saved and !has_per_character_hotkeys and !has_profile_switch_hotkeys) {
            slog.debug("No hotkeys configured", .{});
            return;
        }

        const global_count: usize = @as(usize, if (has_minimize) 1 else 0) + @as(usize, if (has_close) 1 else 0) + @as(usize, if (has_toggle_vis) 1 else 0) + @as(usize, if (has_next_profile) 1 else 0) + @as(usize, if (has_previous_profile) 1 else 0) + @as(usize, if (has_toggle_exclusion) 1 else 0) + @as(usize, if (has_next_excluded) 1 else 0) + @as(usize, if (has_previous_excluded) 1 else 0) + @as(usize, if (has_suspend) 1 else 0) + @as(usize, if (has_cycle_notified) 1 else 0) + @as(usize, if (has_previous_notified) 1 else 0) + @as(usize, if (has_next_all_clients) 1 else 0) + @as(usize, if (has_previous_all_clients) 1 else 0) + @as(usize, if (has_next_not_logged_in) 1 else 0) + @as(usize, if (has_previous_not_logged_in) 1 else 0) + @as(usize, if (has_move_to_saved) 1 else 0);
        const per_character_count = per_character_groups.items.len;
        var profile_switch_count: usize = 0;
        for (self.global_settings.profileSwitchHotkeys.items) |psh| {
            if (psh.hotkey != null) profile_switch_count += 1;
        }
        slog.debug("Registering hotkeys: {} group(s), {} quick group(s), {} global action(s), {} per-character hotkey(s), {} profile-switch hotkey(s)...", .{
            self.config.hotkeyGroups.items.len,
            self.config.quickGroups.items.len,
            global_count,
            per_character_count,
            profile_switch_count,
        });

        var expected_count: usize = 0;
        var failed_count: usize = 0;
        // Shared across every catch block below - each only reads it right after a fresh formatKeyName call, never across two.
        var key_name_buf: [32]u8 = undefined;

        for (self.config.hotkeyGroups.items) |*group| {
            // Every group has a forward key; only backward is optional.
            expected_count += 1;
            if (group.backwardKey != null) expected_count += 1;
        }

        for (self.config.quickGroups.items) |*group| {
            if (group.assignKey != null) expected_count += 1;
            if (group.forwardKey != null) expected_count += 1;
            if (group.backwardKey != null) expected_count += 1;
        }

        expected_count += per_character_count;
        expected_count += profile_switch_count;

        if (has_minimize) expected_count += 1;
        if (has_close) expected_count += 1;
        if (has_toggle_vis) expected_count += 1;
        if (has_next_profile) expected_count += 1;
        if (has_previous_profile) expected_count += 1;
        if (has_toggle_exclusion) expected_count += 1;
        if (has_next_excluded) expected_count += 1;
        if (has_previous_excluded) expected_count += 1;
        if (has_suspend) expected_count += 1;
        if (has_cycle_notified) expected_count += 1;
        if (has_previous_notified) expected_count += 1;
        if (has_next_all_clients) expected_count += 1;
        if (has_previous_all_clients) expected_count += 1;
        if (has_next_not_logged_in) expected_count += 1;
        if (has_previous_not_logged_in) expected_count += 1;
        if (has_move_to_saved) expected_count += 1;

        // PartialHotkeyRegistrationFailure is a deliberate summary return, not a failure to clean up after; the hotkeys that did register should stay live.
        errdefer |err| if (err != error.PartialHotkeyRegistrationFailure) self.unregisterAll(hwnd);

        for (self.config.hotkeyGroups.items, 0..) |*group, group_index| {
            const char_name = if (group.characters.items.len > 0)
                group.characters.items[0]
            else
                "(empty)";

            var desc_buf: [128]u8 = undefined;

            if (group.forwardKey) |forward_vk| {
                const forward_id: c_int = HOTKEY_ID_CYCLE_GROUP_BASE + @as(c_int, @intCast(group_index * 2));
                const forward_action = HotkeyAction{ .CycleGroup = .{ .group_index = group_index, .forward = true } };
                const desc = std.fmt.bufPrint(&desc_buf, "group {} [{s}...] forward", .{ group_index, char_name }) catch "group forward";
                self.registerAndTrackHotkey(hwnd, forward_id, forward_vk, forward_action, desc) catch |err| {
                    const key_name = formatKeyName(forward_vk, &key_name_buf);
                    slog.err("Failed to register forward hotkey {s} for group {} [{s}...]: {}", .{ key_name, group_index, char_name, err });
                    failed_count += 1;
                };
            }

            if (group.backwardKey) |backward_vk| {
                const backward_id: c_int = HOTKEY_ID_CYCLE_GROUP_BASE + @as(c_int, @intCast(group_index * 2 + 1));
                const backward_action = HotkeyAction{ .CycleGroup = .{ .group_index = group_index, .forward = false } };
                const desc2 = std.fmt.bufPrint(&desc_buf, "group {} [{s}...] backward", .{ group_index, char_name }) catch "group backward";
                self.registerAndTrackHotkey(hwnd, backward_id, backward_vk, backward_action, desc2) catch |err| {
                    const key_name = formatKeyName(backward_vk, &key_name_buf);
                    slog.err("Failed to register backward hotkey {s} for group {} [{s}...]: {}", .{ key_name, group_index, char_name, err });
                    failed_count += 1;
                };
            }
        }

        for (self.config.quickGroups.items, 0..) |*group, group_index| {
            var desc_buf: [128]u8 = undefined;

            if (group.assignKey) |assign_vk| {
                const assign_id: c_int = HOTKEY_ID_QUICK_GROUP_BASE + @as(c_int, @intCast(group_index * 3));
                const assign_action = HotkeyAction{ .AssignQuickGroup = .{ .group_index = group_index } };
                const desc = std.fmt.bufPrint(&desc_buf, "quick group {} [{s}] assign", .{ group_index, group.name }) catch "quick group assign";
                self.registerAndTrackHotkey(hwnd, assign_id, assign_vk, assign_action, desc) catch |err| {
                    const key_name = formatKeyName(assign_vk, &key_name_buf);
                    slog.err("Failed to register assign hotkey {s} for quick group {} [{s}]: {}", .{ key_name, group_index, group.name, err });
                    failed_count += 1;
                };
            }

            if (group.forwardKey) |forward_vk| {
                const forward_id: c_int = HOTKEY_ID_QUICK_GROUP_BASE + @as(c_int, @intCast(group_index * 3 + 1));
                const forward_action = HotkeyAction{ .CycleQuickGroup = .{ .group_index = group_index, .forward = true } };
                const desc = std.fmt.bufPrint(&desc_buf, "quick group {} [{s}] forward", .{ group_index, group.name }) catch "quick group forward";
                self.registerAndTrackHotkey(hwnd, forward_id, forward_vk, forward_action, desc) catch |err| {
                    const key_name = formatKeyName(forward_vk, &key_name_buf);
                    slog.err("Failed to register forward hotkey {s} for quick group {} [{s}]: {}", .{ key_name, group_index, group.name, err });
                    failed_count += 1;
                };
            }

            if (group.backwardKey) |backward_vk| {
                const backward_id: c_int = HOTKEY_ID_QUICK_GROUP_BASE + @as(c_int, @intCast(group_index * 3 + 2));
                const backward_action = HotkeyAction{ .CycleQuickGroup = .{ .group_index = group_index, .forward = false } };
                const desc = std.fmt.bufPrint(&desc_buf, "quick group {} [{s}] backward", .{ group_index, group.name }) catch "quick group backward";
                self.registerAndTrackHotkey(hwnd, backward_id, backward_vk, backward_action, desc) catch |err| {
                    const key_name = formatKeyName(backward_vk, &key_name_buf);
                    slog.err("Failed to register backward hotkey {s} for quick group {} [{s}]: {}", .{ key_name, group_index, group.name, err });
                    failed_count += 1;
                };
            }
        }

        for (per_character_groups.items, 0..) |*group, group_index| {
            const char_id: c_int = HOTKEY_ID_PER_CHARACTER_BASE + @as(c_int, @intCast(group_index));
            const first_name = self.config.characters.items[group.indices.items[0]].name;

            var char_desc_buf: [128]u8 = undefined;
            const char_desc = if (group.indices.items.len == 1)
                std.fmt.bufPrint(&char_desc_buf, "activate character [{s}]", .{first_name}) catch "activate character"
            else
                std.fmt.bufPrint(&char_desc_buf, "activate character [{s}...] ({} sharing hotkey)", .{ first_name, group.indices.items.len }) catch "activate character group";

            const owned_indices = self.allocator.dupe(usize, group.indices.items) catch {
                slog.err("Failed to allocate memory for per-character hotkey group [{s}...]", .{first_name});
                failed_count += 1;
                continue;
            };
            const char_action = HotkeyAction{ .ActivateCharacter = .{ .character_indices = owned_indices } };

            self.registerAndTrackHotkey(hwnd, char_id, group.vk, char_action, char_desc) catch |err| {
                self.allocator.free(owned_indices);
                const key_name = formatKeyName(group.vk, &key_name_buf);
                slog.err("Failed to register hotkey {s} for character [{s}...]: {}", .{ key_name, first_name, err });
                failed_count += 1;
            };
        }

        for (self.global_settings.profileSwitchHotkeys.items, 0..) |*psh, psh_index| {
            if (psh.hotkey) |sp_vk| {
                const sp_id: c_int = HOTKEY_ID_PROFILE_SWITCH_BASE + @as(c_int, @intCast(psh_index));
                const sp_action = HotkeyAction{ .SwitchToProfile = .{ .profile_index = psh_index } };
                var sp_desc_buf: [128]u8 = undefined;
                const sp_desc = std.fmt.bufPrint(&sp_desc_buf, "switch to profile [{s}]", .{psh.targetProfile}) catch "switch to profile";
                self.registerAndTrackHotkey(hwnd, sp_id, sp_vk, sp_action, sp_desc) catch |err| {
                    const key_name = formatKeyName(sp_vk, &key_name_buf);
                    slog.err("Failed to register hotkey {s} for switching to profile [{s}]: {}", .{ key_name, psh.targetProfile, err });
                    failed_count += 1;
                };
            }
        }

        if (self.config.hotkeyMinimizeAll) |vk_code| {
            const id = @intFromEnum(GlobalActionId.MinimizeAll);
            const action = HotkeyAction{ .MinimizeAll = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "minimize all clients") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register minimize all hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyCloseAll) |vk_code| {
            const id = @intFromEnum(GlobalActionId.CloseAll);
            const action = HotkeyAction{ .CloseAll = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "close all clients") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register close all hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyToggleVisibility) |vk_code| {
            const id = @intFromEnum(GlobalActionId.ToggleVisibility);
            const action = HotkeyAction{ .ToggleVisibility = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "toggle thumbnails visibility") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register toggle visibility hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyNextProfile) |vk_code| {
            const id = @intFromEnum(GlobalActionId.NextProfile);
            const action = HotkeyAction{ .NextProfile = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to next profile") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register next profile hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyPreviousProfile) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousProfile);
            const action = HotkeyAction{ .PreviousProfile = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to previous profile") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous profile hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyToggleExclusion) |vk_code| {
            const id = @intFromEnum(GlobalActionId.ToggleExclusion);
            const action = HotkeyAction{ .ToggleExclusion = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "toggle character exclusion from cycling") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register toggle exclusion hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyNextExcluded) |vk_code| {
            const id = @intFromEnum(GlobalActionId.NextExcluded);
            const action = HotkeyAction{ .NextExcluded = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to next excluded character") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register next excluded hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyPreviousExcluded) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousExcluded);
            const action = HotkeyAction{ .PreviousExcluded = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to previous excluded character") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous excluded hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeySuspend) |vk_code| {
            const id = @intFromEnum(GlobalActionId.SuspendHotkeys);
            const action = HotkeyAction{ .SuspendHotkeys = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "suspend/resume all hotkeys") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register suspend hotkeys {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyToggleAutoMinimize) |vk_code| {
            const id = @intFromEnum(GlobalActionId.ToggleAutoMinimize);
            const action = HotkeyAction{ .ToggleAutoMinimize = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "toggle auto-minimize mode") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register toggle auto-minimize hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyCycleNotified) |vk_code| {
            const id = @intFromEnum(GlobalActionId.CycleNotified);
            const action = HotkeyAction{ .CycleNotified = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to most recently notified character") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register cycle notified hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyPreviousNotified) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousNotified);
            const action = HotkeyAction{ .PreviousNotified = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle backward through notified characters") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous notified hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyCycleAllClientsForward) |vk_code| {
            const id = @intFromEnum(GlobalActionId.NextAllClients);
            const action = HotkeyAction{ .NextAllClients = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle forward through all logged-in clients") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register next all-clients hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyCycleAllClientsBackward) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousAllClients);
            const action = HotkeyAction{ .PreviousAllClients = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle backward through all logged-in clients") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous all-clients hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyCycleNotLoggedInForward) |vk_code| {
            const id = @intFromEnum(GlobalActionId.NextNotLoggedIn);
            const action = HotkeyAction{ .NextNotLoggedIn = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle forward through not-logged-in clients") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register next not-logged-in hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyCycleNotLoggedInBackward) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousNotLoggedIn);
            const action = HotkeyAction{ .PreviousNotLoggedIn = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle backward through not-logged-in clients") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous not-logged-in hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyMoveToSavedPositions) |vk_code| {
            const id = @intFromEnum(GlobalActionId.MoveToSavedPositions);
            const action = HotkeyAction{ .MoveToSavedPositions = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "move all clients to saved positions") catch |err| {
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register move to saved positions hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        const success_count = self.registered_ids.items.len;
        if (failed_count > 0) {
            if (success_count == 0) {
                slog.err("Failed to register any hotkeys - all {} attempts failed", .{expected_count});
                slog.err("Hotkey functionality will be unavailable", .{});
                return error.AllHotkeysFailedToRegister;
            }
            slog.warn("Registered {} of {} hotkey(s) ({} failed)", .{ success_count, expected_count, failed_count });
            slog.warn("Some hotkey groups may not respond to key presses", .{});
            return error.PartialHotkeyRegistrationFailure;
        }

        slog.debug("Successfully registered all {} hotkey(s)", .{success_count});
    }

    fn registerSingleHotkey(self: *HotkeyManager, hwnd: win32.HWND, id: c_int, virtual_key: u32, description: []const u8) !void {
        _ = self;
        const base_vk: win32.UINT = @intCast(vk.extractVk(virtual_key));
        const key_modifiers: win32.UINT = @intCast(vk.extractModifiers(virtual_key));

        // Deliberately not MOD_NOREPEAT; handleHotkeyPress suppresses repeats itself via trackHotkeyPress.
        if (!win32.toBool(win32.RegisterHotKey(hwnd, id, key_modifiers, base_vk))) {
            // Likely already in use by another application
            return error.HotkeyRegistrationFailed;
        }

        var key_name_buf: [32]u8 = undefined;
        const key_name = formatKeyName(virtual_key, &key_name_buf);

        slog.debug("Registered hotkey: {s} -> {s}", .{ key_name, description });
    }

    pub fn unregisterAll(self: *HotkeyManager, hwnd: win32.HWND) void {
        // Always clear mouse-button bindings too; cheap no-op if none were registered.
        mouse_hook.unregisterAll();
        uninstallHotkeyReleaseHook();

        var action_it = self.hotkey_map.valueIterator();
        while (action_it.next()) |action| {
            if (std.meta.activeTag(action.*) == .ActivateCharacter) {
                self.allocator.free(action.ActivateCharacter.character_indices);
            }
        }

        if (self.registered_ids.items.len == 0) {
            self.hotkey_map.clearRetainingCapacity();
            return;
        }

        slog.debug("Unregistering {} hotkey(s)...", .{self.registered_ids.items.len});
        for (self.registered_ids.items) |id| {
            // Mouse-button hotkeys were never registered via RegisterHotKey, so this expectedly (harmlessly) fails for them.
            if (!win32.toBool(win32.UnregisterHotKey(hwnd, id))) {
                slog.debug("Failed to unregister hotkey ID {}", .{id});
            }
        }
        self.registered_ids.clearRetainingCapacity();
        self.hotkey_map.clearRetainingCapacity();
    }

    /// Handles a WM_HOTKEY press; lparam is the raw lParam, used only to recover the vk code for release-consumption.
    pub fn handleHotkeyPress(self: *HotkeyManager, hotkey_id: c_int, lparam: win32.LPARAM) void {
        const action = self.hotkey_map.get(hotkey_id) orelse {
            slog.warn("Received unknown hotkey ID: {}", .{hotkey_id});
            return;
        };

        // No MOD_NOREPEAT (see registerSingleHotkey), so this must run before every early return or held keys would re-fire.
        const vk_code = win32.hotkeyVkFromLparam(lparam);
        if (!trackHotkeyPress(self.allocator, vk_code)) {
            slog.debug("Hotkey {} ignored - key-repeat re-fire while held", .{hotkey_id});
            return;
        }

        // Always handle suspend hotkey, regardless of suspension state
        if (std.meta.activeTag(action) == .SuspendHotkeys) {
            self.handleSuspendHotkeys();
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

        if (self.config.requireEveFocus) {
            if (!self.hasEveFocus()) {
                slog.debug("Hotkey {} ignored - EVE window not in focus", .{hotkey_id});
                return;
            }
        }

        // Only swallow the key's release if focus actually moved; a cycle with no eligible target never changes foreground.
        const foreground_before = win32.GetForegroundWindow();

        switch (action) {
            .CycleGroup => |cycle| {
                if (cycle.group_index >= self.config.hotkeyGroups.items.len) {
                    slog.err("Invalid group index {} for hotkey ID {}", .{ cycle.group_index, hotkey_id });
                    return;
                }
                const group = &self.config.hotkeyGroups.items[cycle.group_index];
                self.cycleGroup(group, cycle.forward);
            },
            .ActivateCharacter => {
                self.activatePerCharacterGroup(hotkey_id);
            },
            .AssignQuickGroup => |assign| {
                self.handleAssignQuickGroup(assign.group_index);
            },
            .CycleQuickGroup => |cycle| {
                if (cycle.group_index >= self.config.quickGroups.items.len) {
                    slog.err("Invalid quick group index {} for hotkey ID {}", .{ cycle.group_index, hotkey_id });
                    return;
                }
                const group = &self.config.quickGroups.items[cycle.group_index];
                self.cycleQuickGroup(group, cycle.forward);
            },
            .MinimizeAll => {
                self.handleMinimizeAll();
            },
            .CloseAll => {
                self.handleCloseAll();
            },
            .ToggleVisibility => {
                self.handleToggleVisibility();
            },
            .NextProfile => {
                self.handleNextProfile();
            },
            .PreviousProfile => {
                self.handlePreviousProfile();
            },
            .SwitchToProfile => |sp| {
                self.handleSwitchToProfile(sp.profile_index);
            },
            .ToggleExclusion => {
                self.handleToggleExclusion();
            },
            .NextExcluded => {
                self.handleNextExcluded();
            },
            .PreviousExcluded => {
                self.handlePreviousExcluded();
            },
            .SuspendHotkeys => {
                // Already handled above before suspension check
                unreachable;
            },
            .ToggleAutoMinimize => {
                self.handleToggleAutoMinimize();
            },
            .CycleNotified => {
                self.handleCycleNotified(true);
            },
            .PreviousNotified => {
                self.handleCycleNotified(false);
            },
            .NextAllClients => {
                self.handleCycleAllClients(true);
            },
            .PreviousAllClients => {
                self.handleCycleAllClients(false);
            },
            .NextNotLoggedIn => {
                self.handleCycleNotLoggedIn(true);
            },
            .PreviousNotLoggedIn => {
                self.handleCycleNotLoggedIn(false);
            },
            .MoveToSavedPositions => {
                self.handleMoveToSavedPositions();
            },
        }

        if (win32.GetForegroundWindow() != foreground_before) {
            markHotkeySwallowRelease(vk_code);
        }
    }

    fn hasEveFocus(self: *HotkeyManager) bool {
        const foreground_hwnd = win32.GetForegroundWindow();
        if (foreground_hwnd == null) return false;

        const eve_windows = self.scout.getWindows();
        for (eve_windows) |eve_window| {
            if (eve_window.hwnd == foreground_hwnd) {
                return true;
            }
        }

        return false;
    }

    fn handleMinimizeAll(self: *HotkeyManager) void {
        slog.info("Minimize all hotkey pressed", .{});
        self.painter.minimizeAllClients();
    }

    pub fn handleMinimizeAllRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler minimize all request", .{});
        self.handleMinimizeAll();
    }

    fn handleCloseAll(self: *HotkeyManager) void {
        slog.info("Close all hotkey pressed", .{});
        self.painter.closeAllClients();
    }

    pub fn handleCloseAllRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler close all request", .{});
        self.handleCloseAll();
    }

    fn handleMoveToSavedPositions(self: *HotkeyManager) void {
        slog.info("Move to saved positions hotkey pressed", .{});
        self.painter.moveAllClientsToSavedPositions();
    }

    pub fn handleMoveToSavedPositionsRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler move to saved positions request", .{});
        self.handleMoveToSavedPositions();
    }

    fn handleToggleVisibility(self: *HotkeyManager) void {
        slog.info("Toggle visibility hotkey pressed", .{});
        self.painter.toggleAllThumbnailsVisibility();
    }

    fn handleToggleAutoMinimize(self: *HotkeyManager) void {
        slog.info("Toggle auto-minimize hotkey pressed", .{});
        self.painter.toggleAutoMinimize();
    }

    pub fn handleToggleVisibilityRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler toggle visibility request", .{});
        self.handleToggleVisibility();
    }

    pub fn handleToggleAutoMinimizeRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler toggle auto-minimize request", .{});
        self.handleToggleAutoMinimize();
    }

    pub fn handleNextProfileRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler next profile request", .{});
        self.handleNextProfile();
    }

    fn handleNextProfile(self: *HotkeyManager) void {
        self.cycleProfile(true);
    }

    pub fn handlePreviousProfileRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler previous profile request", .{});
        self.handlePreviousProfile();
    }

    fn handlePreviousProfile(self: *HotkeyManager) void {
        self.cycleProfile(false);
    }

    /// Triggers a profile cycle (forward or backward) by posting a message to the main window.
    fn cycleProfile(self: *HotkeyManager, forward: bool) void {
        slog.info("{s} profile hotkey pressed", .{if (forward) "Next" else "Previous"});

        var profiles = config_mod.GlobalSettings.enumerateProfiles(self.allocator) catch |err| {
            slog.err("Failed to enumerate profiles: {}", .{err});
            return;
        };
        defer {
            for (profiles.items) |profile| {
                self.allocator.free(profile);
            }
            profiles.deinit(self.allocator);
        }

        if (profiles.items.len == 0) {
            slog.warn("No profiles found to cycle through", .{});
            return;
        }

        const current_profile = self.config.profile_name;
        var current_index: ?usize = null;
        for (profiles.items, 0..) |profile, i| {
            if (std.mem.eql(u8, profile, current_profile)) {
                current_index = i;
                break;
            }
        }

        const target_index = cycleStartIndex(current_index, profiles.items.len, forward);

        const target_profile = profiles.items[target_index];
        slog.info("Cycling to {s} profile: {s} -> {s}", .{ if (forward) "next" else "previous", current_profile, target_profile });

        // Copied to a static buffer since WM_SWITCH_PROFILE is processed asynchronously, after profiles/target_profile go out of scope.
        if (target_profile.len >= g_profile_cycle_buffer.len) {
            slog.err("Profile name too long: {s}", .{target_profile});
            return;
        }
        @memcpy(g_profile_cycle_buffer[0..target_profile.len], target_profile);
        const profile_name_slice = g_profile_cycle_buffer[0..target_profile.len];

        // Safe because it points into g_profile_cycle_buffer (static storage); tray.zig's takePendingProfileName() doesn't dupe it.
        tray_mod.g_pending_profile_name = profile_name_slice;

        if (main_mod.g_timer_hwnd) |hwnd| {
            _ = win32.PostMessageA(hwnd, win32.WM_SWITCH_PROFILE, 0, 0);
        } else {
            slog.err("Timer window not available for profile switch", .{});
        }
    }

    /// Triggers a profile switch by posting a message to the main window.
    fn handleSwitchToProfile(self: *HotkeyManager, profile_index: usize) void {
        if (profile_index >= self.global_settings.profileSwitchHotkeys.items.len) {
            slog.err("Invalid profile switch index {}", .{profile_index});
            return;
        }

        const target_profile = self.global_settings.profileSwitchHotkeys.items[profile_index].targetProfile;
        slog.info("Switch to profile hotkey pressed: {s} -> {s}", .{ self.config.profile_name, target_profile });

        // Copied to a static buffer since a config reload could free target_profile's backing memory before the async message is handled.
        if (target_profile.len >= g_profile_switch_buffer.len) {
            slog.err("Profile name too long: {s}", .{target_profile});
            return;
        }
        @memcpy(g_profile_switch_buffer[0..target_profile.len], target_profile);
        const profile_name_slice = g_profile_switch_buffer[0..target_profile.len];

        tray_mod.g_pending_profile_name = profile_name_slice;

        if (main_mod.g_timer_hwnd) |hwnd| {
            _ = win32.PostMessageA(hwnd, win32.WM_SWITCH_PROFILE, 0, 0);
        } else {
            slog.err("Timer window not available for profile switch", .{});
        }
    }

    fn handleToggleExclusion(self: *HotkeyManager) void {
        const foreground_hwnd = win32.GetForegroundWindow() orelse {
            slog.debug("No window has focus for exclusion toggle", .{});
            return;
        };

        const eve_windows = self.scout.getWindows();
        for (eve_windows) |eve_window| {
            if (eve_window.hwnd == foreground_hwnd) {
                slog.info("Toggle exclusion hotkey pressed for: {s}", .{eve_window.character_name});
                input.handleThumbnailShiftClick(eve_window.hwnd);
                return;
            }
        }

        slog.debug("Focused window is not an EVE client, exclusion toggle ignored", .{});
    }

    pub fn handleToggleExclusionRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler toggle exclusion request", .{});
        self.handleToggleExclusion();
    }

    pub fn handleNextExcludedRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler next excluded character request", .{});
        self.handleNextExcluded();
    }

    pub fn handlePreviousExcludedRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler previous excluded character request", .{});
        self.handlePreviousExcluded();
    }

    pub fn handleCycleNotifiedRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler cycle notified character request", .{});
        self.handleCycleNotified(true);
    }

    pub fn handlePreviousNotifiedRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler previous notified character request", .{});
        self.handleCycleNotified(false);
    }

    fn handleSuspendHotkeys(self: *HotkeyManager) void {
        self.hotkeys_suspended = !self.hotkeys_suspended;
        const state = if (self.hotkeys_suspended) "suspended" else "resumed";
        slog.info("Hotkeys {s}", .{state});

        if (main_mod.g_timer_hwnd) |hwnd| {
            _ = win32.PostMessageA(hwnd, win32.WM_HOTKEYS_STATE_CHANGED, 0, 0);
        }
    }

    pub fn handleSuspendHotkeysRequest(self: *HotkeyManager) void {
        slog.debug("Protocol handler suspend hotkeys request", .{});
        self.handleSuspendHotkeys();
    }

    pub fn areHotkeysSuspended(self: *HotkeyManager) bool {
        return self.hotkeys_suspended;
    }

    /// Unregisters every live hotkey (not just gates dispatch) since RegisterHotKey intercepts system-wide, so a gate alone would never let the dialog see the keypress.
    pub fn dialogSuspendHotkeys(self: *HotkeyManager, hwnd: win32.HWND) void {
        if (self.dialog_suspended) return;
        slog.debug("Config dialog is recording a hotkey - unregistering live hotkeys", .{});
        self.dialog_suspended = true;
        self.unregisterAll(hwnd);
    }

    /// Re-registers from the same in-memory config unregisterAll left untouched, so this restores exactly what was live before.
    pub fn dialogResumeHotkeys(self: *HotkeyManager, hwnd: win32.HWND) void {
        if (!self.dialog_suspended) return;
        slog.debug("Config dialog finished recording - re-registering hotkeys", .{});
        self.dialog_suspended = false;
        self.registerHotkeys(hwnd) catch |err| {
            slog.err("Failed to re-register hotkeys after dialog recording: {}", .{err});
        };
    }

    /// Advances idx by one position within [0, num), wrapping at either end.
    fn stepCycleIndex(idx: usize, num: usize, forward: bool) usize {
        if (forward) return (idx + 1) % num;
        return if (idx == 0) num - 1 else idx - 1;
    }

    /// Returns the index to step *from*, not the index to check first - for a loop that steps once before its first check, so a stale/absent cursor resolves one-before-the-start.
    fn cycleIndexBeforeStart(current: ?usize, num: usize, forward: bool) usize {
        const valid_current = if (current) |ci| (if (ci < num) ci else null) else null;
        return valid_current orelse (if (forward) num - 1 else 0);
    }

    /// Like cycleIndexBeforeStart, but for a loop that checks its cursor directly with no pre-step.
    fn cycleStartIndex(found_index: ?usize, num: usize, forward: bool) usize {
        if (found_index) |i| return stepCycleIndex(i, num, forward);
        return if (forward) 0 else num - 1;
    }

    /// Cycles to the next running character sharing this hotkey.
    fn activatePerCharacterGroup(self: *HotkeyManager, hotkey_id: c_int) void {
        const action = self.hotkey_map.getPtr(hotkey_id) orelse return;
        if (std.meta.activeTag(action.*) != .ActivateCharacter) return;
        const group = &action.ActivateCharacter;

        const num = group.character_indices.len;
        if (num == 0) return;

        const start_index = group.current_index;
        var idx: usize = cycleIndexBeforeStart(group.current_index, num, true);
        var attempts: usize = 0;

        while (attempts < num) : (attempts += 1) {
            idx = stepCycleIndex(idx, num, true);
            const char_index = group.character_indices[idx];
            if (char_index >= self.config.characters.items.len) continue;
            const char_name = self.config.characters.items[char_index].name;

            if (self.scout.getHwndByName(char_name)) |hwnd| {
                group.current_index = idx;
                slog.info("Activating character: {s} ({}/{})", .{ char_name, idx + 1, num });
                input.handleThumbnailClick(hwnd);
                return;
            }
        }

        group.current_index = start_index;
        slog.warn("No character sharing this hotkey is currently running", .{});
    }

    fn cycleGroup(self: *HotkeyManager, group: *config_mod.HotkeyGroup, forward: bool) void {
        const num_chars = group.characters.items.len;
        if (num_chars == 0) {
            slog.warn("Attempted to cycle empty hotkey group", .{});
            return;
        }

        const start_index = group.currentIndex;
        var idx: usize = cycleIndexBeforeStart(group.currentIndex, num_chars, forward);
        var attempts: usize = 0;

        while (attempts < num_chars) : (attempts += 1) {
            idx = stepCycleIndex(idx, num_chars, forward);

            const char_name = group.characters.items[idx];

            if (isCharacterExcludedInGroup(group, char_name)) {
                slog.debug("Skipping excluded character: {s}", .{char_name});
                continue;
            }

            if (self.scout.getHwndByName(char_name)) |hwnd| {
                group.currentIndex = idx;
                slog.info("Cycling {s} to: {s} ({}/{})", .{
                    if (forward) "forward" else "backward",
                    char_name,
                    idx + 1,
                    num_chars,
                });
                input.handleThumbnailClick(hwnd);
                return;
            }
        }

        group.currentIndex = start_index;
        slog.warn("No characters from hotkey group are currently running (or all are excluded)", .{});
    }

    /// Like cycleGroup, but quick groups have no exclusion list to skip.
    fn cycleQuickGroup(self: *HotkeyManager, group: *config_mod.QuickGroup, forward: bool) void {
        const num_chars = group.characters.items.len;
        if (num_chars == 0) {
            slog.warn("Attempted to cycle empty quick group", .{});
            return;
        }

        const start_index = group.currentIndex;
        var idx: usize = cycleIndexBeforeStart(group.currentIndex, num_chars, forward);
        var attempts: usize = 0;

        while (attempts < num_chars) : (attempts += 1) {
            idx = stepCycleIndex(idx, num_chars, forward);

            const char_name = group.characters.items[idx];

            if (self.scout.getHwndByName(char_name)) |hwnd| {
                group.currentIndex = idx;
                slog.info("Cycling quick group {s} to: {s} ({}/{})", .{
                    if (forward) "forward" else "backward",
                    char_name,
                    idx + 1,
                    num_chars,
                });
                input.handleThumbnailClick(hwnd);
                return;
            }
        }

        group.currentIndex = start_index;
        slog.warn("No characters from quick group are currently running", .{});
    }

    /// Toggle the thumbnail currently under the cursor in/out of a quick group; no-op if nothing's hovered.
    fn handleAssignQuickGroup(self: *HotkeyManager, group_index: usize) void {
        if (group_index >= self.config.quickGroups.items.len) {
            slog.err("Invalid quick group index {}", .{group_index});
            return;
        }

        const thumbnail = input.resolveThumbnailUnderCursor() orelse {
            slog.debug("Quick group {} assign pressed but no thumbnail is under the cursor", .{group_index});
            return;
        };

        const group = &self.config.quickGroups.items[group_index];
        const char_name = thumbnail.character_name;

        const added = toggleStringMembership(self.allocator, &group.characters, char_name) catch {
            slog.err("Failed to toggle {s} in quick group {} [{s}]", .{ char_name, group_index, group.name });
            return;
        };
        if (added) {
            slog.info("Added {s} to quick group {} [{s}]", .{ char_name, group_index, group.name });
        } else {
            slog.info("Removed {s} from quick group {} [{s}]", .{ char_name, group_index, group.name });
        }

        // Membership changed - old index may now point at a shifted member
        group.currentIndex = null;

        self.painter.refreshQuickGroupBadge(thumbnail);
        self.painter.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail after quick group assignment: {}", .{err});
        };
    }

    /// Index of the first slice in `list` equal to `name`, or null.
    fn findStringIndex(list: []const []const u8, name: []const u8) ?usize {
        for (list, 0..) |item, i| {
            if (std.mem.eql(u8, item, name)) return i;
        }
        return null;
    }

    /// Toggles name's membership in list: removes+frees if present (returns false), else dupes+appends (returns true).
    fn toggleStringMembership(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !bool {
        if (findStringIndex(list.items, name)) |index| {
            const removed = list.orderedRemove(index);
            allocator.free(removed);
            return false;
        }
        const duped = try allocator.dupe(u8, name);
        errdefer allocator.free(duped);
        try list.append(allocator, duped);
        return true;
    }

    fn isCharacterExcludedInGroup(group: *const config_mod.HotkeyGroup, character_name: []const u8) bool {
        return findStringIndex(group.excluded_characters.items, character_name) != null;
    }

    pub fn isCharacterExcluded(self: *HotkeyManager, character_name: []const u8) bool {
        if (findStringIndex(self.manually_excluded_characters.items, character_name) != null) {
            return true;
        }

        for (self.config.hotkeyGroups.items) |*group| {
            const in_group = findStringIndex(group.characters.items, character_name) != null;
            if (in_group and isCharacterExcludedInGroup(group, character_name)) {
                return true;
            }
        }
        return false;
    }

    /// Toggles exclusion in every group containing the character; characters in no group fall back to manually_excluded_characters.
    pub fn toggleCharacterExclusion(self: *HotkeyManager, character_name: []const u8) void {
        var found_in_group = false;

        for (self.config.hotkeyGroups.items) |*group| {
            if (findStringIndex(group.characters.items, character_name) == null) continue;
            found_in_group = true;

            const added = toggleStringMembership(self.allocator, &group.excluded_characters, character_name) catch {
                slog.err("Failed to toggle exclusion for {s}", .{character_name});
                return;
            };
            if (added) {
                slog.debug("Added {s} to exclusion list", .{character_name});
            } else {
                slog.debug("Removed {s} from exclusion list", .{character_name});
            }
        }

        if (!found_in_group) {
            self.toggleManualExclusion(character_name);
        }

        // Reset excluded cycle index when exclusion list changes for predictable behavior
        self.excluded_cycle_index = null;
    }

    /// Toggles membership in manually_excluded_characters, the fallback list for characters in no hotkey group.
    fn toggleManualExclusion(self: *HotkeyManager, character_name: []const u8) void {
        const added = toggleStringMembership(self.allocator, &self.manually_excluded_characters, character_name) catch {
            slog.err("Failed to toggle manual exclusion for {s}", .{character_name});
            return;
        };
        if (added) {
            slog.debug("Added {s} to manual exclusion list", .{character_name});
        } else {
            slog.debug("Removed {s} from manual exclusion list", .{character_name});
        }
    }

    fn handleNextExcluded(self: *HotkeyManager) void {
        slog.info("Next excluded character hotkey pressed", .{});
        self.cycleExcluded(true);
    }

    fn handlePreviousExcluded(self: *HotkeyManager) void {
        slog.info("Previous excluded character hotkey pressed", .{});
        self.cycleExcluded(false);
    }

    /// Appends names not already in seen to dest, marking them seen; used by buildExcludedList() to dedupe.
    fn appendUnseenNames(self: *HotkeyManager, dest: *std.ArrayList([]const u8), seen: *std.StringHashMap(void), names: []const []const u8) void {
        for (names) |excluded_name| {
            const result = seen.getOrPut(excluded_name) catch {
                slog.err("Failed to allocate memory for seen map", .{});
                continue;
            };
            if (!result.found_existing) {
                dest.append(self.allocator, excluded_name) catch {
                    slog.err("Failed to add excluded character to list", .{});
                    continue;
                };
            }
        }
    }

    /// Builds the deduplicated union of every group's exclusion list and manually_excluded_characters; shared so cycleExcluded/updateExcludedCycleIndex agree.
    fn buildExcludedList(self: *HotkeyManager) std.ArrayList([]const u8) {
        var excluded_list: std.ArrayList([]const u8) = .empty;

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (self.config.hotkeyGroups.items) |*group| {
            self.appendUnseenNames(&excluded_list, &seen, group.excluded_characters.items);
        }
        self.appendUnseenNames(&excluded_list, &seen, self.manually_excluded_characters.items);

        return excluded_list;
    }

    /// Cycle through excluded characters in the order they were added to exclusion lists
    fn cycleExcluded(self: *HotkeyManager, forward: bool) void {
        var excluded_list = self.buildExcludedList();
        defer excluded_list.deinit(self.allocator);

        const num_excluded = excluded_list.items.len;
        if (num_excluded == 0) {
            slog.info("No excluded characters to cycle through", .{});
            return;
        }

        const start_index = self.excluded_cycle_index;
        var idx: usize = cycleIndexBeforeStart(self.excluded_cycle_index, num_excluded, forward);
        var attempts: usize = 0;

        while (attempts < num_excluded) : (attempts += 1) {
            idx = stepCycleIndex(idx, num_excluded, forward);

            const char_name = excluded_list.items[idx];

            if (self.scout.getHwndByName(char_name)) |hwnd| {
                self.excluded_cycle_index = idx;
                slog.info("Cycling {s} to excluded character: {s} ({}/{})", .{
                    if (forward) "forward" else "backward",
                    char_name,
                    idx + 1,
                    num_excluded,
                });
                input.handleThumbnailClick(hwnd);
                return;
            } else {
                slog.debug("Excluded character {s} is not currently running, skipping", .{char_name});
            }
        }

        self.excluded_cycle_index = start_index;
        slog.warn("No excluded characters are currently running", .{});
    }

    fn handleCycleNotified(self: *HotkeyManager, forward: bool) void {
        slog.info("Cycle notified character hotkey pressed ({s})", .{if (forward) "forward" else "backward"});
        self.cycleNotified(forward);
    }

    /// Cycles to the most-recently-notified character (FIFO); cursor is the last character name jumped to since the queue mutates between presses.
    fn cycleNotified(self: *HotkeyManager, forward: bool) void {
        const retention_ms: u64 = @as(u64, self.config.thumbnail.notifications.notified_cycle_retention_seconds) * 1000;

        var names = self.painter.getNotifiedCharacterNames(self.allocator, retention_ms) catch |err| {
            slog.err("Failed to build notified-character list: {}", .{err});
            return;
        };
        defer names.deinit(self.allocator);

        const num_notified = names.items.len;
        if (num_notified == 0) {
            slog.info("No recently-notified characters to cycle through", .{});
            return;
        }

        var found_index: ?usize = null;
        if (self.last_notified_cycle_name) |last_name| {
            for (names.items, 0..) |name, i| {
                if (std.mem.eql(u8, name, last_name)) {
                    found_index = i;
                    break;
                }
            }
        }
        const start_index = cycleStartIndex(found_index, num_notified, forward);

        var index = start_index;
        var attempts: usize = 0;
        while (attempts < num_notified) : (attempts += 1) {
            const char_name = names.items[index];

            if (self.scout.getHwndByName(char_name)) |hwnd| {
                slog.info("Cycling {s} to notified character: {s} ({}/{})", .{ if (forward) "forward" else "backward", char_name, index + 1, num_notified });
                input.handleThumbnailClick(hwnd);
                self.setLastNotifiedCycleName(char_name);
                return;
            }

            slog.debug("Notified character {s} is not currently running, skipping", .{char_name});
            index = stepCycleIndex(index, num_notified, forward);
        }

        slog.warn("No recently-notified characters are currently running", .{});
    }

    /// Replaces `field.*` with an owned copy of name, freeing the previous value.
    fn setOwnedCursorName(self: *HotkeyManager, field: *?[]const u8, name: []const u8, context: []const u8) void {
        const duped = self.allocator.dupe(u8, name) catch |err| {
            slog.err("Failed to remember {s} cycle cursor for {s}: {}", .{ context, name, err });
            return;
        };
        if (field.*) |old| self.allocator.free(old);
        field.* = duped;
    }

    fn setLastNotifiedCycleName(self: *HotkeyManager, name: []const u8) void {
        self.setOwnedCursorName(&self.last_notified_cycle_name, name, "notified");
    }

    fn handleCycleAllClients(self: *HotkeyManager, forward: bool) void {
        slog.info("Cycle all clients hotkey pressed ({s})", .{if (forward) "forward" else "backward"});
        self.cycleAllClients(forward);
    }

    pub fn handleCycleAllClientsRequest(self: *HotkeyManager, forward: bool) void {
        slog.debug("Protocol handler cycle all clients request ({s})", .{if (forward) "forward" else "backward"});
        self.handleCycleAllClients(forward);
    }

    /// Cycles every logged-in client in Scout's discovery order; unlike other cycles, every entry is guaranteed running.
    fn cycleAllClients(self: *HotkeyManager, forward: bool) void {
        const windows = self.scout.getWindows();
        const num = windows.len;
        if (num == 0) {
            slog.info("No logged-in clients to cycle through", .{});
            return;
        }

        var found_index: ?usize = null;
        if (self.last_all_clients_cycle_name) |last_name| {
            for (windows, 0..) |w, i| {
                if (std.mem.eql(u8, w.character_name, last_name)) {
                    found_index = i;
                    break;
                }
            }
        }
        const start_index = cycleStartIndex(found_index, num, forward);

        const respect_exclusions = self.global_settings.cycleAllClientsRespectExclusions;
        var index = start_index;
        var attempts: usize = 0;
        while (attempts < num) : (attempts += 1) {
            const w = windows[index];

            if (respect_exclusions and self.isCharacterExcluded(w.character_name)) {
                index = stepCycleIndex(index, num, forward);
                continue;
            }

            slog.info("Cycling {s} to client: {s} ({}/{})", .{ if (forward) "forward" else "backward", w.character_name, index + 1, num });
            input.handleThumbnailClick(w.hwnd);
            self.setLastAllClientsCycleName(w.character_name);
            return;
        }

        slog.warn("No logged-in clients are eligible to cycle to (all excluded)", .{});
    }

    fn setLastAllClientsCycleName(self: *HotkeyManager, name: []const u8) void {
        self.setOwnedCursorName(&self.last_all_clients_cycle_name, name, "all-clients");
    }

    fn handleCycleNotLoggedIn(self: *HotkeyManager, forward: bool) void {
        slog.info("Cycle not-logged-in hotkey pressed ({s})", .{if (forward) "forward" else "backward"});
        self.cycleNotLoggedIn(forward);
    }

    pub fn handleCycleNotLoggedInRequest(self: *HotkeyManager, forward: bool) void {
        slog.debug("Protocol handler cycle not-logged-in request ({s})", .{if (forward) "forward" else "backward"});
        self.handleCycleNotLoggedIn(forward);
    }

    /// Cycles windows still at the login screen ("EVE" title); cursor must be HWND since they all share that name.
    fn cycleNotLoggedIn(self: *HotkeyManager, forward: bool) void {
        const windows = self.scout.getWindows();

        var candidates: std.ArrayList(win32.HWND) = .empty;
        defer candidates.deinit(self.allocator);
        for (windows) |w| {
            if (scout.isGenericCharacterName(w.character_name)) {
                candidates.append(self.allocator, w.hwnd) catch |err| {
                    slog.err("Failed to collect not-logged-in candidate window: {}", .{err});
                };
            }
        }

        const num = candidates.items.len;
        if (num == 0) {
            slog.info("No not-logged-in clients to cycle through", .{});
            return;
        }

        var found_index: ?usize = null;
        if (self.last_not_logged_in_cycle_hwnd) |last_hwnd| {
            for (candidates.items, 0..) |hwnd, i| {
                if (hwnd == last_hwnd) {
                    found_index = i;
                    break;
                }
            }
        }
        const start_index = cycleStartIndex(found_index, num, forward);

        const hwnd = candidates.items[start_index];
        slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ if (forward) "forward" else "backward", start_index + 1, num });
        input.handleThumbnailClick(hwnd);
        self.last_not_logged_in_cycle_hwnd = hwnd;
    }

    /// Syncs currentIndex on every group in `groups` containing character_name; returns whether any did. HotkeyGroup and QuickGroup both expose the fields this needs.
    fn syncGroupCycleIndex(comptime GroupT: type, groups: []GroupT, character_name: []const u8, kind: []const u8) bool {
        var found = false;
        for (groups) |*group| {
            const index = findStringIndex(group.characters.items, character_name) orelse continue;
            if (group.currentIndex == null or group.currentIndex.? != index) {
                slog.debug("Updated {s} index: {s} now at position {}/{}", .{ kind, character_name, index + 1, group.characters.items.len });
                group.currentIndex = index;
            }
            found = true;
        }
        return found;
    }

    /// Clears currentIndex on every group in `groups`; used when character_name isn't in any of them.
    fn resetGroupIndices(comptime GroupT: type, groups: []GroupT, character_name: []const u8, kind: []const u8) void {
        for (groups) |*group| {
            group.currentIndex = null;
        }
        slog.debug("Reset {s} cycle indices - {s} is not in any {s}", .{ kind, character_name, kind });
    }

    /// Update currentIndex for hotkey groups when a character is manually focused
    pub fn updateFocusedCharacter(self: *HotkeyManager, character_name: []const u8) void {
        // Verify the window actually has focus first, to avoid stale updates during rapid cycling.
        const character_hwnd = self.scout.getHwndByName(character_name);
        const foreground_hwnd = win32.GetForegroundWindow();

        if (character_hwnd != foreground_hwnd) {
            slog.debug("Ignoring updateFocusedCharacter for {s} - not the foreground window", .{character_name});
            return;
        }

        self.updateExcludedCycleIndex(character_name);

        var pc_it = self.hotkey_map.valueIterator();
        while (pc_it.next()) |action| {
            if (std.meta.activeTag(action.*) != .ActivateCharacter) continue;
            const group = &action.ActivateCharacter;
            for (group.character_indices, 0..) |char_index, idx| {
                if (char_index < self.config.characters.items.len and std.mem.eql(u8, self.config.characters.items[char_index].name, character_name)) {
                    if (group.current_index == null or group.current_index.? != idx) {
                        group.current_index = idx;
                    }
                    break;
                }
            }
        }

        const found_in_hotkey_group = syncGroupCycleIndex(config_mod.HotkeyGroup, self.config.hotkeyGroups.items, character_name, "hotkey group");
        const found_in_quick_group = syncGroupCycleIndex(config_mod.QuickGroup, self.config.quickGroups.items, character_name, "quick group");

        // Each group kind resets independently; being in a hotkey group shouldn't block a quick-group reset or vice versa.
        if (self.config.resetGroupIndexOnNonGroupFocus and !found_in_hotkey_group) {
            resetGroupIndices(config_mod.HotkeyGroup, self.config.hotkeyGroups.items, character_name, "hotkey group");
        }
        if (self.config.resetGroupIndexOnNonGroupFocus and !found_in_quick_group) {
            resetGroupIndices(config_mod.QuickGroup, self.config.quickGroups.items, character_name, "quick group");
        }
    }

    fn updateExcludedCycleIndex(self: *HotkeyManager, character_name: []const u8) void {
        var excluded_list = self.buildExcludedList();
        defer excluded_list.deinit(self.allocator);

        for (excluded_list.items, 0..) |excluded_name, index| {
            if (std.mem.eql(u8, excluded_name, character_name)) {
                if (self.excluded_cycle_index == null or self.excluded_cycle_index.? != index) {
                    slog.debug("Updated excluded cycle index: {s} now at position {}/{}", .{ character_name, index + 1, excluded_list.items.len });
                    self.excluded_cycle_index = index;
                }
                return;
            }
        }
    }

    pub fn deinit(self: *HotkeyManager) void {
        if (self.last_notified_cycle_name) |name| self.allocator.free(name);
        if (self.last_all_clients_cycle_name) |name| self.allocator.free(name);
        for (self.manually_excluded_characters.items) |name| self.allocator.free(name);
        self.manually_excluded_characters.deinit(self.allocator);
        self.hotkey_map.deinit();
        self.registered_ids.deinit(self.allocator);
    }
};
