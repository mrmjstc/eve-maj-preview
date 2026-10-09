//! Hotkey IDs, the actions they trigger, and the table of global actions.
const std = @import("std");
const protocol = @import("../protocol.zig");

// ID bands: 0 group cycle (2 per combo), 1000 global, 2000 character, 3000 profile, 4000 group assign, 5000 app, 6000 URL.
pub const HOTKEY_ID_CYCLE_GROUP_BASE: c_int = 0;

/// IDs in the group cycle band, before it runs into the global band.
pub const CYCLE_GROUP_SLOT_COUNT: usize = 1000;

pub const HOTKEY_ID_GLOBAL_ACTION_BASE: c_int = 1000;

pub const HOTKEY_ID_PER_CHARACTER_BASE: c_int = 2000;

pub const HOTKEY_ID_PROFILE_SWITCH_BASE: c_int = 3000;

pub const HOTKEY_ID_ASSIGN_GROUP_BASE: c_int = 4000;

pub const HOTKEY_ID_APP_HOTKEY_BASE: c_int = 5000;

pub const HOTKEY_ID_URL_HOTKEY_BASE: c_int = 6000;

pub const GLOBAL_BINDINGS = [_]GlobalBinding{
    .{ .action = .minimize_all, .protocol = .minimize_all, .field = "hotkeyMinimizeAll", .description = "minimize all clients" },
    .{ .action = .close_all, .protocol = .close_all, .field = "hotkeyCloseAll", .description = "close all clients" },
    .{ .action = .toggle_visibility, .protocol = .toggle_visibility, .field = "hotkeyToggleVisibility", .description = "toggle thumbnails visibility" },
    .{ .action = .next_profile, .protocol = .next_profile, .field = "hotkeyNextProfile", .in_global_settings = true, .description = "cycle to next profile" },
    .{ .action = .previous_profile, .protocol = .previous_profile, .field = "hotkeyPreviousProfile", .in_global_settings = true, .description = "cycle to previous profile" },
    .{ .action = .toggle_exclusion, .protocol = .toggle_exclusion, .field = "hotkeyToggleExclusion", .description = "toggle character exclusion from cycling" },
    .{ .action = .next_excluded, .protocol = .next_excluded, .field = "hotkeyNextExcluded", .description = "cycle to next excluded character" },
    .{ .action = .previous_excluded, .protocol = .previous_excluded, .field = "hotkeyPreviousExcluded", .description = "cycle to previous excluded character" },
    SUSPEND_BINDING,
    .{ .action = .toggle_auto_minimize, .protocol = .toggle_auto_minimize, .field = "hotkeyToggleAutoMinimize", .description = "toggle auto-minimize mode" },
    .{ .action = .toggle_alert_mute, .protocol = .toggle_alert_mute, .field = "hotkeyToggleAlertMute", .description = "mute/unmute TTS and sound alerts" },
    .{ .action = .cycle_notified, .protocol = .cycle_notified, .field = "hotkeyCycleNotified", .description = "cycle to most recently notified character" },
    .{ .action = .previous_notified, .protocol = .previous_notified, .field = "hotkeyPreviousNotified", .description = "cycle backward through notified characters" },
    .{ .action = .next_all_clients, .protocol = .next_all_clients, .field = "hotkeyCycleAllClientsForward", .in_global_settings = true, .description = "cycle forward through all logged-in clients" },
    .{ .action = .previous_all_clients, .protocol = .previous_all_clients, .field = "hotkeyCycleAllClientsBackward", .in_global_settings = true, .description = "cycle backward through all logged-in clients" },
    .{ .action = .next_not_logged_in, .protocol = .next_not_logged_in, .field = "hotkeyCycleNotLoggedInForward", .in_global_settings = true, .description = "cycle forward through not-logged-in clients" },
    .{ .action = .previous_not_logged_in, .protocol = .previous_not_logged_in, .field = "hotkeyCycleNotLoggedInBackward", .in_global_settings = true, .description = "cycle backward through not-logged-in clients" },
    .{ .action = .move_to_saved_positions, .protocol = .move_to_saved_positions, .field = "hotkeyMoveToSavedPositions", .description = "move all clients to saved positions" },
    .{ .action = .return_to_last_app, .protocol = .return_to_last_app, .field = "hotkeyReturnToLastApp", .in_global_settings = true, .description = "return focus to the last non-EVE app" },
    .{ .action = .next_app, .protocol = .next_app, .field = "hotkeyCycleAppsForward", .in_global_settings = true, .description = "cycle forward through the app hotkeys' running apps" },
    .{ .action = .previous_app, .protocol = .previous_app, .field = "hotkeyCycleAppsBackward", .in_global_settings = true, .description = "cycle backward through the app hotkeys' running apps" },
    .{ .action = .exit_app, .protocol = .exit_app, .field = "hotkeyExitApp", .description = "exit the application" },
    .{ .action = .close_active, .protocol = .close_active, .field = "hotkeyCloseActive", .description = "close the focused client" },
};

/// Also re-registered on its own while hotkeys are suspended, so it can resume them.
pub const SUSPEND_BINDING = GlobalBinding{ .action = .suspend_hotkeys, .protocol = .suspend_hotkeys, .field = "hotkeySuspend", .description = "suspend/resume all hotkeys" };

/// Characters sharing one per-character hotkey; HotkeyManager.unregisterAll frees the owned index list.
pub const CharacterGroup = struct {
    character_indices: []const usize,
    current_index: ?usize = null,
};

/// Hotkey groups sharing one cycle combo, cycled as one list; HotkeyManager.unregisterAll frees the owned index list.
pub const GroupChain = struct {
    /// In hotkeyGroups order.
    group_indices: []const usize,
    forward: bool,
};

pub const HotkeyAction = union(enum) {
    cycle_group: GroupChain,
    activate_character: CharacterGroup,
    assign_group: struct {
        group_index: usize,
    },
    minimize_all: void,
    close_all: void,
    toggle_visibility: void,
    next_profile: void,
    previous_profile: void,
    switch_to_profile: struct {
        profile_index: usize,
    },
    toggle_exclusion: void,
    next_excluded: void,
    previous_excluded: void,
    suspend_hotkeys: void,
    toggle_auto_minimize: void,
    toggle_alert_mute: void,
    cycle_notified: void,
    previous_notified: void,
    next_all_clients: void,
    previous_all_clients: void,
    next_not_logged_in: void,
    previous_not_logged_in: void,
    move_to_saved_positions: void,
    return_to_last_app: void,
    next_app: void,
    previous_app: void,
    exit_app: void,
    close_active: void,
    activate_app: struct {
        app_index: usize,
    },
    open_url: struct {
        url_index: usize,
    },
};

pub const ActionTag = std.meta.Tag(HotkeyAction);

/// A global action: which config field binds it, and the protocol URL action that also triggers it.
pub const GlobalBinding = struct {
    action: ActionTag,
    protocol: protocol.GlobalAction,
    /// Name of the KeyList field, on GlobalConfig when `in_global_settings`, else on the profile's Config.hotkeys.
    field: []const u8,
    in_global_settings: bool = false,
    description: []const u8,
};

pub fn bandId(base: c_int, index: usize) c_int {
    return base + @as(c_int, @intCast(index));
}

/// Global actions carry no payload, so the tag alone identifies both the action and its hotkey ID.
pub fn globalId(action: ActionTag) c_int {
    return bandId(HOTKEY_ID_GLOBAL_ACTION_BASE, @backingInt(action));
}

pub fn actionFor(comptime action: ActionTag) HotkeyAction {
    return @unionInit(HotkeyAction, @tagName(action), {});
}

pub fn fromProtocol(action: protocol.GlobalAction) HotkeyAction {
    inline for (GLOBAL_BINDINGS) |binding| {
        if (binding.protocol == action) return actionFor(binding.action);
    }
    unreachable;
}

comptime {
    for (std.enums.values(protocol.GlobalAction)) |tag| {
        var matches: usize = 0;
        for (GLOBAL_BINDINGS) |binding| {
            if (binding.protocol == tag) matches += 1;
        }
        if (matches != 1) @compileError("protocol.GlobalAction." ++ @tagName(tag) ++ " must map to exactly one global binding");
    }
}

const testing = std.testing;

test "fromProtocol maps each URL action to the hotkey action of the same name" {
    for (std.enums.values(protocol.GlobalAction)) |action| {
        try testing.expectEqualStrings(@tagName(action), @tagName(std.meta.activeTag(fromProtocol(action))));
    }
}

test "global hotkey IDs stay inside their band" {
    for (GLOBAL_BINDINGS) |binding| {
        const id = globalId(binding.action);
        try testing.expect(id >= HOTKEY_ID_GLOBAL_ACTION_BASE and id < HOTKEY_ID_PER_CHARACTER_BASE);
    }
}

test "bandId offsets from the band's base" {
    try testing.expectEqual(@as(c_int, 3002), bandId(HOTKEY_ID_PROFILE_SWITCH_BASE, 2));
    try testing.expectEqual(HOTKEY_ID_CYCLE_GROUP_BASE, bandId(HOTKEY_ID_CYCLE_GROUP_BASE, 0));
}
