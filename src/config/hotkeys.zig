//! The profile's hotkeys: global actions and the cycling groups.
const std = @import("std");
const wire = @import("wire.zig");
const key_list = @import("key_list.zig");

const KeyList = key_list.KeyList;

pub const HotkeysConfig = struct {
    requireEveFocus: bool = false,
    resetGroupIndexOnNonGroupFocus: bool = false,
    allowHotkeyAutoRepeat: bool = false,
    exactHotkeyModifiers: bool = false,
    hotkeyMinimizeAll: KeyList = .empty,
    hotkeyCloseAll: KeyList = .empty,
    hotkeyToggleVisibility: KeyList = .empty,
    hotkeyToggleAutoMinimize: KeyList = .empty,
    hotkeyToggleExclusion: KeyList = .empty,
    hotkeyNextExcluded: KeyList = .empty,
    hotkeyPreviousExcluded: KeyList = .empty,
    hotkeySuspend: KeyList = .empty,
    hotkeyExitApp: KeyList = .empty,
    hotkeyCycleNotified: KeyList = .empty,
    hotkeyPreviousNotified: KeyList = .empty,
    hotkeyMoveToSavedPositions: KeyList = .empty,

    pub const Wire = wire.Wire(HotkeysConfig);
};

/// Only what the profile saves; cycle exclusions and positions live in the hotkey manager (hotkeys/membership.zig, hotkeys/cycling.zig).
pub const HotkeyGroupConfig = struct {
    name: []const u8 = "",
    characters: std.ArrayList([]const u8) = .empty,
    forwardKey: KeyList = .empty,
    backwardKey: KeyList = .empty,
    /// Hover a thumbnail and press this to toggle that character in or out of the group.
    assignKey: KeyList = .empty,
    /// When true, membership is runtime-only: assign-key edits are never written back to the profile.
    temporaryMembership: bool = false,
    /// Draws the group's name on its members' thumbnails.
    showBadge: bool = false,
    /// Appends queued not-logged-in clients to the end of this group's cycle.
    includeNotLoggedIn: bool = false,
    /// Cycling stops at the first/last member instead of wrapping, refocusing it if focus has moved away.
    stopAtEnds: bool = false,
    /// Identifies this group to the config dialog while its name and position in the list change; 0 until assigned (see config/patch.zig).
    id: u32 = 0,

    pub const runtime_fields = .{"id"};

    pub const Wire = wire.Wire(HotkeyGroupConfig);

    /// A temporary group's members exist only while the app runs, so it's saved without them.
    pub fn toWire(self: HotkeyGroupConfig) Wire {
        var saved = wire.toWire(HotkeyGroupConfig, self);
        if (self.temporaryMembership) saved.characters = &.{};
        return saved;
    }
};
