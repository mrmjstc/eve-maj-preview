//! EVE-X Preview and its fork EVE-MultiPreview: a JSON file of named profiles under "_Profiles".
const std = @import("std");
const values = @import("values.zig");
const draft_mod = @import("draft.zig");
const config = @import("../../config.zig");

const Value = std.json.Value;
const Draft = draft_mod.Draft;
const Section = draft_mod.Section;

/// Where each setting lives: older versions split app-wide and profile sections, and version 3 moved them all into the profile, so both layouts are read.
const Source = struct {
    profile: ?Value,
    global: ?Value,
    visuals: ?Value,
    behavior: ?Value,
    hotkeys: ?Value,
    client: ?Value,
    logs: ?Value,

    fn init(root: Value, profile_name: []const u8) Source {
        const profile = values.objectAt(values.objectAt(root, "_Profiles"), profile_name);
        return .{
            .profile = profile,
            .global = globals(root),
            .visuals = values.objectAt(profile, "Thumbnail Settings") orelse values.objectAt(profile, "Thumbnails Visuals"),
            .behavior = values.objectAt(profile, "Thumbnails Behavior"),
            .hotkeys = values.objectAt(profile, "Hotkeys Settings"),
            .client = values.objectAt(profile, "Client Settings"),
            .logs = values.objectAt(profile, "Game Logs Monitoring"),
        };
    }

    /// The first of these settings the file has.
    fn first(_: Source, places: []const struct { ?Value, []const u8 }) ?Value {
        for (places) |place| {
            if (values.get(place[0], place[1])) |v| return v;
        }
        return null;
    }

    fn characterHotkeys(self: Source) []const Value {
        const old = values.arrayAt(self.profile, "Hotkeys");
        return if (old.len > 0) old else values.arrayAt(self.hotkeys, "CharacterHotkeys");
    }

    fn startLocation(self: Source) ?Value {
        return values.objectAt(self.global, "ThumbnailStartLocation") orelse values.objectAt(self.behavior, "ThumbnailStartLocation");
    }

    fn areColorsActive(self: Source) bool {
        const active = values.get(values.objectAt(self.profile, "Custom Colors"), "cColorActive") orelse return false;
        return switch (active) {
            .bool => |b| b,
            .integer => |i| i == 1,
            .string => |s| std.mem.eql(u8, s, "1"),
            else => false,
        };
    }

    fn customColors(self: Source) ?Value {
        return values.objectAt(values.objectAt(self.profile, "Custom Colors"), "cColors");
    }
};

pub fn isFile(root: Value) bool {
    return values.objectAt(root, "_Profiles") != null;
}

pub fn profileNames(arena: std.mem.Allocator, root: Value) ![]const []const u8 {
    const profiles = values.objectAt(root, "_Profiles") orelse return &.{};
    return arena.dupe([]const u8, profiles.object.keys());
}

/// The profile EVE-X last ran, or its first.
pub fn defaultProfile(root: Value) ?[]const u8 {
    const profiles = values.objectAt(root, "_Profiles") orelse return null;
    if (values.stringAt(globals(root), "LastUsedProfile") orelse values.stringAt(root, "LastUsedProfile")) |last| {
        if (profiles.object.contains(last)) return last;
    }
    const names = profiles.object.keys();
    return if (names.len > 0) names[0] else null;
}

pub fn sections(draft: *Draft, root: Value, profile_name: []const u8) ![]const Section {
    const source = Source.init(root, profile_name);
    const position_count = countPositions(values.objectAt(source.profile, "Thumbnail Positions"));
    const color_count = if (source.areColorsActive()) countNames(values.arrayAt(source.customColors(), "CharNames")) else 0;
    const hotkey_count = countHotkeys(source.characterHotkeys());
    const group_count = values.count(values.objectAt(source.profile, "Hotkey Groups"));

    const has_appearance = values.count(source.visuals) > 0 or source.startLocation() != null or
        values.has(source.global, "ShowSystemName") or values.has(source.global, "HideActiveThumbnail");
    const has_auto_minimize = values.has(source.client, "MinimizeInactiveClients") or
        countNames(values.arrayAt(source.client, "Dont_Minimize_Clients")) > 0 or
        values.jsonNumber(values.get(source.global, "Minimize_Delay")) != null;
    const has_snapping = source.first(&.{ .{ source.global, "ThumbnailSnap" }, .{ source.behavior, "ThumbnailSnap" }, .{ source.global, "ThumbnailSnap_Distance" }, .{ source.behavior, "ThumbnailSnap_Distance" } }) != null or
        hasText(suspendHotkey(source));
    const has_global_hotkeys = source.first(&.{ .{ source.global, "HideShowThumbnailsHotkey" }, .{ source.hotkeys, "HideThumbnailsHotkey" }, .{ source.global, "CycleWhileHeld" }, .{ source.global, "LockPositions" }, .{ source.hotkeys, "Close_All_EVE_Win_Hotkey" } }) != null;
    const has_chatlog = source.first(&.{ .{ source.global, "EnableChatLogMonitoring" }, .{ source.global, "EnableGameLogMonitoring" }, .{ source.global, "ChatLogDirectory" }, .{ source.global, "GameLogDirectory" }, .{ source.logs, "gameLogsMonitoringEnabled" } }) != null;

    return draft.arena.dupe(Section, &.{
        .{ .id = "thumbnailAppearance", .title = "dynamic.import.evex.thumbnailAppearance.title", .hint = .{ .key = "dynamic.import.evex.thumbnailAppearance.hint" }, .available = has_appearance },
        .{ .id = "characterPositions", .title = "dynamic.import.evex.characterPositions.title", .hint = try draft.countText("dynamic.import.characterPositionsHint", position_count), .available = position_count > 0 },
        .{ .id = "characterColorsHotkeys", .title = "dynamic.import.evex.characterColorsHotkeys.title", .hint = try colorsHint(draft, color_count, hotkey_count), .available = color_count + hotkey_count > 0 },
        .{ .id = "hotkeyGroups", .title = "dynamic.import.evex.hotkeyGroups.title", .hint = try draft.countText("dynamic.import.hotkeyGroupsCountHint", group_count), .available = group_count > 0 },
        .{ .id = "autoMinimize", .title = "dynamic.import.evex.autoMinimize.title", .hint = .{ .key = "dynamic.import.evex.autoMinimize.hint" }, .available = has_auto_minimize },
        .{ .id = "snapping", .title = "dynamic.import.evex.snapping.title", .hint = .{ .key = "dynamic.import.evex.snapping.hint" }, .available = has_snapping },
        .{ .id = "globalHotkeys", .title = "dynamic.import.apm.globalHotkeys.title", .hint = .{ .key = "dynamic.import.evex.globalHotkeys.hint" }, .available = has_global_hotkeys },
        .{ .id = "chatlog", .title = "dynamic.import.apm.chatlog.title", .hint = .{ .key = "dynamic.import.apm.chatlog.hint" }, .available = has_chatlog },
    });
}

pub fn colorsHint(draft: *Draft, color_count: usize, hotkey_count: usize) !draft_mod.Text {
    return draft.text("dynamic.import.characterColorsHotkeysHint", &.{ .{ .name = "colors", .value = try draft.format(color_count) }, .{ .name = "hotkeys", .value = try draft.format(hotkey_count) } });
}

pub fn hasText(text: ?[]const u8) bool {
    const raw = text orelse return false;
    return std.mem.trim(u8, raw, " \t").len > 0;
}

pub fn build(draft: *Draft, root: Value, profile_name: []const u8, chosen: []const []const u8) !void {
    const source = Source.init(root, profile_name);
    if (draft_mod.isChosen(chosen, "thumbnailAppearance")) try appearance(draft, source);
    if (draft_mod.isChosen(chosen, "characterPositions")) try characterPositions(draft, source);
    if (draft_mod.isChosen(chosen, "characterColorsHotkeys")) try colorsAndHotkeys(draft, source);
    if (draft_mod.isChosen(chosen, "hotkeyGroups")) try hotkeyGroups(draft, source);
    if (draft_mod.isChosen(chosen, "autoMinimize")) try autoMinimize(draft, source);
    if (draft_mod.isChosen(chosen, "snapping")) try snapping(draft, source);
    if (draft_mod.isChosen(chosen, "globalHotkeys")) try globalHotkeys(draft, source);
    if (draft_mod.isChosen(chosen, "chatlog")) try chatlog(draft, source);
}

/// EVE-X ran DPI-unaware, so its positions are in a 96-DPI space Windows scaled for it.
pub fn putPosition(draft: *Draft, character: *std.json.ObjectMap, x: f64, y: f64) !void {
    const legacy: config.Position = .{ .x = std.math.lossyCast(i32, @round(x)), .y = std.math.lossyCast(i32, @round(y)) };
    const position = legacy.scaleFromLegacyDpiUnaware();
    try draft.put(character, "position.x", .{ .integer = position.x });
    try draft.put(character, "position.y", .{ .integer = position.y });
}

/// Version 3 has no "global_Settings" and keeps its few app-wide settings at the top level.
fn globals(root: Value) ?Value {
    return values.objectAt(root, "global_Settings") orelse root;
}

fn countNames(names: []const Value) usize {
    var name_count: usize = 0;
    for (names) |name| {
        if (name == .string and values.characterName(name.string) != null) name_count += 1;
    }
    return name_count;
}

fn countHotkeys(entries: []const Value) usize {
    var hotkey_count: usize = 0;
    for (entries) |entry| {
        if (entry != .object) continue;
        for (entry.object.keys()) |name| {
            if (values.characterName(name) != null) hotkey_count += 1;
        }
    }
    return hotkey_count;
}

fn countPositions(all: ?Value) usize {
    const positions = all orelse return 0;
    var position_count: usize = 0;
    for (positions.object.keys()) |key| {
        if (values.characterName(key) != null) position_count += 1;
    }
    return position_count;
}

fn suspendHotkey(source: Source) ?[]const u8 {
    const value = source.first(&.{ .{ source.global, "Suspend_Hotkeys_Hotkey" }, .{ source.hotkeys, "Suspend_Hotkeys_Hotkey" } }) orelse return null;
    return if (value == .string) value.string else null;
}

fn appearance(draft: *Draft, source: Source) !void {
    const visuals = source.visuals;
    try draft.setNumber("thumbnail.borderWidth", values.number(values.get(visuals, "ClientHighligtBorderthickness")));
    try draft.setColor("thumbnail.borderColor", values.rgbColor(values.stringAt(visuals, "ClientHighligtColor")));
    if (values.get(visuals, "ShowClientHighlightBorder")) |v| try draft.setBool("thumbnail.showBorderWhenFocused", values.truthy(v));

    try draft.setNumber("thumbnail.inactiveBorderWidth", values.number(values.get(visuals, "InactiveClientBorderthickness")));
    try draft.setColor("thumbnail.inactiveBorderColor", values.rgbColor(values.stringAt(visuals, "InactiveClientBorderColor")));
    if (values.get(visuals, "ShowAllColoredBorders")) |v| try draft.setBool("thumbnail.showBorderWhenInactive", values.truthy(v));

    if (values.get(visuals, "ShowThumbnailTextOverlay")) |v| try draft.setBool("thumbnail.showText", values.truthy(v));
    try draft.setColor("thumbnail.characterNameColor", values.rgbColor(values.stringAt(visuals, "ThumbnailTextColor")));
    const font = values.stringAt(visuals, "ThumbnailTextFont");
    try draft.setOverlayFont(if (hasText(font)) font else null, values.number(values.get(visuals, "ThumbnailTextSize")));
    const margins = values.objectAt(visuals, "ThumbnailTextMargins");
    try draft.setNumber("thumbnail.characterNameOffsetX", values.number(values.get(margins, "x")));
    try draft.setNumber("thumbnail.characterNameOffsetY", values.number(values.get(margins, "y")));

    if (values.number(values.get(visuals, "ThumbnailOpacity"))) |percent| try draft.setNumber("thumbnail.thumbnailOpacity", values.opacityFromPercent(percent));
    if (source.first(&.{ .{ visuals, "HideThumbnailsOnLostFocus" }, .{ source.behavior, "HideThumbnailsOnLostFocus" } })) |v| try draft.setBool("thumbnail.hideWhenNoEveFocus", values.truthy(v));

    const start = source.startLocation();
    try draft.setNumber("thumbnail.width", values.number(values.get(start, "width")));
    try draft.setNumber("thumbnail.height", values.number(values.get(start, "height")));

    try draft.setBool("thumbnail.showSystemName", values.flag(values.get(source.global, "ShowSystemName")));
    try draft.setBool("thumbnail.activeThumbnailHidden", values.flag(source.first(&.{ .{ source.global, "HideActiveThumbnail" }, .{ source.behavior, "HideThumbForActiveWin" } })));
    try draft.note("dynamic.import.thumbnailAppearanceImportedNote", &.{});
}

fn characterPositions(draft: *Draft, source: Source) !void {
    const all = values.objectAt(source.profile, "Thumbnail Positions") orelse return;
    var imported_count: usize = 0;
    var skipped_count: usize = 0;
    var it = all.object.iterator();
    while (it.next()) |entry| {
        const name = values.characterName(entry.key_ptr.*) orelse {
            skipped_count += 1;
            continue;
        };
        const position = entry.value_ptr.*;
        const character = try draft.character(name);
        if (values.number(values.get(position, "x"))) |x| {
            if (values.number(values.get(position, "y"))) |y| try putPosition(draft, character, x, y);
        }
        if (values.number(values.get(position, "width"))) |width| try draft.put(character, "thumbnailSize.width", values.numberValue(width));
        if (values.number(values.get(position, "height"))) |height| try draft.put(character, "thumbnailSize.height", values.numberValue(height));
        imported_count += 1;
    }
    try draft.noteCount("dynamic.import.importedPositionsWithSizeNote", "n", imported_count);
    if (skipped_count > 0) try draft.noteCount("dynamic.import.skippedPlaceholderNote", "n", skipped_count);
}

fn colorsAndHotkeys(draft: *Draft, source: Source) !void {
    if (source.areColorsActive()) {
        const colors = source.customColors();
        const names = values.arrayAt(colors, "CharNames");
        const active = values.arrayAt(colors, "Bordercolor");
        const inactive = values.arrayAt(colors, "IABordercolor");
        var imported_count: usize = 0;
        for (names, 0..) |raw, i| {
            if (raw != .string) continue;
            const name = values.characterName(raw.string) orelse continue;
            const character = try draft.character(name);
            if (i < active.len and active[i] == .string) {
                if (values.rgbColor(active[i].string)) |c| try draft.put(character, "borderColors.activeBorderColor", try values.colorValue(draft.arena, c));
            }
            if (i < inactive.len and inactive[i] == .string) {
                if (values.rgbColor(inactive[i].string)) |c| try draft.put(character, "borderColors.inactiveBorderColor", try values.colorValue(draft.arena, c));
            }
            imported_count += 1;
        }
        if (imported_count > 0) try draft.noteCount("dynamic.import.evex.importedBorderColorsForCharsNote", "n", imported_count);
        if (values.arrayAt(colors, "TextColor").len > 0) try draft.note("dynamic.import.evex.textColorNotSupportedNote", &.{});
    }

    const entries = source.characterHotkeys();
    var converted_count: usize = 0;
    var total_count: usize = 0;
    for (entries) |entry| {
        if (entry != .object) continue;
        var it = entry.object.iterator();
        while (it.next()) |hotkey| {
            const name = values.characterName(hotkey.key_ptr.*) orelse continue;
            total_count += 1;
            const raw = if (hotkey.value_ptr.* == .string) hotkey.value_ptr.string else "";
            const character = try draft.character(name);
            if (values.ahkHotkey(raw)) |combined| {
                try draft.put(character, "hotkey", try values.keyValue(draft.arena, combined));
                converted_count += 1;
            } else {
                try draft.note("dynamic.import.evex.hotkeySkippedNote", &.{ .{ .name = "name", .value = name }, .{ .name = "raw", .value = raw } });
            }
        }
    }
    if (total_count > 0) try draft.note("dynamic.import.convertedHotkeysNote", &.{ .{ .name = "converted", .value = try draft.format(converted_count) }, .{ .name = "total", .value = try draft.format(total_count) } });
}

fn hotkeyGroups(draft: *Draft, source: Source) !void {
    const groups = values.objectAt(source.profile, "Hotkey Groups") orelse return;
    const first_note = draft.notes.items.len;
    var it = groups.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const group_settings = entry.value_ptr.*;
        const group = try draft.item("hotkeyGroups", "name", name);
        var members: std.json.Array = .init(draft.arena);
        for (values.arrayAt(group_settings, "Characters")) |member| {
            if (member == .string) try members.append(member);
        }
        try draft.put(group, "characters", .{ .array = members });
        try groupKey(draft, group, "forwardKey", name, values.stringAt(group_settings, "ForwardsHotkey"), "dynamic.import.hotkeyGroupForwardKeyFailedNote");
        try groupKey(draft, group, "backwardKey", name, values.stringAt(group_settings, "BackwardsHotkey"), "dynamic.import.hotkeyGroupBackwardKeyFailedNote");
    }
    try draft.notes.insert(draft.arena, first_note, try draft.countText("dynamic.import.hotkeyGroupsImportedNote", groups.object.count()));
}

fn groupKey(draft: *Draft, group: *std.json.ObjectMap, field: []const u8, name: []const u8, raw: ?[]const u8, failed_note: []const u8) !void {
    if (!hasText(raw)) {
        try draft.put(group, field, .null);
        return;
    }
    if (values.ahkHotkey(raw)) |combined| {
        try draft.put(group, field, try values.keyValue(draft.arena, combined));
    } else {
        try draft.put(group, field, .null);
        try draft.note(failed_note, &.{ .{ .name = "name", .value = name }, .{ .name = "key", .value = raw.? } });
    }
}

fn autoMinimize(draft: *Draft, source: Source) !void {
    if (values.get(source.client, "MinimizeInactiveClients")) |v| try draft.setBool("autoMinimize.enabled", values.truthy(v));
    try draft.setNumber("autoMinimize.delayMs", values.number(source.first(&.{ .{ source.global, "Minimize_Delay" }, .{ source.client, "Minimize_Delay" } })));
    for (values.arrayAt(source.client, "Dont_Minimize_Clients")) |raw| {
        if (raw != .string) continue;
        const name = values.characterName(raw.string) orelse continue;
        try draft.put(try draft.character(name), "excludeFromMinimize", .{ .bool = true });
    }
    try draft.note("dynamic.import.autoMinimizeImportedNote", &.{});
}

fn snapping(draft: *Draft, source: Source) !void {
    if (source.first(&.{ .{ source.global, "ThumbnailSnap" }, .{ source.behavior, "ThumbnailSnap" } })) |v| try draft.setBool("snapping.enabled", values.truthy(v));
    try draft.setNumber("snapping.threshold", values.number(source.first(&.{ .{ source.global, "ThumbnailSnap_Distance" }, .{ source.behavior, "ThumbnailSnap_Distance" } })));
    const raw = suspendHotkey(source);
    if (hasText(raw)) {
        if (values.ahkHotkey(raw)) |combined| {
            try draft.setKeys("hotkeys.hotkeySuspend", .one(combined));
        } else {
            try draft.note("dynamic.import.evex.suspendHotkeyFailedNote", &.{.{ .name = "key", .value = raw.? }});
        }
    }
    try draft.note("dynamic.import.snappingImportedNote", &.{});
}

fn globalHotkeys(draft: *Draft, source: Source) !void {
    try actionHotkey(draft, source.first(&.{ .{ source.global, "HideShowThumbnailsHotkey" }, .{ source.hotkeys, "HideThumbnailsHotkey" } }), "hotkeys.hotkeyToggleVisibility", "dynamic.import.apm.actionLabel.toggleVisibility");
    try actionHotkey(draft, values.get(source.hotkeys, "Close_All_EVE_Win_Hotkey"), "hotkeys.hotkeyCloseAll", "dynamic.import.apm.actionLabel.closeAll");
    try draft.setBool("hotkeys.allowHotkeyAutoRepeat", values.flag(values.get(source.global, "CycleWhileHeld")));
    if (values.flag(values.get(source.global, "LockPositions"))) |locked| try draft.setBool("interaction.enableDragging", !locked);
    try draft.note("dynamic.import.apm.globalHotkeysImportedNote", &.{});
}

fn actionHotkey(draft: *Draft, raw: ?Value, path: []const u8, label: []const u8) !void {
    const value = raw orelse return;
    if (value != .string or !hasText(value.string)) return;
    if (values.ahkHotkey(value.string)) |combined| {
        try draft.setKeys(path, .one(combined));
    } else {
        try draft.note("dynamic.import.apm.globalHotkeyUnsupportedNote", &.{.{ .name = "label", .value = label, .should_translate = true }});
    }
}

fn chatlog(draft: *Draft, source: Source) !void {
    const is_chatlog_enabled = values.flag(values.get(source.global, "EnableChatLogMonitoring"));
    const is_gamelog_enabled = values.flag(values.get(source.global, "EnableGameLogMonitoring"));
    if (is_chatlog_enabled != null or is_gamelog_enabled != null) {
        try draft.setBool("chatlog.enabled", (is_chatlog_enabled orelse false) or (is_gamelog_enabled orelse false));
    } else {
        try draft.setBool("chatlog.enabled", values.flag(values.get(source.logs, "gameLogsMonitoringEnabled")));
    }
    try setDirectory(draft, "chatlog.chatlogDir", values.stringAt(source.global, "ChatLogDirectory") orelse values.stringAt(source.logs, "chatLogsDirectory"));
    try setDirectory(draft, "chatlog.gamelogDir", values.stringAt(source.global, "GameLogDirectory") orelse values.stringAt(source.logs, "gameLogsDirectory"));
    try draft.note("dynamic.import.apm.chatlogImportedNote", &.{});
}

fn setDirectory(draft: *Draft, path: []const u8, raw: ?[]const u8) !void {
    if (!hasText(raw)) return;
    try draft.setString(path, std.mem.trim(u8, raw.?, " \t"));
}
