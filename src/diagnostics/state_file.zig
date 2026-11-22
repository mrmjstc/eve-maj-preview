//! An opt-in JSON snapshot of what the app shows, rewritten whenever it changes, for end-to-end tests to read.
const std = @import("std");
const state = @import("../thumbnail/state.zig");
const notification = @import("../notifications/notification.zig");
const types = @import("../config/types.zig");
const atomic_file = @import("../util/atomic_file.zig");
const log = @import("../log.zig");

const VisibilityState = state.VisibilityState;
const NotificationType = notification.NotificationType;
const slog = log.Scoped("state_file");

/// Unset in normal use; tools/ui_tests sets it to an absolute path.
pub const ENVIRONMENT_VARIABLE = "EVE_MAJ_STATE_FILE";
/// Newest first; enough for a test to find what it just caused.
pub const HISTORY_LIMIT = 50;

/// Window handles are plain integers, so the reader can match them against its own window list.
pub const Snapshot = struct {
    /// Borrows from the profile store.
    profile: []const u8,
    active_hwnd: ?usize,
    are_hotkeys_suspended: bool,
    /// Borrows from the cycle exclusions.
    excluded_characters: []const []const u8,
    groups: []const Group,
    thumbnails: []const Thumbnail,
    clients: []const Client,
    are_alerts_muted: bool,
    /// Since start-up, unmuted only.
    sounds_played: u32,
    /// Since start-up, unmuted only.
    speeches_started: u32,
    /// At most HISTORY_LIMIT, newest first.
    history: []const HistoryEntry,
    /// At most HISTORY_LIMIT, newest first.
    intel_history: []const HistoryEntry,
    /// Those with a window.
    panels: []const Panel,

    pub const Client = struct {
        /// Borrows from the roster.
        character_name: []const u8,
        hwnd: usize,
        /// Borrows from the roster; empty while unknown.
        system_name: []const u8,
        alerts: []const Alert,
        incoming_dps: ?f32,
        outgoing_dps: ?f32,
        mining_rate: ?f32,
        mining_isk_rate: ?f32,
        bounty_isk_rate: ?f32,
    };

    pub const Alert = struct {
        notification_type: NotificationType,
        /// Borrows from the client's alert stack.
        text: []const u8,
        shows_text: bool,
        shows_border: bool,
        flashes_border: bool,
        /// ARGB; null uses the thumbnail's own.
        border_color: ?u32,
        /// ARGB; null uses the alert text default.
        text_color: ?u32,
    };

    pub const HistoryEntry = struct {
        notification_type: NotificationType,
        /// Borrows from the history entry.
        character_name: []const u8,
        /// Borrows from the history entry.
        text: []const u8,
    };

    pub const Group = struct {
        /// Borrows from the live profile.
        name: []const u8,
        /// Borrows from the live profile, so it includes temporary members.
        members: []const []const u8,
    };

    pub const Thumbnail = struct {
        /// Borrows from the thumbnail.
        character_name: []const u8,
        hwnd: usize,
        source_hwnd: usize,
        visibility: VisibilityState,
        is_hidden_by_character: bool,
        /// Borrows from the thumbnail; empty when it shows no badge.
        group_badge: []const u8,
        /// Null before its first render.
        overlay: ?Overlay,
    };

    /// What the thumbnail's last render drew, in overlay pixels.
    pub const Overlay = struct {
        width: i32,
        height: i32,
        /// The overlay texts' alpha.
        text_alpha: u8,
        shows_border: bool,
        border_width: u8,
        border_color: u32,
        border_style: types.BorderStyle,
        shows_exclusion: bool,
        exclusion_style: types.ExclusionOverlayStyle,
        exclusion_color: u32,
        texts: []const Text,
        /// The alert block's background; null while no alert text shows.
        notifications: ?Box,
        notifications_bg_color: u32,
        /// The newest alert line's colour; 0 while no alert text shows.
        notification_color: u32,
        /// Null while the plain system name shows instead.
        connection_map: ?Box,
    };

    pub const Text = struct {
        /// thumbnail/overlay.zig's Element tag name.
        element: []const u8,
        /// Borrows from App's overlay recorder.
        text: []const u8,
        box: Box,
        color: u32,
        bg_color: u32,
    };

    pub const Box = struct {
        left: i32,
        top: i32,
        width: usize,
        height: usize,
    };

    pub const Panel = struct {
        kind: PanelKind,
        hwnd: usize,
        /// What its last render drew, in drawing order.
        texts: []const PanelText,
    };

    pub const PanelKind = enum { client_list, history, intel, map };

    pub const PanelText = struct {
        /// Borrows from the panel's record.
        text: []const u8,
        /// In panel pixels.
        left: i32,
        top: i32,
        color: u32,
    };
};

pub const StateFile = struct {
    /// Borrows from the process environment.
    path: []const u8,
    /// Owned; freed in deinit.
    last_written: []const u8 = "",

    /// `path`: ENVIRONMENT_VARIABLE's value; null when it's unset or empty.
    pub fn init(path: ?[]const u8) ?StateFile {
        const value = path orelse return null;
        if (value.len == 0) return null;
        slog.info("Writing app state to '{s}'", .{value});
        return .{ .path = value };
    }

    pub fn deinit(self: *StateFile, allocator: std.mem.Allocator) void {
        allocator.free(self.last_written);
        self.last_written = "";
    }

    /// Skips the write when nothing changed since the last one.
    pub fn publish(self: *StateFile, allocator: std.mem.Allocator, io: std.Io, snapshot: Snapshot) void {
        const json = format(allocator, snapshot) catch |err| {
            slog.warn("Failed to format the app state: {}", .{err});
            return;
        };
        if (std.mem.eql(u8, json, self.last_written)) {
            allocator.free(json);
            return;
        }
        // atomic_file.write logs its own failures.
        atomic_file.write(allocator, io, self.path, json) catch {
            allocator.free(json);
            return;
        };
        allocator.free(self.last_written);
        self.last_written = json;
    }
};

/// Caller owns the result.
pub fn format(allocator: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, snapshot, .{});
}

const testing = std.testing;

fn emptySnapshot() Snapshot {
    return .{ .profile = "default.json", .active_hwnd = null, .are_hotkeys_suspended = false, .excluded_characters = &.{}, .groups = &.{}, .thumbnails = &.{}, .clients = &.{}, .are_alerts_muted = false, .sounds_played = 0, .speeches_started = 0, .history = &.{}, .intel_history = &.{}, .panels = &.{} };
}

test "format writes window handles as numbers and a missing active window as null" {
    const thumbnails = [_]Snapshot.Thumbnail{.{ .character_name = "Alpha Pilot", .hwnd = 10, .source_hwnd = 20, .visibility = .visible, .is_hidden_by_character = false, .group_badge = "", .overlay = null }};
    var snapshot = emptySnapshot();
    snapshot.thumbnails = &thumbnails;
    const json = try format(testing.allocator, snapshot);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"active_hwnd\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"thumbnails":[{"character_name":"Alpha Pilot","hwnd":10,"source_hwnd":20,"visibility":"visible","is_hidden_by_character":false,"group_badge":"","overlay":null}]
    ) != null);
}

test "format lists each group's members under its name" {
    const members = [_][]const u8{ "Alpha Pilot", "Bravo Pilot" };
    const groups = [_]Snapshot.Group{.{ .name = "Fleet", .members = &members }};
    var snapshot = emptySnapshot();
    snapshot.groups = &groups;
    const json = try format(testing.allocator, snapshot);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"groups":[{"name":"Fleet","members":["Alpha Pilot","Bravo Pilot"]}]
    ) != null);
}

test "format names alert types and leaves rates not yet measured as null" {
    const alerts = [_]Snapshot.Alert{.{ .notification_type = .CargoFull, .text = "Cargo full", .shows_text = true, .shows_border = true, .flashes_border = false, .border_color = null, .text_color = null }};
    const clients = [_]Snapshot.Client{.{ .character_name = "Alpha Pilot", .hwnd = 20, .system_name = "Jita", .alerts = &alerts, .incoming_dps = null, .outgoing_dps = 12.5, .mining_rate = null, .mining_isk_rate = null, .bounty_isk_rate = null }};
    var snapshot = emptySnapshot();
    snapshot.clients = &clients;
    const json = try format(testing.allocator, snapshot);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"alerts":[{"notification_type":"CargoFull","text":"Cargo full","shows_text":true,"shows_border":true,"flashes_border":false,"border_color":null,"text_color":null}],"incoming_dps":null,"outgoing_dps":12.5
    ) != null);
}

test "format names each panel's kind and lists its texts in order" {
    const texts = [_]Snapshot.PanelText{ .{ .text = "Client List", .left = 30, .top = 6, .color = 0xFFFFFFFF }, .{ .text = "Jita", .left = 200, .top = 40, .color = 0xFF8B8F96 } };
    const panels = [_]Snapshot.Panel{.{ .kind = .client_list, .hwnd = 30, .texts = &texts }};
    var snapshot = emptySnapshot();
    snapshot.panels = &panels;
    const json = try format(testing.allocator, snapshot);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"panels":[{"kind":"client_list","hwnd":30,"texts":[{"text":"Client List","left":30,"top":6,"color":4294967295},{"text":"Jita","left":200,"top":40,"color":4287336342}]}]
    ) != null);
}

test "StateFile stays off when the variable is unset or empty" {
    try testing.expect(StateFile.init(null) == null);
    try testing.expect(StateFile.init("") == null);
}
