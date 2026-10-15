//! Profile actions, run between frames since each can replace the documents, reload the app or change the profile folder, and the profile list, names and colours they keep current; main thread only.
const std = @import("std");
const config = @import("../../config.zig");
const profile_files = @import("../../config/profiles.zig");
const host = @import("host.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const import_dialog = @import("import_dialog.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("dialog_knots");

/// Re-exported, since every caller in the window already reaches profiles through this module.
pub const displayName = config.profileDisplayName;

/// A new profile's accent colour, Config's own default.
pub const DEFAULT_ACCENT = blk: {
    const index = std.meta.fieldIndex(config.Config, "accentColor").?;
    break :blk @typeInfo(config.Config).@"struct".field_attrs[index].defaultValue(u32).?;
};
/// For the name prompts; part of en.json's keys, so changing the limit means updating them.
pub const NAME_RULES = std.fmt.comptimePrint("letters, digits, spaces, '-' and '_', up to {d} characters", .{profile_files.MAX_NAME_LENGTH});

comptime {
    std.debug.assert(style.ACCENT_PRESETS[0] == DEFAULT_ACCENT);
}

pub const Action = enum {
    /// The app switches to the profile.
    switch_to,
    create,
    /// A copy of the running profile.
    copy,
    /// Moved to a backup, not deleted.
    delete,
    reset,
    /// A backup restored under the profile's name; the pending backup says which.
    restore,
    /// A backup copied over the existing profile of that name, once the profile itself is backed up; the pending backup says which.
    replace_with_backup,
    /// A backup removed for good; the name is the backup's file name.
    delete_backup,
    /// A new profile with the Import dialog's chosen sections applied to it, then saved.
    import_new,
    /// The Import dialog's chosen sections applied to the running profile and saved, once a backup of it is kept.
    import_running,
};

/// What happens to unsaved changes before an action that switches profiles.
pub const Unsaved = enum { save, discard };

/// Called with an action to run between frames, i.e. a posted command.
pub const Schedule = *const fn () void;

var g_allocator: std.mem.Allocator = undefined;
var g_schedule: Schedule = undefined;
var g_action: ?Action = null;
/// The profile file name the pending action is about. Owned; freed by runPending or clearPending.
var g_name: ?[]u8 = null;
var g_accent: ?u32 = null;
/// The backup file a pending restore reads. Owned; taken by the restore actions, or freed by clearPending.
var g_backup: ?[]u8 = null;
/// Set while the pending action waits on the unsaved-changes prompt, whose modal clears it to cancel.
var g_is_awaiting_choice: bool = false;
/// The prompt's answer, applied before the pending action runs.
var g_unsaved: ?Unsaved = null;
/// Bumped each time the profile list is re-read, i.e. after every action.
var g_revision: u32 = 0;
/// Profile file names, sorted. Owned; refreshed after every action.
var g_profiles: std.ArrayList([]const u8) = .empty;
/// Each profile's saved accent colour, in g_profiles' order.
var g_accents: std.ArrayList(u32) = .empty;

pub fn init(allocator: std.mem.Allocator, schedule: Schedule) void {
    g_allocator = allocator;
    g_schedule = schedule;
    refresh();
}

/// Once the window has closed.
pub fn deinit() void {
    freeProfiles();
    clearPending();
}

/// Borrows from this module until the next action runs.
pub fn list() []const []const u8 {
    return g_profiles.items;
}

/// Each listed profile's saved accent colour, in list()'s order; borrows like list().
pub fn accents() []const u32 {
    return g_accents.items;
}

/// Queues `action` on `name` (a profile file name); a request made while another is pending replaces it.
pub fn request(action: Action, name: []const u8, accent: ?u32) void {
    const owned = g_allocator.dupe(u8, name) catch |err| {
        slog.err("Failed to queue a profile action for '{s}': {}", .{ name, err });
        return;
    };
    if (g_name) |old| g_allocator.free(old);
    g_name = owned;
    g_action = action;
    g_accent = accent;
    g_is_awaiting_choice = false;
    g_unsaved = null;
    g_schedule();
}

/// Restores `backup` (a backup file name) as the profile `name`; `action` is .restore or .replace_with_backup.
pub fn requestRestore(action: Action, name: []const u8, backup: []const u8, accent: ?u32) void {
    const owned = g_allocator.dupe(u8, backup) catch |err| {
        slog.err("Failed to queue restoring backup '{s}': {}", .{ backup, err });
        return;
    };
    if (g_backup) |old| g_allocator.free(old);
    g_backup = owned;
    request(action, name, accent);
}

/// The profile a pending action would switch to, while it waits on the unsaved-changes prompt. Borrows from this module.
pub fn awaitedName() ?[]const u8 {
    if (!g_is_awaiting_choice) return null;
    return displayName(g_name orelse return null);
}

/// The unsaved-changes prompt's open flag.
pub fn awaitingFlag() *bool {
    return &g_is_awaiting_choice;
}

/// Runs the action waiting on the unsaved-changes prompt, after saving or discarding the changes.
pub fn resolve(unsaved: Unsaved) void {
    g_is_awaiting_choice = false;
    g_unsaved = unsaved;
    g_schedule();
}

/// Drops the action waiting on the unsaved-changes prompt.
pub fn cancel() void {
    clearPending();
}

/// Between frames, from the posted command.
pub fn runPending() void {
    const action = g_action orelse return;
    const name = g_name orelse return;
    const unsaved = g_unsaved;
    if (unsaved == null and switchesProfile(action) and session.isDirty()) {
        g_is_awaiting_choice = true;
        return;
    }
    g_action = null;
    g_name = null;
    g_unsaved = null;
    defer g_allocator.free(name);
    run(action, name, g_accent, unsaved) catch |err| {
        slog.err("Failed to run profile action '{t}' on '{s}': {}", .{ action, name, err });
        status.show(.failure, failureText(action), .{ .name = shownName(action, name), .err = err });
    };
    session.profileReplaced();
    refresh();
}

/// Why `typed` can't name a new profile, or null while it can or nothing is typed yet.
pub fn nameProblem(arena: std.mem.Allocator, typed: []const u8) ?[]const u8 {
    if (typed.len == 0) return null;
    const file_name = config.profileFileName(arena, typed) catch |err| switch (err) {
        error.InvalidProfileName => return "Use " ++ NAME_RULES ++ ".",
        else => {
            slog.warn("Failed to check profile name '{s}': {}", .{ typed, err });
            return null;
        },
    };
    if (listedName(file_name) != null) return "A profile with this name already exists.";
    return null;
}

/// The listed profile file name `typed` names, ignoring case; borrows from the profile list.
pub fn existingProfile(arena: std.mem.Allocator, typed: []const u8) ?[]const u8 {
    const file_name = config.profileFileName(arena, typed) catch |err| switch (err) {
        error.InvalidProfileName => return null,
        else => {
            slog.warn("Failed to check profile name '{s}': {}", .{ typed, err });
            return null;
        },
    };
    return listedName(file_name);
}

/// The listed profile file name matching `file_name`, ignoring case; borrows from the profile list.
pub fn listedName(file_name: []const u8) ?[]const u8 {
    for (g_profiles.items) |name| {
        if (std.ascii.eqlIgnoreCase(name, file_name)) return name;
    }
    return null;
}

/// Changes after every profile action, so lists built from the profile folder know to reread it.
pub fn revision() u32 {
    return g_revision;
}

fn run(action: Action, name: []const u8, accent: ?u32, unsaved: ?Unsaved) !void {
    const app = session.runningApp();
    if (unsaved) |choice| switch (choice) {
        .save => try session.save(),
        .discard => try host.discardChanges(),
    };
    switch (action) {
        .switch_to => {
            app.switchProfile(name);
            status.show(.success, "Switched to profile '{name}'", .{ .name = displayName(name) });
        },
        .create => {
            try config.createProfile(g_allocator, app.io, name, accent);
            app.switchProfile(name);
            status.show(.success, "Created profile '{name}'", .{ .name = displayName(name) });
        },
        .copy => {
            try config.copyProfile(g_allocator, app.io, app.store.live.profile_name, name, accent);
            app.switchProfile(name);
            status.show(.success, "Copied to profile '{name}'", .{ .name = displayName(name) });
        },
        .delete => {
            // Checked before any switch, which a refused delete mustn't cause.
            try config.checkProfileDeletable(name);
            if (std.mem.eql(u8, name, app.store.live.profile_name)) app.switchProfile(config.DEFAULT_PROFILE);
            try config.deleteProfileToBackup(g_allocator, app.io, name);
            status.show(.success, "Deleted profile '{name}' (kept as a backup)", .{ .name = displayName(name) });
        },
        .restore => {
            const backup = try takeBackup();
            defer g_allocator.free(backup);
            try config.restoreProfileBackup(g_allocator, app.io, backup, name, accent);
            app.switchProfile(name);
            status.show(.success, "Restored profile '{name}'", .{ .name = displayName(name) });
        },
        .replace_with_backup => {
            const backup = try takeBackup();
            defer g_allocator.free(backup);
            try config.replaceProfileWithBackup(g_allocator, app.io, backup, name, accent);
            app.switchProfile(name);
            status.show(.success, "Replaced profile '{name}' with the backup", .{ .name = displayName(name) });
        },
        .delete_backup => {
            try config.deleteProfileBackup(g_allocator, app.io, name);
            status.show(.success, "Deleted the backup of '{name}'", .{ .name = shownName(action, name) });
        },
        .import_new => {
            try config.createProfile(g_allocator, app.io, name, accent);
            app.switchProfile(name);
            try import_dialog.applyImport();
            try session.save();
            status.show(.success, "Imported into new profile '{name}'", .{ .name = displayName(name) });
        },
        .import_running => {
            try config.backUpProfile(g_allocator, app.io, name);
            try import_dialog.applyImport();
            // Also saves any edits made before the import; the backup predates them.
            try session.save();
            status.show(.success, "Imported into profile '{name}'", .{ .name = displayName(name) });
        },
        .reset => {
            try config.backUpProfile(g_allocator, app.io, name);
            try config.writeDefaultProfile(g_allocator, app.io, name, null);
            if (std.mem.eql(u8, name, app.store.live.profile_name)) app.switchProfile(name);
            status.show(.success, "Reset profile '{name}' to defaults (kept as a backup)", .{ .name = displayName(name) });
        },
    }
}

/// A switch drops unsaved changes unless the prompt saves them.
fn switchesProfile(action: Action) bool {
    return switch (action) {
        .switch_to, .create, .copy, .restore, .replace_with_backup, .import_new => true,
        .delete, .reset, .delete_backup, .import_running => false,
    };
}

/// Whole sentences, since a translation can't put a verb into someone else's.
fn failureText(action: Action) []const u8 {
    return switch (action) {
        .switch_to => "Failed to switch to profile '{name}': {err}",
        .create => "Failed to create profile '{name}': {err}",
        .copy => "Failed to copy to profile '{name}': {err}",
        .delete => "Failed to delete profile '{name}': {err}",
        .reset => "Failed to reset profile '{name}': {err}",
        .restore => "Failed to restore profile '{name}': {err}",
        .replace_with_backup => "Failed to replace profile '{name}' with the backup: {err}",
        .delete_backup => "Failed to delete the backup of profile '{name}': {err}",
        .import_new, .import_running => "Failed to import into profile '{name}': {err}",
    };
}

/// How `name` reads in a status message: a backup's file name is shown as the profile it holds.
fn shownName(action: Action, name: []const u8) []const u8 {
    return switch (action) {
        .delete_backup => config.parseBackupName(name).name,
        .switch_to, .create, .copy, .delete, .reset, .restore, .replace_with_backup, .import_new, .import_running => displayName(name),
    };
}

/// The pending restore's backup file name. Owned by the caller.
fn takeBackup() ![]u8 {
    const backup = g_backup orelse return error.MissingBackup;
    g_backup = null;
    return backup;
}

fn clearPending() void {
    if (g_name) |name| g_allocator.free(name);
    g_name = null;
    if (g_backup) |backup| g_allocator.free(backup);
    g_backup = null;
    g_action = null;
    g_is_awaiting_choice = false;
    g_unsaved = null;
}

fn refresh() void {
    g_revision +%= 1;
    freeProfiles();
    const io = session.runningApp().io;
    g_profiles = config.listProfiles(g_allocator, io) catch |err| blk: {
        slog.err("Failed to list profiles: {}", .{err});
        break :blk .empty;
    };
    std.mem.sort([]const u8, g_profiles.items, {}, alphabetically);
    g_accents.ensureTotalCapacity(g_allocator, g_profiles.items.len) catch |err| {
        slog.err("Failed to read the profiles' colours: {}", .{err});
        freeProfiles();
        return;
    };
    for (g_profiles.items) |name| {
        const accent = config.readProfileAccent(g_allocator, io, name) catch |err| blk: {
            slog.warn("Failed to read the colour of profile '{s}': {}", .{ name, err });
            break :blk null;
        };
        g_accents.appendAssumeCapacity(accent orelse DEFAULT_ACCENT);
    }
}

fn alphabetically(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

fn freeProfiles() void {
    for (g_profiles.items) |name| g_allocator.free(name);
    g_profiles.deinit(g_allocator);
    g_profiles = .empty;
    g_accents.deinit(g_allocator);
    g_accents = .empty;
}
