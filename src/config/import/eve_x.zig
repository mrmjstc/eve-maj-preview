//! EVE-X Preview and its fork EVE-MultiPreview: a JSON file of named profiles under "_Profiles".
//! Older versions keep app-wide settings in "global_Settings" and a profile's in "Thumbnail Settings"/"Hotkeys"; version 3 moved
//! them into the profile ("Thumbnails Visuals", "Thumbnails Behavior", "Hotkeys Settings", "Game Logs Monitoring"), so both are read.
const std = @import("std");
const values = @import("values.zig");
const draft_mod = @import("draft.zig");
const config_mod = @import("../../config.zig");

const Value = std.json.Value;
const Draft = draft_mod.Draft;
const Section = draft_mod.Section;

pub fn isFile(root: Value) bool {
    return values.objectAt(root, "_Profiles") != null;
}

pub fn profileNames(arena: std.mem.Allocator, root: Value) ![]const []const u8 {
    const profiles = values.objectAt(root, "_Profiles").?;
    return arena.dupe([]const u8, profiles.object.keys());
}

/// The profile EVE-X last ran, or its first.
pub fn defaultProfile(root: Value) ?[]const u8 {
    const profiles = values.objectAt(root, "_Profiles").?;
    if (values.stringAt(globals(root), "LastUsedProfile") orelse values.stringAt(root, "LastUsedProfile")) |last| {
        if (profiles.object.contains(last)) return last;
    }
    const names = profiles.object.keys();
    return if (names.len > 0) names[0] else null;
}

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
    fn first(self: Source, places: []const struct { ?Value, []const u8 }) ?Value {
        _ = self;
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

    fn colorsActive(self: Source) bool {
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

/// Version 3 has no "global_Settings" and keeps its few app-wide settings at the top level.
fn globals(root: Value) ?Value {
    return values.objectAt(root, "global_Settings") orelse root;
}

fn countNames(names: []const Value) usize {
    var n: usize = 0;
    for (names) |name| {
        if (name == .string and values.characterName(name.string) != null) n += 1;
    }
    return n;
}

fn countHotkeys(entries: []const Value) usize {
    var n: usize = 0;
    for (entries) |entry| {
        if (entry != .object) continue;
        for (entry.object.keys()) |name| {
            if (values.characterName(name) != null) n += 1;
        }
    }
    return n;
}

fn countPositions(all: ?Value) usize {
    const p = all orelse return 0;
    var n: usize = 0;
    for (p.object.keys()) |key| {
        if (values.characterName(key) != null) n += 1;
    }
    return n;
}

pub fn sections(d: *Draft, root: Value, profile_name: []const u8) ![]const Section {
    const s = Source.init(root, profile_name);
    const position_count = countPositions(values.objectAt(s.profile, "Thumbnail Positions"));
    const colors = if (s.colorsActive()) countNames(values.arrayAt(s.customColors(), "CharNames")) else 0;
    const hotkeys = countHotkeys(s.characterHotkeys());
    const groups = values.count(values.objectAt(s.profile, "Hotkey Groups"));

    const has_appearance = values.count(s.visuals) > 0 or s.startLocation() != null or
        values.has(s.global, "ShowSystemName") or values.has(s.global, "HideActiveThumbnail");
    const has_auto_minimize = values.has(s.client, "MinimizeInactiveClients") or
        countNames(values.arrayAt(s.client, "Dont_Minimize_Clients")) > 0 or
        values.jsonNumber(values.get(s.global, "Minimize_Delay")) != null;
    const has_snapping = s.first(&.{ .{ s.global, "ThumbnailSnap" }, .{ s.behavior, "ThumbnailSnap" }, .{ s.global, "ThumbnailSnap_Distance" }, .{ s.behavior, "ThumbnailSnap_Distance" } }) != null or
        nonEmpty(suspendHotkey(s));
    const has_global_hotkeys = s.first(&.{ .{ s.global, "HideShowThumbnailsHotkey" }, .{ s.hotkeys, "HideThumbnailsHotkey" }, .{ s.global, "CycleWhileHeld" }, .{ s.global, "LockPositions" }, .{ s.hotkeys, "Close_All_EVE_Win_Hotkey" } }) != null;
    const has_chatlog = s.first(&.{ .{ s.global, "EnableChatLogMonitoring" }, .{ s.global, "EnableGameLogMonitoring" }, .{ s.global, "ChatLogDirectory" }, .{ s.global, "GameLogDirectory" }, .{ s.logs, "gameLogsMonitoringEnabled" } }) != null;

    return d.arena.dupe(Section, &.{
        .{ .id = "thumbnailAppearance", .title = "dynamic.import.evex.thumbnailAppearance.title", .hint = .{ .key = "dynamic.import.evex.thumbnailAppearance.hint" }, .available = has_appearance },
        .{ .id = "characterPositions", .title = "dynamic.import.evex.characterPositions.title", .hint = try d.countText("dynamic.import.characterPositionsHint", position_count), .available = position_count > 0 },
        .{ .id = "characterColorsHotkeys", .title = "dynamic.import.evex.characterColorsHotkeys.title", .hint = try colorsHint(d, colors, hotkeys), .available = colors + hotkeys > 0 },
        .{ .id = "hotkeyGroups", .title = "dynamic.import.evex.hotkeyGroups.title", .hint = try d.countText("dynamic.import.hotkeyGroupsCountHint", groups), .available = groups > 0 },
        .{ .id = "autoMinimize", .title = "dynamic.import.evex.autoMinimize.title", .hint = .{ .key = "dynamic.import.evex.autoMinimize.hint" }, .available = has_auto_minimize },
        .{ .id = "snapping", .title = "dynamic.import.evex.snapping.title", .hint = .{ .key = "dynamic.import.evex.snapping.hint" }, .available = has_snapping },
        .{ .id = "globalHotkeys", .title = "dynamic.import.apm.globalHotkeys.title", .hint = .{ .key = "dynamic.import.evex.globalHotkeys.hint" }, .available = has_global_hotkeys },
        .{ .id = "chatlog", .title = "dynamic.import.apm.chatlog.title", .hint = .{ .key = "dynamic.import.apm.chatlog.hint" }, .available = has_chatlog },
    });
}

pub fn colorsHint(d: *Draft, colors: usize, hotkeys: usize) !draft_mod.Text {
    return d.text("dynamic.import.characterColorsHotkeysHint", &.{ .{ .name = "colors", .value = try d.format(colors) }, .{ .name = "hotkeys", .value = try d.format(hotkeys) } });
}

pub fn nonEmpty(text: ?[]const u8) bool {
    const t = text orelse return false;
    return std.mem.trim(u8, t, " \t").len > 0;
}

fn suspendHotkey(s: Source) ?[]const u8 {
    const v = s.first(&.{ .{ s.global, "Suspend_Hotkeys_Hotkey" }, .{ s.hotkeys, "Suspend_Hotkeys_Hotkey" } }) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn build(d: *Draft, root: Value, profile_name: []const u8, chosen: []const []const u8) !void {
    const s = Source.init(root, profile_name);
    if (isChosen(chosen, "thumbnailAppearance")) try appearance(d, s);
    if (isChosen(chosen, "characterPositions")) try characterPositions(d, s);
    if (isChosen(chosen, "characterColorsHotkeys")) try colorsAndHotkeys(d, s);
    if (isChosen(chosen, "hotkeyGroups")) try hotkeyGroups(d, s);
    if (isChosen(chosen, "autoMinimize")) try autoMinimize(d, s);
    if (isChosen(chosen, "snapping")) try snapping(d, s);
    if (isChosen(chosen, "globalHotkeys")) try globalHotkeys(d, s);
    if (isChosen(chosen, "chatlog")) try chatlog(d, s);
}

pub fn isChosen(chosen: []const []const u8, id: []const u8) bool {
    for (chosen) |c| {
        if (std.mem.eql(u8, c, id)) return true;
    }
    return false;
}

fn appearance(d: *Draft, s: Source) !void {
    const vis = s.visuals;
    try d.setNumber("thumbnail.borderWidth", values.number(values.get(vis, "ClientHighligtBorderthickness")));
    try d.setColor("thumbnail.borderColor", values.rgbColor(values.stringAt(vis, "ClientHighligtColor")));
    if (values.get(vis, "ShowClientHighlightBorder")) |v| try d.setBool("thumbnail.showBorderWhenFocused", values.truthy(v));

    try d.setNumber("thumbnail.inactiveBorderWidth", values.number(values.get(vis, "InactiveClientBorderthickness")));
    try d.setColor("thumbnail.inactiveBorderColor", values.rgbColor(values.stringAt(vis, "InactiveClientBorderColor")));
    if (values.get(vis, "ShowAllColoredBorders")) |v| try d.setBool("thumbnail.showBorderWhenInactive", values.truthy(v));

    if (values.get(vis, "ShowThumbnailTextOverlay")) |v| try d.setBool("thumbnail.showText", values.truthy(v));
    try d.setColor("thumbnail.characterNameColor", values.rgbColor(values.stringAt(vis, "ThumbnailTextColor")));
    const font = values.stringAt(vis, "ThumbnailTextFont");
    try d.setOverlayFont(if (nonEmpty(font)) font else null, values.number(values.get(vis, "ThumbnailTextSize")));
    const margins = values.objectAt(vis, "ThumbnailTextMargins");
    try d.setNumber("thumbnail.characterNameOffsetX", values.number(values.get(margins, "x")));
    try d.setNumber("thumbnail.characterNameOffsetY", values.number(values.get(margins, "y")));

    if (values.number(values.get(vis, "ThumbnailOpacity"))) |percent| try d.setNumber("thumbnail.thumbnailOpacity", values.opacityFromPercent(percent));
    if (s.first(&.{ .{ vis, "HideThumbnailsOnLostFocus" }, .{ s.behavior, "HideThumbnailsOnLostFocus" } })) |v| try d.setBool("thumbnail.hideWhenNoEveFocus", values.truthy(v));

    const start = s.startLocation();
    try d.setNumber("thumbnail.width", values.number(values.get(start, "width")));
    try d.setNumber("thumbnail.height", values.number(values.get(start, "height")));

    try d.setBool("thumbnail.showSystemName", values.flag(values.get(s.global, "ShowSystemName")));
    try d.setBool("thumbnail.activeThumbnailHidden", values.flag(s.first(&.{ .{ s.global, "HideActiveThumbnail" }, .{ s.behavior, "HideThumbForActiveWin" } })));
    try d.note("dynamic.import.thumbnailAppearanceImportedNote", &.{});
}

fn characterPositions(d: *Draft, s: Source) !void {
    const all = values.objectAt(s.profile, "Thumbnail Positions") orelse return;
    var imported: usize = 0;
    var skipped: usize = 0;
    var it = all.object.iterator();
    while (it.next()) |entry| {
        const name = values.characterName(entry.key_ptr.*) orelse {
            skipped += 1;
            continue;
        };
        const p = entry.value_ptr.*;
        const character = try d.character(name);
        if (values.number(values.get(p, "x"))) |x| {
            if (values.number(values.get(p, "y"))) |y| try putPosition(d, character, x, y);
        }
        if (values.number(values.get(p, "width"))) |w| try d.put(character, "thumbnailSize.width", values.numberValue(w));
        if (values.number(values.get(p, "height"))) |h| try d.put(character, "thumbnailSize.height", values.numberValue(h));
        imported += 1;
    }
    try d.noteCount("dynamic.import.importedPositionsWithSizeNote", "n", imported);
    if (skipped > 0) try d.noteCount("dynamic.import.skippedPlaceholderNote", "n", skipped);
}

/// EVE-X ran DPI-unaware, so its positions are in a 96-DPI space Windows scaled for it.
pub fn putPosition(d: *Draft, character: *std.json.ObjectMap, x: f64, y: f64) !void {
    const legacy: config_mod.Position = .{ .x = std.math.lossyCast(i32, @round(x)), .y = std.math.lossyCast(i32, @round(y)) };
    const pos = legacy.scaleFromLegacyDpiUnaware();
    try d.put(character, "position.x", .{ .integer = pos.x });
    try d.put(character, "position.y", .{ .integer = pos.y });
}

fn colorsAndHotkeys(d: *Draft, s: Source) !void {
    if (s.colorsActive()) {
        const colors = s.customColors();
        const names = values.arrayAt(colors, "CharNames");
        const active = values.arrayAt(colors, "Bordercolor");
        const inactive = values.arrayAt(colors, "IABordercolor");
        var imported: usize = 0;
        for (names, 0..) |raw, i| {
            if (raw != .string) continue;
            const name = values.characterName(raw.string) orelse continue;
            const character = try d.character(name);
            if (i < active.len and active[i] == .string) {
                if (values.rgbColor(active[i].string)) |c| try d.put(character, "borderColors.activeBorderColor", try values.colorValue(d.arena, c));
            }
            if (i < inactive.len and inactive[i] == .string) {
                if (values.rgbColor(inactive[i].string)) |c| try d.put(character, "borderColors.inactiveBorderColor", try values.colorValue(d.arena, c));
            }
            imported += 1;
        }
        if (imported > 0) try d.noteCount("dynamic.import.evex.importedBorderColorsForCharsNote", "n", imported);
        if (values.arrayAt(colors, "TextColor").len > 0) try d.note("dynamic.import.evex.textColorNotSupportedNote", &.{});
    }

    const entries = s.characterHotkeys();
    var converted: usize = 0;
    var total: usize = 0;
    for (entries) |entry| {
        if (entry != .object) continue;
        var it = entry.object.iterator();
        while (it.next()) |hotkey| {
            const name = values.characterName(hotkey.key_ptr.*) orelse continue;
            total += 1;
            const raw = if (hotkey.value_ptr.* == .string) hotkey.value_ptr.string else "";
            const character = try d.character(name);
            if (values.ahkHotkey(raw)) |combined| {
                try d.put(character, "hotkey", try values.keyValue(d.arena, combined));
                converted += 1;
            } else {
                try d.note("dynamic.import.evex.hotkeySkippedNote", &.{ .{ .name = "name", .value = name }, .{ .name = "raw", .value = raw } });
            }
        }
    }
    if (total > 0) try d.note("dynamic.import.convertedHotkeysNote", &.{ .{ .name = "converted", .value = try d.format(converted) }, .{ .name = "total", .value = try d.format(total) } });
}

fn hotkeyGroups(d: *Draft, s: Source) !void {
    const groups = values.objectAt(s.profile, "Hotkey Groups") orelse return;
    const first_note = d.notes.items.len;
    var it = groups.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const g = entry.value_ptr.*;
        const group = try d.item("hotkeyGroups", "name", name);
        var members = std.json.Array.init(d.arena);
        for (values.arrayAt(g, "Characters")) |member| {
            if (member == .string) try members.append(member);
        }
        try d.put(group, "characters", .{ .array = members });
        try groupKey(d, group, "forwardKey", name, values.stringAt(g, "ForwardsHotkey"), "dynamic.import.hotkeyGroupForwardKeyFailedNote");
        try groupKey(d, group, "backwardKey", name, values.stringAt(g, "BackwardsHotkey"), "dynamic.import.hotkeyGroupBackwardKeyFailedNote");
    }
    try d.notes.insert(d.arena, first_note, try d.countText("dynamic.import.hotkeyGroupsImportedNote", groups.object.count()));
}

fn groupKey(d: *Draft, group: *std.json.ObjectMap, field: []const u8, name: []const u8, raw: ?[]const u8, failed_note: []const u8) !void {
    if (!nonEmpty(raw)) {
        try d.put(group, field, .null);
        return;
    }
    if (values.ahkHotkey(raw)) |combined| {
        try d.put(group, field, try values.keyValue(d.arena, combined));
    } else {
        try d.put(group, field, .null);
        try d.note(failed_note, &.{ .{ .name = "name", .value = name }, .{ .name = "key", .value = raw.? } });
    }
}

fn autoMinimize(d: *Draft, s: Source) !void {
    if (values.get(s.client, "MinimizeInactiveClients")) |v| try d.setBool("autoMinimize.enabled", values.truthy(v));
    try d.setNumber("autoMinimize.delayMs", values.number(s.first(&.{ .{ s.global, "Minimize_Delay" }, .{ s.client, "Minimize_Delay" } })));
    for (values.arrayAt(s.client, "Dont_Minimize_Clients")) |raw| {
        if (raw != .string) continue;
        const name = values.characterName(raw.string) orelse continue;
        try d.put(try d.character(name), "excludeFromMinimize", .{ .bool = true });
    }
    try d.note("dynamic.import.autoMinimizeImportedNote", &.{});
}

fn snapping(d: *Draft, s: Source) !void {
    if (s.first(&.{ .{ s.global, "ThumbnailSnap" }, .{ s.behavior, "ThumbnailSnap" } })) |v| try d.setBool("snapping.enabled", values.truthy(v));
    try d.setNumber("snapping.threshold", values.number(s.first(&.{ .{ s.global, "ThumbnailSnap_Distance" }, .{ s.behavior, "ThumbnailSnap_Distance" } })));
    const raw = suspendHotkey(s);
    if (nonEmpty(raw)) {
        if (values.ahkHotkey(raw)) |combined| {
            try d.setKey("hotkeys.hotkeySuspend", combined);
        } else {
            try d.note("dynamic.import.evex.suspendHotkeyFailedNote", &.{.{ .name = "key", .value = raw.? }});
        }
    }
    try d.note("dynamic.import.snappingImportedNote", &.{});
}

fn globalHotkeys(d: *Draft, s: Source) !void {
    try actionHotkey(d, s.first(&.{ .{ s.global, "HideShowThumbnailsHotkey" }, .{ s.hotkeys, "HideThumbnailsHotkey" } }), "hotkeys.hotkeyToggleVisibility", "dynamic.import.apm.actionLabel.toggleVisibility");
    try actionHotkey(d, values.get(s.hotkeys, "Close_All_EVE_Win_Hotkey"), "hotkeys.hotkeyCloseAll", "dynamic.import.apm.actionLabel.closeAll");
    try d.setBool("hotkeys.allowHotkeyAutoRepeat", values.flag(values.get(s.global, "CycleWhileHeld")));
    if (values.flag(values.get(s.global, "LockPositions"))) |locked| try d.setBool("interaction.enableDragging", !locked);
    try d.note("dynamic.import.apm.globalHotkeysImportedNote", &.{});
}

fn actionHotkey(d: *Draft, raw: ?Value, path: []const u8, label: []const u8) !void {
    const v = raw orelse return;
    if (v != .string or !nonEmpty(v.string)) return;
    if (values.ahkHotkey(v.string)) |combined| {
        try d.setKey(path, combined);
    } else {
        try d.note("dynamic.import.apm.globalHotkeyUnsupportedNote", &.{.{ .name = "label", .value = label, .translate = true }});
    }
}

fn chatlog(d: *Draft, s: Source) !void {
    const chat = values.flag(values.get(s.global, "EnableChatLogMonitoring"));
    const game = values.flag(values.get(s.global, "EnableGameLogMonitoring"));
    if (chat != null or game != null) {
        try d.setBool("chatlog.enabled", (chat orelse false) or (game orelse false));
    } else {
        try d.setBool("chatlog.enabled", values.flag(values.get(s.logs, "gameLogsMonitoringEnabled")));
    }
    try setDirectory(d, "chatlog.chatlogDir", values.stringAt(s.global, "ChatLogDirectory") orelse values.stringAt(s.logs, "chatLogsDirectory"));
    try setDirectory(d, "chatlog.gamelogDir", values.stringAt(s.global, "GameLogDirectory") orelse values.stringAt(s.logs, "gameLogsDirectory"));
    try d.note("dynamic.import.apm.chatlogImportedNote", &.{});
}

fn setDirectory(d: *Draft, path: []const u8, raw: ?[]const u8) !void {
    if (!nonEmpty(raw)) return;
    try d.setString(path, std.mem.trim(u8, raw.?, " \t"));
}
