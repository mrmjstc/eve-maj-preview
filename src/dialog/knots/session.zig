//! What the knots configuration window edits: the running profile's `live` copy, or a draft of another profile, and a draft of the global settings, changed only through `Ref.set`; main thread only.
const std = @import("std");
const config = @import("../../config.zig");
const protocol = @import("../../protocol.zig");
const main = @import("../../main.zig");
const patch = @import("../../config/patch.zig");
const run_on_startup = @import("../run_on_startup.zig");
const log = @import("../../log.zig");

const Config = config.Config;
const GlobalConfig = config.GlobalConfig;
const slog = log.scoped("dialog_knots");

pub const Doc = enum { profile, global };

const Retired = struct { allocator: std.mem.Allocator, bytes: []const u8 };

var g_allocator: std.mem.Allocator = undefined;
var g_global_draft: ?GlobalConfig = null;
/// Another profile than the running one, edited without previewing; its own allocations are freed in dropDraft.
var g_profile_draft: ?Config = null;
/// The draft as loaded, to tell whether it has unsaved edits. Owned; freed in dropDraft.
var g_profile_draft_json: ?[]u8 = null;
/// Replaced strings, freed at the start of the next frame since this one may still be drawing them. Owned.
var g_retired: std.ArrayList(Retired) = .empty;
var g_dirty_stale: bool = true;
var g_profile_dirty: bool = false;
var g_global_dirty: bool = false;
/// Set by any edit, since one made after the widgets showing it were drawn needs another frame to appear.
var g_edited_this_frame: bool = false;

/// A struct inside one of the documents, edited field by field.
pub fn Ref(comptime T: type) type {
    return struct {
        doc: Doc,
        ptr: *T,
        /// What the thumbnails need after an edit.
        layout: main.LiveLayout,
        /// Which item of a list this is, so its widgets' keys differ from its siblings'.
        index: usize = 0,

        const Self = @This();

        pub fn get(self: Self, comptime field: []const u8) @FieldType(T, field) {
            return @field(self.ptr, field);
        }

        /// The only way the window changes a setting: stores `value` (copying strings), clamps the document and previews it.
        pub fn set(self: Self, comptime field: []const u8, value: @FieldType(T, field)) void {
            const F = @FieldType(T, field);
            const slot = &@field(self.ptr, field);
            if (F == []const u8 or F == ?[]const u8) {
                const allocator = documentAllocator(self.doc);
                const owned: F = if (F == []const u8)
                    allocator.dupe(u8, value) catch |err| {
                        slog.err("Failed to store setting '{s}': {}", .{ field, err });
                        return;
                    }
                else if (value) |text| allocator.dupe(u8, text) catch |err| {
                    slog.err("Failed to store setting '{s}': {}", .{ field, err });
                    return;
                } else null;
                retireString(allocator, if (F == []const u8) slot.* else slot.* orelse "", fieldDefault(T, field));
                slot.* = owned;
            } else {
                if (std.meta.eql(slot.*, value)) return;
                slot.* = value;
            }
            edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// A nested section, e.g. `profile().child("thumbnail")`.
        pub fn child(self: Self, comptime field: []const u8) Ref(@FieldType(T, field)) {
            return .{ .doc = self.doc, .ptr = &@field(self.ptr, field), .layout = comptime layoutFor(T, field, .none), .index = self.index };
        }

        /// Item `index` of the list field `field`, e.g. `profile().item("characters", 2)`.
        pub fn item(self: Self, comptime field: []const u8, index: usize) Ref(ListItem(@FieldType(T, field))) {
            return .{ .doc = self.doc, .ptr = &@field(self.ptr, field).items[index], .layout = comptime layoutFor(T, field, .none), .index = index };
        }

        /// Adds `value` to the end of the list field `field`; its strings must be literals, as set copies any it's given later.
        pub fn append(self: Self, comptime field: []const u8, value: ListItem(@FieldType(T, field))) void {
            const list = &@field(self.ptr, field);
            list.append(documentAllocator(self.doc), value) catch |err| {
                slog.err("Failed to add to '{s}': {}", .{ field, err });
                return;
            };
            edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// Removes item `index` of the list field `field`, freeing its strings once this frame has drawn.
        pub fn remove(self: Self, comptime field: []const u8, index: usize) void {
            const Item = ListItem(@FieldType(T, field));
            const list = &@field(self.ptr, field);
            if (index >= list.items.len) return;
            const removed = list.orderedRemove(index);
            const allocator = documentAllocator(self.doc);
            if (Item == []const u8) {
                retireString(allocator, removed, "");
            } else {
                const info = @typeInfo(Item).@"struct";
                inline for (info.field_names, info.field_types) |name, F| {
                    if (F == []const u8) retireString(allocator, @field(removed, name), fieldDefault(Item, name));
                    if (F == ?[]const u8) {
                        if (@field(removed, name)) |text| retireString(allocator, text, fieldDefault(Item, name));
                    }
                    // A string list's strings may still be drawn this frame, but nothing reads the list itself again.
                    if (F == std.ArrayList([]const u8)) {
                        var strings = @field(removed, name);
                        for (strings.items) |text| retireString(allocator, text, "");
                        strings.deinit(allocator);
                    }
                }
            }
            edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// Moves item `from` of the list field `field` to sit before what was item `before` (the length for the end).
        pub fn move(self: Self, comptime field: []const u8, from: usize, before: usize) void {
            const list = &@field(self.ptr, field);
            if (from >= list.items.len or before > list.items.len or before == from or before == from + 1) return;
            const item_value = list.orderedRemove(from);
            const at = if (before > from) before - 1 else before;
            list.insertAssumeCapacity(at, item_value);
            edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// Adds a copy of `value` to the end of the string list `field`.
        pub fn appendString(self: Self, comptime field: []const u8, value: []const u8) void {
            const allocator = documentAllocator(self.doc);
            const owned = allocator.dupe(u8, value) catch |err| {
                slog.err("Failed to add to '{s}': {}", .{ field, err });
                return;
            };
            @field(self.ptr, field).append(allocator, owned) catch |err| {
                slog.err("Failed to add to '{s}': {}", .{ field, err });
                allocator.free(owned);
                return;
            };
            edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// Replaces entry `index` of the string list `field` with a copy of `value`.
        pub fn setStringAt(self: Self, comptime field: []const u8, index: usize, value: []const u8) void {
            const list = &@field(self.ptr, field);
            if (index >= list.items.len or std.mem.eql(u8, list.items[index], value)) return;
            const allocator = documentAllocator(self.doc);
            const owned = allocator.dupe(u8, value) catch |err| {
                slog.err("Failed to store an entry of '{s}': {}", .{ field, err });
                return;
            };
            retireString(allocator, list.items[index], "");
            list.items[index] = owned;
            edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// Replaces the whole string list `field` with copies of `values`.
        pub fn setStrings(self: Self, comptime field: []const u8, values: []const []const u8) void {
            const list = &@field(self.ptr, field);
            if (list.items.len == values.len) {
                for (list.items, values) |old, new| {
                    if (!std.mem.eql(u8, old, new)) break;
                } else return;
            }
            const allocator = documentAllocator(self.doc);
            var replacement: std.ArrayList([]const u8) = .empty;
            for (values) |value| {
                const owned = allocator.dupe(u8, value) catch |err| {
                    slog.err("Failed to store '{s}': {}", .{ field, err });
                    for (replacement.items) |copy| allocator.free(copy);
                    replacement.deinit(allocator);
                    return;
                };
                replacement.append(allocator, owned) catch |err| {
                    slog.err("Failed to store '{s}': {}", .{ field, err });
                    allocator.free(owned);
                    for (replacement.items) |copy| allocator.free(copy);
                    replacement.deinit(allocator);
                    return;
                };
            }
            for (list.items) |old| retireString(allocator, old, "");
            list.deinit(allocator);
            list.* = replacement;
            edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }
    };
}

/// Starts over from what's saved; called as the window opens.
pub fn begin(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;
    g_global_draft = try cloneGlobal(allocator, &main.g_global_settings);
    g_dirty_stale = true;
}

/// Drops unsaved edits; called once the window has closed.
pub fn end() void {
    freeRetired();
    g_retired.deinit(g_allocator);
    g_retired = .empty;
    if (g_global_draft) |*draft| draft.deinit();
    g_global_draft = null;
    log.setLevel(main.g_global_settings.logLevel);
    dropDraft();
    dropProfileEdits();
}

/// Call at the start of every frame.
pub fn beginFrame() void {
    freeRetired();
}

/// The draft while one is open, otherwise the running profile.
pub fn profile() Ref(Config) {
    if (g_profile_draft) |*draft| return .{ .doc = .profile, .ptr = draft, .layout = .none };
    return .{ .doc = .profile, .ptr = &main.g_store.live, .layout = .none };
}

pub fn editsDraft() bool {
    return g_profile_draft != null;
}

/// Edits `name` (a profile file name) from now on, dropping unsaved edits to the one edited so far; between frames only.
pub fn editProfile(name: []const u8) !void {
    dropDraft();
    dropProfileEdits();
    g_dirty_stale = true;
    if (std.mem.eql(u8, name, main.g_store.live.profile_name)) return;
    var draft = try config.loadProfile(g_allocator, name);
    errdefer draft.deinit();
    g_profile_draft_json = try draft.toJsonString(g_allocator);
    g_profile_draft = draft;
}

pub fn global() Ref(GlobalConfig) {
    return .{ .doc = .global, .ptr = &g_global_draft.?, .layout = .none };
}

pub fn isDirty() bool {
    refreshDirty();
    return g_profile_dirty or g_global_dirty;
}

/// Restarts subsystems, so only between frames. Saving a draft also makes it the running profile.
pub fn save() !void {
    refreshDirty();
    slog.info("Saving configuration (profile dirty: {}, global dirty: {})", .{ g_profile_dirty, g_global_dirty });
    const global_draft: ?*GlobalConfig = if (g_global_dirty) &g_global_draft.? else null;
    if (g_profile_draft) |*draft| {
        if (g_profile_dirty) {
            var arena_state = std.heap.ArenaAllocator.init(g_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            try config.saveProfile(draft, arena, try config.profilePath(arena, draft.profile_name));
            const name = try arena.dupe(u8, draft.profile_name);
            dropDraft();
            try main.switchToSavedProfile(name, global_draft);
        } else if (global_draft != null) {
            try main.applySavedSettings(global_draft);
        }
    } else {
        if (g_profile_dirty) try main.g_store.commit();
        if (g_profile_dirty or global_draft != null) try main.applySavedSettings(global_draft);
    }
    if (global_draft != null) {
        try resetGlobalDraft();
        const settings = &main.g_global_settings;
        try settings.save();
        log.setLevel(settings.logLevel);
        if (settings.logLevel == .debug) log.openDebugConsole() else log.closeDebugConsole();
        run_on_startup.apply(settings.runOnStartup);
        if (settings.autoRegisterProtocol) protocol.ensureRegistered(g_allocator);
    }
    g_dirty_stale = true;
}

/// Replaces the documents, so only between frames.
pub fn discard() !void {
    if (g_profile_draft) |*draft| {
        // Copied, since reopening the draft frees the name it holds.
        const name = try g_allocator.dupe(u8, draft.profile_name);
        defer g_allocator.free(name);
        try editProfile(name);
    } else {
        dropProfileEdits();
    }
    try resetGlobalDraft();
    log.setLevel(main.g_global_settings.logLevel);
    g_dirty_stale = true;
}

/// Edit ops (see config/patch.zig) on the profile being edited, e.g. an import's; `arena` holds what they allocate along the way.
pub fn applyOps(arena: std.mem.Allocator, ops: []const patch.Op) !void {
    const target = profile().ptr;
    const ctx: patch.Context = .{ .arena = arena, .allocator = target.allocator };
    // Even after a failed op, since those before it were applied.
    defer edited(.profile, .all, .none);
    for (ops) |op| _ = try patch.apply(config.Config, target, op, ctx);
}

/// After a draft was changed without Ref.set, e.g. by config.applyWindowPosition.
pub fn editedOutside() void {
    edited(.profile, .none, .none);
}

/// Whether anything was edited since the last call, so the frame should be drawn again.
pub fn takeEdited() bool {
    defer g_edited_this_frame = false;
    return g_edited_this_frame;
}

fn edited(doc: Doc, field_layout: main.LiveLayout, ref_layout: main.LiveLayout) void {
    g_dirty_stale = true;
    g_edited_this_frame = true;
    switch (doc) {
        .profile => if (g_profile_draft) |*draft| {
            draft.validate();
        } else {
            main.g_store.live.validate();
            main.onLiveProfileEdited(wider(field_layout, ref_layout));
        },
        .global => {
            const draft = &g_global_draft.?;
            draft.validate();
            log.setLevel(draft.logLevel);
        },
    }
}

fn dropProfileEdits() void {
    const store = &main.g_store;
    if (!store.isDirty()) return;
    slog.info("Dropping unsaved edits to the running profile", .{});
    store.discard() catch |err| {
        slog.err("Failed to drop unsaved edits to the running profile: {}", .{err});
        return;
    };
    main.onLiveProfileEdited(.all);
}

fn dropDraft() void {
    if (g_profile_draft) |*draft| draft.deinit();
    g_profile_draft = null;
    if (g_profile_draft_json) |json| g_allocator.free(json);
    g_profile_draft_json = null;
}

fn resetGlobalDraft() !void {
    const fresh = try cloneGlobal(g_allocator, &main.g_global_settings);
    if (g_global_draft) |*draft| draft.deinit();
    g_global_draft = fresh;
}

/// Serializes both documents, so it runs at most once per frame that edited something.
fn refreshDirty() void {
    if (!g_dirty_stale) return;
    g_dirty_stale = false;
    g_profile_dirty = profileDirty() catch |err| blk: {
        slog.err("Failed to compare the edited profile with the saved one: {}", .{err});
        break :blk true;
    };
    g_global_dirty = globalDirty() catch |err| blk: {
        slog.err("Failed to compare the edited global settings with the saved ones: {}", .{err});
        break :blk true;
    };
}

fn profileDirty() !bool {
    const draft = &(g_profile_draft orelse return main.g_store.isDirty());
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    return !std.mem.eql(u8, try draft.toJsonString(arena_state.allocator()), g_profile_draft_json.?);
}

fn globalDirty() !bool {
    const draft = &(g_global_draft orelse return false);
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return !std.mem.eql(u8, try editableJson(arena, draft), try editableJson(arena, &main.g_global_settings));
}

/// Leaves out GlobalConfig.running_fields, which the app changes and the form never does.
fn editableJson(arena: std.mem.Allocator, settings: *GlobalConfig) ![]const u8 {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, arena, try settings.toJsonString(arena), .{});
    if (value != .object) return error.InvalidGlobalSettings;
    inline for (GlobalConfig.running_fields) |name| _ = value.object.orderedRemove(name);
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

fn cloneGlobal(allocator: std.mem.Allocator, settings: *GlobalConfig) !GlobalConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return GlobalConfig.fromWire(try settings.toWire(arena.allocator()), allocator);
}

fn documentAllocator(doc: Doc) std.mem.Allocator {
    return switch (doc) {
        .profile => profile().ptr.allocator,
        .global => g_global_draft.?.allocator,
    };
}

fn retireString(allocator: std.mem.Allocator, bytes: []const u8, default: []const u8) void {
    // A field still holding its default points at a string literal.
    if (bytes.len == 0 or bytes.ptr == default.ptr) return;
    g_retired.append(g_allocator, .{ .allocator = allocator, .bytes = bytes }) catch |err| {
        slog.warn("Failed to queue a replaced setting for freeing, leaking it: {}", .{err});
    };
}

fn freeRetired() void {
    for (g_retired.items) |retired| retired.allocator.free(retired.bytes);
    g_retired.clearRetainingCapacity();
}

fn fieldDefault(comptime T: type, comptime field: []const u8) []const u8 {
    const F = @FieldType(T, field);
    const index = std.meta.fieldIndex(T, field).?;
    const default = @typeInfo(T).@"struct".field_attrs[index].defaultValue(F) orelse return "";
    return if (F == ?[]const u8) default orelse "" else default;
}

fn ListItem(comptime List: type) type {
    return @typeInfo(@FieldType(List, "items")).pointer.child;
}

/// Display settings place every thumbnail; the thumbnail size shapes the Thumbnail Spaces; the character and hotkey group lists only rank them there.
fn layoutFor(comptime T: type, comptime field: []const u8, comptime inherited: main.LiveLayout) main.LiveLayout {
    if (T == Config) {
        if (std.mem.eql(u8, field, "display")) return .all;
        if (std.mem.eql(u8, field, "characters") or std.mem.eql(u8, field, "hotkeyGroups")) return .region_fit;
    }
    if (T == config.ThumbnailConfig and (std.mem.eql(u8, field, "width") or std.mem.eql(u8, field, "height"))) return .thumbnail_spaces;
    return inherited;
}

/// LiveLayout's tags run from narrowest to widest.
fn wider(a: main.LiveLayout, b: main.LiveLayout) main.LiveLayout {
    return @fromBackingInt(@intCast(@max(@backingInt(a), @backingInt(b))));
}
