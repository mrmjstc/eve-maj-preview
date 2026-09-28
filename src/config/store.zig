//! The only writer of the running profile: `live` is what the app shows, including unsaved dialog edits, and `saved` is what's on disk.
const std = @import("std");
const log = @import("../log.zig");
const config_mod = @import("../config.zig");
const profiles = @import("profiles.zig");
const wire = @import("wire.zig");
const strings = @import("../util/strings.zig");

const Config = config_mod.Config;
const slog = log.scoped("config");

pub const ProfileStore = struct {
    live: Config,
    saved: Config,

    /// Takes ownership of `cfg`, freeing it on failure.
    pub fn init(cfg: Config) !ProfileStore {
        var live = cfg;
        errdefer live.deinit();
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

    pub fn setCharacterPosition(self: *ProfileStore, character_name: []const u8, pos: config_mod.Position) void {
        inline for (.{ &self.live, &self.saved }) |cfg| {
            const char = cfg.getOrCreateCharacter(cfg.allocator, character_name) catch |err| {
                slog.err("Failed to add '{s}' to profile '{s}' for its position: {}", .{ character_name, cfg.profile_name, err });
                return;
            };
            char.position = pos;
        }
        self.persist();
    }

    /// Returns whether `character_name` is now in the group; a temporary group's members are never saved.
    pub fn toggleGroupMember(self: *ProfileStore, group_index: usize, character_name: []const u8) !bool {
        const group = &self.live.hotkeyGroups.items[group_index];
        const member = strings.indexOfString(group.characters.items, character_name) == null;
        try setMembership(&self.live, group_index, character_name, member);
        try setMembership(&self.saved, group_index, character_name, member);
        if (!group.temporaryMembership) self.persist();
        return member;
    }

    /// Makes `live` what was last saved, dropping unsaved dialog edits; callers refresh whatever borrowed from the old `live`.
    pub fn discard(self: *ProfileStore) !void {
        const fresh = try self.saved.clone(self.saved.allocator);
        self.live.deinit();
        self.live = fresh;
    }

    fn persist(self: *ProfileStore) void {
        const allocator = self.saved.allocator;
        const path = profiles.path(allocator, self.saved.profile_name) catch |err| {
            slog.err("Failed to build path to save profile '{s}': {}", .{ self.saved.profile_name, err });
            return;
        };
        defer allocator.free(path);
        profiles.save(&self.saved, allocator, path) catch |err| {
            slog.err("Failed to save profile '{s}': {}", .{ self.saved.profile_name, err });
        };
    }
};

/// Idempotent, so both copies end up agreeing even if they didn't before.
fn setMembership(cfg: *Config, group_index: usize, character_name: []const u8, member: bool) !void {
    if (group_index >= cfg.hotkeyGroups.items.len) return error.InvalidGroupIndex;
    const members = &cfg.hotkeyGroups.items[group_index].characters;
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
