//! What the configuration window edits: the running profile's `live` copy, or a draft when it edits another profile, and a draft of the global settings.
//! Main thread only.
const std = @import("std");
const config_mod = @import("../config.zig");
const patch = @import("../config/patch.zig");
const main_mod = @import("../main.zig");
const host = @import("host.zig");
const log = @import("../log.zig");

const slog = log.scoped("dialog");
const Config = config_mod.Config;
const GlobalConfig = config_mod.GlobalConfig;

pub const Doc = enum { profile, global };

var g_profile_draft: ?Config = null;
/// The draft as loaded, to tell whether it has unsaved edits.
var g_profile_draft_json: ?[]u8 = null;
var g_global_draft: ?GlobalConfig = null;

/// Starts over from what's saved, dropping unsaved edits.
pub fn begin() !void {
    end();
    const allocator = host.allocator();
    if (!host.editsLiveProfile()) {
        var draft = try config_mod.loadProfile(allocator, host.editingProfile());
        errdefer draft.deinit();
        patch.assignIds(Config, &draft);
        g_profile_draft_json = try draft.toJsonString(allocator);
        g_profile_draft = draft;
    }
    g_global_draft = try cloneGlobal(allocator, &main_mod.g_global_settings);
}

/// Drops unsaved edits.
pub fn end() void {
    if (g_profile_draft) |*draft| draft.deinit();
    g_profile_draft = null;
    if (g_profile_draft_json) |json| host.allocator().free(json);
    g_profile_draft_json = null;
    if (g_global_draft) |*draft| draft.deinit();
    g_global_draft = null;

    const store = &main_mod.g_store;
    if (!store.isDirty()) return;
    store.discard() catch |err| {
        slog.err("Failed to drop unsaved edits to the running profile: {}", .{err});
        return;
    };
    main_mod.onLiveProfileEdited(true);
}

/// The profile being edited; edits to the running one preview live.
pub fn profile() *Config {
    if (g_profile_draft) |*draft| return draft;
    return &main_mod.g_store.live;
}

pub fn editsDraft() bool {
    return g_profile_draft != null;
}

pub fn global() !*GlobalConfig {
    if (g_global_draft) |*draft| return draft;
    return error.NoSession;
}

pub fn profileDirty() bool {
    const draft = &(g_profile_draft orelse return main_mod.g_store.isDirty());
    var arena = std.heap.ArenaAllocator.init(host.allocator());
    defer arena.deinit();
    const json = draft.toJsonString(arena.allocator()) catch |err| {
        slog.err("Failed to serialize the edited profile to compare it: {}", .{err});
        return true;
    };
    return !std.mem.eql(u8, json, g_profile_draft_json.?);
}

pub fn globalDirty() bool {
    const draft = global() catch return false;
    var arena = std.heap.ArenaAllocator.init(host.allocator());
    defer arena.deinit();
    const edited = editableJson(arena.allocator(), draft) catch |err| {
        slog.err("Failed to serialize the edited global settings to compare them: {}", .{err});
        return true;
    };
    const running = editableJson(arena.allocator(), &main_mod.g_global_settings) catch |err| {
        slog.err("Failed to serialize the global settings to compare them: {}", .{err});
        return true;
    };
    return !std.mem.eql(u8, edited, running);
}

/// Applies `ops` in order, then writes one result per op to `jw` if given: a `set`'s value as clamped, an `insert`'s new item with its id, otherwise null.
pub fn apply(jw: ?*std.json.Stringify, arena: std.mem.Allocator, doc: Doc, ops: []const patch.Op) !void {
    switch (doc) {
        .profile => {
            // Even after a failed op, since those before it were applied.
            defer if (!editsDraft()) main_mod.onLiveProfileEdited(touchesLayout(ops));
            try applyTo(Config, profile(), jw, arena, ops);
        },
        .global => try applyTo(GlobalConfig, try global(), jw, arena, ops),
    }
}

fn applyTo(comptime T: type, target: *T, maybe_jw: ?*std.json.Stringify, arena: std.mem.Allocator, ops: []const patch.Op) !void {
    const ctx: patch.Context = .{ .arena = arena, .allocator = target.allocator };
    const inserted = try arena.alloc(?u32, ops.len);
    errdefer target.validate();
    for (ops, inserted) |op, *id| id.* = try patch.apply(T, target, op, ctx);
    target.validate();

    const jw = maybe_jw orelse return;
    try jw.beginArray();
    for (ops, inserted) |op, id| {
        if (id) |item_id| {
            const path = try arena.alloc(std.json.Value, op.path.len + 1);
            @memcpy(path[0..op.path.len], op.path);
            path[op.path.len] = .{ .integer = item_id };
            try patch.writeAt(jw, T, target, path);
        } else if (std.mem.eql(u8, op.op, "set")) {
            try patch.writeAt(jw, T, target, op.path);
        } else {
            try jw.write(null);
        }
    }
    try jw.endArray();
}

/// Display settings place the thumbnails, so they also need repositioning.
fn touchesLayout(ops: []const patch.Op) bool {
    for (ops) |op| {
        if (op.path.len > 0 and op.path[0] == .string and std.mem.eql(u8, op.path[0].string, "display")) return true;
    }
    return false;
}

/// After the app adopted the global draft (see GlobalConfig.adopt), which then holds the replaced values: it starts over from the running settings.
pub fn resetGlobalDraft() !void {
    const draft = try global();
    const fresh = try cloneGlobal(host.allocator(), &main_mod.g_global_settings);
    draft.deinit();
    g_global_draft = fresh;
}

/// The profile draft was saved and is now the running profile, whose `live` copy the window edits from here on.
pub fn dropProfileDraft() void {
    if (g_profile_draft) |*draft| draft.deinit();
    g_profile_draft = null;
    if (g_profile_draft_json) |json| host.allocator().free(json);
    g_profile_draft_json = null;
}

pub fn writeProfile(jw: *std.json.Stringify) !void {
    try patch.write(jw, Config, profile());
}

pub fn writeGlobal(jw: *std.json.Stringify) !void {
    try patch.write(jw, GlobalConfig, try global());
}

fn cloneGlobal(allocator: std.mem.Allocator, settings: *GlobalConfig) !GlobalConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return GlobalConfig.fromWire(try settings.toWire(arena.allocator()), allocator);
}

/// Leaves out GlobalConfig.running_fields, which the app changes and the form never does.
fn editableJson(arena: std.mem.Allocator, settings: *GlobalConfig) ![]const u8 {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, arena, try settings.toJsonString(arena), .{});
    if (value != .object) return error.InvalidGlobalSettings;
    inline for (GlobalConfig.running_fields) |name| _ = value.object.orderedRemove(name);
    return std.json.Stringify.valueAlloc(arena, value, .{});
}
