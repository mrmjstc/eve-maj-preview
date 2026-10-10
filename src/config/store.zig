//! The only writer of the running profile: `live` is what the app shows, including unsaved dialog edits, and `saved` is what's on disk.
const std = @import("std");
const config = @import("../config.zig");
const profiles = @import("profiles.zig");
const wire = @import("wire.zig");
const patch_mod = @import("patch.zig");
const strings = @import("../util/strings.zig");
const log = @import("../log.zig");

const Config = config.Config;
const slog = log.scoped("config");

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
    }

    pub const CharacterPosition = struct { name: []const u8, pos: config.Position };

    /// Saved once for the whole batch, so a group drag writes the profile once rather than per thumbnail.
    pub fn setCharacterPositions(self: *ProfileStore, entries: []const CharacterPosition) void {
        for (entries) |entry| {
            setPosition(&self.live, entry) catch |err| {
                slog.err("Failed to add '{s}' to profile '{s}' for its position: {}", .{ entry.name, self.live.profile_name, err });
                continue;
            };
            setPosition(&self.saved, entry) catch |err| {
                slog.err("Failed to add '{s}' to profile '{s}' for its position: {}", .{ entry.name, self.saved.profile_name, err });
                continue;
            };
        }
        // A character this created needs an id, which the config dialog tracks it by.
        patch_mod.assignIds(Config, &self.live);
        self.persist();
    }

    fn setPosition(cfg: *Config, entry: CharacterPosition) !void {
        const char = try cfg.getOrCreateCharacter(cfg.allocator, entry.name);
        char.position = entry.pos;
    }

    /// Sets `character_name`'s saved game-window position and size, or with a null name every character's; clearing a missing character is a no-op.
    pub fn setWindowPosition(self: *ProfileStore, character_name: ?[]const u8, pos: ?config.Position, size: ?config.WindowSize) !void {
        try applyWindowPosition(&self.live, character_name, pos, size);
        try applyWindowPosition(&self.saved, character_name, pos, size);
        // A character this created needs an id, which the config dialog tracks it by.
        patch_mod.assignIds(Config, &self.live);
        self.persist();
    }

    /// `group_index` is into `saved`, which the hotkey manager reads; returns whether `character_name` is now in the group.
    /// A temporary group's members are never saved.
    pub fn toggleGroupMember(self: *ProfileStore, group_index: usize, character_name: []const u8) !bool {
        if (group_index >= self.saved.hotkeyGroups.items.len) return error.InvalidGroupIndex;
        const group = &self.saved.hotkeyGroups.items[group_index];
        const member = strings.indexOfString(group.characters.items, character_name) == null;
        try setMembership(&self.saved, group, character_name, member);
        // Unsaved dialog edits may have moved or removed the group in `live`.
        for (self.live.hotkeyGroups.items) |*live_group| {
            if (live_group.id != group.id) continue;
            try setMembership(&self.live, live_group, character_name, member);
        }
        if (!group.temporaryMembership) self.persist();
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
};

/// Shared with the dialog's edits to a profile the app isn't running, which only exist on disk.
pub fn applyWindowPosition(cfg: *Config, character_name: ?[]const u8, pos: ?config.Position, size: ?config.WindowSize) !void {
    if (character_name) |name| {
        if (pos == null and cfg.findCharacter(name) == null) return;
        const char = try cfg.getOrCreateCharacter(cfg.allocator, name);
        char.windowPosition = pos;
        char.windowSize = size;
    } else {
        for (cfg.characters.items) |*char| {
            char.windowPosition = pos;
            char.windowSize = size;
        }
    }
}

/// Idempotent, so both copies end up agreeing even if they didn't before.
fn setMembership(cfg: *Config, group: *config.HotkeyGroupConfig, character_name: []const u8, member: bool) !void {
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
    inline for (@typeInfo(@TypeOf(patch)).@"struct".field_names) |name| {
        const Field = @FieldType(T, name);
        const value = @field(patch, name);
        if (@TypeOf(value) != Field and @typeInfo(Field) == .@"struct") {
            assign(Field, &@field(target, name), value);
        } else {
            if (comptime wire.hasPointers(Field)) @compileError(name ++ " holds pointers, so it can't be set through ProfileStore.update");
            @field(target, name) = value;
        }
    }
}
