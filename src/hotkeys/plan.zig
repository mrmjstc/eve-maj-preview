//! What the hotkeys do before Win32 is involved: which ones a profile binds, in registration order, and whether a press runs; no Win32.
const std = @import("std");
const config_mod = @import("../config.zig");
const bindings = @import("bindings.zig");
const cycle_order = @import("cycle_order.zig");

const CharacterConfig = config_mod.CharacterConfig;
const GlobalConfig = config_mod.GlobalConfig;
const HotkeyAction = bindings.HotkeyAction;
const HotkeyGroupConfig = config_mod.HotkeyGroupConfig;
const HotkeysConfig = config_mod.HotkeysConfig;
const KeyList = config_mod.KeyList;

/// The settings a plan is built from; each borrowed for the build, and names in the plan borrow from them.
pub const Settings = struct {
    characters: []const CharacterConfig,
    groups: []const HotkeyGroupConfig,
    hotkeys: *const HotkeysConfig,
    global: *const GlobalConfig,
};

/// One hotkey to hook: each of `keys` posts `id`, which runs `action`.
pub const Entry = struct {
    id: c_int,
    keys: KeyList,
    /// Its index slices borrow from the Plan's arena.
    action: HotkeyAction,
    /// Borrows from the Plan's arena, or is a literal.
    description: []const u8,
};

/// A group cycle combo past bindings.CYCLE_GROUP_SLOT_COUNT, which gets no entry.
pub const Overflow = struct {
    /// Borrows from the settings.
    group_name: []const u8,
    is_forward: bool,
};

/// What the registration's log line reports.
pub const Counts = struct {
    groups: usize = 0,
    globals: usize = 0,
    character_combos: usize = 0,
    profile_switches: usize = 0,
    apps: usize = 0,
    urls: usize = 0,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    /// Globals first, since a combo bound twice stays with whichever registers first, and suspend and exit must keep theirs.
    entries: std.ArrayList(Entry) = .empty,
    overflows: std.ArrayList(Overflow) = .empty,
    counts: Counts = .{},

    /// Frees every entry's actions too, so the hotkeys must be unhooked first.
    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }

    pub fn isEmpty(self: *const Plan) bool {
        return self.entries.items.len == 0 and self.overflows.items.len == 0;
    }

    fn add(self: *Plan, entry: Entry) !void {
        try self.entries.append(self.arena.allocator(), entry);
    }
};

/// The characters or hotkey groups bound to one key combo, in config order.
const ComboSharers = struct {
    virtual_key: u32,
    indices: std.ArrayList(usize),
};

/// What a hotkey press knows when it arrives, read once.
pub const PressFacts = struct {
    is_repeat: bool,
    allows_repeat: bool,
    is_suspend_key: bool,
    are_hotkeys_suspended: bool,
    is_dialog_recording: bool,
    requires_eve_focus: bool,
    has_eve_focus: bool,
};

pub const Verdict = enum { run, toggle_suspend, ignore_repeat, ignore_suspended, ignore_recording, ignore_unfocused };

/// Characters, or groups, sharing a combo cycle through one another, while their other combos stay their own.
pub fn build(allocator: std.mem.Allocator, settings: Settings) !Plan {
    var plan: Plan = .{ .arena = .init(allocator) };
    errdefer plan.deinit();
    const arena = plan.arena.allocator();

    var character_combos: std.ArrayList(ComboSharers) = .empty;
    for (settings.characters, 0..) |*character, character_index| {
        for (character.hotkey.slice()) |hotkey_vk| try addComboSharer(arena, &character_combos, hotkey_vk, character_index);
    }
    var forward_chains: std.ArrayList(ComboSharers) = .empty;
    var backward_chains: std.ArrayList(ComboSharers) = .empty;
    for (settings.groups, 0..) |*group, group_index| {
        for (group.forwardKey.slice()) |group_vk| try addComboSharer(arena, &forward_chains, group_vk, group_index);
        for (group.backwardKey.slice()) |group_vk| try addComboSharer(arena, &backward_chains, group_vk, group_index);
    }
    plan.counts.groups = settings.groups.len;
    plan.counts.character_combos = character_combos.items.len;

    inline for (bindings.GLOBAL_BINDINGS) |binding| {
        if (globalEntry(settings, binding)) |entry| {
            try plan.add(entry);
            plan.counts.globals += 1;
        }
    }

    try addGroupChains(&plan, settings.groups, forward_chains.items, true);
    try addGroupChains(&plan, settings.groups, backward_chains.items, false);

    for (settings.groups, 0..) |*group, group_index| {
        try addGroupKey(&plan, bindings.HOTKEY_ID_ASSIGN_GROUP_BASE, group, group_index, group.assignKey, .{ .assign_group = .{ .group_index = group_index } }, "assign");
        try addGroupKey(&plan, bindings.HOTKEY_ID_MINIMIZE_GROUP_BASE, group, group_index, group.minimizeKey, .{ .minimize_group = .{ .group_index = group_index } }, "minimize");
        try addGroupKey(&plan, bindings.HOTKEY_ID_CLOSE_GROUP_BASE, group, group_index, group.closeKey, .{ .close_group = .{ .group_index = group_index } }, "close");
    }

    for (character_combos.items, 0..) |combo, combo_index| {
        const first_name = settings.characters[combo.indices.items[0]].name;
        const description = if (combo.indices.items.len == 1)
            try std.fmt.allocPrint(arena, "activate character [{s}]", .{first_name})
        else
            try std.fmt.allocPrint(arena, "activate character [{s}...] ({d} sharing hotkey)", .{ first_name, combo.indices.items.len });
        try plan.add(.{
            .id = bindings.bandId(bindings.HOTKEY_ID_PER_CHARACTER_BASE, combo_index),
            .keys = .one(combo.virtual_key),
            .action = .{ .activate_character = .{ .character_indices = combo.indices.items } },
            .description = description,
        });
    }

    for (settings.global.profileSwitchHotkeys.items, 0..) |profile_hotkey, index| {
        if (profile_hotkey.hotkey.isEmpty()) continue;
        plan.counts.profile_switches += 1;
        const description = try std.fmt.allocPrint(arena, "switch to profile [{s}]", .{profile_hotkey.targetProfile});
        try plan.add(.{ .id = bindings.bandId(bindings.HOTKEY_ID_PROFILE_SWITCH_BASE, index), .keys = profile_hotkey.hotkey, .action = .{ .switch_to_profile = .{ .profile_index = index } }, .description = description });
    }

    for (settings.global.appHotkeys.items, 0..) |app_hotkey, index| {
        if (app_hotkey.hotkey.isEmpty()) continue;
        plan.counts.apps += 1;
        const description = try std.fmt.allocPrint(arena, "activate app [{s}]", .{app_hotkey.executableName});
        try plan.add(.{ .id = bindings.bandId(bindings.HOTKEY_ID_APP_HOTKEY_BASE, index), .keys = app_hotkey.hotkey, .action = .{ .activate_app = .{ .app_index = index } }, .description = description });
    }

    for (settings.global.urlHotkeys.items, 0..) |url_hotkey, index| {
        if (url_hotkey.hotkey.isEmpty()) continue;
        plan.counts.urls += 1;
        const description = try std.fmt.allocPrint(arena, "open url [{s}]", .{url_hotkey.url});
        try plan.add(.{ .id = bindings.bandId(bindings.HOTKEY_ID_URL_HOTKEY_BASE, index), .keys = url_hotkey.hotkey, .action = .{ .open_url = .{ .url_index = index } }, .description = description });
    }

    return plan;
}

/// Null while `binding` has no keys.
pub fn globalEntry(settings: Settings, comptime binding: bindings.GlobalBinding) ?Entry {
    const keys: KeyList = if (binding.is_global_setting) @field(settings.global, binding.field) else @field(settings.hotkeys, binding.field);
    if (keys.isEmpty()) return null;
    return .{ .id = bindings.globalId(binding.action), .keys = keys, .action = bindings.actionFor(binding.action), .description = binding.description };
}

/// The suspend key still toggles while hotkeys are suspended, as it's what resumes them.
pub fn pressVerdict(facts: PressFacts) Verdict {
    if (facts.is_repeat and !facts.allows_repeat) return .ignore_repeat;
    if (facts.is_suspend_key) return .toggle_suspend;
    if (facts.are_hotkeys_suspended) return .ignore_suspended;
    if (facts.is_dialog_recording) return .ignore_recording;
    if (facts.requires_eve_focus and !facts.has_eve_focus) return .ignore_unfocused;
    return .run;
}

/// A chain's forward and backward combos take adjacent slots.
fn addGroupChains(plan: *Plan, groups: []const HotkeyGroupConfig, chains: []const ComboSharers, is_forward: bool) !void {
    const arena = plan.arena.allocator();
    const direction = cycle_order.directionName(is_forward);
    for (chains, 0..) |chain, chain_index| {
        const first_name = groups[chain.indices.items[0]].name;
        const slot = chain_index * 2 + @intFromBool(!is_forward);
        if (slot >= bindings.CYCLE_GROUP_SLOT_COUNT) {
            try plan.overflows.append(arena, .{ .group_name = first_name, .is_forward = is_forward });
            continue;
        }
        const description = if (chain.indices.items.len == 1)
            try std.fmt.allocPrint(arena, "group [{s}] {s}", .{ first_name, direction })
        else
            try std.fmt.allocPrint(arena, "groups [{s}...] {s} ({d} sharing hotkey)", .{ first_name, direction, chain.indices.items.len });
        try plan.add(.{
            .id = bindings.bandId(bindings.HOTKEY_ID_CYCLE_GROUP_BASE, slot),
            .keys = .one(chain.virtual_key),
            .action = .{ .cycle_group = .{ .group_indices = chain.indices.items, .is_forward = is_forward } },
            .description = description,
        });
    }
}

fn addGroupKey(plan: *Plan, base: c_int, group: *const HotkeyGroupConfig, group_index: usize, keys: KeyList, action: HotkeyAction, comptime verb: []const u8) !void {
    if (keys.isEmpty()) return;
    const description = try std.fmt.allocPrint(plan.arena.allocator(), "group {d} [{s}] " ++ verb, .{ group_index, group.name });
    try plan.add(.{ .id = bindings.bandId(base, group_index), .keys = keys, .action = action, .description = description });
}

fn addComboSharer(arena: std.mem.Allocator, list: *std.ArrayList(ComboSharers), combo_vk: u32, index: usize) !void {
    for (list.items) |*sharers| {
        if (sharers.virtual_key == combo_vk) return sharers.indices.append(arena, index);
    }
    var sharers: ComboSharers = .{ .virtual_key = combo_vk, .indices = .empty };
    try sharers.indices.append(arena, index);
    try list.append(arena, sharers);
}

const testing = std.testing;

const F1 = 0x70;
const F2 = 0x71;
const F3 = 0x72;
const NO_HOTKEYS: HotkeysConfig = .{};
const QUIET_PRESS: PressFacts = .{
    .is_repeat = false,
    .allows_repeat = false,
    .is_suspend_key = false,
    .are_hotkeys_suspended = false,
    .is_dialog_recording = false,
    .requires_eve_focus = false,
    .has_eve_focus = true,
};

fn testSettings(characters: []const CharacterConfig, groups: []const HotkeyGroupConfig, global: *const GlobalConfig) Settings {
    return .{ .characters = characters, .groups = groups, .hotkeys = &NO_HOTKEYS, .global = global };
}

fn findEntry(plan: *const Plan, id: c_int) ?Entry {
    for (plan.entries.items) |entry| {
        if (entry.id == id) return entry;
    }
    return null;
}

test "characters sharing a hotkey become one activate_character entry" {
    const global: GlobalConfig = .{ .allocator = testing.allocator };
    const characters = [_]CharacterConfig{ .{ .name = "Alpha", .hotkey = .one(F1) }, .{ .name = "Bravo", .hotkey = .one(F2) }, .{ .name = "Charlie", .hotkey = .one(F1) } };
    var plan = try build(testing.allocator, testSettings(&characters, &.{}, &global));
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 2), plan.entries.items.len);
    const shared = findEntry(&plan, bindings.HOTKEY_ID_PER_CHARACTER_BASE).?;
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, shared.action.activate_character.character_indices);
    try testing.expectEqualStrings("activate character [Alpha...] (2 sharing hotkey)", shared.description);
}

test "a group's forward and backward keys take adjacent cycle slots" {
    const global: GlobalConfig = .{ .allocator = testing.allocator };
    const groups = [_]HotkeyGroupConfig{.{ .name = "Miners", .forwardKey = .one(F1), .backwardKey = .one(F2) }};
    var plan = try build(testing.allocator, testSettings(&.{}, &groups, &global));
    defer plan.deinit();

    const forward = findEntry(&plan, bindings.HOTKEY_ID_CYCLE_GROUP_BASE).?;
    const backward = findEntry(&plan, bindings.HOTKEY_ID_CYCLE_GROUP_BASE + 1).?;
    try testing.expect(forward.action.cycle_group.is_forward);
    try testing.expect(!backward.action.cycle_group.is_forward);
    try testing.expectEqualStrings("group [Miners] forward", forward.description);
}

test "group chains past CYCLE_GROUP_SLOT_COUNT are reported, not planned" {
    const global: GlobalConfig = .{ .allocator = testing.allocator };
    const chain_count = bindings.CYCLE_GROUP_SLOT_COUNT / 2 + 1;
    var groups: [chain_count]HotkeyGroupConfig = undefined;
    for (&groups, 0..) |*group, index| group.* = .{ .name = "Group", .forwardKey = .one(@intCast(0x10000 + index)) };
    var plan = try build(testing.allocator, testSettings(&.{}, &groups, &global));
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 1), plan.overflows.items.len);
    try testing.expect(plan.overflows.items[0].is_forward);
    try testing.expectEqual(@as(usize, chain_count - 1), plan.entries.items.len);
}

test "global bindings are planned before groups and characters" {
    var global: GlobalConfig = .{ .allocator = testing.allocator };
    global.hotkeyNextProfile = .one(F3);
    const characters = [_]CharacterConfig{.{ .name = "Alpha", .hotkey = .one(F1) }};
    const groups = [_]HotkeyGroupConfig{.{ .name = "Miners", .forwardKey = .one(F2) }};
    var plan = try build(testing.allocator, testSettings(&characters, &groups, &global));
    defer plan.deinit();

    try testing.expectEqual(bindings.globalId(.next_profile), plan.entries.items[0].id);
    try testing.expectEqual(@as(usize, 1), plan.counts.globals);
}

test "unbound group, profile, app and url hotkeys get no entry" {
    var global: GlobalConfig = .{ .allocator = testing.allocator };
    defer global.profileSwitchHotkeys.deinit(testing.allocator);
    try global.profileSwitchHotkeys.append(testing.allocator, .{ .targetProfile = "Other" });
    const groups = [_]HotkeyGroupConfig{.{ .name = "Idle" }};
    var plan = try build(testing.allocator, testSettings(&.{}, &groups, &global));
    defer plan.deinit();

    try testing.expect(plan.isEmpty());
    try testing.expectEqual(@as(usize, 0), plan.counts.profile_switches);
}

test "a repeat press is dropped unless auto-repeat is allowed" {
    var press = QUIET_PRESS;
    press.is_repeat = true;
    try testing.expectEqual(Verdict.ignore_repeat, pressVerdict(press));
    press.allows_repeat = true;
    try testing.expectEqual(Verdict.run, pressVerdict(press));
}

test "the suspend hotkey still toggles while hotkeys are suspended" {
    var press = QUIET_PRESS;
    press.are_hotkeys_suspended = true;
    try testing.expectEqual(Verdict.ignore_suspended, pressVerdict(press));
    press.is_suspend_key = true;
    try testing.expectEqual(Verdict.toggle_suspend, pressVerdict(press));
}

test "a press needing EVE focus is dropped when no EVE window is in front" {
    var press = QUIET_PRESS;
    press.requires_eve_focus = true;
    press.has_eve_focus = false;
    try testing.expectEqual(Verdict.ignore_unfocused, pressVerdict(press));
    press.has_eve_focus = true;
    try testing.expectEqual(Verdict.run, pressVerdict(press));
}
