//! This app's own profile files, loaded through the normal profile loader so an older format migrates and clamps the same way.
const std = @import("std");
const values = @import("values.zig");
const draft_mod = @import("draft.zig");
const wire = @import("../wire.zig");
const readable = @import("../readable.zig");
const config_mod = @import("../../config.zig");

const Value = std.json.Value;
const Config = config_mod.Config;
const Draft = draft_mod.Draft;
const Section = draft_mod.Section;

pub fn isFile(root: Value) bool {
    const app = values.stringAt(root, "app") orelse return false;
    return std.mem.eql(u8, app, config_mod.PROFILE_FORMAT_IDENTIFIER);
}

/// Every saved section, so one added later is importable without a change here.
pub fn sections(draft: *Draft, root: Value) ![]const Section {
    var migrated = root;
    try config_mod.migrateProfileJson(draft.arena, &migrated);
    var out: std.ArrayList(Section) = .empty;
    inline for (comptime wire.savedFields(Config)) |f| {
        if (comptime isStamp(f.name)) continue;
        const raw = values.get(migrated, f.name);
        const key = "dynamic.import.maj." ++ f.name;
        if (comptime isList(f.type)) {
            const item_count = if (raw) |value| (if (value == .array) value.array.items.len else 0) else 0;
            try out.append(draft.arena, .{ .id = f.name, .title = key ++ ".title", .hint = try draft.countText(key ++ ".hint", item_count), .available = item_count > 0 });
        } else {
            const is_in_file = if (raw) |value| value != .null else false;
            try out.append(draft.arena, .{ .id = f.name, .title = key ++ ".title", .hint = .{ .key = key ++ ".hint" }, .available = is_in_file });
        }
    }
    return out.items;
}

pub fn build(draft: *Draft, text: []const u8, root: Value, chosen: []const []const u8) !void {
    // So an unreadable setting keeps the profile's current value instead of taking the default.
    var readable_root = root;
    // The same upgrade buildConfigFromJson applies, so present() still finds the migrated sections in the file.
    try config_mod.migrateProfileJson(draft.arena, &readable_root);
    var skipped: std.ArrayList([]const u8) = .empty;
    _ = readable.dropUnreadable(Config.Wire, draft.arena, &readable_root, &skipped);

    const config = try Config.buildConfigFromJson(draft.arena, text, "import");
    inline for (comptime wire.savedFields(Config)) |f| {
        if (comptime isStamp(f.name)) continue;
        if (draft_mod.isChosen(chosen, f.name)) try importSection(draft, &config, readable_root, f.name);
    }
    for (skipped.items) |path| {
        const section_end = std.mem.findScalar(u8, path, '.') orelse path.len;
        if (!draft_mod.isChosen(chosen, path[0..section_end])) continue;
        try draft.skipped.append(draft.arena, path);
    }
}

/// Stamped on every save rather than chosen by the user.
fn isStamp(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "app") or std.mem.eql(u8, name, "formatVersion");
}

fn isList(comptime T: type) bool {
    return wire.ListItem(T) != null;
}

fn importSection(draft: *Draft, config: *const Config, root: Value, comptime name: []const u8) !void {
    const raw = values.get(root, name) orelse return;
    if (raw == .null) return;
    const loaded = try draft_mod.toValue(draft.arena, Config, config, &.{.{ .string = name }});
    var section = try present(draft.arena, loaded, raw);
    if (comptime std.mem.eql(u8, name, "characters")) dropPlaceholderCharacters(&section);
    try draft.root.put(draft.arena, name, section);
    try sectionNote(draft, name, if (section == .array) section.array.items.len else 0);
}

/// Older imports from other tools let their sample entries ("Example Name1") through, so a profile copy shouldn't carry them on.
fn dropPlaceholderCharacters(list: *Value) void {
    if (list.* != .array) return;
    var kept_count: usize = 0;
    for (list.array.items) |item| {
        if (values.characterName(values.stringAt(item, "name") orelse "") == null) continue;
        list.array.items[kept_count] = item;
        kept_count += 1;
    }
    list.array.shrinkRetainingCapacity(kept_count);
}

fn sectionNote(draft: *Draft, comptime name: []const u8, item_count: usize) !void {
    const list_notes = .{
        .{ "characters", "dynamic.import.maj.charactersImportedNote" },
        .{ "systemColors", "dynamic.import.maj.systemColorsImportedNote" },
        .{ "hotkeyGroups", "dynamic.import.hotkeyGroupsImportedNote" },
        .{ "windowFilters", "dynamic.import.maj.windowFiltersImportedNote" },
        .{ "thumbnailSpaces", "dynamic.import.maj.thumbnailSpacesImportedNote" },
    };
    inline for (list_notes) |entry| {
        if (comptime std.mem.eql(u8, entry[0], name)) return draft.noteCount(entry[1], "n", item_count);
    }
    try draft.note("dynamic.import.maj.sectionImportedNote", &.{.{ .name = "title", .value = "dynamic.import.maj." ++ name ++ ".title", .should_translate = true }});
}

/// Only what the file has: `loaded` holds every field, defaults included, but a field an older file lacks should keep its current value.
fn present(arena: std.mem.Allocator, loaded: Value, raw: Value) !Value {
    if (loaded == .object and raw == .object) {
        var out: std.json.ObjectMap = .empty;
        var it = loaded.object.iterator();
        while (it.next()) |entry| {
            const raw_field = raw.object.get(entry.key_ptr.*) orelse continue;
            try out.put(arena, entry.key_ptr.*, try present(arena, entry.value_ptr.*, raw_field));
        }
        return .{ .object = out };
    }
    if (loaded == .array and raw == .array and loaded.array.items.len == raw.array.items.len) {
        var out: std.json.Array = .init(arena);
        for (loaded.array.items, raw.array.items) |item, raw_item| try out.append(try present(arena, item, raw_item));
        return .{ .array = out };
    }
    return loaded;
}
