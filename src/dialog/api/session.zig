//! The profile and global settings the window edits, as documents changed by edit ops (see config/patch.zig) until Save or Discard.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const patch = @import("../../config/patch.zig");
const schema = @import("../../config/schema.zig");
const notification = @import("../../notifications/notification.zig");
const painter_mod = @import("../../painter.zig");
const protocol = @import("../../protocol.zig");
const main = @import("../../main.zig");
const host = @import("../host.zig");
const run_on_startup = @import("../run_on_startup.zig");
const session = @import("../session.zig");
const rpc = @import("../rpc.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog");

/// Starts over from what's saved, dropping unsaved edits.
pub fn openSession(arena: std.mem.Allocator) !rpc.RawJson {
    try session.begin();
    return snapshot(arena);
}

/// The documents as edited so far, to resync after a failed edit.
pub fn getSession(arena: std.mem.Allocator) !rpc.RawJson {
    return snapshot(arena);
}

/// Returns one result per op (see session.apply) and whether the document now differs from what's saved.
pub fn applyOps(arena: std.mem.Allocator, args: struct { doc: session.Doc, ops: []const patch.Op }) !rpc.RawJson {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("results");
    try session.apply(&jw, arena, args.doc, args.ops);
    try jw.objectField("dirty");
    try writeDirty(&jw);
    try jw.endObject();
    return .{ .text = out.written() };
}

/// Saving another profile's draft also makes it the running profile; the global settings are taken in by the restart that follows.
pub fn saveSession(arena: std.mem.Allocator) !rpc.RawJson {
    slog.info("Saving configuration (profile dirty: {}, global dirty: {})", .{ session.profileDirty(), session.globalDirty() });
    const global_draft: ?*config.GlobalConfig = if (session.globalDirty()) try session.global() else null;

    if (session.editsDraft()) {
        const draft = session.profile();
        try config.saveProfile(draft, arena, try config.profilePath(arena, draft.profile_name));
        const name = try arena.dupe(u8, draft.profile_name);
        session.dropProfileDraft();
        try main.switchToSavedProfile(name, global_draft);
    } else {
        const profile_changed = main.g_store.isDirty();
        if (profile_changed) try main.g_store.commit();
        if (profile_changed or global_draft != null) try main.applySavedSettings(global_draft);
    }

    if (global_draft != null) {
        try session.resetGlobalDraft();
        const settings = &main.g_global_settings;
        try settings.save();
        log.setLevel(settings.logLevel);
        if (settings.logLevel == .debug) log.openDebugConsole() else log.closeDebugConsole();
        run_on_startup.apply(settings.runOnStartup);
        if (settings.autoRegisterProtocol) protocol.ensureRegistered(host.allocator());
    }
    return snapshot(arena);
}

/// Every setting's kind, default, bounds and options (see config/schema.zig).
pub fn getSchema(arena: std.mem.Allocator) !rpc.RawJson {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try schema.write(&jw);
    return .{ .text = out.written() };
}

/// Fires `type` on every thumbnail with the settings the window has for it, saved or not.
pub fn testNotification(_: std.mem.Allocator, args: struct { type: []const u8 }) !void {
    const ntype = std.meta.stringToEnum(notification.NotificationType, args.type) orelse return error.InvalidNotificationType;
    const painter = painter_mod.g_painter_ptr orelse return;
    try painter.showTestNotification(ntype, session.profile().thumbnail.notifications.getTypeConfig(ntype));
}

/// `oreCatalog` is the built-in ore list whose prices oreTable overrides, `profiles` feeds the dropdown and profile-switch hotkeys, and `characterIds` the portraits.
fn snapshot(arena: std.mem.Allocator) !rpc.RawJson {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("profileName");
    try jw.write(session.profile().profile_name);
    try jw.objectField("editsDraft");
    try jw.write(session.editsDraft());
    try jw.objectField("profile");
    try session.writeProfile(&jw);
    try jw.objectField("global");
    try session.writeGlobal(&jw);
    try jw.objectField("oreCatalog");
    try jw.write(config.DEFAULT_ORE_TABLE);
    try jw.objectField("profiles");
    try jw.write((try config.listProfiles(arena)).items);
    try jw.objectField("characterIds");
    try main.g_character_ids.write(&jw);
    try jw.objectField("dirty");
    try writeDirty(&jw);
    try jw.endObject();
    return .{ .text = out.written() };
}

fn writeDirty(jw: *std.json.Stringify) !void {
    try jw.write(.{ .profile = session.profileDirty(), .global = session.globalDirty() });
}

