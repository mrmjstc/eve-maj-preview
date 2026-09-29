//! EVE-APM Preview's settings, a Qt QSettings INI file.
const std = @import("std");
const values = @import("values.zig");
const draft = @import("draft.zig");
const eve_x = @import("eve_x.zig");
const vk = @import("../../platform/virtual_keys.zig");

const Draft = draft.Draft;
const Section = draft.Section;

/// EVE-APM's OverlayPosition, and EVE-O's ZoomAnchor, list the anchors in TextPosition's order.
const POSITIONS_IN_ORDER = [_][]const u8{ "TopLeft", "TopCenter", "TopRight", "LeftCenter", "Center", "RightCenter", "BottomLeft", "BottomCenter", "BottomRight" };

/// Only the first four of EVE-APM's border styles look alike here; the rest are glow and animated effects.
const BORDER_STYLES = [_][]const u8{ "Solid", "Dashed", "Dotted", "DashDot", "FadedEdges", "CornerAccents", "RoundedCorners", "Neon", "Shimmer", "ThickThin", "ElectricArc", "Rainbow", "BreathingGlow", "DoubleGlow", "Zigzag" };

/// "mining_started" has no notification type here and is reported as unsupported.
const EVENT_TYPES = [_]struct { []const u8, []const u8 }{
    .{ "fleet_invite", "FleetInvite" },
    .{ "follow_warp", "FleetFollow" },
    .{ "regroup", "FleetRegroup" },
    .{ "compression", "MiningCompression" },
    .{ "decloak", "Decloak" },
    .{ "mining_stopped", "MiningStopped" },
    .{ "crystal_broke", "CrystalBroke" },
    .{ "convo_request", "ConversationInvite" },
};

const Keys = std.StringArrayHashMapUnmanaged([]const u8);

const Font = struct { family: ?[]const u8, size: ?f64 };

const Tuple = struct { enabled: bool, vk_code: ?i64, ctrl: bool, alt: bool, shift: bool };

const Group = struct { members: []const []const u8, forward: ?[]const u8, backward: ?[]const u8 };

/// Keys are percent-encoded, points "@Point(x y)", fonts "Family,Size,...", and hotkeys "enabled,vk,ctrl,alt,shift" tuples joined by '|'.
pub const Ini = struct {
    sections: std.StringArrayHashMapUnmanaged(Keys) = .empty,

    pub fn parse(arena: std.mem.Allocator, text: []const u8) !Ini {
        var ini: Ini = .{};
        // By name, since adding a section can move the others.
        var current: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
            if (line[0] == '[' and line[line.len - 1] == ']') {
                const name = line[1 .. line.len - 1];
                const entry = try ini.sections.getOrPut(arena, name);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                current = name;
                continue;
            }
            const keys = ini.sections.getPtr(current orelse continue).?;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            try keys.put(arena, std.mem.trim(u8, line[0..eq], " \t"), std.mem.trim(u8, line[eq + 1 ..], " \t"));
        }
        return ini;
    }

    pub fn section(self: *const Ini, name: []const u8) ?*const Keys {
        return self.sections.getPtr(name);
    }

    pub fn get(self: *const Ini, section_name: []const u8, key: []const u8) ?[]const u8 {
        const keys = self.section(section_name) orelse return null;
        return keys.get(key);
    }

    fn count(self: *const Ini, section_name: []const u8) usize {
        const keys = self.section(section_name) orelse return 0;
        return keys.count();
    }
};

/// QSettings' own percent-encoding: "%XX" is a Latin-1 byte and "%UXXXX" a UTF-16 unit, unlike URI encoding.
fn decodeKey(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < key.len) {
        if (key[i] == '%' and i + 6 <= key.len and key[i + 1] == 'U') {
            if (std.fmt.parseInt(u16, key[i + 2 .. i + 6], 16)) |unit| {
                try appendCodepoint(arena, &out, unit);
                i += 6;
                continue;
            } else |_| {}
        }
        if (key[i] == '%' and i + 3 <= key.len) {
            if (std.fmt.parseInt(u8, key[i + 1 .. i + 3], 16)) |byte| {
                try appendCodepoint(arena, &out, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(arena, key[i]);
        i += 1;
    }
    return out.items;
}

fn appendCodepoint(arena: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u21) !void {
    var buf: [4]u8 = undefined;
    // A lone surrogate half can't be encoded; a replacement keeps the rest of the name.
    const len = std.unicode.utf8Encode(codepoint, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    try out.appendSlice(arena, buf[0..len]);
}

fn unquote(raw: ?[]const u8) ?[]const u8 {
    const t = std.mem.trim(u8, raw orelse return null, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}

fn qtBool(raw: ?[]const u8) ?bool {
    const t = std.mem.trim(u8, raw orelse return null, " \t");
    return std.ascii.eqlIgnoreCase(t, "true");
}

/// QVariant's unset value.
fn isInvalid(raw: ?[]const u8) bool {
    const t = std.mem.trim(u8, raw orelse return true, " \t");
    return t.len == 0 or std.mem.eql(u8, t, "@Invalid()");
}

fn qtPoint(raw: ?[]const u8) ?struct { x: i64, y: i64 } {
    const text = raw orelse return null;
    const start = std.mem.indexOf(u8, text, "@Point(") orelse return null;
    const end = std.mem.indexOfScalarPos(u8, text, start, ')') orelse return null;
    var parts = std.mem.tokenizeAny(u8, text[start + "@Point(".len .. end], " \t");
    const x = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    return .{ .x = x, .y = y };
}

/// "Family,Size,...": only the family and point size carry over.
fn qtFont(raw: ?[]const u8) ?Font {
    const text = unquote(raw) orelse return null;
    if (text.len == 0) return null;
    var parts = std.mem.splitScalar(u8, text, ',');
    const family = std.mem.trim(u8, parts.next().?, " \t");
    const size = values.parseIntLoose(parts.next());
    return .{
        .family = if (family.len > 0) family else null,
        .size = if (size) |s| (if (s > 0) @floatFromInt(s) else null) else null,
    };
}

fn number(raw: ?[]const u8) ?f64 {
    const t = std.mem.trim(u8, raw orelse return null, " \t");
    if (t.len == 0) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

fn intValue(raw: ?[]const u8) ?f64 {
    const n = values.parseIntLoose(raw) orelse return null;
    return @floatFromInt(n);
}

fn parseTuple(raw: ?[]const u8) ?Tuple {
    const text = unquote(raw) orelse return null;
    if (text.len == 0) return null;
    var fields: [5]?i64 = .{ null, null, null, null, null };
    var parts = std.mem.splitScalar(u8, text, ',');
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) {
        if (n < fields.len) fields[n] = values.parseIntLoose(part);
    }
    if (n < 2) return null;
    const set = struct {
        fn f(v: ?i64) bool {
            return (v orelse 0) != 0;
        }
    }.f;
    return .{ .enabled = set(fields[0]), .vk_code = fields[1], .ctrl = set(fields[2]), .alt = set(fields[3]), .shift = set(fields[4]) };
}

/// Whether something was bound at all, so a binding that can't be converted is reported rather than dropped.
fn isBound(raw: ?[]const u8) bool {
    const t = parseTuple(raw) orelse return false;
    return t.enabled and (t.vk_code orelse 0) > 0;
}

/// Null for an unbound tuple and for the left, right and middle mouse buttons, which thumbnails use themselves.
fn tupleHotkey(raw: ?[]const u8) ?u32 {
    const t = parseTuple(raw) orelse return null;
    if (!t.enabled) return null;
    const code = t.vk_code orelse return null;
    if (code <= 0 or code > 0xFF or code == 0x01 or code == 0x02 or code == 0x04) return null;
    var modifiers: u32 = 0;
    if (t.ctrl) modifiers |= vk.MOD_CONTROL;
    if (t.alt) modifiers |= vk.MOD_ALT;
    if (t.shift) modifiers |= vk.MOD_SHIFT;
    return vk.combineKey(@intCast(code), modifiers);
}

pub fn anchorName(n: ?f64) ?[]const u8 {
    const i = n orelse return null;
    if (i < 0 or i >= POSITIONS_IN_ORDER.len) return null;
    return POSITIONS_IN_ORDER[@intFromFloat(i)];
}

fn eventType(event: []const u8) ?[]const u8 {
    for (EVENT_TYPES) |entry| {
        if (std.mem.eql(u8, entry[0], event)) return entry[1];
    }
    return null;
}

/// "<process>.exe::<title>" entries come from EVE-APM's overlay for non-EVE windows and aren't characters.
fn isNonEveWindow(name: []const u8) bool {
    const sep = std.mem.indexOf(u8, name, "::") orelse return false;
    const dot = std.mem.lastIndexOfScalar(u8, name[0..sep], '.') orelse return false;
    return dot + 1 < sep;
}

pub fn sections(d: *Draft, ini: *const Ini) ![]const Section {
    const positions = ini.count("thumbnailPositions");
    const colors = ini.count("characterBorderColors");
    const hotkeys = ini.count("characterHotkeys");
    const groups = try groupCount(d, ini);
    const has_appearance = ini.section("ui") != null or ini.section("overlay") != null or ini.section("thumbnail") != null;
    const has_auto_minimize = ini.get("window", "minimizeInactiveClients") != null or ini.get("window", "minimizeDelay") != null or
        !isInvalid(ini.get("window", "neverMinimizeCharacters")) or !isInvalid(ini.get("window", "neverCloseCharacters"));
    const has_snapping = ini.get("position", "enableSnapping") != null or ini.get("position", "snapDistance") != null;
    const has_global_hotkeys = ini.section("closeAllHotkeys") != null or ini.section("minimizeAllHotkeys") != null or
        ini.section("toggleThumbnailsVisibilityHotkeys") != null or ini.section("hotkeys") != null or ini.section("hotkey") != null;
    const has_chatlog = ini.section("chatlog") != null or ini.section("gamelog") != null;
    const has_notifications = eve_x.nonEmpty(ini.get("combatMessages", "enabledEventTypes"));

    return d.arena.dupe(Section, &.{
        .{ .id = "thumbnailAppearance", .title = "dynamic.import.apm.thumbnailAppearance.title", .hint = .{ .key = "dynamic.import.apm.thumbnailAppearance.hint" }, .available = has_appearance },
        .{ .id = "characterPositions", .title = "dynamic.import.apm.characterPositions.title", .hint = try d.countText("dynamic.import.characterPositionsHint", positions), .available = positions > 0 },
        .{ .id = "characterColors", .title = "dynamic.import.apm.characterColors.title", .hint = try eve_x.colorsHint(d, colors, hotkeys), .available = colors + hotkeys > 0 },
        .{ .id = "hotkeyGroups", .title = "dynamic.import.apm.hotkeyGroups.title", .hint = try d.countText("dynamic.import.hotkeyGroupsCountHint", groups), .available = groups > 0 },
        .{ .id = "globalHotkeys", .title = "dynamic.import.apm.globalHotkeys.title", .hint = .{ .key = "dynamic.import.apm.globalHotkeys.hint" }, .available = has_global_hotkeys },
        .{ .id = "autoMinimize", .title = "dynamic.import.apm.autoMinimize.title", .hint = .{ .key = "dynamic.import.apm.autoMinimize.hint" }, .available = has_auto_minimize },
        .{ .id = "snapping", .title = "dynamic.import.apm.snapping.title", .hint = .{ .key = "dynamic.import.apm.snapping.hint" }, .available = has_snapping },
        .{ .id = "chatlog", .title = "dynamic.import.apm.chatlog.title", .hint = .{ .key = "dynamic.import.apm.chatlog.hint" }, .available = has_chatlog },
        .{ .id = "notifications", .title = "dynamic.import.apm.notifications.title", .hint = .{ .key = "dynamic.import.apm.notifications.hint" }, .available = has_notifications },
    });
}

/// Groups with no members and no keys are the empty one EVE-APM starts with.
fn groupCount(d: *Draft, ini: *const Ini) !usize {
    const groups = ini.section("cycleGroups") orelse return 0;
    var n: usize = 0;
    for (groups.values()) |raw| {
        const group = try parseGroup(d.arena, raw);
        if (group.members.len > 0 or isBound(group.forward) or isBound(group.backward)) n += 1;
    }
    return n;
}

/// "member,member|forward tuple|backward tuple|...".
fn parseGroup(arena: std.mem.Allocator, raw: []const u8) !Group {
    var parts = std.mem.splitScalar(u8, unquote(raw).?, '|');
    var members: std.ArrayList([]const u8) = .empty;
    var names = std.mem.splitScalar(u8, parts.next().?, ',');
    while (names.next()) |name| {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len > 0) try members.append(arena, trimmed);
    }
    return .{ .members = members.items, .forward = parts.next(), .backward = parts.next() };
}

pub fn build(d: *Draft, ini: *const Ini, chosen: []const []const u8) !void {
    if (eve_x.isChosen(chosen, "thumbnailAppearance")) try appearance(d, ini);
    if (eve_x.isChosen(chosen, "characterPositions")) try characterPositions(d, ini);
    if (eve_x.isChosen(chosen, "characterColors")) try colorsAndHotkeys(d, ini);
    if (eve_x.isChosen(chosen, "hotkeyGroups")) try hotkeyGroups(d, ini);
    if (eve_x.isChosen(chosen, "globalHotkeys")) try globalHotkeys(d, ini);
    if (eve_x.isChosen(chosen, "autoMinimize")) try autoMinimize(d, ini);
    if (eve_x.isChosen(chosen, "snapping")) try snapping(d, ini);
    if (eve_x.isChosen(chosen, "chatlog")) try chatlog(d, ini);
    if (eve_x.isChosen(chosen, "notifications")) try notifications(d, ini);
}

fn borderStyle(d: *Draft, path: []const u8, raw: ?[]const u8, label: []const u8) !void {
    const n = values.parseIntLoose(raw orelse return) orelse return;
    const name = if (n >= 0 and n < BORDER_STYLES.len) BORDER_STYLES[@intCast(n)] else try std.fmt.allocPrint(d.arena, "#{d}", .{n});
    if (n >= 0 and n < 4) return d.setString(path, name);
    try d.note("dynamic.import.apm.borderStyleUnsupportedNote", &.{ .{ .name = "label", .value = label, .translate = true }, .{ .name = "name", .value = name } });
}

fn appearance(d: *Draft, ini: *const Ini) !void {
    try d.note("dynamic.import.thumbnailAppearanceImportedNote", &.{});
    try d.setColor("thumbnail.borderColor", values.rgbColor(ini.get("ui", "highlightColor")));
    try d.setNumber("thumbnail.borderWidth", number(ini.get("ui", "highlightBorderWidth")));
    try d.setBool("thumbnail.showBorderWhenFocused", qtBool(ini.get("ui", "highlightActiveWindow")));
    try d.setBool("thumbnail.hideWhenNoEveFocus", qtBool(ini.get("ui", "hideThumbnailsWhenEVENotFocused")));
    try d.setBool("thumbnail.activeThumbnailHidden", qtBool(ini.get("ui", "hideActiveClientThumbnail")));
    try borderStyle(d, "thumbnail.borderStyle", ini.get("ui", "activeBorderStyle"), "dynamic.import.apm.activeLabel");

    try d.setColor("thumbnail.inactiveBorderColor", values.rgbColor(ini.get("ui", "inactiveBorderColor")));
    try d.setNumber("thumbnail.inactiveBorderWidth", number(ini.get("ui", "inactiveBorderWidth")));
    try d.setBool("thumbnail.showBorderWhenInactive", qtBool(ini.get("ui", "showInactiveBorders")));
    try borderStyle(d, "thumbnail.inactiveBorderStyle", ini.get("ui", "inactiveBorderStyle"), "dynamic.import.apm.inactiveLabel");

    const show_name = qtBool(ini.get("overlay", "showCharacterName"));
    const show_system = qtBool(ini.get("overlay", "showSystemName"));
    try d.setBool("thumbnail.showCharacterName", show_name);
    try d.setBool("thumbnail.showSystemName", show_system);
    if (show_name != null or show_system != null) try d.setBool("thumbnail.showText", (show_name orelse false) or (show_system orelse false));

    try d.setColor("thumbnail.characterNameColor", values.rgbColor(ini.get("overlay", "characterNameColor")));
    try d.setColor("thumbnail.systemNameColor", values.rgbColor(ini.get("overlay", "systemNameColor")));
    try d.setBool("thumbnail.useUniqueSystemColors", qtBool(ini.get("overlay", "uniqueSystemNameColors")));
    try d.setString("thumbnail.characterNamePosition", anchorName(intValue(ini.get("overlay", "characterNamePosition"))));
    try d.setString("thumbnail.systemNamePosition", anchorName(intValue(ini.get("overlay", "systemNamePosition"))));
    try d.setNumber("thumbnail.characterNameOffsetX", number(ini.get("overlay", "characterNameOffsetX")));
    try d.setNumber("thumbnail.characterNameOffsetY", number(ini.get("overlay", "characterNameOffsetY")));
    try d.setNumber("thumbnail.systemNameOffsetX", number(ini.get("overlay", "systemNameOffsetX")));
    try d.setNumber("thumbnail.systemNameOffsetY", number(ini.get("overlay", "systemNameOffsetY")));

    if (values.rgbColor(ini.get("overlay", "backgroundColor"))) |background| {
        const shown = qtBool(ini.get("overlay", "showBackground")) orelse true;
        const alpha: f64 = if (!shown) 0 else if (number(ini.get("overlay", "backgroundOpacity"))) |percent| percent * 2.55 else 255;
        // One shared background, which each overlay text here has its own of.
        const color = values.withAlpha(background, alpha);
        inline for (.{ "thumbnail.characterNameBgColor", "thumbnail.systemNameBgColor", "thumbnail.quickGroupBadgeBgColor", "thumbnail.notifications.bg_color" }) |path| {
            try d.setColor(path, color);
        }
    }

    // Older versions have one overlay font; newer ones also a font each for the character and system name.
    if (qtFont(ini.get("overlay", "font"))) |font| try d.setOverlayFont(font.family, font.size);
    if (qtFont(ini.get("overlay", "characterNameFont"))) |font| {
        try d.setString("thumbnail.characterNameFontName", font.family);
        try d.setNumber("thumbnail.characterNameFontSize", font.size);
    }
    if (qtFont(ini.get("overlay", "systemNameFont"))) |font| {
        try d.setString("thumbnail.systemNameFontName", font.family);
        try d.setNumber("thumbnail.systemNameFontSize", font.size);
    }

    try d.setNumber("thumbnail.width", number(ini.get("thumbnail", "width")));
    try d.setNumber("thumbnail.height", number(ini.get("thumbnail", "height")));
    if (number(ini.get("thumbnail", "opacity"))) |percent| try d.setNumber("thumbnail.thumbnailOpacity", values.opacityFromPercent(percent));
}

fn characterPositions(d: *Draft, ini: *const Ini) !void {
    const entries = ini.section("thumbnailPositions") orelse return;
    var imported: usize = 0;
    var skipped: usize = 0;
    var it = entries.iterator();
    while (it.next()) |entry| {
        const point = qtPoint(entry.value_ptr.*) orelse continue;
        const decoded = try decodeKey(d.arena, entry.key_ptr.*);
        if (isNonEveWindow(decoded)) {
            skipped += 1;
            continue;
        }
        const name = values.characterName(decoded) orelse continue;
        try eve_x.putPosition(d, try d.character(name), @floatFromInt(point.x), @floatFromInt(point.y));
        imported += 1;
    }
    try d.noteCount("dynamic.import.apm.importedPositionsNote", "n", imported);
    if (skipped > 0) try d.noteCount("dynamic.import.apm.skippedNonEveWindowNote", "n", skipped);
}

fn colorsAndHotkeys(d: *Draft, ini: *const Ini) !void {
    var skipped: usize = 0;
    var colored: usize = 0;
    if (ini.section("characterBorderColors")) |entries| {
        var it = entries.iterator();
        while (it.next()) |entry| {
            const color = values.rgbColor(entry.value_ptr.*) orelse continue;
            const decoded = try decodeKey(d.arena, entry.key_ptr.*);
            if (isNonEveWindow(decoded)) {
                skipped += 1;
                continue;
            }
            const name = values.characterName(decoded) orelse continue;
            try d.put(try d.character(name), "borderColors.activeBorderColor", try values.colorValue(d.arena, color));
            colored += 1;
        }
    }

    var converted: usize = 0;
    const hotkeys = ini.section("characterHotkeys");
    if (hotkeys) |entries| {
        var it = entries.iterator();
        while (it.next()) |entry| {
            const decoded = try decodeKey(d.arena, entry.key_ptr.*);
            if (isNonEveWindow(decoded)) {
                skipped += 1;
                continue;
            }
            const name = values.characterName(decoded) orelse continue;
            const combined = tupleHotkey(entry.value_ptr.*) orelse continue;
            try d.put(try d.character(name), "hotkey", try values.keyValue(d.arena, combined));
            converted += 1;
        }
    }

    try d.noteCount("dynamic.import.importedBorderColorsCountNote", "n", colored);
    const total = if (hotkeys) |h| h.count() else 0;
    if (total > 0) try d.note("dynamic.import.apm.convertedHotkeysDecodedNote", &.{ .{ .name = "converted", .value = try d.format(converted) }, .{ .name = "total", .value = try d.format(total) } });
    if (skipped > 0) try d.noteCount("dynamic.import.apm.skippedNonEveWindowNote", "n", skipped);
}

fn hotkeyGroups(d: *Draft, ini: *const Ini) !void {
    const entries = ini.section("cycleGroups") orelse return;
    const first_note = d.notes.items.len;
    var imported: usize = 0;
    var it = entries.iterator();
    while (it.next()) |entry| {
        const group = try parseGroup(d.arena, entry.value_ptr.*);
        if (group.members.len == 0 and !isBound(group.forward) and !isBound(group.backward)) continue;
        const name = try decodeKey(d.arena, entry.key_ptr.*);
        const forward = tupleHotkey(group.forward);
        const backward = tupleHotkey(group.backward);

        var members = std.json.Array.init(d.arena);
        for (group.members) |member| try members.append(.{ .string = member });
        const fields = try d.item("hotkeyGroups", "name", name);
        try d.put(fields, "characters", .{ .array = members });
        try d.put(fields, "forwardKey", if (forward) |k| try values.keyValue(d.arena, k) else .null);
        try d.put(fields, "backwardKey", if (backward) |k| try values.keyValue(d.arena, k) else .null);
        imported += 1;

        if (forward != null or backward != null) try d.note("dynamic.import.apm.hotkeyGroupDecodedNote", &.{.{ .name = "name", .value = name }});
        if (forward == null and isBound(group.forward)) try d.note("dynamic.import.apm.hotkeyGroupForwardUnsupportedNote", &.{.{ .name = "name", .value = name }});
        if (backward == null and isBound(group.backward)) try d.note("dynamic.import.apm.hotkeyGroupBackwardUnsupportedNote", &.{.{ .name = "name", .value = name }});
    }
    try d.notes.insert(d.arena, first_note, try d.countText("dynamic.import.hotkeyGroupsImportedNote", imported));
}

/// EVE-APM can bind several keys to one action; one is kept here.
fn actionHotkey(d: *Draft, ini: *const Ini, section_name: []const u8, key: []const u8, path: []const u8, label: []const u8) !void {
    const raw = unquote(ini.get(section_name, key)) orelse return;
    var bound: std.ArrayList([]const u8) = .empty;
    var tuples = std.mem.splitScalar(u8, raw, '|');
    while (tuples.next()) |tuple| {
        if (isBound(tuple)) try bound.append(d.arena, tuple);
    }
    if (bound.items.len == 0) return;
    if (tupleHotkey(bound.items[0])) |combined| {
        try d.setKey(path, combined);
    } else {
        try d.note("dynamic.import.apm.globalHotkeyUnsupportedNote", &.{.{ .name = "label", .value = label, .translate = true }});
    }
    if (bound.items.len > 1) try d.note("dynamic.import.apm.globalHotkeyMultipleBoundNote", &.{ .{ .name = "label", .value = label, .translate = true }, .{ .name = "n", .value = try d.format(bound.items.len) } });
}

fn globalHotkeys(d: *Draft, ini: *const Ini) !void {
    try actionHotkey(d, ini, "closeAllHotkeys", "closeAllClients", "hotkeys.hotkeyCloseAll", "dynamic.import.apm.actionLabel.closeAll");
    try actionHotkey(d, ini, "minimizeAllHotkeys", "minimizeAllClients", "hotkeys.hotkeyMinimizeAll", "dynamic.import.apm.actionLabel.minimizeAll");
    try actionHotkey(d, ini, "toggleThumbnailsVisibilityHotkeys", "toggleThumbnailsVisibility", "hotkeys.hotkeyToggleVisibility", "dynamic.import.apm.actionLabel.toggleVisibility");
    try actionHotkey(d, ini, "hotkeys", "suspendHotkey", "hotkeys.hotkeySuspend", "dynamic.import.apm.actionLabel.suspend");
    try d.setBool("hotkeys.requireEveFocus", qtBool(ini.get("hotkey", "onlyWhenEVEFocused")));
    try d.setBool("hotkeys.resetGroupIndexOnNonGroupFocus", qtBool(ini.get("hotkey", "resetGroupIndexOnNonGroupFocus")));
    try d.note("dynamic.import.apm.globalHotkeysImportedNote", &.{});
}

fn characterList(d: *Draft, raw: ?[]const u8, field: []const u8) !void {
    if (isInvalid(raw)) return;
    var names = std.mem.splitScalar(u8, unquote(raw).?, ',');
    while (names.next()) |raw_name| {
        const name = values.characterName(raw_name) orelse continue;
        try d.put(try d.character(name), field, .{ .bool = true });
    }
}

fn autoMinimize(d: *Draft, ini: *const Ini) !void {
    try d.setBool("autoMinimize.enabled", qtBool(ini.get("window", "minimizeInactiveClients")));
    try d.setNumber("autoMinimize.delayMs", intValue(ini.get("window", "minimizeDelay")));
    try characterList(d, ini.get("window", "neverMinimizeCharacters"), "excludeFromMinimize");
    try characterList(d, ini.get("window", "neverCloseCharacters"), "excludeFromCloseAll");
    try d.note("dynamic.import.autoMinimizeImportedNote", &.{});
}

fn snapping(d: *Draft, ini: *const Ini) !void {
    try d.setBool("snapping.enabled", qtBool(ini.get("position", "enableSnapping")));
    try d.setNumber("snapping.threshold", intValue(ini.get("position", "snapDistance")));
    if (qtBool(ini.get("position", "lockPositions"))) |locked| try d.setBool("interaction.enableDragging", !locked);
    try d.note("dynamic.import.snappingImportedNote", &.{});
}

fn chatlog(d: *Draft, ini: *const Ini) !void {
    const chat = qtBool(ini.get("chatlog", "enableMonitoring"));
    const game = qtBool(ini.get("gamelog", "enableMonitoring"));
    if (chat != null or game != null) try d.setBool("chatlog.enabled", (chat orelse false) or (game orelse false));
    if (unquote(ini.get("chatlog", "directory"))) |dir| {
        if (dir.len > 0) try d.setString("chatlog.chatlogDir", dir);
    }
    if (unquote(ini.get("gamelog", "directory"))) |dir| {
        if (dir.len > 0) try d.setString("chatlog.gamelogDir", dir);
    }
    try d.note("dynamic.import.apm.chatlogImportedNote", &.{});
}

fn notifications(d: *Draft, ini: *const Ini) !void {
    try d.setBool("thumbnail.notifications.enabled", qtBool(ini.get("combatMessages", "enabled")));
    const default_duration = intValue(ini.get("combatMessages", "duration"));
    const color = values.rgbColor(ini.get("combatMessages", "color"));
    const suppress_all = qtBool(ini.get("combatMessages", "suppressWhenFocused"));

    var mapped: usize = 0;
    var total: usize = 0;
    var events = std.mem.splitScalar(u8, ini.get("combatMessages", "enabledEventTypes") orelse "", ',');
    while (events.next()) |raw| {
        const event = std.mem.trim(u8, raw, " \t");
        if (event.len == 0) continue;
        total += 1;
        const target = eventType(event) orelse {
            try d.note("dynamic.import.apm.eventTypeUnsupportedNote", &.{.{ .name = "evt", .value = event }});
            continue;
        };
        const base = try std.fmt.allocPrint(d.arena, "thumbnail.notifications.type_configs.{s}.", .{target});
        try d.setBool(try concat(d, base, "enabled"), true);
        const duration_key = try std.fmt.allocPrint(d.arena, "eventDurations\\{s}", .{event});
        try d.setNumber(try concat(d, base, "duration_ms"), intValue(ini.get("combatMessages", duration_key)) orelse default_duration);
        try d.setColor(try concat(d, base, "border_color"), color);
        const suppress_key = try std.fmt.allocPrint(d.arena, "suppressFocused\\{s}", .{event});
        try d.setBool(try concat(d, base, "suppress_when_focused"), qtBool(ini.get("combatMessages", suppress_key)) orelse suppress_all);
        mapped += 1;
    }
    if (total > 0) try d.note("dynamic.import.apm.notificationTypesImportedNote", &.{ .{ .name = "mapped", .value = try d.format(mapped) }, .{ .name = "total", .value = try d.format(total) } });
}

fn concat(d: *Draft, a: []const u8, b: []const u8) ![]const u8 {
    return std.mem.concat(d.arena, u8, &.{ a, b });
}
