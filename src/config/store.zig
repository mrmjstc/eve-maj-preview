//! The only writer of the running profile: `live` is what the app shows, including unsaved dialog edits, and `saved` is what's on disk.
const std = @import("std");
const log = @import("../log.zig");
const config_mod = @import("../config.zig");
const profiles = @import("profiles.zig");
const wire = @import("wire.zig");
const patch_mod = @import("patch.zig");
const strings = @import("../util/strings.zig");

const Config = config_mod.Config;
const slog = log.scoped("config");

/// Told about each runtime change as edit ops (see config/patch.zig), so an open config dialog can follow it.
pub var on_runtime_change: ?*const fn (ops_json: []const u8) void = null;

pub const ProfileStore = struct {
    live: Config,
    saved: Config,

    /// Takes ownership of `cfg`, freeing it on failure.
    pub fn init(cfg: Config) !ProfileStore {
        var live = cfg;
        errdefer live.deinit();
        patch_mod.assignIds(Config, &live);
        return .{ .live = live, .saved = try live.clone(live.allocator) };
    }

    pub fn deinit(self: *ProfileStore) void {
        self.live.deinit();
        self.saved.deinit();
    }

    /// A runtime change (drag, tray or panel toggle): applied to both copies and saved, so a dialog preview never reaches disk and neither Save nor Discard undoes it.
    /// `patch` mirrors Config's nesting, e.g. `.{ .display = .{ .startX = 10 } }`.
    pub fn update(self: *ProfileStore, patch: anytype) void {
        assign(Config, &self.live, patch);
        assign(Config, &self.saved, patch);
        self.persist();
        const paths: []const []const []const u8 = comptime patch_mod.leafPaths(Config, @TypeOf(patch));
        self.emit(paths, writeFieldSets);
    }

    pub const CharacterPosition = struct { name: []const u8, pos: config_mod.Position };

    /// Saved once for the whole batch, so a group drag writes the profile once rather than per thumbnail.
    pub fn setCharacterPositions(self: *ProfileStore, entries: []const CharacterPosition) void {
        for (entries) |entry| {
            const existed = self.live.findCharacter(entry.name) != null;
            setPosition(&self.live, entry) catch |err| {
                slog.err("Failed to add '{s}' to profile '{s}' for its position: {}", .{ entry.name, self.live.profile_name, err });
                continue;
            };
            setPosition(&self.saved, entry) catch |err| {
                slog.err("Failed to add '{s}' to profile '{s}' for its position: {}", .{ entry.name, self.saved.profile_name, err });
                continue;
            };
            self.emitCharacter(entry.name, existed, "position");
        }
        self.persist();
    }

    fn setPosition(cfg: *Config, entry: CharacterPosition) !void {
        const char = try cfg.getOrCreateCharacter(cfg.allocator, entry.name);
        char.position = entry.pos;
    }

    /// Sets `character_name`'s saved game-window position, or with a null name every character's; clearing a missing character is a no-op.
    pub fn setWindowPosition(self: *ProfileStore, character_name: ?[]const u8, pos: ?config_mod.Position) !void {
        const existed = if (character_name) |name| self.live.findCharacter(name) != null else true;
        try applyWindowPosition(&self.live, character_name, pos);
        try applyWindowPosition(&self.saved, character_name, pos);
        self.persist();
        if (character_name) |name| {
            if (self.live.findCharacter(name) != null) self.emitCharacter(name, existed, "windowPosition");
        } else {
            for (self.live.characters.items) |char| self.emitCharacter(char.name, true, "windowPosition");
        }
    }

    /// `group_index` is into `saved`, which the hotkey manager reads; returns whether `character_name` is now in the group.
    /// A temporary group's members are never saved.
    pub fn toggleGroupMember(self: *ProfileStore, group_index: usize, character_name: []const u8) !bool {
        if (group_index >= self.saved.hotkeyGroups.items.len) return error.InvalidGroupIndex;
        const group = &self.saved.hotkeyGroups.items[group_index];
        const member = strings.indexOfString(group.characters.items, character_name) == null;
        try setMembership(&self.saved, group, character_name, member);
        // Unsaved dialog edits may have moved or removed the group in `live`.
        var in_live = false;
        for (self.live.hotkeyGroups.items) |*live_group| {
            if (live_group.id != group.id) continue;
            try setMembership(&self.live, live_group, character_name, member);
            in_live = true;
        }
        if (!group.temporaryMembership) self.persist();
        if (in_live) self.emit(group.id, writeGroupMembers);
        return member;
    }

    /// Saves everything the dialog changed in `live`.
    pub fn commit(self: *ProfileStore) !void {
        const fresh = try self.live.clone(self.live.allocator);
        self.saved.deinit();
        self.saved = fresh;
        try self.save();
    }

    /// Makes `live` what was last saved, dropping unsaved dialog edits; callers refresh whatever borrowed from the old `live`.
    pub fn discard(self: *ProfileStore) !void {
        var fresh = try self.saved.clone(self.saved.allocator);
        patch_mod.assignIds(Config, &fresh);
        self.live.deinit();
        self.live = fresh;
    }

    /// Whether `live` holds dialog edits not yet saved.
    pub fn isDirty(self: *ProfileStore) bool {
        var arena = std.heap.ArenaAllocator.init(self.live.allocator);
        defer arena.deinit();
        const live = self.live.toJsonString(arena.allocator()) catch |err| {
            slog.err("Failed to serialize the running profile to compare it: {}", .{err});
            return true;
        };
        const saved = self.saved.toJsonString(arena.allocator()) catch |err| {
            slog.err("Failed to serialize the saved profile to compare it: {}", .{err});
            return true;
        };
        return !std.mem.eql(u8, live, saved);
    }

    fn persist(self: *ProfileStore) void {
        self.save() catch |err| {
            slog.err("Failed to save profile '{s}': {}", .{ self.saved.profile_name, err });
        };
    }

    fn save(self: *ProfileStore) !void {
        const allocator = self.saved.allocator;
        const path = try profiles.path(allocator, self.saved.profile_name);
        defer allocator.free(path);
        try profiles.save(&self.saved, allocator, path);
    }

    fn emitCharacter(self: *ProfileStore, character_name: []const u8, existed: bool, comptime field: []const u8) void {
        // A character this change created has no id yet.
        patch_mod.assignIds(Config, &self.live);
        const index = self.live.characterIndex(character_name) orelse return;
        if (existed) {
            self.emit(CharacterField{ .id = self.live.characters.items[index].id, .field = field }, writeCharacterField);
        } else {
            self.emit(index, writeCharacterInsert);
        }
    }

    /// `write` adds this change's ops to a JSON array, which goes to `on_runtime_change`.
    fn emit(self: *ProfileStore, context: anytype, comptime write: fn (*std.json.Stringify, *const Config, @TypeOf(context)) anyerror!void) void {
        const callback = on_runtime_change orelse return;
        var arena = std.heap.ArenaAllocator.init(self.live.allocator);
        defer arena.deinit();
        var out: std.Io.Writer.Allocating = .init(arena.allocator());
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        writeArray(&jw, &self.live, context, write) catch |err| {
            slog.err("Failed to describe a runtime change for the config dialog: {}", .{err});
            return;
        };
        callback(out.written());
    }
};

fn writeArray(jw: *std.json.Stringify, cfg: *const Config, context: anytype, comptime write: fn (*std.json.Stringify, *const Config, @TypeOf(context)) anyerror!void) !void {
    try jw.beginArray();
    try write(jw, cfg, context);
    try jw.endArray();
}

fn writeFieldSets(jw: *std.json.Stringify, cfg: *const Config, paths: []const []const []const u8) anyerror!void {
    for (paths) |names| {
        var buf: [8]std.json.Value = undefined;
        if (names.len > buf.len) return error.PathTooDeep;
        for (names, 0..) |name, i| buf[i] = .{ .string = name };
        try writeSet(jw, cfg, buf[0..names.len]);
    }
}

const CharacterField = struct { id: u32, field: []const u8 };

fn writeCharacterField(jw: *std.json.Stringify, cfg: *const Config, change: CharacterField) anyerror!void {
    try writeSet(jw, cfg, &.{ .{ .string = "characters" }, .{ .integer = change.id }, .{ .string = change.field } });
}

fn writeCharacterInsert(jw: *std.json.Stringify, cfg: *const Config, index: usize) anyerror!void {
    try jw.beginObject();
    try jw.objectField("op");
    try jw.write("insert");
    try jw.objectField("path");
    try jw.write(&[_]std.json.Value{.{ .string = "characters" }});
    try jw.objectField("index");
    try jw.write(index);
    try jw.objectField("value");
    try patch_mod.write(jw, config_mod.CharacterConfig, &cfg.characters.items[index]);
    try jw.endObject();
}

fn writeGroupMembers(jw: *std.json.Stringify, cfg: *const Config, group_id: u32) anyerror!void {
    try writeSet(jw, cfg, &.{ .{ .string = "hotkeyGroups" }, .{ .integer = group_id }, .{ .string = "characters" } });
}

fn writeSet(jw: *std.json.Stringify, cfg: *const Config, path: []const std.json.Value) !void {
    try jw.beginObject();
    try jw.objectField("op");
    try jw.write("set");
    try jw.objectField("path");
    try jw.write(path);
    try jw.objectField("value");
    try patch_mod.writeAt(jw, Config, cfg, path);
    try jw.endObject();
}

/// Shared with the dialog's edits to a profile the app isn't running, which only exist on disk.
pub fn applyWindowPosition(cfg: *Config, character_name: ?[]const u8, pos: ?config_mod.Position) !void {
    if (character_name) |name| {
        if (pos == null and cfg.findCharacter(name) == null) return;
        const char = try cfg.getOrCreateCharacter(cfg.allocator, name);
        char.windowPosition = pos;
    } else {
        for (cfg.characters.items) |*char| char.windowPosition = pos;
    }
}

/// Idempotent, so both copies end up agreeing even if they didn't before.
fn setMembership(cfg: *Config, group: *config_mod.HotkeyGroupConfig, character_name: []const u8, member: bool) !void {
    const members = &group.characters;
    const index = strings.indexOfString(members.items, character_name);
    if (member and index == null) {
        const owned = try cfg.allocator.dupe(u8, character_name);
        errdefer cfg.allocator.free(owned);
        try members.append(cfg.allocator, owned);
    } else if (!member) {
        if (index) |i| cfg.allocator.free(members.orderedRemove(i));
    }
}

/// Leaves must hold no pointers, since both copies would then share one allocation.
fn assign(comptime T: type, target: *T, patch: anytype) void {
    inline for (@typeInfo(@TypeOf(patch)).@"struct".fields) |f| {
        const Field = @FieldType(T, f.name);
        const value = @field(patch, f.name);
        if (@TypeOf(value) != Field and @typeInfo(Field) == .@"struct") {
            assign(Field, &@field(target, f.name), value);
        } else {
            if (comptime wire.hasPointers(Field)) @compileError(f.name ++ " holds pointers, so it can't be set through ProfileStore.update");
            @field(target, f.name) = value;
        }
    }
}
