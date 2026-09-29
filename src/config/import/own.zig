//! This app's own profile files, loaded through the normal profile loader so an older format migrates and clamps the same way.
const std = @import("std");
const values = @import("values.zig");
const draft = @import("draft.zig");
const eve_x = @import("eve_x.zig");
const wire = @import("../wire.zig");
const config = @import("../../config.zig");

const Value = std.json.Value;
const Config = config.Config;
const Draft = draft.Draft;
const Section = draft.Section;

pub fn isFile(root: Value) bool {
    const app = values.stringAt(root, "app") orelse return false;
    return std.mem.eql(u8, app, config.PROFILE_FORMAT_IDENTIFIER);
}

/// Stamped on every save rather than chosen by the user.
fn isStamp(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "app") or std.mem.eql(u8, name, "formatVersion");
}

fn isList(comptime T: type) bool {
    return wire.ListItem(T) != null;
}

/// Every saved section, so one added later is importable without a change here.
pub fn sections(d: *Draft, root: Value) ![]const Section {
    var out: std.ArrayList(Section) = .empty;
    inline for (comptime wire.savedFields(Config)) |f| {
        if (comptime isStamp(f.name)) continue;
        const raw = values.get(root, f.name);
        const key = "dynamic.import.maj." ++ f.name;
        if (comptime isList(f.type)) {
            const n = if (raw) |r| (if (r == .array) r.array.items.len else 0) else 0;
            try out.append(d.arena, .{ .id = f.name, .title = key ++ ".title", .hint = try d.countText(key ++ ".hint", n), .available = n > 0 });
        } else {
            const in_file = if (raw) |r| r != .null else false;
            try out.append(d.arena, .{ .id = f.name, .title = key ++ ".title", .hint = .{ .key = key ++ ".hint" }, .available = in_file });
        }
    }
    return out.items;
}

pub fn build(d: *Draft, text: []const u8, root: Value, chosen: []const []const u8) !void {
    const cfg = try Config.buildConfigFromJson(d.arena, text, "import");
    inline for (comptime wire.savedFields(Config)) |f| {
        if (comptime isStamp(f.name)) continue;
        if (eve_x.isChosen(chosen, f.name)) try importSection(d, &cfg, root, f.name);
    }
}

fn importSection(d: *Draft, cfg: *const Config, root: Value, comptime name: []const u8) !void {
    const raw = values.get(root, name) orelse return;
    if (raw == .null) return;
    const loaded = try draft.toValue(d.arena, Config, cfg, &.{.{ .string = name }});
    try d.root.put(d.arena, name, try present(d.arena, loaded, raw));
    try sectionNote(d, name, if (raw == .array) raw.array.items.len else 0);
}

fn sectionNote(d: *Draft, comptime name: []const u8, n: usize) !void {
    const list_notes = .{
        .{ "characters", "dynamic.import.maj.charactersImportedNote" },
        .{ "systemColors", "dynamic.import.maj.systemColorsImportedNote" },
        .{ "hotkeyGroups", "dynamic.import.hotkeyGroupsImportedNote" },
        .{ "windowFilters", "dynamic.import.maj.windowFiltersImportedNote" },
    };
    inline for (list_notes) |entry| {
        if (comptime std.mem.eql(u8, entry[0], name)) return d.noteCount(entry[1], "n", n);
    }
    try d.note("dynamic.import.maj.sectionImportedNote", &.{.{ .name = "title", .value = "dynamic.import.maj." ++ name ++ ".title", .translate = true }});
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
        var out = std.json.Array.init(arena);
        for (loaded.array.items, raw.array.items) |item, raw_item| try out.append(try present(arena, item, raw_item));
        return .{ .array = out };
    }
    return loaded;
}
