//! An opt-in JSON snapshot of what the app shows, rewritten whenever it changes, for end-to-end tests to read.
const std = @import("std");
const state = @import("../thumbnail/state.zig");
const atomic_file = @import("../util/atomic_file.zig");
const log = @import("../log.zig");

const VisibilityState = state.VisibilityState;
const slog = log.Scoped("state_file");

/// Unset in normal use; tools/ui_tests sets it to an absolute path.
pub const ENVIRONMENT_VARIABLE = "EVE_MAJ_STATE_FILE";

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

test "format writes window handles as numbers and a missing active window as null" {
    const thumbnails = [_]Snapshot.Thumbnail{.{ .character_name = "Alpha Pilot", .hwnd = 10, .source_hwnd = 20, .visibility = .visible, .is_hidden_by_character = false, .group_badge = "" }};
    const json = try format(testing.allocator, .{ .profile = "default.json", .active_hwnd = null, .are_hotkeys_suspended = false, .excluded_characters = &.{}, .groups = &.{}, .thumbnails = &thumbnails });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"profile":"default.json","active_hwnd":null,"are_hotkeys_suspended":false,"excluded_characters":[],"groups":[],"thumbnails":[{"character_name":"Alpha Pilot","hwnd":10,"source_hwnd":20,"visibility":"visible","is_hidden_by_character":false,"group_badge":""}]}
    , json);
}

test "format lists each group's members under its name" {
    const members = [_][]const u8{ "Alpha Pilot", "Bravo Pilot" };
    const groups = [_]Snapshot.Group{.{ .name = "Fleet", .members = &members }};
    const json = try format(testing.allocator, .{ .profile = "default.json", .active_hwnd = 5, .are_hotkeys_suspended = true, .excluded_characters = &.{"Bravo Pilot"}, .groups = &groups, .thumbnails = &.{} });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"profile":"default.json","active_hwnd":5,"are_hotkeys_suspended":true,"excluded_characters":["Bravo Pilot"],"groups":[{"name":"Fleet","members":["Alpha Pilot","Bravo Pilot"]}],"thumbnails":[]}
    , json);
}

test "StateFile stays off when the variable is unset or empty" {
    try testing.expect(StateFile.init(null) == null);
    try testing.expect(StateFile.init("") == null);
}
