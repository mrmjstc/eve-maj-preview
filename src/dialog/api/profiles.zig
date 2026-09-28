//! Listing, switching, creating, copying, deleting and resetting profiles.
const std = @import("std");
const config_mod = @import("../../config.zig");
const main_mod = @import("../../main.zig");
const host = @import("../host.zig");

/// `current` is the profile the window edits, `live` the one the app runs.
pub fn listProfiles(arena: std.mem.Allocator) !struct { profiles: []const []const u8, current: []const u8, live: []const u8 } {
    const names = try config_mod.listProfiles(arena);
    return .{ .profiles = names.items, .current = host.editingProfile(), .live = main_mod.g_store.live.profile_name };
}

pub fn listProfileBackups(arena: std.mem.Allocator) !struct { backups: []const []const u8 } {
    const names = try config_mod.listProfileBackups(arena);
    return .{ .backups = names.items };
}

/// Changes which profile the window edits, not which one the app runs.
pub fn switchProfile(_: std.mem.Allocator, args: struct { name: []const u8 }) !void {
    try config_mod.validateProfileName(args.name);
    try host.setEditingProfile(args.name);
}

/// "Make It Live": the app switches to `name`.
pub fn switchProfileLive(_: std.mem.Allocator, args: struct { name: []const u8 }) !void {
    try config_mod.validateProfileName(args.name);
    main_mod.switchProfile(args.name);
}

/// `name` is the display name typed by the user, without ".json".
pub fn createProfile(arena: std.mem.Allocator, args: struct { name: []const u8, accentColor: ?[]const u8 = null }) !void {
    const file_name = try config_mod.profileFileName(arena, args.name);
    try config_mod.createProfile(host.allocator(), file_name, try parseAccentColor(args.accentColor));
}

/// `target` is a display name, `source` a profile file name.
pub fn copyProfile(arena: std.mem.Allocator, args: struct { source: []const u8, target: []const u8, accentColor: ?[]const u8 = null }) !void {
    const target = try config_mod.profileFileName(arena, args.target);
    try config_mod.copyProfile(host.allocator(), args.source, target, try parseAccentColor(args.accentColor));
}

/// `backup` is a file name from listProfileBackups, `target` a display name.
pub fn restoreProfileBackup(arena: std.mem.Allocator, args: struct { backup: []const u8, target: []const u8, accentColor: ?[]const u8 = null }) !void {
    const target = try config_mod.profileFileName(arena, args.target);
    try config_mod.restoreProfileBackup(host.allocator(), args.backup, target, try parseAccentColor(args.accentColor));
}

/// Moved to a backup rather than deleted; deleting the running profile first switches the app to the default one.
/// The window goes on to edit whichever profile the app then runs.
pub fn deleteProfile(_: std.mem.Allocator, args: struct { name: []const u8 }) !void {
    try config_mod.validateProfileName(args.name);
    if (std.mem.eql(u8, args.name, config_mod.DEFAULT_PROFILE)) return error.CannotDeleteDefaultProfile;
    if (std.mem.eql(u8, args.name, main_mod.g_store.live.profile_name)) main_mod.switchProfile(config_mod.DEFAULT_PROFILE);
    try config_mod.deleteProfileToBackup(host.allocator(), args.name);
    if (std.mem.eql(u8, args.name, host.editingProfile())) try host.setEditingProfile(main_mod.g_store.live.profile_name);
}

/// Resetting the running profile reloads the app onto its defaults.
pub fn resetProfile(_: std.mem.Allocator, args: struct { name: []const u8 }) !void {
    try config_mod.validateProfileName(args.name);
    try config_mod.writeDefaultProfile(host.allocator(), args.name, null);
    if (std.mem.eql(u8, args.name, main_mod.g_store.live.profile_name)) main_mod.switchProfile(args.name);
}

fn parseAccentColor(hex: ?[]const u8) !?u32 {
    const text = hex orelse return null;
    if (text.len == 0) return null;
    return config_mod.parseHexColor(text) catch return error.InvalidAccentColor;
}
