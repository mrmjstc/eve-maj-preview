//! Profile actions from the header and the Backups tab, run between frames since each can replace the documents, reload the app or change the profile folder, and the profile list they keep current; main thread only.
const std = @import("std");
const config = @import("../../config.zig");
const main = @import("../../main.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const import_dialog = @import("import_dialog.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog_knots");

pub const Action = enum {
    /// The app switches to the profile, and the window edits it.
    make_live,
    /// The window edits the profile as a draft; the app keeps running its own.
    edit,
    create,
    /// A copy of the profile being edited.
    copy,
    /// Moved to a backup, not deleted.
    delete,
    reset,
    /// A backup restored under the profile's name; the pending backup says which.
    restore,
    /// A backup removed for good; the name is the backup's file name.
    delete_backup,
    /// A new profile, edited as a draft, with the Import dialog's chosen sections applied to it.
    import_new,
};

/// Called with an action to run between frames, i.e. a posted command.
pub const Schedule = *const fn () void;

var g_allocator: std.mem.Allocator = undefined;
var g_schedule: Schedule = undefined;
var g_action: ?Action = null;
/// The profile file name the pending action is about. Owned; freed by runPending.
var g_name: ?[]u8 = null;
var g_accent: ?u32 = null;
/// The backup file a pending restore reads. Owned; freed by runPending.
var g_backup: ?[]u8 = null;
/// Bumped each time the profile list is re-read, i.e. after every action.
var g_revision: u32 = 0;
/// A profile just created or copied, which the header offers to switch to. Owned; freed by takeCreated or deinit.
var g_created: ?[]u8 = null;
/// Profile file names, sorted. Owned; refreshed after every action.
var g_profiles: std.ArrayList([]const u8) = .empty;

pub fn init(allocator: std.mem.Allocator, schedule: Schedule) void {
    g_allocator = allocator;
    g_schedule = schedule;
    refresh();
}

/// Once the window has closed.
pub fn deinit() void {
    freeProfiles();
    if (g_name) |name| g_allocator.free(name);
    g_name = null;
    if (g_backup) |backup| g_allocator.free(backup);
    g_backup = null;
    g_action = null;
    if (g_created) |name| g_allocator.free(name);
    g_created = null;
}

/// Borrows from this module until the next action runs.
pub fn list() []const []const u8 {
    return g_profiles.items;
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
    g_schedule();
}

/// Restores `backup` (a backup file name) as the profile `name`.
pub fn requestRestore(name: []const u8, backup: []const u8, accent: ?u32) void {
    const owned = g_allocator.dupe(u8, backup) catch |err| {
        slog.err("Failed to queue restoring backup '{s}': {}", .{ backup, err });
        return;
    };
    if (g_backup) |old| g_allocator.free(old);
    g_backup = owned;
    request(.restore, name, accent);
}

/// Between frames, from the posted command.
pub fn runPending() void {
    const action = g_action orelse return;
    const name = g_name orelse return;
    g_action = null;
    g_name = null;
    defer g_allocator.free(name);
    run(action, name, g_accent) catch |err| {
        slog.err("Failed to {s} profile '{s}': {}", .{ verb(action), name, err });
        status.show(.failure, "Failed to {s} profile '{s}': {t}", .{ verb(action), shownName(action, name), err });
    };
    refresh();
}

/// The profile just created or copied, if any; the caller owns it.
pub fn takeCreated() ?[]u8 {
    const name = g_created orelse return null;
    g_created = null;
    return name;
}

/// "Main" for "Main.json".
pub fn displayName(file_name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, file_name, ".json")) file_name[0 .. file_name.len - ".json".len] else file_name;
}

/// Changes after every profile action, so a list built from the profile folder, e.g. the backups, can tell to read it again.
pub fn revision() u32 {
    return g_revision;
}

fn run(action: Action, name: []const u8, accent: ?u32) !void {
    switch (action) {
        .make_live => {
            try session.editProfile(main.g_store.live.profile_name);
            main.switchProfile(name);
            status.show(.success, "Switched to profile '{s}'", .{displayName(name)});
        },
        .edit => {
            try session.editProfile(name);
            status.show(.info, "Editing profile '{s}'; the app keeps running '{s}'", .{ displayName(name), displayName(main.g_store.live.profile_name) });
        },
        .create => {
            try config.createProfile(g_allocator, name, accent);
            try offerSwitch(name);
            status.show(.success, "Created profile '{s}'", .{displayName(name)});
        },
        .copy => {
            try config.copyProfile(g_allocator, session.profile().ptr.profile_name, name, accent);
            try offerSwitch(name);
            status.show(.success, "Copied to profile '{s}'", .{displayName(name)});
        },
        .delete => {
            // Checked before any switch, which a refused delete mustn't cause.
            try config.checkProfileDeletable(name);
            const running = std.mem.eql(u8, name, main.g_store.live.profile_name);
            if (running or std.mem.eql(u8, name, session.profile().ptr.profile_name)) try session.editProfile(main.g_store.live.profile_name);
            if (running) main.switchProfile(config.DEFAULT_PROFILE);
            try config.deleteProfileToBackup(g_allocator, name);
            status.show(.success, "Deleted profile '{s}' (kept as a backup)", .{displayName(name)});
        },
        .restore => {
            const backup = g_backup orelse return error.MissingBackup;
            defer {
                g_allocator.free(backup);
                g_backup = null;
            }
            try config.restoreProfileBackup(g_allocator, backup, name, accent);
            try offerSwitch(name);
            status.show(.success, "Profile restored successfully", .{});
        },
        .delete_backup => {
            try config.deleteProfileBackup(g_allocator, name);
            status.show(.success, "Deleted the backup of '{s}'", .{shownName(action, name)});
        },
        .import_new => {
            try config.createProfile(g_allocator, name, accent);
            try session.editProfile(name);
            import_dialog.applyImport();
            status.show(.info, "Imported into new profile '{s}'; review it, then Save", .{displayName(name)});
        },
        .reset => {
            try config.writeDefaultProfile(g_allocator, name, null);
            if (std.mem.eql(u8, name, main.g_store.live.profile_name)) {
                try session.editProfile(name);
                main.switchProfile(name);
            } else if (std.mem.eql(u8, name, session.profile().ptr.profile_name)) {
                try session.editProfile(name);
            }
            status.show(.success, "Reset profile '{s}' to defaults", .{displayName(name)});
        },
    }
}

fn offerSwitch(name: []const u8) !void {
    const owned = try g_allocator.dupe(u8, name);
    if (g_created) |old| g_allocator.free(old);
    g_created = owned;
}

fn verb(action: Action) []const u8 {
    return switch (action) {
        .make_live => "switch to",
        .edit => "edit",
        .create => "create",
        .copy => "copy to",
        .delete => "delete",
        .reset => "reset",
        .restore => "restore",
        .delete_backup => "delete the backup of",
        .import_new => "import into",
    };
}

/// How `name` reads in a status message: a backup's file name is shown as the profile it holds.
fn shownName(action: Action, name: []const u8) []const u8 {
    return switch (action) {
        .delete_backup => config.parseBackupName(name).name,
        .make_live, .edit, .create, .copy, .delete, .reset, .restore, .import_new => displayName(name),
    };
}

fn refresh() void {
    g_revision +%= 1;
    freeProfiles();
    g_profiles = config.listProfiles(g_allocator) catch |err| blk: {
        slog.err("Failed to list profiles: {}", .{err});
        break :blk .empty;
    };
}

fn freeProfiles() void {
    for (g_profiles.items) |name| g_allocator.free(name);
    g_profiles.deinit(g_allocator);
    g_profiles = .empty;
}
