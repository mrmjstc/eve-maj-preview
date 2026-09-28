const std = @import("std");
const protocol = @import("../protocol.zig");

// Hotkey IDs are banded to avoid collisions: 0-999 groups (3 per group), 1000s global, 2000s per-character, 3000s profile switch, 5000s app hotkeys, 6000s URL hotkeys.
pub const HOTKEY_ID_CYCLE_GROUP_BASE: c_int = 0;
pub const HOTKEY_ID_GLOBAL_ACTION_BASE: c_int = 1000;
pub const HOTKEY_ID_PER_CHARACTER_BASE: c_int = 2000;
pub const HOTKEY_ID_PROFILE_SWITCH_BASE: c_int = 3000;
pub const HOTKEY_ID_APP_HOTKEY_BASE: c_int = 5000;
pub const HOTKEY_ID_URL_HOTKEY_BASE: c_int = 6000;

pub fn bandId(base: c_int, index: usize) c_int {
    return base + @as(c_int, @intCast(index));
}

/// Characters sharing one per-character hotkey; HotkeyManager.unregisterAll frees the owned index list.
pub const CharacterGroup = struct {
    character_indices: []const usize,
    current_index: ?usize = null,
};

pub const HotkeyAction = union(enum) {
    CycleGroup: struct {
        group_index: usize,
        forward: bool,
    },
    ActivateCharacter: CharacterGroup,
    AssignGroup: struct {
        group_index: usize,
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
    ReturnToLastApp: void,
    ActivateApp: struct {
        app_index: usize,
    },
    OpenUrl: struct {
        url_index: usize,
    },
};

pub const ActionTag = std.meta.Tag(HotkeyAction);

/// A single-key global action: which config field binds it, and the protocol URL action that also triggers it.
pub const GlobalBinding = struct {
    action: ActionTag,
    protocol: protocol.GlobalAction,
    /// Name of the ?u32 key field, on GlobalConfig when `in_global_settings`, else on the profile's Config.hotkeys.
    field: []const u8,
    in_global_settings: bool = false,
    description: []const u8,
};

/// Global actions carry no payload, so the tag alone identifies both the action and its hotkey ID.
pub fn globalId(action: ActionTag) c_int {
    return bandId(HOTKEY_ID_GLOBAL_ACTION_BASE, @intFromEnum(action));
}

pub fn actionFor(comptime action: ActionTag) HotkeyAction {
    return @unionInit(HotkeyAction, @tagName(action), {});
}

pub fn fromProtocol(action: protocol.GlobalAction) HotkeyAction {
    inline for (global_bindings) |binding| {
        if (binding.protocol == action) return actionFor(binding.action);
    }
    unreachable;
}

comptime {
    for (std.enums.values(protocol.GlobalAction)) |tag| {
        var matches: usize = 0;
        for (global_bindings) |binding| {
            if (binding.protocol == tag) matches += 1;
        }
        if (matches != 1) @compileError("protocol.GlobalAction." ++ @tagName(tag) ++ " must map to exactly one global binding");
    }
}

pub const global_bindings = [_]GlobalBinding{
    .{ .action = .MinimizeAll, .protocol = .minimize_all, .field = "hotkeyMinimizeAll", .description = "minimize all clients" },
    .{ .action = .CloseAll, .protocol = .close_all, .field = "hotkeyCloseAll", .description = "close all clients" },
    .{ .action = .ToggleVisibility, .protocol = .toggle_visibility, .field = "hotkeyToggleVisibility", .description = "toggle thumbnails visibility" },
    .{ .action = .NextProfile, .protocol = .next_profile, .field = "hotkeyNextProfile", .in_global_settings = true, .description = "cycle to next profile" },
    .{ .action = .PreviousProfile, .protocol = .previous_profile, .field = "hotkeyPreviousProfile", .in_global_settings = true, .description = "cycle to previous profile" },
    .{ .action = .ToggleExclusion, .protocol = .toggle_exclusion, .field = "hotkeyToggleExclusion", .description = "toggle character exclusion from cycling" },
    .{ .action = .NextExcluded, .protocol = .next_excluded, .field = "hotkeyNextExcluded", .description = "cycle to next excluded character" },
    .{ .action = .PreviousExcluded, .protocol = .previous_excluded, .field = "hotkeyPreviousExcluded", .description = "cycle to previous excluded character" },
    suspend_binding,
    .{ .action = .ToggleAutoMinimize, .protocol = .toggle_auto_minimize, .field = "hotkeyToggleAutoMinimize", .description = "toggle auto-minimize mode" },
    .{ .action = .CycleNotified, .protocol = .cycle_notified, .field = "hotkeyCycleNotified", .description = "cycle to most recently notified character" },
    .{ .action = .PreviousNotified, .protocol = .previous_notified, .field = "hotkeyPreviousNotified", .description = "cycle backward through notified characters" },
    .{ .action = .NextAllClients, .protocol = .next_all_clients, .field = "hotkeyCycleAllClientsForward", .in_global_settings = true, .description = "cycle forward through all logged-in clients" },
    .{ .action = .PreviousAllClients, .protocol = .previous_all_clients, .field = "hotkeyCycleAllClientsBackward", .in_global_settings = true, .description = "cycle backward through all logged-in clients" },
    .{ .action = .NextNotLoggedIn, .protocol = .next_not_logged_in, .field = "hotkeyCycleNotLoggedInForward", .in_global_settings = true, .description = "cycle forward through not-logged-in clients" },
    .{ .action = .PreviousNotLoggedIn, .protocol = .previous_not_logged_in, .field = "hotkeyCycleNotLoggedInBackward", .in_global_settings = true, .description = "cycle backward through not-logged-in clients" },
    .{ .action = .MoveToSavedPositions, .protocol = .move_to_saved_positions, .field = "hotkeyMoveToSavedPositions", .description = "move all clients to saved positions" },
    .{ .action = .ReturnToLastApp, .protocol = .return_to_last_app, .field = "hotkeyReturnToLastApp", .in_global_settings = true, .description = "return focus to the last non-EVE app" },
};

/// Also re-registered on its own while hotkeys are suspended, so it can resume them.
pub const suspend_binding = GlobalBinding{ .action = .SuspendHotkeys, .protocol = .suspend_hotkeys, .field = "hotkeySuspend", .description = "suspend/resume all hotkeys" };
