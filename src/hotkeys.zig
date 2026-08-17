const std = @import("std");
const win32 = @import("win32.zig");
const input = @import("input.zig");
const scout = @import("scout.zig");
const config_mod = @import("config.zig");
const vk = @import("virtual_keys.zig");
const mouse_hook = @import("mouse_hook.zig");
const log = @import("log.zig");
const slog = log.scoped("hotkeys");

// Static buffers for profile names - must stay valid until the asynchronously processed
// WM_SWITCH_PROFILE message is handled.
var g_profile_cycle_buffer: [256]u8 = undefined;
var g_profile_switch_buffer: [256]u8 = undefined;

// Hotkey IDs are banded by range to avoid collisions: 0-999 cycling groups, 1000-1999 global
// actions, 2000-2999 per-character, 3000+ profile switch, 4000+ quick groups (3 IDs each).
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
    // Future actions can be added here
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
        character_index: usize,
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
    painter: *@import("painter.zig").Painter,
    hotkey_map: std.AutoHashMap(c_int, HotkeyAction),
    /// List of successfully registered hotkey IDs for cleanup
    registered_ids: std.ArrayList(c_int),
    /// Current index for cycling through excluded characters (global across all groups); null = not yet cycled, see cycleExcluded
    excluded_cycle_index: ?usize = null,
    /// Whether hotkeys are currently suspended (except suspend hotkey itself)
    hotkeys_suspended: bool = false,
    /// Whether the config dialog is actively recording a new hotkey - separate from
    /// hotkeys_suspended so this doesn't clobber (or get clobbered by) the user's own
    /// suspend/resume toggle. See dialogSuspendHotkeys()/dialogResumeHotkeys().
    dialog_suspended: bool = false,
    /// Owned copy of the character name we last jumped to via cycleNotified() —
    /// used as the cursor for the next press instead of a raw index, since
    /// Painter's notified_queue mutates between presses (entries age out,
    /// re-notifies bump to the back). null = no press yet; start from the front.
    last_notified_cycle_name: ?[]const u8 = null,
    /// Owned copy of the character name we last jumped to via cycleAllClients() —
    /// same rationale as last_notified_cycle_name: Scout.windows mutates as clients
    /// log in/out between key presses, so a raw index would drift. null = no press
    /// yet; start from the front (forward) or back (backward).
    last_all_clients_cycle_name: ?[]const u8 = null,
    /// HWND (not name) we last jumped to via cycleNotLoggedIn() — every not-logged-in
    /// window shares the same character_name ("EVE"), so name can't disambiguate
    /// between them the way it does for last_all_clients_cycle_name. HWNDs are stable
    /// for the lifetime of the window, so no dupe/free bookkeeping is needed either.
    last_not_logged_in_cycle_hwnd: ?win32.HWND = null,
    /// Owned names of characters excluded via shift-click that don't belong to any
    /// hotkey group. Per-group exclusion lists only mean anything to group-specific
    /// cycling, so a character with no group would otherwise have nowhere to record
    /// "excluded" at all — this is that fallback, checked by isCharacterExcluded().
    manually_excluded_characters: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config_mod.Config, gs: *const config_mod.GlobalSettings, s: *scout.Scout, p: *@import("painter.zig").Painter) !HotkeyManager {
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
        var fbs = std.io.fixedBufferStream(buffer);
        vk.writeVirtualKey(fbs.writer(), virtual_key) catch |err| {
            slog.warn("Failed to format virtual key 0x{X}: {}", .{ virtual_key, err });
            const fallback = std.fmt.bufPrint(buffer, "VK{X}", .{virtual_key}) catch "VK?";
            return fallback;
        };
        return fbs.getWritten();
    }

    /// Layered errdefer: each step's cleanup only runs if a later step in registration fails.
    fn registerAndTrackHotkey(self: *HotkeyManager, hwnd: win32.HWND, id: c_int, virtual_key: u32, action: HotkeyAction, description: []const u8) !void {
        // RegisterHotKey can't see mouse buttons; route those through the mouse hook instead,
        // which re-posts WM_HOTKEY on a match so downstream code stays unaware of the distinction.
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
        var has_per_character_hotkeys = false;
        for (self.config.characters.items) |char| {
            if (char.hotkey != null) {
                has_per_character_hotkeys = true;
                break;
            }
        }
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
        var per_character_count: usize = 0;
        for (self.config.characters.items) |char| {
            if (char.hotkey != null) per_character_count += 1;
        }
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

        errdefer self.unregisterAll(hwnd);

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
                    var key_name_buf: [32]u8 = undefined;
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
                    var key_name_buf: [64]u8 = undefined;
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
                    var key_name_buf: [32]u8 = undefined;
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
                    var key_name_buf: [32]u8 = undefined;
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
                    var key_name_buf: [32]u8 = undefined;
                    const key_name = formatKeyName(backward_vk, &key_name_buf);
                    slog.err("Failed to register backward hotkey {s} for quick group {} [{s}]: {}", .{ key_name, group_index, group.name, err });
                    failed_count += 1;
                };
            }
        }

        for (self.config.characters.items, 0..) |*char, char_index| {
            if (char.hotkey) |char_vk| {
                const char_id: c_int = HOTKEY_ID_PER_CHARACTER_BASE + @as(c_int, @intCast(char_index));
                const char_action = HotkeyAction{ .ActivateCharacter = .{ .character_index = char_index } };
                var char_desc_buf: [128]u8 = undefined;
                const char_desc = std.fmt.bufPrint(&char_desc_buf, "activate character [{s}]", .{char.name}) catch "activate character";
                self.registerAndTrackHotkey(hwnd, char_id, char_vk, char_action, char_desc) catch |err| {
                    var key_name_buf: [32]u8 = undefined;
                    const key_name = formatKeyName(char_vk, &key_name_buf);
                    slog.err("Failed to register hotkey {s} for character [{s}]: {}", .{ key_name, char.name, err });
                    failed_count += 1;
                };
            }
        }

        for (self.global_settings.profileSwitchHotkeys.items, 0..) |*psh, psh_index| {
            if (psh.hotkey) |sp_vk| {
                const sp_id: c_int = HOTKEY_ID_PROFILE_SWITCH_BASE + @as(c_int, @intCast(psh_index));
                const sp_action = HotkeyAction{ .SwitchToProfile = .{ .profile_index = psh_index } };
                var sp_desc_buf: [128]u8 = undefined;
                const sp_desc = std.fmt.bufPrint(&sp_desc_buf, "switch to profile [{s}]", .{psh.targetProfile}) catch "switch to profile";
                self.registerAndTrackHotkey(hwnd, sp_id, sp_vk, sp_action, sp_desc) catch |err| {
                    var key_name_buf: [32]u8 = undefined;
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
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register minimize all hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyCloseAll) |vk_code| {
            const id = @intFromEnum(GlobalActionId.CloseAll);
            const action = HotkeyAction{ .CloseAll = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "close all clients") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register close all hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyToggleVisibility) |vk_code| {
            const id = @intFromEnum(GlobalActionId.ToggleVisibility);
            const action = HotkeyAction{ .ToggleVisibility = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "toggle thumbnails visibility") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register toggle visibility hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyNextProfile) |vk_code| {
            const id = @intFromEnum(GlobalActionId.NextProfile);
            const action = HotkeyAction{ .NextProfile = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to next profile") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register next profile hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyPreviousProfile) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousProfile);
            const action = HotkeyAction{ .PreviousProfile = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to previous profile") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous profile hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyToggleExclusion) |vk_code| {
            const id = @intFromEnum(GlobalActionId.ToggleExclusion);
            const action = HotkeyAction{ .ToggleExclusion = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "toggle character exclusion from cycling") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register toggle exclusion hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyNextExcluded) |vk_code| {
            const id = @intFromEnum(GlobalActionId.NextExcluded);
            const action = HotkeyAction{ .NextExcluded = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to next excluded character") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register next excluded hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyPreviousExcluded) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousExcluded);
            const action = HotkeyAction{ .PreviousExcluded = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to previous excluded character") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous excluded hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeySuspend) |vk_code| {
            const id = @intFromEnum(GlobalActionId.SuspendHotkeys);
            const action = HotkeyAction{ .SuspendHotkeys = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "suspend/resume all hotkeys") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register suspend hotkeys {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyToggleAutoMinimize) |vk_code| {
            const id = @intFromEnum(GlobalActionId.ToggleAutoMinimize);
            const action = HotkeyAction{ .ToggleAutoMinimize = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "toggle auto-minimize mode") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register toggle auto-minimize hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyCycleNotified) |vk_code| {
            const id = @intFromEnum(GlobalActionId.CycleNotified);
            const action = HotkeyAction{ .CycleNotified = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle to most recently notified character") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register cycle notified hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyPreviousNotified) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousNotified);
            const action = HotkeyAction{ .PreviousNotified = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle backward through notified characters") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous notified hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyCycleAllClientsForward) |vk_code| {
            const id = @intFromEnum(GlobalActionId.NextAllClients);
            const action = HotkeyAction{ .NextAllClients = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle forward through all logged-in clients") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register next all-clients hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyCycleAllClientsBackward) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousAllClients);
            const action = HotkeyAction{ .PreviousAllClients = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle backward through all logged-in clients") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous all-clients hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyCycleNotLoggedInForward) |vk_code| {
            const id = @intFromEnum(GlobalActionId.NextNotLoggedIn);
            const action = HotkeyAction{ .NextNotLoggedIn = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle forward through not-logged-in clients") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register next not-logged-in hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.global_settings.hotkeyCycleNotLoggedInBackward) |vk_code| {
            const id = @intFromEnum(GlobalActionId.PreviousNotLoggedIn);
            const action = HotkeyAction{ .PreviousNotLoggedIn = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "cycle backward through not-logged-in clients") catch |err| {
                var key_name_buf: [32]u8 = undefined;
                const key_name = formatKeyName(vk_code, &key_name_buf);
                slog.err("Failed to register previous not-logged-in hotkey {s}: {}", .{ key_name, err });
                failed_count += 1;
            };
        }

        if (self.config.hotkeyMoveToSavedPositions) |vk_code| {
            const id = @intFromEnum(GlobalActionId.MoveToSavedPositions);
            const action = HotkeyAction{ .MoveToSavedPositions = {} };
            self.registerAndTrackHotkey(hwnd, id, vk_code, action, "move all clients to saved positions") catch |err| {
                var key_name_buf: [32]u8 = undefined;
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
        // virtual_key packs modifier flags (Ctrl/Alt/Shift/Win) alongside the base key; split
        // them back out since RegisterHotKey takes them as separate arguments.
        //
        // Deliberately not using MOD_NOREPEAT: it relies on observing the key's physical release,
        // but input.zig's release tracking already swallows that release at a lower level once a
        // hotkey's action moves focus, so MOD_NOREPEAT would never re-arm. handleHotkeyPress does
        // repeat suppression itself instead, via input.trackHotkeyPress on the same hook.
        const base_vk: win32.UINT = @intCast(vk.extractVk(virtual_key));
        const key_modifiers: win32.UINT = @intCast(vk.extractModifiers(virtual_key));
        const modifiers: win32.UINT = key_modifiers;

        if (!win32.toBool(win32.RegisterHotKey(hwnd, id, modifiers, base_vk))) {
            // Likely already in use by another application
            return error.HotkeyRegistrationFailed;
        }

        var key_name_buf: [32]u8 = undefined;
        const key_name = formatKeyName(virtual_key, &key_name_buf);

        slog.debug("Registered hotkey: {s} -> {s}", .{ key_name, description });
    }

    pub fn unregisterAll(self: *HotkeyManager, hwnd: win32.HWND) void {
        // Always clear mouse-button bindings too, regardless of whether any keyboard hotkeys
        // were registered - cheap no-op if none were ever added.
        mouse_hook.unregisterAll();
        input.uninstallHotkeyReleaseHook();

        if (self.registered_ids.items.len == 0) return;

        slog.debug("Unregistering {} hotkey(s)...", .{self.registered_ids.items.len});
        for (self.registered_ids.items) |id| {
            // Mouse-button hotkeys were never registered via RegisterHotKey, so this call is
            // expected to (harmlessly) fail for them - already cleaned up by mouse_hook.unregisterAll() above.
            if (!win32.toBool(win32.UnregisterHotKey(hwnd, id))) {
                slog.debug("Failed to unregister hotkey ID {}", .{id});
            }
        }
        self.registered_ids.clearRetainingCapacity();
        self.hotkey_map.clearRetainingCapacity();
    }

    /// Handle a hotkey press event from WM_HOTKEY. `lparam` is the raw WM_HOTKEY lParam,
    /// used only to recover the triggering virtual-key code for release-consumption.
    pub fn handleHotkeyPress(self: *HotkeyManager, hotkey_id: c_int, lparam: win32.LPARAM) void {
        const action = self.hotkey_map.get(hotkey_id) orelse {
            slog.warn("Received unknown hotkey ID: {}", .{hotkey_id});
            return;
        };

        // Hotkeys aren't registered with MOD_NOREPEAT (see registerSingleHotkey), so this has to
        // run before every early return below - otherwise Windows' auto-repeat would re-fire
        // WM_HOTKEY while the key is held, e.g. rapidly flipping the suspend toggle on and off.
        const vk_code = win32.hotkeyVkFromLparam(lparam);
        if (!input.trackHotkeyPress(self.allocator, vk_code)) {
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

        // Only swallow this key's physical release if the action actually moved focus, not just
        // because its type is capable of it - a cycle that finds no eligible target still runs
        // this dispatch but never calls input.handleThumbnailClick, so foreground stays unchanged
        // and the release passes through normally instead of being eaten from under the user.
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
            .ActivateCharacter => |activate| {
                self.activateCharacterByIndex(activate.character_index);
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
            input.markHotkeySwallowRelease(vk_code);
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

        const target_index = if (current_index) |idx|
            (if (forward) (idx + 1) % profiles.items.len else if (idx == 0) profiles.items.len - 1 else idx - 1)
        else if (forward)
            // If current not found, start at beginning
            0
        else
            // If current not found, start at end
            profiles.items.len - 1;

        const target_profile = profiles.items[target_index];
        slog.info("Cycling to {s} profile: {s} -> {s}", .{ if (forward) "next" else "previous", current_profile, target_profile });

        // Copy the profile name to a static buffer before freeing the profiles list
        // This is necessary because the WM_SWITCH_PROFILE message is processed asynchronously
        if (target_profile.len >= g_profile_cycle_buffer.len) {
            slog.err("Profile name too long: {s}", .{target_profile});
            return;
        }
        @memcpy(g_profile_cycle_buffer[0..target_profile.len], target_profile);
        const profile_name_slice = g_profile_cycle_buffer[0..target_profile.len];

        // Store the target profile name in tray module for WM_SWITCH_PROFILE handler.
        // Safe because it points into g_profile_cycle_buffer (static, file-scope storage),
        // not a stack frame - tray.zig's takePendingProfileName() does NOT dupe this slice,
        // it just hands the pointer back as-is.
        const tray_mod = @import("tray.zig");
        tray_mod.g_pending_profile_name = profile_name_slice;

        const main_mod = @import("main.zig");
        if (main_mod.g_timer_hwnd) |hwnd| {
            _ = win32.PostMessageA(hwnd, win32.WM_SWITCH_PROFILE, 0, 0);
        } else {
            slog.err("Timer window not available for profile switch", .{});
        }
    }

    /// This triggers a profile switch by posting a message to the main window
    fn handleSwitchToProfile(self: *HotkeyManager, profile_index: usize) void {
        if (profile_index >= self.global_settings.profileSwitchHotkeys.items.len) {
            slog.err("Invalid profile switch index {}", .{profile_index});
            return;
        }

        const target_profile = self.global_settings.profileSwitchHotkeys.items[profile_index].targetProfile;
        slog.info("Switch to profile hotkey pressed: {s} -> {s}", .{ self.config.profile_name, target_profile });

        // Copy the profile name to a static buffer since the WM_SWITCH_PROFILE message
        // is processed asynchronously and target_profile's backing memory may be freed
        // if the config is reloaded before the message is handled
        if (target_profile.len >= g_profile_switch_buffer.len) {
            slog.err("Profile name too long: {s}", .{target_profile});
            return;
        }
        @memcpy(g_profile_switch_buffer[0..target_profile.len], target_profile);
        const profile_name_slice = g_profile_switch_buffer[0..target_profile.len];

        // Store the target profile name in tray module for WM_SWITCH_PROFILE handler
        const tray_mod = @import("tray.zig");
        tray_mod.g_pending_profile_name = profile_name_slice;

        const main_mod = @import("main.zig");
        if (main_mod.g_timer_hwnd) |hwnd| {
            _ = win32.PostMessageA(hwnd, win32.WM_SWITCH_PROFILE, 0, 0);
        } else {
            slog.err("Timer window not available for profile switch", .{});
        }
    }

    /// Toggles exclusion for the currently focused EVE window
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

        // Update tray menu to reflect new state
        const main_mod = @import("main.zig");
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

    /// Suspend hotkeys while the config dialog records a new key combo (via
    /// PROTOCOL_DIALOG_SUSPEND_HOTKEYS). This actually unregisters every live
    /// RegisterHotKey binding, not just gates dispatch of the resulting action:
    /// RegisterHotKey intercepts its key combo system-wide, so a key already bound to
    /// a running hotkey never reaches the dialog's browser window as a normal
    /// keyup/keydown event at all - the Record UI would never see it fire, no matter
    /// what handleHotkeyPress does after the fact. dialog_suspended still gates
    /// dispatch too, as a safety net for any WM_HOTKEY already queued the instant
    /// before UnregisterHotKey takes effect.
    pub fn dialogSuspendHotkeys(self: *HotkeyManager, hwnd: win32.HWND) void {
        if (self.dialog_suspended) return;
        slog.debug("Config dialog is recording a hotkey - unregistering live hotkeys", .{});
        self.dialog_suspended = true;
        self.unregisterAll(hwnd);
    }

    /// Re-register hotkeys after the config dialog finishes recording (via
    /// PROTOCOL_DIALOG_RESUME_HOTKEYS). Re-reads from the same in-memory config/
    /// global_settings unregisterAll left untouched, so this restores exactly what
    /// was live before - nothing on disk changed just from recording.
    pub fn dialogResumeHotkeys(self: *HotkeyManager, hwnd: win32.HWND) void {
        if (!self.dialog_suspended) return;
        slog.debug("Config dialog finished recording - re-registering hotkeys", .{});
        self.dialog_suspended = false;
        self.registerHotkeys(hwnd) catch |err| {
            slog.err("Failed to re-register hotkeys after dialog recording: {}", .{err});
        };
    }

    /// Activate (focus) a specific character's EVE window by its index in config.characters
    fn activateCharacterByIndex(self: *HotkeyManager, character_index: usize) void {
        if (character_index >= self.config.characters.items.len) {
            slog.err("Invalid character index {}", .{character_index});
            return;
        }

        const char_name = self.config.characters.items[character_index].name;
        if (self.scout.getHwndByName(char_name)) |hwnd| {
            slog.info("Activating character: {s}", .{char_name});
            input.handleThumbnailClick(hwnd);
        } else {
            slog.warn("Character '{s}' is not currently running", .{char_name});
        }
    }

    /// Cycle through characters in a group and activate the next/previous one
    fn cycleGroup(self: *HotkeyManager, group: *config_mod.HotkeyGroup, forward: bool) void {
        const num_chars = group.characters.items.len;
        if (num_chars == 0) {
            slog.warn("Attempted to cycle empty hotkey group", .{});
            return;
        }

        // Try up to num_chars times to find an available character
        const start_index = group.currentIndex;
        // null/stale index starts just before the first element (forward) or just after the last (backward).
        const valid_current = if (group.currentIndex) |ci| (if (ci < num_chars) ci else null) else null;
        var idx: usize = valid_current orelse (if (forward) num_chars - 1 else 0);
        var attempts: usize = 0;

        while (attempts < num_chars) : (attempts += 1) {
            if (forward) {
                idx = (idx + 1) % num_chars;
            } else {
                idx = if (idx == 0) num_chars - 1 else idx - 1;
            }

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

        // Restore original index if no characters were found
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
        // null/stale index starts just before the first element (forward) or just after the last (backward).
        const valid_current = if (group.currentIndex) |ci| (if (ci < num_chars) ci else null) else null;
        var idx: usize = valid_current orelse (if (forward) num_chars - 1 else 0);
        var attempts: usize = 0;

        while (attempts < num_chars) : (attempts += 1) {
            if (forward) {
                idx = (idx + 1) % num_chars;
            } else {
                idx = if (idx == 0) num_chars - 1 else idx - 1;
            }

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

        var removed_index: ?usize = null;
        for (group.characters.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, char_name)) {
                removed_index = i;
                break;
            }
        }

        if (removed_index) |i| {
            self.allocator.free(group.characters.items[i]);
            _ = group.characters.orderedRemove(i);
            slog.info("Removed {s} from quick group {} [{s}]", .{ char_name, group_index, group.name });
        } else {
            const owned_name = self.allocator.dupe(u8, char_name) catch {
                slog.err("Failed to allocate character name for quick group assignment", .{});
                return;
            };
            group.characters.append(self.allocator, owned_name) catch {
                slog.err("Failed to add character to quick group", .{});
                self.allocator.free(owned_name);
                return;
            };
            slog.info("Added {s} to quick group {} [{s}]", .{ char_name, group_index, group.name });
        }

        // Membership changed - old index may now point at a shifted member
        group.currentIndex = null;

        self.painter.refreshQuickGroupBadge(thumbnail);
        self.painter.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail after quick group assignment: {}", .{err});
        };
    }

    fn isCharacterExcludedInGroup(group: *const config_mod.HotkeyGroup, character_name: []const u8) bool {
        for (group.excluded_characters.items) |excluded| {
            if (std.mem.eql(u8, excluded, character_name)) {
                return true;
            }
        }
        return false;
    }

    pub fn isCharacterExcluded(self: *HotkeyManager, character_name: []const u8) bool {
        for (self.manually_excluded_characters.items) |excluded| {
            if (std.mem.eql(u8, excluded, character_name)) {
                return true;
            }
        }

        for (self.config.hotkeyGroups.items) |*group| {
            var in_group = false;
            for (group.characters.items) |char_name| {
                if (std.mem.eql(u8, char_name, character_name)) {
                    in_group = true;
                    break;
                }
            }

            if (in_group and isCharacterExcludedInGroup(group, character_name)) {
                return true;
            }
        }
        return false;
    }

    /// Toggle character exclusion from cycling in all groups that contain the character.
    /// Characters that belong to no group fall back to manually_excluded_characters, so
    /// shift-click exclusion still works (and Cycle All Clients still respects it) before
    /// the user has set up any hotkey groups.
    pub fn toggleCharacterExclusion(self: *HotkeyManager, character_name: []const u8) void {
        var found_in_group = false;

        for (self.config.hotkeyGroups.items) |*group| {
            var in_group = false;
            for (group.characters.items) |char_name| {
                if (std.mem.eql(u8, char_name, character_name)) {
                    in_group = true;
                    break;
                }
            }

            if (!in_group) continue;
            found_in_group = true;

            var excluded_index: ?usize = null;
            for (group.excluded_characters.items, 0..) |excluded, i| {
                if (std.mem.eql(u8, excluded, character_name)) {
                    excluded_index = i;
                    break;
                }
            }

            if (excluded_index) |index| {
                const removed = group.excluded_characters.orderedRemove(index);
                self.allocator.free(removed);
                slog.debug("Removed {s} from exclusion list", .{character_name});
            } else {
                const duped = self.allocator.dupe(u8, character_name) catch {
                    slog.err("Failed to allocate memory for excluded character", .{});
                    return;
                };
                group.excluded_characters.append(self.allocator, duped) catch {
                    self.allocator.free(duped);
                    slog.err("Failed to add character to exclusion list", .{});
                    return;
                };
                slog.debug("Added {s} to exclusion list", .{character_name});
            }
        }

        if (!found_in_group) {
            self.toggleManualExclusion(character_name);
        }

        // Reset excluded cycle index when exclusion list changes for predictable behavior
        self.excluded_cycle_index = null;
    }

    /// Toggle a character's membership in manually_excluded_characters (the fallback
    /// exclusion list for characters that don't belong to any hotkey group).
    fn toggleManualExclusion(self: *HotkeyManager, character_name: []const u8) void {
        var excluded_index: ?usize = null;
        for (self.manually_excluded_characters.items, 0..) |excluded, i| {
            if (std.mem.eql(u8, excluded, character_name)) {
                excluded_index = i;
                break;
            }
        }

        if (excluded_index) |index| {
            const removed = self.manually_excluded_characters.orderedRemove(index);
            self.allocator.free(removed);
            slog.debug("Removed {s} from manual exclusion list", .{character_name});
        } else {
            const duped = self.allocator.dupe(u8, character_name) catch {
                slog.err("Failed to allocate memory for manually excluded character", .{});
                return;
            };
            self.manually_excluded_characters.append(self.allocator, duped) catch {
                self.allocator.free(duped);
                slog.err("Failed to add character to manual exclusion list", .{});
                return;
            };
            slog.debug("Added {s} to manual exclusion list", .{character_name});
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

    /// Appends names not already in `seen` to `dest`, marking them seen. Used by
    /// buildExcludedList() to dedupe across multiple exclusion sources.
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

    /// Builds a unified, deduplicated list of all excluded character names, combining
    /// every hotkey group's exclusion list with manually_excluded_characters (the
    /// fallback for characters that belong to no group). Shared by cycleExcluded() and
    /// updateExcludedCycleIndex() so both agree on ordering/membership.
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

        // Try up to num_excluded times to find a running character
        const start_index = self.excluded_cycle_index;
        // null/stale index starts just before the first element (forward) or just after the last (backward).
        const valid_current = if (self.excluded_cycle_index) |ci| (if (ci < num_excluded) ci else null) else null;
        var idx: usize = valid_current orelse (if (forward) num_excluded - 1 else 0);
        var attempts: usize = 0;

        while (attempts < num_excluded) : (attempts += 1) {
            if (forward) {
                idx = (idx + 1) % num_excluded;
            } else {
                idx = if (idx == 0) num_excluded - 1 else idx - 1;
            }

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

        // Restore original index if no characters were found
        self.excluded_cycle_index = start_index;
        slog.warn("No excluded characters are currently running", .{});
    }

    fn handleCycleNotified(self: *HotkeyManager, forward: bool) void {
        slog.info("Cycle notified character hotkey pressed ({s})", .{if (forward) "forward" else "backward"});
        self.cycleNotified(forward);
    }

    /// Cycle to the character whose window most recently sent a notification.
    /// FIFO order: oldest-still-eligible entry first, advancing toward newest,
    /// then wrapping back to oldest (or the reverse, when `forward` is false).
    /// Re-notifying an already-queued character bumps it to the back (see
    /// Painter.trackNotifiedCharacter), so "newest" always means "most recently
    /// (re-)notified". The cursor is the last character name we jumped to (not
    /// a raw index), since the underlying queue mutates between presses
    /// (entries age out, re-notifies bump).
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

        var start_index: usize = if (forward) 0 else num_notified - 1;
        if (self.last_notified_cycle_name) |last_name| {
            for (names.items, 0..) |name, i| {
                if (std.mem.eql(u8, name, last_name)) {
                    start_index = if (forward)
                        (i + 1) % num_notified
                    else if (i == 0)
                        num_notified - 1
                    else
                        i - 1;
                    break;
                }
            }
        }

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
            index = if (forward) (index + 1) % num_notified else if (index == 0) num_notified - 1 else index - 1;
        }

        slog.warn("No recently-notified characters are currently running", .{});
    }

    /// Replace self.last_notified_cycle_name with an owned copy of `name`,
    /// freeing the previous owned copy (if any).
    fn setLastNotifiedCycleName(self: *HotkeyManager, name: []const u8) void {
        const duped = self.allocator.dupe(u8, name) catch |err| {
            slog.err("Failed to remember notified cycle cursor for {s}: {}", .{ name, err });
            return;
        };
        if (self.last_notified_cycle_name) |old| self.allocator.free(old);
        self.last_notified_cycle_name = duped;
    }

    fn handleCycleAllClients(self: *HotkeyManager, forward: bool) void {
        slog.info("Cycle all clients hotkey pressed ({s})", .{if (forward) "forward" else "backward"});
        self.cycleAllClients(forward);
    }

    pub fn handleCycleAllClientsRequest(self: *HotkeyManager, forward: bool) void {
        slog.debug("Protocol handler cycle all clients request ({s})", .{if (forward) "forward" else "backward"});
        self.handleCycleAllClients(forward);
    }

    /// Cycle through every currently logged-in EVE client, regardless of profile,
    /// in the order Scout first discovered them (tracked/launch order). Unlike
    /// cycleGroup/cycleExcluded/cycleNotified, every entry here is guaranteed to be
    /// running (Scout only tracks live windows), so the only reason to skip an entry
    /// is the optional exclusion filter.
    fn cycleAllClients(self: *HotkeyManager, forward: bool) void {
        const windows = self.scout.getWindows();
        const num = windows.len;
        if (num == 0) {
            slog.info("No logged-in clients to cycle through", .{});
            return;
        }

        var start_index: usize = if (forward) 0 else num - 1;
        if (self.last_all_clients_cycle_name) |last_name| {
            for (windows, 0..) |w, i| {
                if (std.mem.eql(u8, w.character_name, last_name)) {
                    start_index = if (forward)
                        (i + 1) % num
                    else if (i == 0)
                        num - 1
                    else
                        i - 1;
                    break;
                }
            }
        }

        const respect_exclusions = self.global_settings.cycleAllClientsRespectExclusions;
        var index = start_index;
        var attempts: usize = 0;
        while (attempts < num) : (attempts += 1) {
            const w = windows[index];

            if (respect_exclusions and self.isCharacterExcluded(w.character_name)) {
                index = if (forward) (index + 1) % num else if (index == 0) num - 1 else index - 1;
                continue;
            }

            slog.info("Cycling {s} to client: {s} ({}/{})", .{ if (forward) "forward" else "backward", w.character_name, index + 1, num });
            input.handleThumbnailClick(w.hwnd);
            self.setLastAllClientsCycleName(w.character_name);
            return;
        }

        slog.warn("No logged-in clients are eligible to cycle to (all excluded)", .{});
    }

    /// Replace self.last_all_clients_cycle_name with an owned copy of `name`,
    /// freeing the previous owned copy (if any).
    fn setLastAllClientsCycleName(self: *HotkeyManager, name: []const u8) void {
        const duped = self.allocator.dupe(u8, name) catch |err| {
            slog.err("Failed to remember all-clients cycle cursor for {s}: {}", .{ name, err });
            return;
        };
        if (self.last_all_clients_cycle_name) |old| self.allocator.free(old);
        self.last_all_clients_cycle_name = duped;
    }

    fn handleCycleNotLoggedIn(self: *HotkeyManager, forward: bool) void {
        slog.info("Cycle not-logged-in hotkey pressed ({s})", .{if (forward) "forward" else "backward"});
        self.cycleNotLoggedIn(forward);
    }

    pub fn handleCycleNotLoggedInRequest(self: *HotkeyManager, forward: bool) void {
        slog.debug("Protocol handler cycle not-logged-in request ({s})", .{if (forward) "forward" else "backward"});
        self.handleCycleNotLoggedIn(forward);
    }

    /// Cycle through EVE client windows that are sitting at the login screen, i.e. still
    /// carry the generic "EVE" window title (see Scout.extractCharacterName). Every such
    /// window shares that same character_name, so - unlike cycleAllClients - the cursor
    /// has to be the HWND we last jumped to rather than a name.
    fn cycleNotLoggedIn(self: *HotkeyManager, forward: bool) void {
        const windows = self.scout.getWindows();

        var candidates: std.ArrayList(win32.HWND) = .empty;
        defer candidates.deinit(self.allocator);
        for (windows) |w| {
            if (std.mem.eql(u8, w.character_name, "EVE")) {
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

        var start_index: usize = if (forward) 0 else num - 1;
        if (self.last_not_logged_in_cycle_hwnd) |last_hwnd| {
            for (candidates.items, 0..) |hwnd, i| {
                if (hwnd == last_hwnd) {
                    start_index = if (forward)
                        (i + 1) % num
                    else if (i == 0)
                        num - 1
                    else
                        i - 1;
                    break;
                }
            }
        }

        const hwnd = candidates.items[start_index];
        slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ if (forward) "forward" else "backward", start_index + 1, num });
        input.handleThumbnailClick(hwnd);
        self.last_not_logged_in_cycle_hwnd = hwnd;
    }

    /// Update currentIndex for hotkey groups when a character is manually focused
    pub fn updateFocusedCharacter(self: *HotkeyManager, character_name: []const u8) void {
        // Verify the character's window actually has focus before updating cycle position
        // This prevents stale updates during rapid cycling
        const character_hwnd = self.scout.getHwndByName(character_name);
        const foreground_hwnd = win32.GetForegroundWindow();

        if (character_hwnd != foreground_hwnd) {
            slog.debug("Ignoring updateFocusedCharacter for {s} - not the foreground window", .{character_name});
            return;
        }

        self.updateExcludedCycleIndex(character_name);

        var found_in_hotkey_group = false;
        for (self.config.hotkeyGroups.items) |*group| {
            for (group.characters.items, 0..) |char_name, index| {
                if (std.mem.eql(u8, char_name, character_name)) {
                    if (group.currentIndex == null or group.currentIndex.? != index) {
                        slog.debug("Updated hotkey group index: {s} now at position {}/{}", .{ character_name, index + 1, group.characters.items.len });
                        group.currentIndex = index;
                    }
                    found_in_hotkey_group = true;
                    break;
                }
            }
        }

        var found_in_quick_group = false;
        for (self.config.quickGroups.items) |*group| {
            for (group.characters.items, 0..) |char_name, index| {
                if (std.mem.eql(u8, char_name, character_name)) {
                    if (group.currentIndex == null or group.currentIndex.? != index) {
                        slog.debug("Updated quick group index: {s} now at position {}/{}", .{ character_name, index + 1, group.characters.items.len });
                        group.currentIndex = index;
                    }
                    found_in_quick_group = true;
                    break;
                }
            }
        }

        // Each group kind resets independently - being in a hotkey group shouldn't
        // block a quick-group reset (or vice versa) when you've left that kind's groups.
        if (self.config.resetGroupIndexOnNonGroupFocus and !found_in_hotkey_group) {
            for (self.config.hotkeyGroups.items) |*group| {
                group.currentIndex = null;
            }
            slog.debug("Reset hotkey group cycle indices - {s} is not in any hotkey group", .{character_name});
        }
        if (self.config.resetGroupIndexOnNonGroupFocus and !found_in_quick_group) {
            for (self.config.quickGroups.items) |*group| {
                group.currentIndex = null;
            }
            slog.debug("Reset quick group cycle indices - {s} is not in any quick group", .{character_name});
        }
    }

    /// Update excluded cycle index when a character is manually focused
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
