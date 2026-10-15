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
    hotkeyCloseActive: KeyList = .empty,
    hotkeyToggleVisibility: KeyList = .empty,
    hotkeyToggleAutoMinimize: KeyList = .empty,
    hotkeyToggleAlertMute: KeyList = .empty,
    hotkeyToggleExclusion: KeyList = .empty,
    hotkeyNextExcluded: KeyList = .empty,
    hotkeyPreviousExcluded: KeyList = .empty,
    hotkeySuspend: KeyList = .empty,
    hotkeyExitApp: KeyList = .empty,
    hotkeyCycleNotified: KeyList = .empty,
    hotkeyPreviousNotified: KeyList = .empty,
    hotkeyMoveToSavedPositions: KeyList = .empty,
    hotkeyToggleDragging: KeyList = .empty,
    hotkeyToggleTravelMode: KeyList = .empty,
    hotkeyToggleNotificationHistory: KeyList = .empty,
    hotkeyClearNotificationHistory: KeyList = .empty,

    pub const Wire = wire.Wire(HotkeysConfig);
};

/// Only what the profile saves; cycle state lives in hotkeys/membership.zig and hotkeys/cycling.zig.
pub const HotkeyGroupConfig = struct {
    name: []const u8 = "",
    characters: std.ArrayList([]const u8) = .empty,
    forwardKey: KeyList = .empty,
    backwardKey: KeyList = .empty,
    /// Hover a thumbnail and press this to toggle that character in or out of the group.
    assignKey: KeyList = .empty,
    minimizeKey: KeyList = .empty,
    /// Closes every running client in the group, ignoring the Close All exclusions.
    closeKey: KeyList = .empty,
    /// When true, membership is runtime-only: assign-key edits are never written back to the profile.
    temporaryMembership: bool = false,
    /// Draws the group's name on its members' thumbnails.
    showBadge: bool = false,
    /// Appends queued not-logged-in clients to the end of this group's cycle.
    includeNotLoggedIn: bool = false,
    /// Cycling stops at the first/last member instead of wrapping, refocusing it if focus has moved away.
    stopAtEnds: bool = false,
    /// The dialog's handle across renames and reorders; 0 until assigned (see config/patch.zig).
    id: u32 = 0,

    pub const runtime_fields = .{"id"};

    /// Fits "Hotkey Group " and any usize.
    pub const DISPLAY_NAME_SIZE = 40;

    pub const Wire = wire.Wire(HotkeyGroupConfig);

    /// Its name, or English "Hotkey Group N" counting from 1 when unnamed; borrows from self or `buffer`.
    pub fn displayName(self: HotkeyGroupConfig, buffer: *[DISPLAY_NAME_SIZE]u8, index: usize) []const u8 {
        if (self.name.len > 0) return self.name;
        return std.mem.print(buffer, "Hotkey Group {}", .{index + 1}) catch unreachable;
    }

    /// A temporary group's members exist only while the app runs, so it's saved without them.
    pub fn toWire(self: HotkeyGroupConfig) Wire {
        var saved = wire.toWire(HotkeyGroupConfig, self);
        if (self.temporaryMembership) saved.characters = &.{};
        return saved;
    }
};

const testing = std.testing;

test "displayName numbers an unnamed group from 1 and keeps a given name" {
    var buffer: [HotkeyGroupConfig.DISPLAY_NAME_SIZE]u8 = undefined;
    try testing.expectEqualStrings("Hotkey Group 3", (HotkeyGroupConfig{}).displayName(&buffer, 2));
    try testing.expectEqualStrings("Miners", (HotkeyGroupConfig{ .name = "Miners" }).displayName(&buffer, 2));
}
