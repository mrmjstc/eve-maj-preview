//! The profile's hotkeys: single-key actions and the cycling groups.
const std = @import("std");
const wire = @import("wire.zig");

pub const HotkeysConfig = struct {
    requireEveFocus: bool = false,
    resetGroupIndexOnNonGroupFocus: bool = false,
    allowHotkeyAutoRepeat: bool = false,
    exactHotkeyModifiers: bool = false,
    hotkeyMinimizeAll: ?u32 = null,
    hotkeyCloseAll: ?u32 = null,
    hotkeyToggleVisibility: ?u32 = null,
    hotkeyToggleAutoMinimize: ?u32 = null,
    hotkeyToggleExclusion: ?u32 = null,
    hotkeyNextExcluded: ?u32 = null,
    hotkeyPreviousExcluded: ?u32 = null,
    hotkeySuspend: ?u32 = null,
    hotkeyCycleNotified: ?u32 = null,
    hotkeyPreviousNotified: ?u32 = null,
    hotkeyMoveToSavedPositions: ?u32 = null,

    pub const Wire = wire.Wire(HotkeysConfig);
};

/// Only what the profile saves; cycle exclusions and positions live in the hotkey manager (hotkeys/membership.zig, hotkeys/cycling.zig).
pub const HotkeyGroupConfig = struct {
    name: []const u8 = "",
    characters: std.ArrayList([]const u8) = .empty,
    forwardKey: ?u32 = null,
    backwardKey: ?u32 = null,
    /// Hover a thumbnail and press this to toggle that character in or out of the group.
    assignKey: ?u32 = null,
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
