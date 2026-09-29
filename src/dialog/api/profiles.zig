//! Listing, switching, creating, copying, deleting and resetting profiles.
const std = @import("std");
const config = @import("../../config.zig");
const main = @import("../../main.zig");
const host = @import("../host.zig");

const Reloaded = struct { reloaded: bool };

pub fn listProfileBackups(arena: std.mem.Allocator) !struct { backups: []const []const u8 } {
    const names = try config.listProfileBackups(arena);
    return .{ .backups = names.items };
}

/// Changes which profile the window edits, not which one the app runs.
pub fn switchProfile(_: std.mem.Allocator, args: struct { name: []const u8 }) !void {
    try config.validateProfileName(args.name);
    try host.setEditingProfile(args.name);
}

/// "Make It Live": the app switches to `name`, and the window edits it; the profileSwitched event that follows reopens the session.
pub fn switchProfileLive(_: std.mem.Allocator, args: struct { name: []const u8 }) !void {
    try config.validateProfileName(args.name);
    // Before the switch, so the session it reopens is `name`'s rather than a draft of the old one.
    try host.setEditingProfile(args.name);
    main.switchProfile(args.name);
}

/// `name` is the display name typed by the user, without ".json".
pub fn createProfile(arena: std.mem.Allocator, args: struct { name: []const u8, accentColor: ?[]const u8 = null }) !void {
    const file_name = try config.profileFileName(arena, args.name);
    try config.createProfile(host.allocator(), file_name, try parseAccentColor(args.accentColor));
}

/// `target` is a display name, `source` a profile file name.
pub fn copyProfile(arena: std.mem.Allocator, args: struct { source: []const u8, target: []const u8, accentColor: ?[]const u8 = null }) !void {
    const target = try config.profileFileName(arena, args.target);
    try config.copyProfile(host.allocator(), args.source, target, try parseAccentColor(args.accentColor));
}

/// `backup` is a file name from listProfileBackups, `target` a display name.
pub fn restoreProfileBackup(arena: std.mem.Allocator, args: struct { backup: []const u8, target: []const u8, accentColor: ?[]const u8 = null }) !void {
    const target = try config.profileFileName(arena, args.target);
    try config.restoreProfileBackup(host.allocator(), args.backup, target, try parseAccentColor(args.accentColor));
}

/// Moved to a backup rather than deleted; deleting the running profile first switches the app, and the window, to the default one.
/// `reloaded` when the app switched profile, whose profileSwitched event reopens the window's session.
pub fn deleteProfile(_: std.mem.Allocator, args: struct { name: []const u8 }) !Reloaded {
    // Checked before the switch below, which a refused delete mustn't cause.
    try config.checkProfileDeletable(args.name);
    const running = std.mem.eql(u8, args.name, main.g_store.live.profile_name);
    if (running) main.switchProfile(config.DEFAULT_PROFILE);
    try config.deleteProfileToBackup(host.allocator(), args.name);
    if (std.mem.eql(u8, args.name, host.editingProfile())) try host.setEditingProfile(main.g_store.live.profile_name);
    return .{ .reloaded = running };
}

/// Resetting the running profile reloads the app onto its defaults; `reloaded` as for deleteProfile.
pub fn resetProfile(_: std.mem.Allocator, args: struct { name: []const u8 }) !Reloaded {
    try config.validateProfileName(args.name);
    try config.writeDefaultProfile(host.allocator(), args.name, null);
    const running = std.mem.eql(u8, args.name, main.g_store.live.profile_name);
    if (running) main.switchProfile(args.name);
    return .{ .reloaded = running };
}

fn parseAccentColor(hex: ?[]const u8) !?u32 {
    const text = hex orelse return null;
    if (text.len == 0) return null;
    return config.parseHexColor(text) catch return error.InvalidAccentColor;
}
