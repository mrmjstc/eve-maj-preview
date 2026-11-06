//! The only writer of the running profile: `live` is what the app shows, including unsaved dialog edits, and `saved` is what's on disk.
const std = @import("std");
const config_mod = @import("../config.zig");
const profiles = @import("profiles.zig");
const types = @import("types.zig");
const wire = @import("wire.zig");
const patch_mod = @import("patch.zig");
const strings = @import("../util/strings.zig");
const log = @import("../log.zig");

const Config = config_mod.Config;
const slog = log.Scoped("config");

pub const ProfileStore = struct {
    live: Config,
    saved: Config,
    io: std.Io,

    /// Takes ownership of `config`, freeing it on failure.
    pub fn init(config: Config, io: std.Io) !ProfileStore {
        var live = config;
        errdefer live.deinit();
        patch_mod.assignIds(Config, &live);
        return .{ .live = live, .saved = try live.clone(live.allocator), .io = io };
    }

    pub fn deinit(self: *ProfileStore) void {
        self.live.deinit();
        self.saved.deinit();
    }

    /// A runtime change (drag, tray or panel toggle) saved to both copies, which Save and Discard can't undo; `patch` mirrors Config's nesting, e.g. `.{ .display = .{ .startX = 10 } }`.
    pub fn update(self: *ProfileStore, patch: anytype) void {
        assign(Config, &self.live, patch);
        assign(Config, &self.saved, patch);
        self.persist();
    }

    pub const CharacterPosition = struct { name: []const u8, position: config_mod.Position };

    /// Saved once for the whole batch, so a group drag writes the profile once rather than per thumbnail.
    pub fn setCharacterPositions(self: *ProfileStore, entries: []const CharacterPosition) void {
        setCharacterPositionsInBoth(&self.live, &self.saved, entries);
        self.persist();
    }

    /// A null name sets every character's; clearing a missing character is a no-op.
    pub fn setWindowPosition(self: *ProfileStore, character_name: ?[]const u8, position: ?config_mod.Position, size: ?config_mod.WindowSize) !void {
        try setWindowPositionInBoth(&self.live, &self.saved, character_name, position, size);
        self.persist();
    }

    /// `group_index` is into `saved`; returns whether `character_name` is now a member, never saving a temporary group's.
    pub fn toggleGroupMember(self: *ProfileStore, group_index: usize, character_name: []const u8) !bool {
        const toggle = try toggleGroupMemberInBoth(&self.live, &self.saved, group_index, character_name);
        if (toggle.should_save) self.persist();
        return toggle.is_member;
    }

    /// Returns whether `system_id` is now avoided, going by what the app shows; error.AvoidListFull past types.MAX_AVOIDED_SYSTEMS.
    pub fn toggleAvoidedSystem(self: *ProfileStore, system_id: u32) !bool {
        const is_avoided = try toggleAvoidedSystemInBoth(&self.live, &self.saved, system_id);
        self.persist();
        return is_avoided;
    }

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

    pub fn isDirty(self: *const ProfileStore) bool {
        var arena: std.heap.ArenaAllocator = .init(self.live.allocator);
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
        try profiles.save(&self.saved, allocator, self.io, path);
    }
};

/// What a group toggle changed, for its caller to save.
const GroupToggle = struct {
    is_member: bool,
    /// False for a temporary group, whose membership is never saved.
    should_save: bool,
};

fn setCharacterPositionsInBoth(live: *Config, saved: *Config, entries: []const ProfileStore.CharacterPosition) void {
    for (entries) |entry| {
        setPosition(live, entry) catch |err| {
            slog.err("Failed to add '{s}' to profile '{s}' for its position: {}", .{ entry.name, live.profile_name, err });
            continue;
        };
        setPosition(saved, entry) catch |err| {
            slog.err("Failed to add '{s}' to profile '{s}' for its position: {}", .{ entry.name, saved.profile_name, err });
            continue;
        };
    }
    giveNewCharactersIds(live, saved);
}

fn setPosition(config: *Config, entry: ProfileStore.CharacterPosition) !void {
    const character = try config.getOrCreateCharacter(entry.name);
    character.position = entry.position;
}

fn setWindowPositionInBoth(live: *Config, saved: *Config, character_name: ?[]const u8, position: ?config_mod.Position, size: ?config_mod.WindowSize) !void {
    try applyWindowPosition(live, character_name, position, size);
    try applyWindowPosition(saved, character_name, position, size);
    giveNewCharactersIds(live, saved);
}

fn applyWindowPosition(config: *Config, character_name: ?[]const u8, position: ?config_mod.Position, size: ?config_mod.WindowSize) !void {
    if (character_name) |name| {
        if (position == null and config.findCharacter(name) == null) return;
        const character = try config.getOrCreateCharacter(name);
        character.windowPosition = position;
        character.windowSize = size;
    } else {
        for (config.characters.items) |*character| {
            character.windowPosition = position;
            character.windowSize = size;
        }
    }
}

/// The config dialog tracks characters by id, so a character created in both copies takes the same one in each, which a later discard keeps.
fn giveNewCharactersIds(live: *Config, saved: *Config) void {
    patch_mod.assignIds(Config, live);
    for (saved.characters.items) |*character| {
        if (character.id != 0) continue;
        const live_character = live.findCharacterConst(character.name) orelse continue;
        character.id = live_character.id;
    }
}

fn toggleGroupMemberInBoth(live: *Config, saved: *Config, group_index: usize, character_name: []const u8) !GroupToggle {
    if (group_index >= saved.hotkeyGroups.items.len) return error.InvalidGroupIndex;
    const group = &saved.hotkeyGroups.items[group_index];
    const is_member = strings.indexOfString(group.characters.items, character_name) == null;
    try setMembership(saved, group, character_name, is_member);
    // Unsaved dialog edits may have moved or removed the group in `live`.
    for (live.hotkeyGroups.items) |*live_group| {
        if (live_group.id != group.id) continue;
        try setMembership(live, live_group, character_name, is_member);
    }
    return .{ .is_member = is_member, .should_save = !group.temporaryMembership };
}

/// Idempotent, so both copies end up agreeing even if they didn't before.
fn setMembership(config: *Config, group: *config_mod.HotkeyGroupConfig, character_name: []const u8, is_member: bool) !void {
    const members = &group.characters;
    const index = strings.indexOfString(members.items, character_name);
    if (is_member and index == null) {
        const owned = try config.allocator.dupe(u8, character_name);
        errdefer config.allocator.free(owned);
        try members.append(config.allocator, owned);
    } else if (!is_member) {
        if (index) |i| config.allocator.free(members.orderedRemove(i));
    }
}

fn toggleAvoidedSystemInBoth(live: *Config, saved: *Config, system_id: u32) !bool {
    const is_avoided = live.avoidedSystemIndex(system_id) == null;
    try setAvoided(live, system_id, is_avoided);
    try setAvoided(saved, system_id, is_avoided);
    return is_avoided;
}

/// Idempotent, as unsaved dialog edits can leave the two copies disagreeing.
fn setAvoided(config: *Config, system_id: u32, is_avoided: bool) !void {
    const index = config.avoidedSystemIndex(system_id);
    if (is_avoided and index == null) {
        if (config.avoidedSystems.items.len >= types.MAX_AVOIDED_SYSTEMS) return error.AvoidListFull;
        try config.avoidedSystems.append(config.allocator, .{ .systemId = system_id });
    } else if (!is_avoided) {
        if (index) |i| _ = config.avoidedSystems.orderedRemove(i);
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

const testing = std.testing;

/// Built from `json_text` without touching the disk; nothing here saves.
fn testStore(json_text: []const u8) !ProfileStore {
    return ProfileStore.init(try Config.buildConfigFromJson(testing.allocator, json_text, "Test"), testing.io);
}

fn expectMembers(group: *const config_mod.HotkeyGroupConfig, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, group.characters.items.len);
    for (expected, group.characters.items) |expected_name, actual_name| try testing.expectEqualStrings(expected_name, actual_name);
}

test "a group toggle adds the character to both copies, and a second toggle removes it from both" {
    var store = try testStore(
        \\{"hotkeyGroups": [{"name": "Miners"}]}
    );
    defer store.deinit();

    const added = try toggleGroupMemberInBoth(&store.live, &store.saved, 0, "Alpha");
    try testing.expect(added.is_member and added.should_save);
    try expectMembers(&store.live.hotkeyGroups.items[0], &.{"Alpha"});
    try expectMembers(&store.saved.hotkeyGroups.items[0], &.{"Alpha"});

    const removed = try toggleGroupMemberInBoth(&store.live, &store.saved, 0, "Alpha");
    try testing.expect(!removed.is_member);
    try expectMembers(&store.live.hotkeyGroups.items[0], &.{});
    try expectMembers(&store.saved.hotkeyGroups.items[0], &.{});
}

test "a group toggle reaches the live group by id after the dialog reordered the groups" {
    var store = try testStore(
        \\{"hotkeyGroups": [{"name": "Miners"}, {"name": "Scouts"}]}
    );
    defer store.deinit();
    std.mem.swap(config_mod.HotkeyGroupConfig, &store.live.hotkeyGroups.items[0], &store.live.hotkeyGroups.items[1]);

    _ = try toggleGroupMemberInBoth(&store.live, &store.saved, 0, "Alpha");
    try expectMembers(&store.live.hotkeyGroups.items[1], &.{"Alpha"});
    try expectMembers(&store.live.hotkeyGroups.items[0], &.{});
}

test "a group toggle for a group the dialog removed changes only the saved copy" {
    var store = try testStore(
        \\{"hotkeyGroups": [{"name": "Miners"}, {"name": "Scouts"}]}
    );
    defer store.deinit();
    var removed = store.live.hotkeyGroups.orderedRemove(0);
    wire.free(config_mod.HotkeyGroupConfig, &removed, store.live.allocator);

    _ = try toggleGroupMemberInBoth(&store.live, &store.saved, 0, "Alpha");
    try expectMembers(&store.saved.hotkeyGroups.items[0], &.{"Alpha"});
    try expectMembers(&store.live.hotkeyGroups.items[0], &.{});
}

test "a temporary group's toggle isn't saved" {
    var store = try testStore(
        \\{"hotkeyGroups": [{"name": "Fleet", "temporaryMembership": true}]}
    );
    defer store.deinit();

    const toggle = try toggleGroupMemberInBoth(&store.live, &store.saved, 0, "Alpha");
    try testing.expect(toggle.is_member and !toggle.should_save);
    try expectMembers(&store.live.hotkeyGroups.items[0], &.{"Alpha"});
}

test "a group index past the saved groups is an error" {
    var store = try testStore("{}");
    defer store.deinit();

    try testing.expectError(error.InvalidGroupIndex, toggleGroupMemberInBoth(&store.live, &store.saved, 0, "Alpha"));
}

test "an avoided-system toggle follows the live copy and leaves both agreeing" {
    var store = try testStore(
        \\{"avoidedSystems": [{"systemId": 30000142}]}
    );
    defer store.deinit();
    _ = store.live.avoidedSystems.orderedRemove(0);

    try testing.expect(try toggleAvoidedSystemInBoth(&store.live, &store.saved, 30000142));
    try testing.expectEqual(@as(usize, 1), store.live.avoidedSystems.items.len);
    try testing.expectEqual(@as(usize, 1), store.saved.avoidedSystems.items.len);
}

test "avoiding a system past the limit fails and changes neither copy" {
    var store = try testStore("{}");
    defer store.deinit();
    for (0..types.MAX_AVOIDED_SYSTEMS) |index| {
        const system_id: u32 = @intCast(index + 1);
        try store.live.avoidedSystems.append(store.live.allocator, .{ .systemId = system_id });
        try store.saved.avoidedSystems.append(store.saved.allocator, .{ .systemId = system_id });
    }

    try testing.expectError(error.AvoidListFull, toggleAvoidedSystemInBoth(&store.live, &store.saved, 30000142));
    try testing.expectEqual(@as(usize, types.MAX_AVOIDED_SYSTEMS), store.live.avoidedSystems.items.len);
    try testing.expectEqual(@as(usize, types.MAX_AVOIDED_SYSTEMS), store.saved.avoidedSystems.items.len);
}

test "clearing a missing character's window position adds no character" {
    var store = try testStore("{}");
    defer store.deinit();

    try setWindowPositionInBoth(&store.live, &store.saved, "Alpha", null, null);
    try testing.expectEqual(@as(usize, 0), store.live.characters.items.len);
    try testing.expectEqual(@as(usize, 0), store.saved.characters.items.len);
}

test "a window position without a name sets every character's" {
    var store = try testStore(
        \\{"characters": [{"name": "Alpha"}, {"name": "Beta"}]}
    );
    defer store.deinit();
    const position: config_mod.Position = .{ .x = 10, .y = 20 };

    try setWindowPositionInBoth(&store.live, &store.saved, null, position, .{ .width = 800, .height = 600 });
    for ([_]*const Config{ &store.live, &store.saved }) |config| {
        for (config.characters.items) |character| try testing.expectEqual(@as(?config_mod.Position, position), character.windowPosition);
    }
}

test "a character created by a position has the same id in both copies" {
    var store = try testStore("{}");
    defer store.deinit();

    setCharacterPositionsInBoth(&store.live, &store.saved, &.{.{ .name = "Alpha", .position = .{ .x = 1, .y = 2 } }});
    try setWindowPositionInBoth(&store.live, &store.saved, "Beta", .{ .x = 3, .y = 4 }, null);
    for ([_][]const u8{ "Alpha", "Beta" }) |name| {
        const live_id = (store.live.findCharacterConst(name) orelse return error.MissingCharacter).id;
        const saved_id = (store.saved.findCharacterConst(name) orelse return error.MissingCharacter).id;
        try testing.expect(live_id != 0);
        try testing.expectEqual(live_id, saved_id);
    }
}

test "discard keeps the id of a character a position created" {
    var store = try testStore("{}");
    defer store.deinit();
    setCharacterPositionsInBoth(&store.live, &store.saved, &.{.{ .name = "Alpha", .position = .{ .x = 1, .y = 2 } }});
    const id = (store.live.findCharacterConst("Alpha") orelse return error.MissingCharacter).id;

    try store.discard();
    try testing.expectEqual(id, (store.live.findCharacterConst("Alpha") orelse return error.MissingCharacter).id);
}

test "a nested patch sets only the fields it names" {
    var store = try testStore("{}");
    defer store.deinit();
    const start_y = store.live.display.startY;

    assign(Config, &store.live, .{ .display = .{ .startX = 42 } });
    try testing.expectEqual(@as(i32, 42), store.live.display.startX);
    try testing.expectEqual(start_y, store.live.display.startY);
}

test "a new store isn't dirty, a live edit makes it dirty, and discard undoes it" {
    var store = try testStore("{}");
    defer store.deinit();
    const start_x = store.live.display.startX;
    try testing.expect(!store.isDirty());

    store.live.display.startX = start_x + 5;
    try testing.expect(store.isDirty());

    try store.discard();
    try testing.expect(!store.isDirty());
    try testing.expectEqual(start_x, store.live.display.startX);
}
