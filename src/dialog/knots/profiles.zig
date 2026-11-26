//! Profile actions, run between frames since each can replace the documents, reload the app or change the profile folder, and the profile list, names and colours they keep current; main thread only.
const std = @import("std");
const config = @import("../../config.zig");
const profile_files = @import("../../config/profiles.zig");
const host = @import("host.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const import_dialog = @import("import_dialog.zig");
const window_mod = @import("window.zig");
const log = @import("../../log.zig");

const Window = window_mod.Window;
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
    switch_to,
    create,
    /// A copy of the running profile.
    copy,
    /// The running profile, given the name; its switch hotkeys follow it.
    rename,
    /// Moved to a backup, not deleted.
    delete,
    reset,
    /// Of the saved file, so unsaved edits aren't in it.
    back_up,
    /// Under the profile's name; the pending backup says which.
    restore,
    /// Over the existing profile, after backing it up; the pending backup says which.
    replace_with_backup,
    /// For good; the name is the backup's file name.
    delete_backup,
    /// A new profile from the Import dialog's chosen sections.
    import_new,
    /// The Import dialog's chosen sections, applied after backing the running profile up.
    import_running,
};

/// What happens to unsaved changes before an action that switches profiles.
pub const Unsaved = enum { save, discard };

/// One window's, reset as each opens.
pub const State = struct {
    action: ?Action = null,
    /// The profile file name the pending action is about; owned, freed by runPending or clearPending.
    name: ?[]u8 = null,
    accent: ?u32 = null,
    /// The backup file a pending restore reads; owned, taken by the restore actions, or freed by the next request or clearPending.
    backup: ?[]u8 = null,
    /// Set while the pending action waits on the unsaved-changes prompt, whose modal clears it to cancel.
    is_awaiting_choice: bool = false,
    /// The prompt's answer, applied before the pending action runs.
    unsaved: ?Unsaved = null,
    /// Bumped each time the profile list is re-read, i.e. after every action.
    revision: u32 = 0,
    /// Profile file names, sorted; owned, refreshed after every action.
    profiles: std.ArrayList([]const u8) = .empty,
    /// Each profile's saved accent colour, in profiles' order.
    accents: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.freeProfiles(allocator);
        self.clearPending(allocator);
    }

    fn clearPending(self: *State, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.name = null;
        if (self.backup) |backup| allocator.free(backup);
        self.backup = null;
        self.action = null;
        self.is_awaiting_choice = false;
        self.unsaved = null;
    }

    fn freeProfiles(self: *State, allocator: std.mem.Allocator) void {
        for (self.profiles.items) |name| allocator.free(name);
        self.profiles.deinit(allocator);
        self.profiles = .empty;
        self.accents.deinit(allocator);
        self.accents = .empty;
    }
};

/// Borrows from the window's State until the next action runs.
pub fn list(window: *Window) []const []const u8 {
    return window.profiles.profiles.items;
}

/// Each listed profile's saved accent colour, in list's order; borrows like list.
pub fn accents(window: *Window) []const u32 {
    return window.profiles.accents.items;
}

/// Queues `action` on `name` (a profile file name); a request made while another is pending replaces it.
pub fn request(window: *Window, action: Action, name: []const u8, accent: ?u32) void {
    queue(window, action, name, accent, null);
}

/// Restores `backup` (a backup file name) as the profile `name`; `action` is .restore or .replace_with_backup.
pub fn requestRestore(window: *Window, action: Action, name: []const u8, backup: []const u8, accent: ?u32) void {
    const owned = window.allocator.dupe(u8, backup) catch |err| {
        slog.err("Failed to queue restoring backup '{s}': {}", .{ backup, err });
        return;
    };
    queue(window, action, name, accent, owned);
}

/// The profile a pending action would switch to, while it waits on the unsaved-changes prompt; borrows from the window's State.
pub fn awaitedName(window: *Window) ?[]const u8 {
    if (!window.profiles.is_awaiting_choice) return null;
    return displayName(window.profiles.name orelse return null);
}

/// Whether the action waiting on the unsaved-changes prompt is a rename, which the prompt words apart from a switch.
pub fn isAwaitingRename(window: *Window) bool {
    return window.profiles.is_awaiting_choice and window.profiles.action == .rename;
}

/// The unsaved-changes prompt's open flag.
pub fn awaitingFlag(window: *Window) *bool {
    return &window.profiles.is_awaiting_choice;
}

/// Runs the action waiting on the unsaved-changes prompt, after saving or discarding the changes.
pub fn resolve(window: *Window, unsaved: Unsaved) void {
    window.profiles.is_awaiting_choice = false;
    window.profiles.unsaved = unsaved;
    window.host.scheduleProfileAction();
}

/// Drops the action waiting on the unsaved-changes prompt.
pub fn cancel(window: *Window) void {
    window.profiles.clearPending(window.allocator);
}

/// Between frames, from the posted command.
pub fn runPending(window: *Window) void {
    const action = window.profiles.action orelse return;
    const name = window.profiles.name orelse return;
    const unsaved = window.profiles.unsaved;
    if (unsaved == null and switchesProfile(action) and window.session.isDirty()) {
        window.profiles.is_awaiting_choice = true;
        return;
    }
    window.profiles.action = null;
    window.profiles.name = null;
    window.profiles.unsaved = null;
    defer window.allocator.free(name);
    run(window, action, name, window.profiles.accent, unsaved) catch |err| switch (err) {
        // saveChanges has logged it and shown which hotkeys to fix.
        error.ConflictingHotkeys => {},
        else => {
            slog.err("Failed to run profile action '{t}' on '{s}': {}", .{ action, name, err });
            window.status.show(.failure, failureText(action), .{ .name = shownName(action, name), .err = err });
        },
    };
    window.session.profileReplaced();
    refresh(window);
}

/// Why `typed` can't name a new profile, or null while it can or nothing is typed yet.
pub fn nameProblem(window: *Window, arena: std.mem.Allocator, typed: []const u8) ?[]const u8 {
    if (typed.len == 0) return null;
    const file_name = config.profileFileName(arena, typed) catch |err| switch (err) {
        error.InvalidProfileName => return "Use " ++ NAME_RULES ++ ".",
        else => {
            slog.warn("Failed to check profile name '{s}': {}", .{ typed, err });
            return null;
        },
    };
    if (listedName(window, file_name) != null) return "A profile with this name already exists.";
    return null;
}

/// The listed profile file name `typed` names, ignoring case; borrows from the profile list.
pub fn existingProfile(window: *Window, arena: std.mem.Allocator, typed: []const u8) ?[]const u8 {
    const file_name = config.profileFileName(arena, typed) catch |err| switch (err) {
        error.InvalidProfileName => return null,
        else => {
            slog.warn("Failed to check profile name '{s}': {}", .{ typed, err });
            return null;
        },
    };
    return listedName(window, file_name);
}

/// The listed profile file name matching `file_name`, ignoring case; borrows from the profile list.
pub fn listedName(window: *Window, file_name: []const u8) ?[]const u8 {
    for (window.profiles.profiles.items) |name| {
        if (std.ascii.eqlIgnoreCase(name, file_name)) return name;
    }
    return null;
}

/// Changes after every profile action, so lists built from the profile folder know to reread it.
pub fn revision(window: *Window) u32 {
    return window.profiles.revision;
}

/// Rereads the profile list, as the window opens and after every action.
pub fn refresh(window: *Window) void {
    window.profiles.revision +%= 1;
    window.profiles.freeProfiles(window.allocator);
    const io = window.session.appContext().io;
    window.profiles.profiles = config.listProfiles(window.allocator, io) catch |err| blk: {
        slog.err("Failed to list profiles: {}", .{err});
        break :blk .empty;
    };
    std.mem.sort([]const u8, window.profiles.profiles.items, {}, alphabetically);
    window.profiles.accents.ensureTotalCapacity(window.allocator, window.profiles.profiles.items.len) catch |err| {
        slog.err("Failed to read the profiles' colours: {}", .{err});
        window.profiles.freeProfiles(window.allocator);
        return;
    };
    for (window.profiles.profiles.items) |name| {
        const accent = config.readProfileAccent(window.allocator, io, name) catch |err| blk: {
            slog.warn("Failed to read the colour of profile '{s}': {}", .{ name, err });
            break :blk null;
        };
        window.profiles.accents.appendAssumeCapacity(accent orelse DEFAULT_ACCENT);
    }
}

fn run(window: *Window, action: Action, name: []const u8, accent: ?u32, unsaved: ?Unsaved) !void {
    const app_context = window.session.appContext();
    if (unsaved) |choice| switch (choice) {
        .save => try window.host.saveChanges(),
        .discard => try window.host.discardChanges(),
    };
    switch (action) {
        .switch_to => {
            try window.session.switchProfile(name);
            window.status.show(.success, "Switched to profile '{name}'", .{ .name = displayName(name) });
        },
        .create => {
            try config.createProfile(window.allocator, app_context.io, name, accent);
            try window.session.switchProfile(name);
            window.status.show(.success, "Created profile '{name}'", .{ .name = displayName(name) });
        },
        .copy => {
            try config.copyProfile(window.allocator, app_context.io, app_context.store.live.profile_name, name, accent);
            try window.session.switchProfile(name);
            window.status.show(.success, "Copied to profile '{name}'", .{ .name = displayName(name) });
        },
        .rename => {
            // Copied, since the switch below frees the running profile's name.
            const old_name = try window.allocator.dupe(u8, app_context.store.live.profile_name);
            defer window.allocator.free(old_name);
            try config.renameProfile(window.allocator, app_context.io, old_name, name);
            retargetProfileSwitches(window, old_name, name);
            window.session.switchProfile(name) catch |err| {
                undoRename(window, name, old_name);
                return err;
            };
            window.status.show(.success, "Renamed profile to '{name}'", .{ .name = displayName(name) });
        },
        .delete => {
            // Checked before any switch, which a refused delete mustn't cause.
            try config.checkProfileDeletable(name);
            if (std.mem.eql(u8, name, app_context.store.live.profile_name)) try window.session.switchProfile(config.DEFAULT_PROFILE);
            try config.deleteProfileToBackup(window.allocator, app_context.io, name);
            window.status.show(.success, "Deleted profile '{name}' (kept as a backup)", .{ .name = displayName(name) });
        },
        .restore => {
            const backup = try takeBackup(window);
            defer window.allocator.free(backup);
            try config.restoreProfileBackup(window.allocator, app_context.io, backup, name, accent);
            try window.session.switchProfile(name);
            window.status.show(.success, "Restored profile '{name}'", .{ .name = displayName(name) });
        },
        .replace_with_backup => {
            const backup = try takeBackup(window);
            defer window.allocator.free(backup);
            try config.replaceProfileWithBackup(window.allocator, app_context.io, backup, name, accent);
            try window.session.switchProfile(name);
            window.status.show(.success, "Replaced profile '{name}' with the backup", .{ .name = displayName(name) });
        },
        .delete_backup => {
            try config.deleteProfileBackup(window.allocator, app_context.io, name);
            window.status.show(.success, "Deleted the backup of '{name}'", .{ .name = shownName(action, name) });
        },
        .import_new => {
            try config.createProfile(window.allocator, app_context.io, name, accent);
            try window.session.switchProfile(name);
            try import_dialog.applyImport(window);
            try window.host.saveChanges();
            window.status.show(.success, "Imported into new profile '{name}'", .{ .name = displayName(name) });
        },
        .import_running => {
            try config.backUpProfile(window.allocator, app_context.io, name);
            try import_dialog.applyImport(window);
            // Also saves any edits made before the import; the backup predates them.
            try window.host.saveChanges();
            window.status.show(.success, "Imported into profile '{name}'", .{ .name = displayName(name) });
        },
        .back_up => {
            try config.backUpProfile(window.allocator, app_context.io, name);
            window.status.show(.success, "Backed up profile '{name}'", .{ .name = displayName(name) });
        },
        .reset => {
            try config.backUpProfile(window.allocator, app_context.io, name);
            try config.writeDefaultProfile(window.allocator, app_context.io, name, null);
            if (std.mem.eql(u8, name, app_context.store.live.profile_name)) try window.session.switchProfile(name);
            window.status.show(.success, "Reset profile '{name}' to defaults (kept as a backup)", .{ .name = displayName(name) });
        },
    }
}

/// Points the running and edited settings' switch hotkeys for profile `from` at `to`.
fn retargetProfileSwitches(window: *Window, from: []const u8, to: []const u8) void {
    const app_context = window.session.appContext();
    app_context.global_settings.retargetProfileSwitches(app_context.io, from, to) catch |err| {
        slog.warn("Failed to point the switch hotkeys of '{s}' at '{s}': {}", .{ from, to, err });
    };
    window.session.retargetProfileSwitches(from, to);
}

/// After a rename whose switch failed, since the old settings still run, and save, under `old_name`.
fn undoRename(window: *Window, new_name: []const u8, old_name: []const u8) void {
    config.renameProfile(window.allocator, window.session.appContext().io, new_name, old_name) catch |err| {
        slog.err("Failed to rename profile '{s}' back to '{s}' after the switch failed: {}", .{ new_name, old_name, err });
        return;
    };
    retargetProfileSwitches(window, new_name, old_name);
}

/// A switch drops unsaved changes unless the prompt saves them.
fn switchesProfile(action: Action) bool {
    return switch (action) {
        .switch_to, .create, .copy, .rename, .restore, .replace_with_backup, .import_new => true,
        .delete, .reset, .back_up, .delete_backup, .import_running => false,
    };
}

/// Whole sentences, since a translation can't put a verb into someone else's.
fn failureText(action: Action) []const u8 {
    return switch (action) {
        .switch_to => "Failed to switch to profile '{name}': {err}",
        .create => "Failed to create profile '{name}': {err}",
        .copy => "Failed to copy to profile '{name}': {err}",
        .rename => "Failed to rename profile to '{name}': {err}",
        .delete => "Failed to delete profile '{name}': {err}",
        .reset => "Failed to reset profile '{name}': {err}",
        .back_up => "Failed to back up profile '{name}': {err}",
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
        .switch_to, .create, .copy, .rename, .delete, .reset, .back_up, .restore, .replace_with_backup, .import_new, .import_running => displayName(name),
    };
}

/// Takes ownership of `backup`, freeing it on failure; replaces the pending action and its backup whole.
fn queue(window: *Window, action: Action, name: []const u8, accent: ?u32, backup: ?[]u8) void {
    const owned = window.allocator.dupe(u8, name) catch |err| {
        slog.err("Failed to queue a profile action for '{s}': {}", .{ name, err });
        if (backup) |unused| window.allocator.free(unused);
        return;
    };
    window.profiles.clearPending(window.allocator);
    window.profiles.name = owned;
    window.profiles.backup = backup;
    window.profiles.action = action;
    window.profiles.accent = accent;
    window.host.scheduleProfileAction();
}

/// The pending restore's backup file name; owned by the caller.
fn takeBackup(window: *Window) ![]u8 {
    const backup = window.profiles.backup orelse return error.MissingBackup;
    window.profiles.backup = null;
    return backup;
}

fn alphabetically(_: void, first: []const u8, second: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(first, second);
}
