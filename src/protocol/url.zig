//! The evemajpreview:// URL grammar and the commands it names; no I/O.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.Scoped("protocol");

pub const SCHEME = "evemajpreview://";
/// Sent by any second launch so the running instance opens its configuration window.
pub const OPEN_CONFIG_URL = SCHEME ++ "config";

/// hotkeys/bindings.zig's GLOBAL_BINDINGS maps each to its HotkeyAction.
pub const GlobalAction = enum {
    minimize_all,
    close_all,
    toggle_visibility,
    next_profile,
    previous_profile,
    toggle_exclusion,
    next_excluded,
    previous_excluded,
    suspend_hotkeys,
    toggle_auto_minimize,
    toggle_alert_mute,
    cycle_notified,
    previous_notified,
    next_all_clients,
    previous_all_clients,
    next_not_logged_in,
    previous_not_logged_in,
    move_to_saved_positions,
    return_to_last_app,
    next_app,
    previous_app,
    exit_app,
    close_active,
    toggle_dragging,
    toggle_travel_mode,
    toggle_notification_history,
    clear_notification_history,
};

pub const GroupAction = enum { next, previous, assign, minimize, close };

pub const Command = union(enum) {
    /// Owned; freed in deinit.
    switch_character: []const u8,
    /// Owned; freed in deinit.
    profile: []const u8,
    hotkey: GlobalAction,
    group: struct {
        action: GroupAction,
        /// Owned; freed in deinit.
        name: []const u8,
    },
    open_config: void,

    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        switch (self) {
            .switch_character, .profile => |name| allocator.free(name),
            .group => |group| allocator.free(group.name),
            .hotkey, .open_config => {},
        }
    }
};

/// `evemajpreview://action/params`; logs each failure, and the result is freed with Command.deinit.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Command {
    if (!std.mem.startsWith(u8, text, SCHEME)) {
        slog.err("Failed to parse protocol URL '{s}': it doesn't start with '{s}'", .{ text, SCHEME });
        return error.InvalidProtocol;
    }

    var segments = std.mem.splitScalar(u8, text[SCHEME.len..], '/');
    const action = segments.first();

    if (std.mem.eql(u8, action, "switch")) {
        return .{ .switch_character = try decodedSegment(allocator, &segments, "character name") };
    } else if (std.mem.eql(u8, action, "profile")) {
        return .{ .profile = try decodedSegment(allocator, &segments, "profile name") };
    } else if (std.mem.eql(u8, action, "hotkey")) {
        return .{ .hotkey = try enumSegment(GlobalAction, &segments, "hotkey action") };
    } else if (std.mem.eql(u8, action, "group")) {
        const group_action = try enumSegment(GroupAction, &segments, "group action");
        return .{ .group = .{ .action = group_action, .name = try decodedSegment(allocator, &segments, "group name") } };
    } else if (std.mem.eql(u8, action, "config")) {
        return .open_config;
    } else {
        slog.err("Failed to parse protocol URL: unknown action '{s}'", .{action});
        return error.InvalidAction;
    }
}

/// The next segment, decoded and owned; logs a missing or empty one.
fn decodedSegment(allocator: std.mem.Allocator, segments: *std.mem.SplitIterator(u8, .scalar), comptime what: []const u8) ![]const u8 {
    const encoded = segments.next() orelse "";
    if (encoded.len == 0) {
        slog.err("Failed to parse protocol URL: no " ++ what, .{});
        return error.MissingParameter;
    }
    return urlDecode(allocator, encoded) catch |err| {
        slog.err("Failed to decode the " ++ what ++ " '{s}': {}", .{ encoded, err });
        return err;
    };
}

/// The next segment as a tag of `Enum`; logs a missing or unknown one.
fn enumSegment(comptime Enum: type, segments: *std.mem.SplitIterator(u8, .scalar), comptime what: []const u8) !Enum {
    const name = segments.next() orelse "";
    if (name.len == 0) {
        slog.err("Failed to parse protocol URL: no " ++ what, .{});
        return error.MissingParameter;
    }
    return std.meta.stringToEnum(Enum, name) orelse {
        slog.err("Failed to parse protocol URL: unknown " ++ what ++ " '{s}'", .{name});
        return error.InvalidParameter;
    };
}

/// Percent escapes only: a path keeps '+' as written, unlike a web form.
fn urlDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            if (hexDigit(encoded[i + 1])) |high| {
                if (hexDigit(encoded[i + 2])) |low| {
                    try result.append(allocator, high * 16 + low);
                    i += 3;
                    continue;
                }
            }
        }
        try result.append(allocator, encoded[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn hexDigit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

const testing = std.testing;

test "parse reads switch and profile commands and decodes their names" {
    const switch_command = try parse(testing.allocator, "evemajpreview://switch/Some%20Pilot");
    defer switch_command.deinit(testing.allocator);
    try testing.expectEqualStrings("Some Pilot", switch_command.switch_character);

    const profile_command = try parse(testing.allocator, "evemajpreview://profile/My%20Alts/");
    defer profile_command.deinit(testing.allocator);
    try testing.expectEqualStrings("My Alts", profile_command.profile);
}

test "parse reads every hotkey action by name" {
    var buf: [128]u8 = undefined;
    for (std.enums.values(GlobalAction)) |action| {
        const text = try std.mem.print(&buf, "evemajpreview://hotkey/{s}", .{@tagName(action)});
        try testing.expectEqual(action, (try parse(testing.allocator, text)).hotkey);
    }
}

test "parse reads every group action with its decoded group name" {
    var buf: [128]u8 = undefined;
    for (std.enums.values(GroupAction)) |action| {
        const text = try std.mem.print(&buf, "evemajpreview://group/{s}/Mining%20Fleet", .{@tagName(action)});
        const command = try parse(testing.allocator, text);
        defer command.deinit(testing.allocator);
        try testing.expectEqual(action, command.group.action);
        try testing.expectEqualStrings("Mining Fleet", command.group.name);
    }
}

test "parse reads the open-config URL a second launch sends" {
    try testing.expectEqual(Command.open_config, try parse(testing.allocator, OPEN_CONFIG_URL));
    try testing.expectEqual(Command.open_config, try parse(testing.allocator, OPEN_CONFIG_URL ++ "/"));
}

test "parse rejects other schemes, unknown actions and missing parameters" {
    try testing.expectError(error.InvalidProtocol, parse(testing.allocator, "https://example.com/switch/Pilot"));
    try testing.expectError(error.InvalidAction, parse(testing.allocator, "evemajpreview://launch/Pilot"));
    try testing.expectError(error.InvalidAction, parse(testing.allocator, "evemajpreview://"));
    try testing.expectError(error.MissingParameter, parse(testing.allocator, "evemajpreview://switch"));
    try testing.expectError(error.MissingParameter, parse(testing.allocator, "evemajpreview://switch/"));
    try testing.expectError(error.MissingParameter, parse(testing.allocator, "evemajpreview://hotkey"));
    try testing.expectError(error.InvalidParameter, parse(testing.allocator, "evemajpreview://hotkey/self_destruct"));
    try testing.expectError(error.MissingParameter, parse(testing.allocator, "evemajpreview://group/close"));
    try testing.expectError(error.MissingParameter, parse(testing.allocator, "evemajpreview://group/close/"));
    try testing.expectError(error.InvalidParameter, parse(testing.allocator, "evemajpreview://group/explode/Miners"));
}

test "urlDecode decodes percent escapes and keeps plus signs" {
    const decoded = try urlDecode(testing.allocator, "Jita%204%20-%20Moon%204%2fX+1");
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("Jita 4 - Moon 4/X+1", decoded);
}

test "urlDecode keeps a malformed or truncated escape as written" {
    const malformed = try urlDecode(testing.allocator, "100%zz");
    defer testing.allocator.free(malformed);
    try testing.expectEqualStrings("100%zz", malformed);

    const truncated = try urlDecode(testing.allocator, "abc%4");
    defer testing.allocator.free(truncated);
    try testing.expectEqualStrings("abc%4", truncated);

    const signed = try urlDecode(testing.allocator, "%+1");
    defer testing.allocator.free(signed);
    try testing.expectEqualStrings("%+1", signed);
}
