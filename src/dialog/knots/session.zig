//! What the knots configuration window edits: the running profile's `live` copy and a draft of the global settings, changed only through `Ref`'s setters; main thread only.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const patch = @import("../../config/patch.zig");
const field_strings = @import("../../config/field_strings.zig");
const set = @import("../../thumbnail/set.zig");
const dialog_host = @import("../dialog_host.zig");
const notifier_mod = @import("../../notifications/notifier.zig");
const reorder_math = @import("reorder_math.zig");
const log = @import("../../log.zig");

const Config = config.Config;
const GlobalConfig = config.GlobalConfig;
const ThumbnailSet = set.ThumbnailSet;
const LiveLayout = dialog_host.LiveLayout;
const ListItem = field_strings.ListItem;
const fieldDefault = field_strings.fieldDefault;
const slog = log.Scoped("dialog_knots");

pub const Doc = enum { profile, global };

const Retired = struct { allocator: std.mem.Allocator, bytes: []const u8 };

pub const Session = struct {
    /// What it borrows outlives the window.
    context: dialog_host.Context,
    app_host: dialog_host.Host,
    /// Set while the window is open, from begin to end.
    global_draft: ?GlobalConfig = null,
    /// Replaced strings, freed at the start of the next frame since this one may still be drawing them; owned.
    retired: std.ArrayList(Retired) = .empty,
    is_dirty_stale: bool = true,
    is_profile_dirty: bool = false,
    is_global_dirty: bool = false,
    /// Set by a failed Save with global changes and cleared by the next that succeeds, since the running settings may match the draft yet not be on disk.
    is_global_save_pending: bool = false,
    /// Set by any edit, since one made after the widgets showing it were drawn needs another frame to appear.
    edited_this_frame: bool = false,

    pub fn init(app_context: dialog_host.Context, app_host: dialog_host.Host) Session {
        return .{ .context = app_context, .app_host = app_host };
    }

    /// What the window edits and previews into.
    pub fn appContext(self: *const Session) dialog_host.Context {
        return self.context;
    }

    /// Null while a rebuild failed; read each time, as it's rebuilt.
    pub fn thumbnailSet(self: *const Session) ?*ThumbnailSet {
        return self.appHost().thumbnail_set();
    }

    /// Null outside the run.
    pub fn notifier(self: *const Session) ?notifier_mod.Notifier {
        return self.appHost().notifier();
    }

    /// The hidden window commands are posted to; null until main.zig creates it.
    pub fn timerWindow(self: *const Session) ?win32.HWND {
        return self.appHost().timer_window();
    }

    pub fn run(self: *const Session, request: dialog_host.Request) void {
        self.appHost().run(request);
    }

    /// Starts over from what's saved; called as the window opens.
    pub fn begin(self: *Session) !void {
        self.global_draft = try self.appContext().global_settings.clone(self.context.allocator);
        self.is_dirty_stale = true;
    }

    /// Drops unsaved edits; called once the window has closed.
    pub fn end(self: *Session) void {
        self.freeRetired();
        self.retired.deinit(self.context.allocator);
        self.retired = .empty;
        if (self.global_draft) |*draft| draft.deinit();
        self.global_draft = null;
        log.setLevel(self.appContext().global_settings.logLevel);
        self.dropProfileEdits();
    }

    /// Call at the start of every frame.
    pub fn beginFrame(self: *Session) void {
        self.freeRetired();
    }

    /// The running profile, edited and previewed live.
    pub fn profile(self: *Session) Ref(Config) {
        return .{ .session = self, .doc = .profile, .ptr = &self.appContext().store.live, .layout = .none };
    }

    /// Whether the edited profile shows thumbnails, which decides where thumbnail-only settings are offered.
    pub fn showsThumbnails(self: *Session) bool {
        return self.profile().ptr.display.viewMode.showsThumbnails();
    }

    /// After the running profile was replaced, e.g. by a profile switch, so isDirty compares it again.
    pub fn profileReplaced(self: *Session) void {
        self.is_dirty_stale = true;
    }

    /// The global settings as the window has them, saved or not; the running ones while it's closed.
    pub fn liveGlobal(self: *const Session) *const GlobalConfig {
        if (self.global_draft) |*draft| return draft;
        return self.appContext().global_settings;
    }

    /// Only while the window is open, between begin and end.
    pub fn global(self: *Session) Ref(GlobalConfig) {
        if (self.global_draft) |*draft| return .{ .session = self, .doc = .global, .ptr = draft, .layout = .none };
        unreachable;
    }

    /// After profile `old_name` was renamed `new_name`: the draft's switch hotkeys follow it, as the running settings' did.
    pub fn retargetProfileSwitches(self: *Session, old_name: []const u8, new_name: []const u8) void {
        if (self.global_draft == null) return;
        const settings = self.global();
        for (settings.ptr.profileSwitchHotkeys.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.targetProfile, old_name)) settings.item("profileSwitchHotkeys", index).set("targetProfile", new_name);
        }
    }

    pub fn isDirty(self: *Session) bool {
        self.refreshDirty();
        return self.is_profile_dirty or self.is_global_dirty;
    }

    /// Restarts subsystems, so only between frames.
    pub fn save(self: *Session) !void {
        self.refreshDirty();
        slog.info("Saving configuration (profile dirty: {}, global dirty: {})", .{ self.is_profile_dirty, self.is_global_dirty });
        const global_draft: ?*const GlobalConfig = if (!self.is_global_dirty) null else if (self.global_draft) |*draft| draft else null;
        errdefer {
            if (global_draft != null) self.is_global_save_pending = true;
            self.is_dirty_stale = true;
        }
        try self.appHost().save(.{ .is_profile_dirty = self.is_profile_dirty, .global_draft = global_draft });
        if (global_draft != null) {
            try self.resetGlobalDraft();
            self.is_global_save_pending = false;
        }
        self.is_dirty_stale = true;
    }

    /// Replaces the documents, so only between frames.
    pub fn discard(self: *Session) !void {
        self.dropProfileEdits();
        try self.resetGlobalDraft();
        log.setLevel(self.appContext().global_settings.logLevel);
        self.is_dirty_stale = true;
    }

    /// Patch ops on the edited profile, e.g. an import's; `arena` holds what they allocate.
    pub fn applyOps(self: *Session, arena: std.mem.Allocator, ops: []const patch.Op) !void {
        const target = self.profile().ptr;
        const ids = &self.appContext().store.ids;
        const patch_context: patch.Context = .{ .arena = arena, .allocator = target.allocator, .ids = ids };
        // Even after a failed op, since those before it were applied.
        defer {
            // A list set whole comes in without ids.
            patch.assignIds(config.Config, target, ids);
            self.edited(.profile, .all, .none);
        }
        for (ops) |op| _ = try patch.apply(config.Config, target, op, patch_context);
    }

    /// Patch ops on the global settings' draft, e.g. an import's Log Monitoring.
    pub fn applyGlobalOps(self: *Session, arena: std.mem.Allocator, ops: []const patch.Op) !void {
        if (ops.len == 0) return;
        const target = self.global().ptr;
        const patch_context: patch.Context = .{ .arena = arena, .allocator = target.allocator, .ids = &self.appContext().store.ids };
        // Even after a failed op, since those before it were applied.
        defer self.edited(.global, .none, .none);
        for (ops) |op| _ = try patch.apply(GlobalConfig, target, op, patch_context);
    }

    /// Whether anything was edited since the last call, so the frame should be drawn again.
    pub fn takeEdited(self: *Session) bool {
        defer self.edited_this_frame = false;
        return self.edited_this_frame;
    }

    fn edited(self: *Session, doc: Doc, field_layout: LiveLayout, ref_layout: LiveLayout) void {
        self.is_dirty_stale = true;
        self.edited_this_frame = true;
        switch (doc) {
            .profile => {
                self.appContext().store.live.validate();
                self.run(.{ .live_profile_edited = wider(field_layout, ref_layout) });
            },
            .global => {
                const draft = if (self.global_draft) |*open| open else {
                    slog.err("Failed to apply a global setting: the configuration window isn't open", .{});
                    return;
                };
                draft.validate();
                log.setLevel(draft.logLevel);
            },
        }
    }

    fn dropProfileEdits(self: *const Session) void {
        const store = self.appContext().store;
        if (!store.isDirty()) return;
        slog.info("Dropping unsaved edits to the running profile", .{});
        store.discard() catch |err| {
            slog.err("Failed to drop unsaved edits to the running profile: {}", .{err});
            return;
        };
        self.run(.{ .live_profile_edited = .all });
    }

    fn appHost(self: *const Session) dialog_host.Host {
        return self.app_host;
    }

    fn resetGlobalDraft(self: *Session) !void {
        const fresh = try self.appContext().global_settings.clone(self.context.allocator);
        if (self.global_draft) |*draft| draft.deinit();
        self.global_draft = fresh;
    }

    /// Serializes both documents, so it runs at most once per frame that edited something.
    fn refreshDirty(self: *Session) void {
        if (!self.is_dirty_stale) return;
        self.is_dirty_stale = false;
        self.is_profile_dirty = self.appContext().store.isDirty();
        const is_draft_changed = self.isGlobalDirty() catch |err| blk: {
            slog.err("Failed to compare the edited global settings with the saved ones: {}", .{err});
            break :blk true;
        };
        self.is_global_dirty = self.is_global_save_pending or is_draft_changed;
    }

    fn isGlobalDirty(self: *const Session) !bool {
        const draft = if (self.global_draft) |*open| open else return false;
        var arena_state: std.heap.ArenaAllocator = .init(self.context.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        return !std.mem.eql(u8, try editableJson(arena, draft), try editableJson(arena, self.appContext().global_settings));
    }

    fn documentAllocator(self: *Session, doc: Doc) std.mem.Allocator {
        return switch (doc) {
            .profile => self.profile().ptr.allocator,
            // begin clones the draft with it.
            .global => self.context.allocator,
        };
    }

    fn retireString(self: *Session, allocator: std.mem.Allocator, bytes: []const u8, default: []const u8) void {
        if (!field_strings.isOwned(bytes, default)) return;
        self.retired.append(self.context.allocator, .{ .allocator = allocator, .bytes = bytes }) catch |err| {
            slog.warn("Failed to queue a replaced setting for freeing, leaking it: {}", .{err});
        };
    }

    /// In nested sections too.
    fn retireStrings(self: *Session, comptime Item: type, allocator: std.mem.Allocator, value: Item) void {
        const info = @typeInfo(Item).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            if (F == []const u8) self.retireString(allocator, @field(value, name), fieldDefault(Item, name));
            if (F == ?[]const u8) {
                if (@field(value, name)) |text| self.retireString(allocator, text, fieldDefault(Item, name));
            }
            // A string list's strings may still be drawn this frame, but nothing reads the list itself again.
            if (F == std.ArrayList([]const u8)) {
                var strings = @field(value, name);
                for (strings.items) |text| self.retireString(allocator, text, "");
                strings.deinit(allocator);
            }
            if (comptime @typeInfo(F) == .@"struct" and @hasDecl(F, "Wire")) self.retireStrings(F, allocator, @field(value, name));
        }
    }

    fn freeRetired(self: *Session) void {
        for (self.retired.items) |retired| retired.allocator.free(retired.bytes);
        self.retired.clearRetainingCapacity();
    }
};

/// A struct inside one of the documents, edited field by field.
pub fn Ref(comptime T: type) type {
    return struct {
        /// Borrows the session the document belongs to.
        session: *Session,
        doc: Doc,
        ptr: *T,
        /// What the thumbnails need after an edit.
        layout: LiveLayout,
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
                const allocator = self.session.documentAllocator(self.doc);
                const owned: F = if (F == []const u8)
                    allocator.dupe(u8, value) catch |err| {
                        slog.err("Failed to store setting '{s}': {}", .{ field, err });
                        return;
                    }
                else if (value) |text| allocator.dupe(u8, text) catch |err| {
                    slog.err("Failed to store setting '{s}': {}", .{ field, err });
                    return;
                } else null;
                self.session.retireString(allocator, if (F == []const u8) slot.* else slot.* orelse "", fieldDefault(T, field));
                slot.* = owned;
            } else {
                if (std.meta.eql(slot.*, value)) return;
                slot.* = value;
            }
            self.session.edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// `set` for several non-string fields, previewed once so thumbnails never lay out a half-applied change; `values` is e.g. `.{ .width = w, .height = h }`.
        pub fn setFields(self: Self, values: anytype) void {
            var layout: LiveLayout = .none;
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
            if (is_changed) self.session.edited(self.doc, layout, self.layout);
        }

        /// A nested section, e.g. `profile().child("thumbnail")`.
        pub fn child(self: Self, comptime field: []const u8) Ref(@FieldType(T, field)) {
            return .{ .session = self.session, .doc = self.doc, .ptr = &@field(self.ptr, field), .layout = comptime layoutFor(T, field, .none), .index = self.index };
        }

        /// Item `index` of the list field `field`, e.g. `profile().item("characters", 2)`.
        pub fn item(self: Self, comptime field: []const u8, index: usize) Ref(ListItem(@FieldType(T, field))) {
            return .{ .session = self.session, .doc = self.doc, .ptr = &@field(self.ptr, field).items[index], .layout = comptime layoutFor(T, field, .none), .index = index };
        }

        /// Appends a copy of `value`; null once it has logged a failure.
        pub fn append(self: Self, comptime field: []const u8, value: ListItem(@FieldType(T, field))) ?Ref(ListItem(@FieldType(T, field))) {
            const allocator = self.session.documentAllocator(self.doc);
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
            if (self.doc == .profile) patch.assignIds(config.Config, self.session.profile().ptr, &self.session.appContext().store.ids);
            self.session.edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
            return self.item(field, list.items.len - 1);
        }

        /// Removes item `index` of the list field `field`, freeing its strings once this frame has drawn.
        pub fn remove(self: Self, comptime field: []const u8, index: usize) void {
            const Item = ListItem(@FieldType(T, field));
            const list = &@field(self.ptr, field);
            if (index >= list.items.len) return;
            const removed = list.orderedRemove(index);
            const allocator = self.session.documentAllocator(self.doc);
            if (Item == []const u8) self.session.retireString(allocator, removed, "") else self.session.retireStrings(Item, allocator, removed);
            self.session.edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// Moves item `from` of the list field `field` to sit before what was item `before` (the length for the end).
        pub fn move(self: Self, comptime field: []const u8, from: usize, before: usize) void {
            const list = &@field(self.ptr, field);
            if (from >= list.items.len or before > list.items.len or !reorder_math.isMove(from, before)) return;
            const item_value = list.orderedRemove(from);
            list.insertAssumeCapacity(reorder_math.landingIndex(from, before), item_value);
            self.session.edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// Adds a copy of `value` to the end of the string list `field`.
        pub fn appendString(self: Self, comptime field: []const u8, value: []const u8) void {
            const allocator = self.session.documentAllocator(self.doc);
            const owned = allocator.dupe(u8, value) catch |err| {
                slog.err("Failed to add to '{s}': {}", .{ field, err });
                return;
            };
            @field(self.ptr, field).append(allocator, owned) catch |err| {
                slog.err("Failed to add to '{s}': {}", .{ field, err });
                allocator.free(owned);
                return;
            };
            self.session.edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// Replaces entry `index` of the string list `field` with a copy of `value`.
        pub fn setStringAt(self: Self, comptime field: []const u8, index: usize, value: []const u8) void {
            const list = &@field(self.ptr, field);
            if (index >= list.items.len or std.mem.eql(u8, list.items[index], value)) return;
            const allocator = self.session.documentAllocator(self.doc);
            const owned = allocator.dupe(u8, value) catch |err| {
                slog.err("Failed to store an entry of '{s}': {}", .{ field, err });
                return;
            };
            self.session.retireString(allocator, list.items[index], "");
            list.items[index] = owned;
            self.session.edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }

        /// Replaces the whole string list `field` with copies of `values`.
        pub fn setStrings(self: Self, comptime field: []const u8, values: []const []const u8) void {
            const list = &@field(self.ptr, field);
            if (list.items.len == values.len) {
                for (list.items, values) |old, new| {
                    if (!std.mem.eql(u8, old, new)) break;
                } else return;
            }
            const allocator = self.session.documentAllocator(self.doc);
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
            for (list.items) |old| self.session.retireString(allocator, old, "");
            list.deinit(allocator);
            list.* = replacement;
            self.session.edited(self.doc, comptime layoutFor(T, field, .none), self.layout);
        }
    };
}

/// Leaves out GlobalConfig.running_fields, which the app changes and the form never does.
fn editableJson(arena: std.mem.Allocator, settings: *const GlobalConfig) ![]const u8 {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, arena, try settings.toJsonString(arena), .{});
    if (value != .object) return error.InvalidGlobalSettings;
    inline for (GlobalConfig.running_fields) |name| _ = value.object.orderedRemove(name);
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

/// What an edit to `field` re-lays out: display and spaces everything; thumbnail size and member lists the spaces.
fn layoutFor(comptime T: type, comptime field: []const u8, comptime inherited: LiveLayout) LiveLayout {
    if (T == Config) {
        if (std.mem.eql(u8, field, "display") or std.mem.eql(u8, field, "thumbnailSpaces")) return .all;
        if (std.mem.eql(u8, field, "characters") or std.mem.eql(u8, field, "hotkeyGroups")) return .spaces;
    }
    if (T == config.ThumbnailConfig and (std.mem.eql(u8, field, "width") or std.mem.eql(u8, field, "height"))) return .spaces;
    return inherited;
}

/// LiveLayout's tags run from narrowest to widest.
fn wider(first: LiveLayout, second: LiveLayout) LiveLayout {
    return @fromBackingInt(@intCast(@max(@backingInt(first), @backingInt(second))));
}
