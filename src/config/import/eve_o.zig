//! EVE-O Preview's settings, one flat JSON object written by a WinForms app.
const std = @import("std");
const vk = @import("../../platform/virtual_keys.zig");
const values = @import("values.zig");
const draft_mod = @import("draft.zig");
const eve_x = @import("eve_x.zig");
const eve_apm = @import("eve_apm.zig");
const key_list = @import("../key_list.zig");

const Value = std.json.Value;
const Draft = draft_mod.Draft;
const KeyList = key_list.KeyList;
const Section = draft_mod.Section;

/// EVE-O Preview's fixed number of cycle groups.
const CYCLE_GROUP_COUNT = 5;
/// Right Win, which `vk` has no name for.
const VK_RWIN = 0x5C;

/// .NET's named colours, the CSS3/X11 set.
const NAMED_COLORS = [_]struct { []const u8, u24 }{
    .{ "aliceblue", 0xF0F8FF },       .{ "antiquewhite", 0xFAEBD7 },      .{ "aqua", 0x00FFFF },                 .{ "aquamarine", 0x7FFFD4 },
    .{ "azure", 0xF0FFFF },           .{ "beige", 0xF5F5DC },             .{ "bisque", 0xFFE4C4 },               .{ "black", 0x000000 },
    .{ "blanchedalmond", 0xFFEBCD },  .{ "blue", 0x0000FF },              .{ "blueviolet", 0x8A2BE2 },           .{ "brown", 0xA52A2A },
    .{ "burlywood", 0xDEB887 },       .{ "cadetblue", 0x5F9EA0 },         .{ "chartreuse", 0x7FFF00 },           .{ "chocolate", 0xD2691E },
    .{ "coral", 0xFF7F50 },           .{ "cornflowerblue", 0x6495ED },    .{ "cornsilk", 0xFFF8DC },             .{ "crimson", 0xDC143C },
    .{ "cyan", 0x00FFFF },            .{ "darkblue", 0x00008B },          .{ "darkcyan", 0x008B8B },             .{ "darkgoldenrod", 0xB8860B },
    .{ "darkgray", 0xA9A9A9 },        .{ "darkgreen", 0x006400 },         .{ "darkgrey", 0xA9A9A9 },             .{ "darkkhaki", 0xBDB76B },
    .{ "darkmagenta", 0x8B008B },     .{ "darkolivegreen", 0x556B2F },    .{ "darkorange", 0xFF8C00 },           .{ "darkorchid", 0x9932CC },
    .{ "darkred", 0x8B0000 },         .{ "darksalmon", 0xE9967A },        .{ "darkseagreen", 0x8FBC8F },         .{ "darkslateblue", 0x483D8B },
    .{ "darkslategray", 0x2F4F4F },   .{ "darkslategrey", 0x2F4F4F },     .{ "darkturquoise", 0x00CED1 },        .{ "darkviolet", 0x9400D3 },
    .{ "deeppink", 0xFF1493 },        .{ "deepskyblue", 0x00BFFF },       .{ "dimgray", 0x696969 },              .{ "dimgrey", 0x696969 },
    .{ "dodgerblue", 0x1E90FF },      .{ "firebrick", 0xB22222 },         .{ "floralwhite", 0xFFFAF0 },          .{ "forestgreen", 0x228B22 },
    .{ "fuchsia", 0xFF00FF },         .{ "gainsboro", 0xDCDCDC },         .{ "ghostwhite", 0xF8F8FF },           .{ "gold", 0xFFD700 },
    .{ "goldenrod", 0xDAA520 },       .{ "gray", 0x808080 },              .{ "grey", 0x808080 },                 .{ "green", 0x008000 },
    .{ "greenyellow", 0xADFF2F },     .{ "honeydew", 0xF0FFF0 },          .{ "hotpink", 0xFF69B4 },              .{ "indianred", 0xCD5C5C },
    .{ "indigo", 0x4B0082 },          .{ "ivory", 0xFFFFF0 },             .{ "khaki", 0xF0E68C },                .{ "lavender", 0xE6E6FA },
    .{ "lavenderblush", 0xFFF0F5 },   .{ "lawngreen", 0x7CFC00 },         .{ "lemonchiffon", 0xFFFACD },         .{ "lightblue", 0xADD8E6 },
    .{ "lightcoral", 0xF08080 },      .{ "lightcyan", 0xE0FFFF },         .{ "lightgoldenrodyellow", 0xFAFAD2 }, .{ "lightgray", 0xD3D3D3 },
    .{ "lightgreen", 0x90EE90 },      .{ "lightgrey", 0xD3D3D3 },         .{ "lightpink", 0xFFB6C1 },            .{ "lightsalmon", 0xFFA07A },
    .{ "lightseagreen", 0x20B2AA },   .{ "lightskyblue", 0x87CEFA },      .{ "lightslategray", 0x778899 },       .{ "lightslategrey", 0x778899 },
    .{ "lightsteelblue", 0xB0C4DE },  .{ "lightyellow", 0xFFFFE0 },       .{ "lime", 0x00FF00 },                 .{ "limegreen", 0x32CD32 },
    .{ "linen", 0xFAF0E6 },           .{ "magenta", 0xFF00FF },           .{ "maroon", 0x800000 },               .{ "mediumaquamarine", 0x66CDAA },
    .{ "mediumblue", 0x0000CD },      .{ "mediumorchid", 0xBA55D3 },      .{ "mediumpurple", 0x9370DB },         .{ "mediumseagreen", 0x3CB371 },
    .{ "mediumslateblue", 0x7B68EE }, .{ "mediumspringgreen", 0x00FA9A }, .{ "mediumturquoise", 0x48D1CC },      .{ "mediumvioletred", 0xC71585 },
    .{ "midnightblue", 0x191970 },    .{ "mintcream", 0xF5FFFA },         .{ "mistyrose", 0xFFE4E1 },            .{ "moccasin", 0xFFE4B5 },
    .{ "navajowhite", 0xFFDEAD },     .{ "navy", 0x000080 },              .{ "oldlace", 0xFDF5E6 },              .{ "olive", 0x808000 },
    .{ "olivedrab", 0x6B8E23 },       .{ "orange", 0xFFA500 },            .{ "orangered", 0xFF4500 },            .{ "orchid", 0xDA70D6 },
    .{ "palegoldenrod", 0xEEE8AA },   .{ "palegreen", 0x98FB98 },         .{ "paleturquoise", 0xAFEEEE },        .{ "palevioletred", 0xDB7093 },
    .{ "papayawhip", 0xFFEFD5 },      .{ "peachpuff", 0xFFDAB9 },         .{ "peru", 0xCD853F },                 .{ "pink", 0xFFC0CB },
    .{ "plum", 0xDDA0DD },            .{ "powderblue", 0xB0E0E6 },        .{ "purple", 0x800080 },               .{ "rebeccapurple", 0x663399 },
    .{ "red", 0xFF0000 },             .{ "rosybrown", 0xBC8F8F },         .{ "royalblue", 0x4169E1 },            .{ "saddlebrown", 0x8B4513 },
    .{ "salmon", 0xFA8072 },          .{ "sandybrown", 0xF4A460 },        .{ "seagreen", 0x2E8B57 },             .{ "seashell", 0xFFF5EE },
    .{ "sienna", 0xA0522D },          .{ "silver", 0xC0C0C0 },            .{ "skyblue", 0x87CEEB },              .{ "slateblue", 0x6A5ACD },
    .{ "slategray", 0x708090 },       .{ "slategrey", 0x708090 },         .{ "snow", 0xFFFAFA },                 .{ "springgreen", 0x00FF7F },
    .{ "steelblue", 0x4682B4 },       .{ "tan", 0xD2B48C },               .{ "teal", 0x008080 },                 .{ "thistle", 0xD8BFD8 },
    .{ "tomato", 0xFF6347 },          .{ "turquoise", 0x40E0D0 },         .{ "violet", 0xEE82EE },               .{ "wheat", 0xF5DEB3 },
    .{ "white", 0xFFFFFF },           .{ "whitesmoke", 0xF5F5F5 },        .{ "yellow", 0xFFFF00 },               .{ "yellowgreen", 0x9ACD32 },
};

/// It has no wrapper key to recognise it by, so a few fields it always writes are.
pub fn isFile(root: Value) bool {
    if (values.get(root, "CycleGroup1ForwardHotkeys")) |v| {
        if (v == .array) return true;
    }
    return values.objectAt(root, "FlatLayout") != null or values.objectAt(root, "DisableThumbnail") != null;
}

pub fn sections(draft: *Draft, root: Value) ![]const Section {
    var positioned: std.array_hash_map.String(void) = .empty;
    var position_count: usize = 0;
    inline for (.{ "FlatLayout", "PerClientThumbnailSize", "DisableThumbnail" }) |map| {
        position_count += try countCharacters(draft.arena, values.objectAt(root, map), &positioned);
    }
    var colored: std.array_hash_map.String(void) = .empty;
    const color_count = try countCharacters(draft.arena, values.objectAt(root, "PerClientActiveClientHighlightColor"), &colored);
    var hotkeyed: std.array_hash_map.String(void) = .empty;
    const hotkey_count = try countCharacters(draft.arena, values.objectAt(root, "ClientHotkey"), &hotkeyed);
    var group_count: usize = 0;
    for (1..CYCLE_GROUP_COUNT + 1) |group_number| {
        if ((try cycleGroupMembers(draft.arena, root, group_number)).len > 0) group_count += 1;
    }
    const has_appearance = values.has(root, "ThumbnailsOpacity") or values.has(root, "ActiveClientHighlightColor") or
        values.has(root, "OverlayLabelColor") or values.has(root, "ThumbnailSize");

    return draft.arena.dupe(Section, &.{
        .{ .id = "thumbnailAppearance", .title = "dynamic.import.eveo.thumbnailAppearance.title", .hint = .{ .key = "dynamic.import.eveo.thumbnailAppearance.hint" }, .available = has_appearance },
        .{ .id = "characterPositions", .title = "dynamic.import.eveo.characterPositions.title", .hint = try draft.countText("dynamic.import.characterPositionsHint", position_count), .available = position_count > 0 },
        .{ .id = "characterColors", .title = "dynamic.import.eveo.characterColors.title", .hint = try eve_x.colorsHint(draft, color_count, hotkey_count), .available = color_count + hotkey_count > 0 },
        .{ .id = "hotkeyGroups", .title = "dynamic.import.eveo.hotkeyGroups.title", .hint = try draft.countText("dynamic.import.hotkeyGroupsCountHint", group_count), .available = group_count > 0 },
        .{ .id = "autoMinimize", .title = "dynamic.import.eveo.autoMinimize.title", .hint = .{ .key = "dynamic.import.eveo.autoMinimize.hint" }, .available = values.has(root, "MinimizeInactiveClients") },
        .{ .id = "snapping", .title = "dynamic.import.eveo.snapping.title", .hint = .{ .key = "dynamic.import.eveo.snapping.hint" }, .available = values.has(root, "EnableThumbnailSnap") },
    });
}

/// `cycle_group_name` is the translated "Cycle Group {n}", since EVE-O Preview's groups have no names.
pub fn build(draft: *Draft, root: Value, chosen: []const []const u8, cycle_group_name: []const u8) !void {
    if (draft_mod.isChosen(chosen, "thumbnailAppearance")) try appearance(draft, root);
    if (draft_mod.isChosen(chosen, "characterPositions")) try characterPositions(draft, root);
    if (draft_mod.isChosen(chosen, "characterColors")) try colorsAndHotkeys(draft, root);
    if (draft_mod.isChosen(chosen, "hotkeyGroups")) try hotkeyGroups(draft, root, cycle_group_name);
    if (draft_mod.isChosen(chosen, "autoMinimize")) {
        if (values.get(root, "MinimizeInactiveClients")) |v| try draft.setBool("autoMinimize.enabled", values.truthy(v));
        try draft.note("dynamic.import.autoMinimizeImportedNote", &.{});
    }
    if (draft_mod.isChosen(chosen, "snapping")) {
        if (values.get(root, "EnableThumbnailSnap")) |v| try draft.setBool("snapping.enabled", values.truthy(v));
        try draft.note("dynamic.import.snappingImportedNote", &.{});
    }
}

/// "#RRGGBB", "#AARRGGBB" (its alpha dropped, as borders and text here are opaque) or a .NET colour name.
fn color(text: ?[]const u8) ?u32 {
    const trimmed = std.mem.trim(u8, text orelse return null, " \t");
    if (std.mem.startsWith(u8, trimmed, "#")) {
        if (trimmed.len == 9) {
            const argb = std.fmt.parseInt(u32, trimmed[1..], 16) catch return null;
            return 0xFF000000 | (argb & 0x00FFFFFF);
        }
        return values.rgbColor(trimmed);
    }
    for (NAMED_COLORS) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry[0])) return 0xFF000000 | @as(u32, entry[1]);
    }
    return null;
}

/// WinForms writes a Size or Point as "W, H" / "X, Y".
fn pair(value: ?Value) ?[2]f64 {
    const unwrapped = value orelse return null;
    if (unwrapped != .string) return null;
    var parts = std.mem.tokenizeAny(u8, unwrapped.string, ", \t");
    const first = values.parseIntLoose(parts.next()) orelse return null;
    const second = values.parseIntLoose(parts.next()) orelse return null;
    return .{ @floatFromInt(first), @floatFromInt(second) };
}

/// WinForms' Keys names the digit row "D0".."D9" and has LWin/RWin keys of its own.
fn baseKey(token: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, token, " \t");
    if (trimmed.len == 2 and (trimmed[0] == 'D' or trimmed[0] == 'd') and std.ascii.isDigit(trimmed[1])) return trimmed[1];
    if (std.ascii.eqlIgnoreCase(trimmed, "lwin")) return vk.VK_LWIN;
    if (std.ascii.eqlIgnoreCase(trimmed, "rwin")) return VK_RWIN;
    return values.legacyBaseKey(trimmed);
}

/// "Control+Alt+F14"; WinForms' key flags have no Windows-key modifier.
fn hotkey(raw: []const u8) ?u32 {
    var buf: [8][]const u8 = undefined;
    var tokens: std.ArrayList([]const u8) = .initBuffer(&buf);
    var it = std.mem.tokenizeScalar(u8, raw, '+');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len == 0) continue;
        tokens.appendBounded(trimmed) catch return null;
    }
    if (tokens.items.len == 0) return null;
    var modifiers: u32 = 0;
    for (tokens.items[0 .. tokens.items.len - 1]) |word| {
        if (std.ascii.eqlIgnoreCase(word, "control")) {
            modifiers |= vk.MOD_CONTROL;
        } else if (std.ascii.eqlIgnoreCase(word, "alt")) {
            modifiers |= vk.MOD_ALT;
        } else if (std.ascii.eqlIgnoreCase(word, "shift")) {
            modifiers |= vk.MOD_SHIFT;
        } else return null;
    }
    const code = baseKey(tokens.items[tokens.items.len - 1]) orelse return null;
    return vk.combineKey(code, modifiers);
}

fn boundKeys(arena: std.mem.Allocator, list: []const Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |v| {
        if (v == .string and std.mem.trim(u8, v.string, " \t").len > 0) try out.append(arena, v.string);
    }
    return out.items;
}

/// Every key that converts, noting each one that doesn't; EVE-O Preview can bind several.
fn groupKeys(draft: *Draft, bound: []const []const u8, group_name: []const u8, failed_note: []const u8) !KeyList {
    var keys: KeyList = .empty;
    for (bound) |raw| {
        const combined = hotkey(raw) orelse {
            try draft.note(failed_note, &.{ .{ .name = "name", .value = group_name }, .{ .name = "key", .value = raw } });
            continue;
        };
        _ = keys.append(combined);
    }
    return keys;
}

/// In the order EVE-O Preview cycles them, its ClientsOrder index.
fn cycleGroupMembers(arena: std.mem.Allocator, root: Value, group_number: usize) ![]const []const u8 {
    const key = try arena.print("CycleGroup{d}ClientsOrder", .{group_number});
    const order = values.objectAt(root, key) orelse return &.{};
    const Member = struct { name: []const u8, order: f64 };
    var members: std.ArrayList(Member) = .empty;
    var it = order.object.iterator();
    while (it.next()) |entry| {
        const name = values.characterName(entry.key_ptr.*) orelse continue;
        try members.append(arena, .{ .name = name, .order = values.number(entry.value_ptr.*) orelse 0 });
    }
    std.mem.sort(Member, members.items, {}, struct {
        fn lessThan(_: void, a: Member, b: Member) bool {
            return a.order < b.order;
        }
    }.lessThan);
    const names = try arena.alloc([]const u8, members.items.len);
    for (members.items, names) |member, *name| name.* = member.name;
    return names;
}

fn countCharacters(arena: std.mem.Allocator, map: ?Value, seen: *std.array_hash_map.String(void)) !usize {
    const object = map orelse return 0;
    var new_count: usize = 0;
    for (object.object.keys()) |key| {
        const name = values.characterName(key) orelse continue;
        if (!(try seen.getOrPut(arena, name)).found_existing) new_count += 1;
    }
    return new_count;
}

fn appearance(draft: *Draft, root: Value) !void {
    try draft.note("dynamic.import.thumbnailAppearanceImportedNote", &.{});
    if (values.jsonNumber(values.get(root, "ThumbnailsOpacity"))) |fraction| {
        try draft.setNumber("thumbnail.thumbnailOpacity", std.math.clamp(@round(fraction * 255), 0, 255));
    }
    if (values.get(root, "EnableActiveClientHighlight")) |v| try draft.setBool("thumbnail.showBorderWhenFocused", values.truthy(v));
    if (values.stringAt(root, "ActiveClientHighlightColor")) |raw| {
        if (color(raw)) |parsed| {
            try draft.setColor("thumbnail.borderColor", parsed);
        } else {
            try draft.note("dynamic.import.eveo.activeColorUnrecognizedNote", &.{.{ .name = "color", .value = raw }});
        }
    }
    try draft.setNumber("thumbnail.borderWidth", values.jsonNumber(values.get(root, "ActiveClientHighlightThickness")));

    // One "frames on every thumbnail" toggle rather than separate active and inactive borders.
    if (values.get(root, "ShowThumbnailFrames")) |v| try draft.setBool("thumbnail.showBorderWhenInactive", values.truthy(v));
    if (values.get(root, "ShowThumbnailOverlays")) |v| try draft.setBool("thumbnail.showText", values.truthy(v));

    if (values.stringAt(root, "OverlayLabelColor")) |raw| {
        if (color(raw)) |parsed| {
            try draft.setColor("thumbnail.characterNameColor", parsed);
        } else {
            try draft.note("dynamic.import.eveo.labelColorUnrecognizedNote", &.{.{ .name = "color", .value = raw }});
        }
    }
    try draft.setOverlayFont(null, values.jsonNumber(values.get(root, "OverlayLabelSize")));
    try draft.setString("thumbnail.characterNamePosition", eve_apm.anchorName(values.jsonNumber(values.get(root, "OverlayLabelAnchor"))));

    if (values.get(root, "HideThumbnailsOnLostFocus")) |v| try draft.setBool("thumbnail.hideWhenNoEveFocus", values.truthy(v));
    if (values.get(root, "HideActiveClientThumbnail")) |v| try draft.setBool("thumbnail.activeThumbnailHidden", values.truthy(v));

    if (values.get(root, "ThumbnailZoomEnabled")) |v| try draft.setBool("interaction.hoverZoomEnabled", values.truthy(v));
    // EVE-O stores a multiple, not a percentage.
    if (values.jsonNumber(values.get(root, "ThumbnailZoomFactor"))) |factor| try draft.setNumber("interaction.hoverZoomPercent", factor * 100);
    try draft.setString("interaction.hoverZoomAnchor", eve_apm.anchorName(values.jsonNumber(values.get(root, "ThumbnailZoomAnchor"))));

    if (pair(values.get(root, "ThumbnailSize"))) |size| {
        try draft.setNumber("thumbnail.width", size[0]);
        try draft.setNumber("thumbnail.height", size[1]);
    }
}

fn characterPositions(draft: *Draft, root: Value) !void {
    var imported_names: std.array_hash_map.String(void) = .empty;
    var skipped_names: std.array_hash_map.String(void) = .empty;

    if (values.objectAt(root, "FlatLayout")) |layout| {
        var it = layout.object.iterator();
        while (it.next()) |entry| {
            const name = values.characterName(entry.key_ptr.*) orelse {
                try skipped_names.put(draft.arena, entry.key_ptr.*, {});
                continue;
            };
            const point = pair(entry.value_ptr.*) orelse continue;
            try eve_x.putPosition(draft, try draft.character(name), point[0], point[1]);
            try imported_names.put(draft.arena, name, {});
        }
    }
    if (values.objectAt(root, "PerClientThumbnailSize")) |sizes| {
        var it = sizes.object.iterator();
        while (it.next()) |entry| {
            const name = values.characterName(entry.key_ptr.*) orelse {
                try skipped_names.put(draft.arena, entry.key_ptr.*, {});
                continue;
            };
            const size = pair(entry.value_ptr.*) orelse continue;
            const character = try draft.character(name);
            try draft.put(character, "thumbnailSize.width", values.numberValue(size[0]));
            try draft.put(character, "thumbnailSize.height", values.numberValue(size[1]));
            try imported_names.put(draft.arena, name, {});
        }
    }
    if (values.objectAt(root, "DisableThumbnail")) |disabled| {
        var it = disabled.object.iterator();
        while (it.next()) |entry| {
            const name = values.characterName(entry.key_ptr.*) orelse {
                try skipped_names.put(draft.arena, entry.key_ptr.*, {});
                continue;
            };
            if (!values.truthy(entry.value_ptr.*)) continue;
            try draft.put(try draft.character(name), "hideThumbnail", .{ .bool = true });
            try imported_names.put(draft.arena, name, {});
        }
    }
    try draft.noteCount("dynamic.import.importedPositionsWithSizeNote", "n", imported_names.count());
    if (skipped_names.count() > 0) try draft.noteCount("dynamic.import.eveo.skippedPlaceholderNote", "n", skipped_names.count());
}

fn colorsAndHotkeys(draft: *Draft, root: Value) !void {
    var skipped_names: std.array_hash_map.String(void) = .empty;
    var colored_count: usize = 0;
    if (values.objectAt(root, "PerClientActiveClientHighlightColor")) |colors| {
        var it = colors.object.iterator();
        while (it.next()) |entry| {
            const name = values.characterName(entry.key_ptr.*) orelse {
                try skipped_names.put(draft.arena, entry.key_ptr.*, {});
                continue;
            };
            const border_color = color(if (entry.value_ptr.* == .string) entry.value_ptr.string else null) orelse continue;
            try draft.put(try draft.character(name), "borderColors.activeBorderColor", try values.colorValue(draft.arena, border_color));
            colored_count += 1;
        }
    }

    var converted_count: usize = 0;
    var total_count: usize = 0;
    if (values.objectAt(root, "ClientHotkey")) |hotkeys| {
        total_count = hotkeys.object.count();
        var it = hotkeys.object.iterator();
        while (it.next()) |entry| {
            const name = values.characterName(entry.key_ptr.*) orelse {
                try skipped_names.put(draft.arena, entry.key_ptr.*, {});
                continue;
            };
            if (entry.value_ptr.* != .string) continue;
            const combined = hotkey(entry.value_ptr.string) orelse continue;
            try draft.put(try draft.character(name), "hotkey", try values.keyValue(draft.arena, combined));
            converted_count += 1;
        }
    }

    try draft.noteCount("dynamic.import.importedBorderColorsCountNote", "n", colored_count);
    if (total_count > 0) try draft.note("dynamic.import.convertedHotkeysNote", &.{ .{ .name = "converted", .value = try draft.format(converted_count) }, .{ .name = "total", .value = try draft.format(total_count) } });
    if (skipped_names.count() > 0) try draft.noteCount("dynamic.import.eveo.skippedPlaceholderNote", "n", skipped_names.count());
}

fn hotkeyGroups(draft: *Draft, root: Value, cycle_group_name: []const u8) !void {
    const first_note = draft.notes.items.len;
    var imported_count: usize = 0;
    for (1..CYCLE_GROUP_COUNT + 1) |group_number| {
        const members = try cycleGroupMembers(draft.arena, root, group_number);
        if (members.len == 0) continue;
        const forward_bound = try boundKeys(draft.arena, values.arrayAt(root, try draft.arena.print("CycleGroup{d}ForwardHotkeys", .{group_number})));
        const backward_bound = try boundKeys(draft.arena, values.arrayAt(root, try draft.arena.print("CycleGroup{d}BackwardHotkeys", .{group_number})));
        const name = try std.mem.replaceOwned(u8, draft.arena, cycle_group_name, "{n}", try draft.format(group_number));
        const forward = try groupKeys(draft, forward_bound, name, "dynamic.import.hotkeyGroupForwardKeyFailedNote");
        const backward = try groupKeys(draft, backward_bound, name, "dynamic.import.hotkeyGroupBackwardKeyFailedNote");

        var list: std.json.Array = .init(draft.arena);
        for (members) |member| try list.append(.{ .string = member });
        const group = try draft.item("hotkeyGroups", "name", name);
        try draft.put(group, "characters", .{ .array = list });
        try draft.put(group, "forwardKey", try values.keysValue(draft.arena, forward));
        try draft.put(group, "backwardKey", try values.keysValue(draft.arena, backward));
        imported_count += 1;
    }
    try draft.notes.insert(draft.arena, first_note, try draft.countText("dynamic.import.hotkeyGroupsImportedNote", imported_count));
}
