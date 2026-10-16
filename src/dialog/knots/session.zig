//! What the knots configuration window edits: the running profile's `live` copy and a draft of the global settings, changed only through `Ref`'s setters; main thread only.
const std = @import("std");
const config = @import("../../config.zig");
const registry = @import("../../protocol/registry.zig");
const app_mod = @import("../../app.zig");
const patch = @import("../../config/patch.zig");
const run_on_startup = @import("../run_on_startup.zig");
const field_strings = @import("field_strings.zig");
const log = @import("../../log.zig");

const App = app_mod.App;
const Config = config.Config;
const GlobalConfig = config.GlobalConfig;
const ListItem = field_strings.ListItem;
const fieldDefault = field_strings.fieldDefault;
const slog = log.Scoped("dialog_knots");

pub const Doc = enum { profile, global };

const Retired = struct { allocator: std.mem.Allocator, bytes: []const u8 };

/// Set once by init; outlives the window.
var g_app: ?*App = null;
var g_allocator: std.mem.Allocator = undefined;
/// Set while the window is open, from begin to end.
var g_global_draft: ?GlobalConfig = null;
/// Replaced strings, freed at the start of the next frame since this one may still be drawing them. Owned.
var g_retired: std.ArrayList(Retired) = .empty;
var g_is_dirty_stale: bool = true;
var g_is_profile_dirty: bool = false;
var g_is_global_dirty: bool = false;
/// Set by any edit, since one made after the widgets showing it were drawn needs another frame to appear.
var g_edited_this_frame: bool = false;

/// A struct inside one of the documents, edited field by field.
pub fn Ref(comptime T: type) type {
    return struct {
        doc: Doc,
        ptr: *T,
        /// What the thumbnails need after an edit.
        layout: app_mod.LiveLayout,
        /// Which item of a list this is, so its widgets' keys differ from its siblings'.
        index: usize = 0,

        const Self = @This();

        pub fn get(self: Self, comptime field: []const u8) @FieldType(T, field) {
            return @field(self.ptr, field);
        }

        /// Stores `value` (copying strings), clamps the document and previews it.
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

        /// `set` for several non-string fields, previewed once so thumbnails never lay out a half-applied change; `values` is e.g. `.{ .width = w, .height = h }`.
        pub fn setFields(self: Self, values: anytype) void {
            var layout: app_mod.LiveLayout = .none;
            var is_changed = false;
            inline for (@typeInfo(@TypeOf(values)).@"struct".field_names) |field| {
                const F = @FieldType(T, field);
                if (F == []const u8 or F == ?[]const u8) @compileError("setFields doesn't copy strings; use set for '" ++ field ++ "'");
                const value: F = @field(values, field);
                const slot = &@field(self.ptr, field);
                if (!std.meta.eql(slot.*, value)) {
                    slot.* = value;
                    is_changed = true;
                    layout = wider(layout, comptime layoutFor(T, field, .none));
                }
            }
            if (is_changed) edited(self.doc, layout, self.layout);
        }

        /// A nested section, e.g. `profile().child("thumbnail")`.
        pub fn child(self: Self, comptime field: []const u8) Ref(@FieldType(T, field)) {
            return .{ .doc = self.doc, .ptr = &@field(self.ptr, field), .layout = comptime layoutFor(T, field, .none), .index = self.index };
        }

        /// Item `index` of the list field `field`, e.g. `profile().item("characters", 2)`.
        pub fn item(self: Self, comptime field: []const u8, index: usize) Ref(ListItem(@FieldType(T, field))) {
            return .{ .doc = self.doc, .ptr = &@field(self.ptr, field).items[index], .layout = comptime layoutFor(T, field, .none), .index = index };
        }

        /// Appends a copy of `value`; null once it has logged a failure.
        pub fn append(self: Self, comptime field: []const u8, value: ListItem(@FieldType(T, field))) ?Ref(ListItem(@FieldType(T, field))) {
            const allocator = documentAllocator(self.doc);
            const list = &@field(self.ptr, field);
            var entry = value;
            // Copied, since a later set frees the string it replaces.
            field_strings.ownStrings(@TypeOf(entry), allocator, &entry) catch |err| {
                slog.err("Failed to add to '{s}': {}", .{ field, err });
                return null;
            };
            list.append(allocator, entry) catch |err| {
                slog.err("Failed to add to '{s}': {}", .{ field, err });
                field_strings.freeOwnedStrings(@TypeOf(entry), allocator, &entry);
                return null;
            };
            // Characters and hotkey groups are tracked by id, e.g. to keep a selection across a reorder.
            if (self.doc == .profile) patch.assignIds(config.Config, profile().ptr);
            edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
            return self.item(field, list.items.len - 1);
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

/// At startup, before anything else here; `app` outlives every window.
pub fn init(app: *App) void {
    g_app = app;
    g_allocator = app.allocator;
}

/// What the window edits and previews into; only after init, which host.init runs at startup.
pub fn runningApp() *App {
    return g_app orelse unreachable;
}

/// Starts over from what's saved; called as the window opens.
pub fn begin() !void {
    g_global_draft = try cloneGlobal(g_allocator, &runningApp().global_settings);
    g_is_dirty_stale = true;
}

/// Drops unsaved edits; called once the window has closed.
pub fn end() void {
    freeRetired();
    g_retired.deinit(g_allocator);
    g_retired = .empty;
    if (g_global_draft) |*draft| draft.deinit();
    g_global_draft = null;
    log.setLevel(runningApp().global_settings.logLevel);
    dropProfileEdits();
}

/// Call at the start of every frame.
pub fn beginFrame() void {
    freeRetired();
}

/// The running profile, edited and previewed live.
pub fn profile() Ref(Config) {
    return .{ .doc = .profile, .ptr = &runningApp().store.live, .layout = .none };
}

/// Whether the edited profile shows thumbnails, which decides where thumbnail-only settings are offered.
pub fn showsThumbnails() bool {
    return profile().ptr.display.viewMode == .Thumbnails;
}

/// After the running profile was replaced, e.g. by a profile switch, so isDirty compares it again.
pub fn profileReplaced() void {
    g_is_dirty_stale = true;
}

/// The global settings as the window has them, saved or not; the running ones while it's closed.
pub fn liveGlobal() *const GlobalConfig {
    if (g_global_draft) |*draft| return draft;
    return &runningApp().global_settings;
}

/// Only while the window is open, between begin and end.
pub fn global() Ref(GlobalConfig) {
    if (g_global_draft) |*draft| return .{ .doc = .global, .ptr = draft, .layout = .none };
    unreachable;
}

pub fn isDirty() bool {
    refreshDirty();
    return g_is_profile_dirty or g_is_global_dirty;
}

/// Restarts subsystems, so only between frames.
pub fn save() !void {
    refreshDirty();
    slog.info("Saving configuration (profile dirty: {}, global dirty: {})", .{ g_is_profile_dirty, g_is_global_dirty });
    const global_draft: ?*GlobalConfig = if (!g_is_global_dirty) null else if (g_global_draft) |*draft| draft else null;
    if (g_is_profile_dirty) try runningApp().store.commit();
    if (g_is_profile_dirty or global_draft != null) try runningApp().applySavedSettings(global_draft);
    if (global_draft != null) {
        try resetGlobalDraft();
        const settings = &runningApp().global_settings;
        try settings.save(runningApp().io);
        log.setLevel(settings.logLevel);
        if (settings.logLevel == .debug) log.openDebugConsole() else log.closeDebugConsole();
        run_on_startup.apply(settings.runOnStartup);
        if (settings.autoRegisterProtocol) registry.ensureRegistered();
    }
    g_is_dirty_stale = true;
}

/// Replaces the documents, so only between frames.
pub fn discard() !void {
    dropProfileEdits();
    try resetGlobalDraft();
    log.setLevel(runningApp().global_settings.logLevel);
    g_is_dirty_stale = true;
}

/// Patch ops on the edited profile, e.g. an import's; `arena` holds what they allocate.
pub fn applyOps(arena: std.mem.Allocator, ops: []const patch.Op) !void {
    const target = profile().ptr;
    const patch_context: patch.Context = .{ .arena = arena, .allocator = target.allocator };
    // Even after a failed op, since those before it were applied.
    defer {
        // A list set whole comes in without ids.
        patch.assignIds(config.Config, target);
        edited(.profile, .all, .none);
    }
    for (ops) |op| _ = try patch.apply(config.Config, target, op, patch_context);
}

/// Whether anything was edited since the last call, so the frame should be drawn again.
pub fn takeEdited() bool {
    defer g_edited_this_frame = false;
    return g_edited_this_frame;
}

fn edited(doc: Doc, field_layout: app_mod.LiveLayout, ref_layout: app_mod.LiveLayout) void {
    g_is_dirty_stale = true;
    g_edited_this_frame = true;
    switch (doc) {
        .profile => {
            runningApp().store.live.validate();
            runningApp().onLiveProfileEdited(wider(field_layout, ref_layout));
        },
        .global => {
            const draft = if (g_global_draft) |*open| open else {
                slog.err("Failed to apply a global setting: the configuration window isn't open", .{});
                return;
            };
            draft.validate();
            log.setLevel(draft.logLevel);
        },
    }
}

fn dropProfileEdits() void {
    const store = &runningApp().store;
    if (!store.isDirty()) return;
    slog.info("Dropping unsaved edits to the running profile", .{});
    store.discard() catch |err| {
        slog.err("Failed to drop unsaved edits to the running profile: {}", .{err});
        return;
    };
    runningApp().onLiveProfileEdited(.all);
}

fn resetGlobalDraft() !void {
    const fresh = try cloneGlobal(g_allocator, &runningApp().global_settings);
    if (g_global_draft) |*draft| draft.deinit();
    g_global_draft = fresh;
}

/// Serializes both documents, so it runs at most once per frame that edited something.
fn refreshDirty() void {
    if (!g_is_dirty_stale) return;
    g_is_dirty_stale = false;
    g_is_profile_dirty = runningApp().store.isDirty();
    g_is_global_dirty = isGlobalDirty() catch |err| blk: {
        slog.err("Failed to compare the edited global settings with the saved ones: {}", .{err});
        break :blk true;
    };
}

fn isGlobalDirty() !bool {
    const draft = if (g_global_draft) |*open| open else return false;
    var arena_state = std.heap.ArenaAllocator.init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return !std.mem.eql(u8, try editableJson(arena, draft), try editableJson(arena, &runningApp().global_settings));
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
        // cloneGlobal builds the draft with it.
        .global => g_allocator,
    };
}

fn retireString(allocator: std.mem.Allocator, bytes: []const u8, default: []const u8) void {
    if (!field_strings.isOwned(bytes, default)) return;
    g_retired.append(g_allocator, .{ .allocator = allocator, .bytes = bytes }) catch |err| {
        slog.warn("Failed to queue a replaced setting for freeing, leaking it: {}", .{err});
    };
}

fn freeRetired() void {
    for (g_retired.items) |retired| retired.allocator.free(retired.bytes);
    g_retired.clearRetainingCapacity();
}

/// What an edit to `field` re-lays out: display and spaces everything; thumbnail size and member lists the spaces.
fn layoutFor(comptime T: type, comptime field: []const u8, comptime inherited: app_mod.LiveLayout) app_mod.LiveLayout {
    if (T == Config) {
        if (std.mem.eql(u8, field, "display") or std.mem.eql(u8, field, "thumbnailSpaces")) return .all;
        if (std.mem.eql(u8, field, "characters") or std.mem.eql(u8, field, "hotkeyGroups")) return .spaces;
    }
    if (T == config.ThumbnailConfig and (std.mem.eql(u8, field, "width") or std.mem.eql(u8, field, "height"))) return .spaces;
    return inherited;
}

/// LiveLayout's tags run from narrowest to widest.
fn wider(a: app_mod.LiveLayout, b: app_mod.LiveLayout) app_mod.LiveLayout {
    return @fromBackingInt(@intCast(@max(@backingInt(a), @backingInt(b))));
}
