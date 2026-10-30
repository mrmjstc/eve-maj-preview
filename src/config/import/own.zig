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

/// Each saved section's name and hint in the import dialog, in English; {n} in a list's hint is its item count.
const SECTIONS = std.StaticStringMap(SectionWords).initComptime(.{
    .{ "autoMinimize", SectionWords{ .title = "Auto-Minimize", .hint = "Minimize inactive clients" } },
    .{ "bounty", SectionWords{ .title = "Bounty Tracker", .hint = "Bounty log parsing" } },
    .{ "characters", SectionWords{ .title = "Characters", .hint = "Positions, sizes, colors, hotkeys ({n})" } },
    .{ "chatAlerts", SectionWords{ .title = "Chat Alerts", .hint = "Chat channel alert rules ({n})" } },
    .{ "chatlog", SectionWords{ .title = "Chatlog Monitoring", .hint = "Chat/game log directories and triggers" } },
    .{ "closeAll", SectionWords{ .title = "Close All", .hint = "Close-all behavior" } },
    .{ "combat", SectionWords{ .title = "Combat Tracker", .hint = "Combat log parsing" } },
    .{ "display", SectionWords{ .title = "Display", .hint = "List view appearance" } },
    .{ "hotkeyGroups", SectionWords{ .title = "Hotkey Groups", .hint = "Character cycling groups ({n})" } },
    .{ "hotkeys", SectionWords{ .title = "Global Hotkeys", .hint = "App-wide hotkeys" } },
    .{ "interaction", SectionWords{ .title = "Interaction", .hint = "Click/drag behavior" } },
    .{ "mining", SectionWords{ .title = "Mining Tracker", .hint = "Mining log parsing" } },
    .{ "ping", SectionWords{ .title = "Ping", .hint = "Per-client ping overlay" } },
    .{ "resources", SectionWords{ .title = "Resource Usage", .hint = "Per-client CPU/RAM/VRAM overlay" } },
    .{ "snapping", SectionWords{ .title = "Snapping", .hint = "Thumbnail snapping" } },
    .{ "systemColors", SectionWords{ .title = "System Colors", .hint = "Per-system name colors ({n})" } },
    .{ "thumbnail", SectionWords{ .title = "Thumbnail Appearance & Notifications", .hint = "Border/text styling, per-state visuals, alert notifications" } },
    .{ "thumbnailSpaces", SectionWords{ .title = "Thumbnail Spaces", .hint = "Screen regions hotkey groups fill ({n})" } },
    .{ "timer", SectionWords{ .title = "Scan Timer", .hint = "Window scan interval" } },
    .{ "windowFilters", SectionWords{ .title = "Window Filters", .hint = "Window matching rules for other apps ({n})" } },
    .{ "autoMovePosition", SectionWords{ .title = "Auto-Move Windows", .hint = "Moving game windows to their saved positions" } },
    .{ "exclusion", SectionWords{ .title = "Cycle Exclusion", .hint = "Shift+click exclusion and excluded characters" } },
    .{ "travel", SectionWords{ .title = "Travel Alerts", .hint = "Alerts for characters left behind while traveling" } },
    .{ "accentColor", SectionWords{ .title = "Accent Color", .hint = "The profile's color in this window" } },
});

const SectionWords = struct { title: []const u8, hint: []const u8 };

pub fn isFile(root: Value) bool {
    const app = values.stringAt(root, "app") orelse return false;
    return std.mem.eql(u8, app, config_mod.PROFILE_FORMAT_IDENTIFIER);
}

/// Every saved section; one added later only needs its words in SECTIONS.
pub fn sections(draft: *Draft, root: Value) ![]const Section {
    var migrated = root;
    try config_mod.migrateProfileJson(draft.arena, &migrated);
    var out: std.ArrayList(Section) = .empty;
    inline for (comptime wire.savedFields(Config)) |f| {
        if (comptime isStamp(f.name)) continue;
        const raw = values.get(migrated, f.name);
        const words = comptime sectionWords(f.name);
        if (comptime isList(f.type)) {
            const item_count = if (raw) |value| (if (value == .array) value.array.items.len else 0) else 0;
            try out.append(draft.arena, .{ .id = f.name, .title = words.title, .hint = try draft.countText(words.hint, item_count), .available = item_count > 0 });
        } else {
            const is_in_file = if (raw) |value| value != .null else false;
            try out.append(draft.arena, .{ .id = f.name, .title = words.title, .hint = .{ .key = words.hint }, .available = is_in_file });
        }
    }
    return out.items;
}

pub fn build(draft: *Draft, text: []const u8, root: Value, chosen: []const []const u8) !void {
    var readable_root = root;
    // The same upgrade buildConfigFromJson applies, so present() still finds the migrated sections in the file.
    try config_mod.migrateProfileJson(draft.arena, &readable_root);
    var skipped: std.ArrayList([]const u8) = .empty;
    // So an unreadable setting keeps the profile's current value instead of taking the default.
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

fn sectionWords(comptime name: []const u8) SectionWords {
    return SECTIONS.get(name) orelse @compileError("own.zig's SECTIONS has no words for profile section '" ++ name ++ "'");
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
}

/// Older imports let sample entries ("Example Name1") through; a profile copy drops them.
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

/// A field an older file lacks keeps its current value, though `loaded` has every field.
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
