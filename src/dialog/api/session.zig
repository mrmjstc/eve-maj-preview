//! The profile and global settings the window edits, as documents changed by edit ops (see config/patch.zig) until Save or Discard.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config_mod = @import("../../config.zig");
const patch = @import("../../config/patch.zig");
const schema = @import("../../config/schema.zig");
const notification_mod = @import("../../notifications/notification.zig");
const painter_mod = @import("../../painter.zig");
const protocol = @import("../../protocol.zig");
const main_mod = @import("../../main.zig");
const host = @import("../host.zig");
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

/// Saving another profile's draft also makes it the running profile.
/// The global settings are taken in by the restart that follows, once nothing else is reading them.
pub fn saveSession(arena: std.mem.Allocator) !rpc.RawJson {
    const global_draft: ?*config_mod.GlobalConfig = if (session.globalDirty()) try session.global() else null;

    if (session.editsDraft()) {
        const draft = session.profile();
        try config_mod.saveProfile(draft, arena, try config_mod.profilePath(arena, draft.profile_name));
        const name = try arena.dupe(u8, draft.profile_name);
        session.dropProfileDraft();
        try main_mod.switchToSavedProfile(name, global_draft);
    } else {
        const profile_changed = main_mod.g_store.isDirty();
        if (profile_changed) try main_mod.g_store.commit();
        if (profile_changed or global_draft != null) try main_mod.applySavedSettings(global_draft);
    }

    if (global_draft != null) {
        try session.resetGlobalDraft();
        const settings = &main_mod.g_global_settings;
        try settings.save();
        log.setLevel(settings.logLevel);
        applyRunOnStartup(settings.runOnStartup);
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
pub fn testNotification(_: std.mem.Allocator, args: struct { @"type": []const u8 }) !void {
    const ntype = std.meta.stringToEnum(notification_mod.NotificationType, args.@"type") orelse return error.InvalidNotificationType;
    const painter = painter_mod.g_painter_ptr orelse return;
    try painter.showTestNotification(ntype, session.profile().thumbnail.notifications.getTypeConfig(ntype));
}

/// `oreCatalog` is the built-in ore list the ore table shows, whose prices the global settings' oreTable overrides;
/// `profiles` lists every profile for the dropdown and the profile-switch hotkeys, and `characterIds` gives the portraits.
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
    try jw.write(config_mod.DEFAULT_ORE_TABLE);
    try jw.objectField("profiles");
    try jw.write((try config_mod.listProfiles(arena)).items);
    try jw.objectField("characterIds");
    try main_mod.g_character_ids.write(&jw);
    try jw.objectField("dirty");
    try writeDirty(&jw);
    try jw.endObject();
    return .{ .text = out.written() };
}

fn writeDirty(jw: *std.json.Stringify) !void {
    try jw.write(.{ .profile = session.profileDirty(), .global = session.globalDirty() });
}

const STARTUP_RUN_KEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const STARTUP_RUN_VALUE_NAME = "EVE-Maj Preview";

fn applyRunOnStartup(enabled: bool) void {
    if (!enabled) {
        var key: win32.HKEY = undefined;
        const open_result = win32.RegOpenKeyExA(win32.HKEY_CURRENT_USER, STARTUP_RUN_KEY, 0, win32.KEY_WRITE, &key);
        // Nothing to remove if the Run key can't even be opened.
        if (open_result != win32.ERROR_SUCCESS) return;
        defer _ = win32.RegCloseKey(key);
        const delete_result = win32.RegDeleteValueA(key, STARTUP_RUN_VALUE_NAME);
        if (delete_result != win32.ERROR_SUCCESS and delete_result != win32.ERROR_FILE_NOT_FOUND) {
            slog.warn("Failed to remove the startup registry value: error {}", .{delete_result});
        }
        return;
    }

    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = win32.selfExeDirPath(&exe_path_buf) catch |err| {
        slog.err("Failed to find the executable directory for startup registration: {}", .{err});
        return;
    };
    var command_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const command = std.fmt.bufPrintZ(&command_buf, "\"{s}\\eve-maj-preview.exe\"", .{exe_dir}) catch |err| {
        slog.err("Failed to build the startup command: {}", .{err});
        return;
    };

    var key: win32.HKEY = undefined;
    var disposition: win32.DWORD = undefined;
    const create_result = win32.RegCreateKeyExA(win32.HKEY_CURRENT_USER, STARTUP_RUN_KEY, 0, null, win32.REG_OPTION_NON_VOLATILE, win32.KEY_WRITE, null, &key, &disposition);
    if (create_result != win32.ERROR_SUCCESS) {
        slog.err("Failed to open the startup registry key: error {}", .{create_result});
        return;
    }
    defer _ = win32.RegCloseKey(key);

    const set_result = win32.RegSetValueExA(key, STARTUP_RUN_VALUE_NAME, 0, win32.REG_SZ, command.ptr, @intCast(command.len + 1));
    if (set_result != win32.ERROR_SUCCESS) {
        slog.err("Failed to set the startup registry value: error {}", .{set_result});
    }
}
