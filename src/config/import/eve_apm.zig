//! EVE-APM Preview's settings, a Qt QSettings INI file.
const std = @import("std");
const vk = @import("../../platform/virtual_keys.zig");
const values = @import("values.zig");
const draft_mod = @import("draft.zig");
const eve_x = @import("eve_x.zig");
const key_list = @import("../key_list.zig");

const Draft = draft_mod.Draft;
const KeyList = key_list.KeyList;
const Section = draft_mod.Section;

/// EVE-APM's OverlayPosition, and EVE-O's ZoomAnchor, list the anchors in TextPosition's order.
const POSITIONS_IN_ORDER = [_][]const u8{ "TopLeft", "TopCenter", "TopRight", "LeftCenter", "Center", "RightCenter", "BottomLeft", "BottomCenter", "BottomRight" };

/// Only the first SUPPORTED_BORDER_STYLE_COUNT of EVE-APM's border styles look alike here; the rest are glow and animated effects.
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

const SKIPPED_NON_EVE_NOTE = "Skipped {n} non-EVE window item(s) (tracked via EVE-APM's non-EVE window overlay - not real characters).";
const SUPPORTED_BORDER_STYLE_COUNT = 4;

/// The mouse buttons thumbnails use themselves, which `vk` has no names for.
const VK_LBUTTON = 0x01;
const VK_RBUTTON = 0x02;

const Keys = std.array_hash_map.String([]const u8);

const Font = struct { family: ?[]const u8, size: ?f64 };

const Tuple = struct { is_enabled: bool, vk_code: ?i64, has_ctrl: bool, has_alt: bool, has_shift: bool };

const Group = struct { members: []const []const u8, forward: ?[]const u8, backward: ?[]const u8 };

/// Keys are percent-encoded, points "@Point(x y)", fonts "Family,Size,...", and hotkeys "enabled,vk,ctrl,alt,shift" tuples joined by '|'.
pub const Ini = struct {
    /// Names and values borrow from the parsed text; the maps live in the arena given to parse.
    sections: std.array_hash_map.String(Keys) = .empty,

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
            const keys = ini.sections.getPtr(current orelse continue) orelse continue;
            const equals_index = std.mem.findScalar(u8, line, '=') orelse continue;
            try keys.put(arena, std.mem.trim(u8, line[0..equals_index], " \t"), std.mem.trim(u8, line[equals_index + 1 ..], " \t"));
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

pub fn anchorName(index: ?f64) ?[]const u8 {
    const position = index orelse return null;
    if (position < 0 or position >= POSITIONS_IN_ORDER.len) return null;
    return POSITIONS_IN_ORDER[@intFromFloat(position)];
}

pub fn sections(draft: *Draft, ini: *const Ini) ![]const Section {
    const position_count = ini.count("thumbnailPositions");
    const color_count = ini.count("characterBorderColors");
    const hotkey_count = ini.count("characterHotkeys");
    const group_count = try groupCount(draft, ini);
    const has_appearance = ini.section("ui") != null or ini.section("overlay") != null or ini.section("thumbnail") != null;
    const has_auto_minimize = ini.get("window", "minimizeInactiveClients") != null or ini.get("window", "minimizeDelay") != null or
        !isInvalid(ini.get("window", "neverMinimizeCharacters")) or !isInvalid(ini.get("window", "neverCloseCharacters"));
    const has_snapping = ini.get("position", "enableSnapping") != null or ini.get("position", "snapDistance") != null;
    const has_global_hotkeys = ini.section("closeAllHotkeys") != null or ini.section("minimizeAllHotkeys") != null or
        ini.section("toggleThumbnailsVisibilityHotkeys") != null or ini.section("hotkeys") != null or ini.section("hotkey") != null;
    const has_chatlog = ini.section("chatlog") != null or ini.section("gamelog") != null;
    const has_notifications = eve_x.hasText(ini.get("combatMessages", "enabledEventTypes"));

    return draft.arena.dupe(Section, &.{
        .{ .id = "thumbnailAppearance", .title = "Thumbnail Appearance", .hint = .{ .key = "Border/text colors, opacity, font" }, .available = has_appearance },
        .{ .id = "characterPositions", .title = "Character Positions", .hint = try draft.countText("{n} character(s) with saved positions", position_count), .available = position_count > 0 },
        .{ .id = "characterColors", .title = "Character Colors & Hotkeys", .hint = try eve_x.colorsHint(draft, color_count, hotkey_count), .available = color_count + hotkey_count > 0 },
        .{ .id = "hotkeyGroups", .title = "Hotkey Groups", .hint = try draft.countText("{n} group(s)", group_count), .available = group_count > 0 },
        .{ .id = "globalHotkeys", .title = "Global Hotkeys & Behavior", .hint = .{ .key = "Close/minimize-all, toggle visibility, suspend, EVE-focus requirement" }, .available = has_global_hotkeys },
        .{ .id = "autoMinimize", .title = "Auto-Minimize", .hint = .{ .key = "Minimize inactive clients + excluded characters" }, .available = has_auto_minimize },
        .{ .id = "snapping", .title = "Snapping", .hint = .{ .key = "Thumbnail snapping" }, .available = has_snapping },
        .{ .id = "chatlog", .title = "Chatlog Monitoring", .hint = .{ .key = "Chatlog/gamelog folders" }, .available = has_chatlog },
        .{ .id = "notifications", .title = "Fleet/Event Notifications", .hint = .{ .key = "Fleet invite, decloak, mining, etc." }, .available = has_notifications },
    });
}

pub fn build(draft: *Draft, ini: *const Ini, chosen: []const []const u8) !void {
    if (draft_mod.isChosen(chosen, "thumbnailAppearance")) try appearance(draft, ini);
    if (draft_mod.isChosen(chosen, "characterPositions")) try characterPositions(draft, ini);
    if (draft_mod.isChosen(chosen, "characterColors")) try colorsAndHotkeys(draft, ini);
    if (draft_mod.isChosen(chosen, "hotkeyGroups")) try hotkeyGroups(draft, ini);
    if (draft_mod.isChosen(chosen, "globalHotkeys")) try globalHotkeys(draft, ini);
    if (draft_mod.isChosen(chosen, "autoMinimize")) try autoMinimize(draft, ini);
    if (draft_mod.isChosen(chosen, "snapping")) try snapping(draft, ini);
    if (draft_mod.isChosen(chosen, "chatlog")) try chatlog(draft, ini);
    if (draft_mod.isChosen(chosen, "notifications")) try notifications(draft, ini);
}

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
    const encoded_length = std.unicode.utf8Encode(codepoint, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    try out.appendSlice(arena, buf[0..encoded_length]);
}

fn unquote(raw: ?[]const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') return trimmed[1 .. trimmed.len - 1];
    return trimmed;
}

fn qtBool(raw: ?[]const u8) ?bool {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t");
    return std.ascii.eqlIgnoreCase(trimmed, "true");
}

/// QVariant's unset value.
fn isInvalid(raw: ?[]const u8) bool {
    const trimmed = std.mem.trim(u8, raw orelse return true, " \t");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "@Invalid()");
}

fn qtPoint(raw: ?[]const u8) ?struct { x: i64, y: i64 } {
    const text = raw orelse return null;
    const start = std.mem.find(u8, text, "@Point(") orelse return null;
    const end = std.mem.findScalarPos(u8, text, start, ')') orelse return null;
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
    const family = std.mem.trim(u8, parts.first(), " \t");
    const size = values.parseIntLoose(parts.next());
    return .{
        .family = if (family.len > 0) family else null,
        .size = if (size) |s| (if (s > 0) @floatFromInt(s) else null) else null,
    };
}

fn number(raw: ?[]const u8) ?f64 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseFloat(f64, trimmed) catch null;
}

fn intValue(raw: ?[]const u8) ?f64 {
    const integer = values.parseIntLoose(raw) orelse return null;
    return @floatFromInt(integer);
}

fn parseTuple(raw: ?[]const u8) ?Tuple {
    const text = unquote(raw) orelse return null;
    if (text.len == 0) return null;
    var fields: [5]?i64 = .{ null, null, null, null, null };
    var parts = std.mem.splitScalar(u8, text, ',');
    var field_count: usize = 0;
    while (parts.next()) |part| : (field_count += 1) {
        if (field_count < fields.len) fields[field_count] = values.parseIntLoose(part);
    }
    if (field_count < 2) return null;
    return .{ .is_enabled = isNonZero(fields[0]), .vk_code = fields[1], .has_ctrl = isNonZero(fields[2]), .has_alt = isNonZero(fields[3]), .has_shift = isNonZero(fields[4]) };
}

fn isNonZero(field: ?i64) bool {
    return (field orelse 0) != 0;
}

/// Whether something was bound at all, so a binding that can't be converted is reported rather than dropped.
fn isBound(raw: ?[]const u8) bool {
    const tuple = parseTuple(raw) orelse return false;
    return tuple.is_enabled and (tuple.vk_code orelse 0) > 0;
}

/// Null for an unbound tuple and for the left and right mouse buttons, which thumbnails use themselves.
fn tupleHotkey(raw: ?[]const u8) ?u32 {
    const tuple = parseTuple(raw) orelse return null;
    if (!tuple.is_enabled) return null;
    const virtual_key = tuple.vk_code orelse return null;
    if (virtual_key <= 0 or virtual_key > 0xFF or virtual_key == VK_LBUTTON or virtual_key == VK_RBUTTON) return null;
    var modifiers: u32 = 0;
    if (tuple.has_ctrl) modifiers |= vk.MOD_CONTROL;
    if (tuple.has_alt) modifiers |= vk.MOD_ALT;
    if (tuple.has_shift) modifiers |= vk.MOD_SHIFT;
    return vk.combineKey(@intCast(virtual_key), modifiers);
}

fn eventType(event: []const u8) ?[]const u8 {
    for (EVENT_TYPES) |entry| {
        if (std.mem.eql(u8, entry[0], event)) return entry[1];
    }
    return null;
}

/// "<process>.exe::<title>" entries come from EVE-APM's overlay for non-EVE windows and aren't characters.
fn isNonEveWindow(name: []const u8) bool {
    const separator_index = std.mem.find(u8, name, "::") orelse return false;
    const dot_index = std.mem.findScalarLast(u8, name[0..separator_index], '.') orelse return false;
    return dot_index + 1 < separator_index;
}

/// Groups with no members and no keys are the empty one EVE-APM starts with.
fn groupCount(draft: *Draft, ini: *const Ini) !usize {
    const groups = ini.section("cycleGroups") orelse return 0;
    var group_count: usize = 0;
    for (groups.values()) |raw| {
        const group = try parseGroup(draft.arena, raw);
        if (group.members.len > 0 or isBound(group.forward) or isBound(group.backward)) group_count += 1;
    }
    return group_count;
}

/// "member,member|forward tuple|backward tuple|...".
fn parseGroup(arena: std.mem.Allocator, raw: []const u8) !Group {
    var parts = std.mem.splitScalar(u8, unquote(raw).?, '|');
    var members: std.ArrayList([]const u8) = .empty;
    var names = std.mem.splitScalar(u8, parts.first(), ',');
    while (names.next()) |name| {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len > 0) try members.append(arena, trimmed);
    }
    return .{ .members = members.items, .forward = parts.next(), .backward = parts.next() };
}

fn borderStyle(draft: *Draft, path: []const u8, raw: ?[]const u8, label: []const u8) !void {
    const style_index = values.parseIntLoose(raw orelse return) orelse return;
    const name = if (style_index >= 0 and style_index < BORDER_STYLES.len) BORDER_STYLES[@intCast(style_index)] else try draft.arena.print("#{d}", .{style_index});
    if (style_index >= 0 and style_index < SUPPORTED_BORDER_STYLE_COUNT) return draft.setString(path, name);
    try draft.note("{label} border style \"{name}\" has no equivalent in EVE-Maj Preview and was not imported.", &.{ .{ .name = "label", .value = label, .should_translate = true }, .{ .name = "name", .value = name } });
}

fn appearance(draft: *Draft, ini: *const Ini) !void {
    try draft.setColor("thumbnail.borderColor", values.rgbColor(ini.get("ui", "highlightColor")));
    try draft.setNumber("thumbnail.borderWidth", number(ini.get("ui", "highlightBorderWidth")));
    try draft.setBool("thumbnail.showBorderWhenFocused", qtBool(ini.get("ui", "highlightActiveWindow")));
    try draft.setBool("thumbnail.hideWhenNoEveFocus", qtBool(ini.get("ui", "hideThumbnailsWhenEVENotFocused")));
    try draft.setBool("thumbnail.activeThumbnailHidden", qtBool(ini.get("ui", "hideActiveClientThumbnail")));
    try borderStyle(draft, "thumbnail.borderStyle", ini.get("ui", "activeBorderStyle"), "Active");

    try draft.setColor("thumbnail.inactiveBorderColor", values.rgbColor(ini.get("ui", "inactiveBorderColor")));
    try draft.setNumber("thumbnail.inactiveBorderWidth", number(ini.get("ui", "inactiveBorderWidth")));
    try draft.setBool("thumbnail.showBorderWhenInactive", qtBool(ini.get("ui", "showInactiveBorders")));
    try borderStyle(draft, "thumbnail.inactiveBorderStyle", ini.get("ui", "inactiveBorderStyle"), "Inactive");

    const is_name_shown = qtBool(ini.get("overlay", "showCharacterName"));
    const is_system_shown = qtBool(ini.get("overlay", "showSystemName"));
    try draft.setBool("thumbnail.showCharacterName", is_name_shown);
    try draft.setBool("thumbnail.showSystemName", is_system_shown);
    if (is_name_shown != null or is_system_shown != null) try draft.setBool("thumbnail.showText", (is_name_shown orelse false) or (is_system_shown orelse false));

    try draft.setColor("thumbnail.characterNameColor", values.rgbColor(ini.get("overlay", "characterNameColor")));
    try draft.setColor("thumbnail.systemNameColor", values.rgbColor(ini.get("overlay", "systemNameColor")));
    try draft.setBool("thumbnail.useUniqueSystemColors", qtBool(ini.get("overlay", "uniqueSystemNameColors")));
    try draft.setString("thumbnail.characterNamePosition", anchorName(intValue(ini.get("overlay", "characterNamePosition"))));
    try draft.setString("thumbnail.systemNamePosition", anchorName(intValue(ini.get("overlay", "systemNamePosition"))));
    try draft.setNumber("thumbnail.characterNameOffsetX", number(ini.get("overlay", "characterNameOffsetX")));
    try draft.setNumber("thumbnail.characterNameOffsetY", number(ini.get("overlay", "characterNameOffsetY")));
    try draft.setNumber("thumbnail.systemNameOffsetX", number(ini.get("overlay", "systemNameOffsetX")));
    try draft.setNumber("thumbnail.systemNameOffsetY", number(ini.get("overlay", "systemNameOffsetY")));

    if (values.rgbColor(ini.get("overlay", "backgroundColor"))) |background| {
        const is_shown = qtBool(ini.get("overlay", "showBackground")) orelse true;
        const alpha: f64 = if (!is_shown) 0 else if (number(ini.get("overlay", "backgroundOpacity"))) |percent| values.opacityFromPercent(percent) else 255;
        // One shared background, which each overlay text here has its own of.
        const color = values.withAlpha(background, alpha);
        inline for (.{ "thumbnail.characterNameBgColor", "thumbnail.systemNameBgColor", "thumbnail.quickGroupBadgeBgColor", "thumbnail.notifications.bg_color" }) |path| {
            try draft.setColor(path, color);
        }
    }

    // Older versions have one overlay font; newer ones also a font each for the character and system name.
    if (qtFont(ini.get("overlay", "font"))) |font| try draft.setOverlayFont(font.family, font.size);
    if (qtFont(ini.get("overlay", "characterNameFont"))) |font| {
        try draft.setString("thumbnail.characterNameFontName", font.family);
        try draft.setNumber("thumbnail.characterNameFontSize", font.size);
    }
    if (qtFont(ini.get("overlay", "systemNameFont"))) |font| {
        try draft.setString("thumbnail.systemNameFontName", font.family);
        try draft.setNumber("thumbnail.systemNameFontSize", font.size);
    }

    try draft.setNumber("thumbnail.width", number(ini.get("thumbnail", "width")));
    try draft.setNumber("thumbnail.height", number(ini.get("thumbnail", "height")));
    if (number(ini.get("thumbnail", "opacity"))) |percent| try draft.setNumber("thumbnail.thumbnailOpacity", values.opacityFromPercent(percent));
}

fn characterPositions(draft: *Draft, ini: *const Ini) !void {
    const entries = ini.section("thumbnailPositions") orelse return;
    var skipped_count: usize = 0;
    var it = entries.iterator();
    while (it.next()) |entry| {
        const point = qtPoint(entry.value_ptr.*) orelse continue;
        const decoded = try decodeKey(draft.arena, entry.key_ptr.*);
        if (isNonEveWindow(decoded)) {
            skipped_count += 1;
            continue;
        }
        const name = values.characterName(decoded) orelse continue;
        try eve_x.putPosition(draft, try draft.character(name), @floatFromInt(point.x), @floatFromInt(point.y));
    }
    if (skipped_count > 0) try draft.noteCount(SKIPPED_NON_EVE_NOTE, "n", skipped_count);
}

fn colorsAndHotkeys(draft: *Draft, ini: *const Ini) !void {
    var skipped_count: usize = 0;
    if (ini.section("characterBorderColors")) |entries| {
        var it = entries.iterator();
        while (it.next()) |entry| {
            const color = values.rgbColor(entry.value_ptr.*) orelse continue;
            const decoded = try decodeKey(draft.arena, entry.key_ptr.*);
            if (isNonEveWindow(decoded)) {
                skipped_count += 1;
                continue;
            }
            const name = values.characterName(decoded) orelse continue;
            try draft.put(try draft.character(name), "borderColors.activeBorderColor", try values.colorValue(draft.arena, color));
        }
    }

    var has_converted = false;
    if (ini.section("characterHotkeys")) |entries| {
        var it = entries.iterator();
        while (it.next()) |entry| {
            const decoded = try decodeKey(draft.arena, entry.key_ptr.*);
            if (isNonEveWindow(decoded)) {
                skipped_count += 1;
                continue;
            }
            const name = values.characterName(decoded) orelse continue;
            const combined = tupleHotkey(entry.value_ptr.*) orelse {
                if (isBound(entry.value_ptr.*)) try draft.note("Skipped hotkey for \"{name}\": it can't be represented as a keyboard hotkey (mouse button or unsupported).", &.{.{ .name = "name", .value = name }});
                continue;
            };
            try draft.put(try draft.character(name), "hotkey", try values.keyValue(draft.arena, combined));
            has_converted = true;
        }
    }
    if (has_converted) try draft.note("Character hotkeys were decoded from EVE-APM Preview's internal hotkey format - please confirm they're correct.", &.{});

    if (skipped_count > 0) try draft.noteCount(SKIPPED_NON_EVE_NOTE, "n", skipped_count);
}

fn hotkeyGroups(draft: *Draft, ini: *const Ini) !void {
    const entries = ini.section("cycleGroups") orelse return;
    var it = entries.iterator();
    while (it.next()) |entry| {
        const group = try parseGroup(draft.arena, entry.value_ptr.*);
        if (group.members.len == 0 and !isBound(group.forward) and !isBound(group.backward)) continue;
        const name = try decodeKey(draft.arena, entry.key_ptr.*);
        const forward = tupleHotkey(group.forward);
        const backward = tupleHotkey(group.backward);

        var members: std.json.Array = .init(draft.arena);
        for (group.members) |member| try members.append(.{ .string = member });
        const fields = try draft.item("hotkeyGroups", "name", name);
        try draft.put(fields, "characters", .{ .array = members });
        try draft.put(fields, "forwardKey", if (forward) |k| try values.keyValue(draft.arena, k) else .null);
        try draft.put(fields, "backwardKey", if (backward) |k| try values.keyValue(draft.arena, k) else .null);

        if (forward != null or backward != null) try draft.note("Hotkey group \"{name}\": forward/backward key(s) were decoded from EVE-APM Preview's internal hotkey format - please confirm they're correct.", &.{.{ .name = "name", .value = name }});
        if (forward == null and isBound(group.forward)) try draft.note("Hotkey group \"{name}\": forward key can't be represented as a keyboard hotkey (mouse button or unsupported) and was skipped.", &.{.{ .name = "name", .value = name }});
        if (backward == null and isBound(group.backward)) try draft.note("Hotkey group \"{name}\": backward key can't be represented as a keyboard hotkey (mouse button or unsupported) and was skipped.", &.{.{ .name = "name", .value = name }});
    }
}

/// EVE-APM can bind several keys to one action.
fn actionHotkey(draft: *Draft, ini: *const Ini, section_name: []const u8, key: []const u8, path: []const u8, label: []const u8) !void {
    const raw = unquote(ini.get(section_name, key)) orelse return;
    var keys: KeyList = .empty;
    var has_unsupported = false;
    var tuples = std.mem.splitScalar(u8, raw, '|');
    while (tuples.next()) |tuple| {
        if (!isBound(tuple)) continue;
        if (tupleHotkey(tuple)) |combined| {
            _ = keys.append(combined);
        } else {
            has_unsupported = true;
        }
    }
    try draft.setKeys(path, keys);
    if (has_unsupported) try draft.note("{label} hotkey can't be represented as a keyboard hotkey (mouse button or unsupported) and was skipped.", &.{.{ .name = "label", .value = label, .should_translate = true }});
}

fn globalHotkeys(draft: *Draft, ini: *const Ini) !void {
    try actionHotkey(draft, ini, "closeAllHotkeys", "closeAllClients", "hotkeys.hotkeyCloseAll", "Close All Clients");
    try actionHotkey(draft, ini, "minimizeAllHotkeys", "minimizeAllClients", "hotkeys.hotkeyMinimizeAll", "Minimize All Clients");
    try actionHotkey(draft, ini, "toggleThumbnailsVisibilityHotkeys", "toggleThumbnailsVisibility", "hotkeys.hotkeyToggleVisibility", "Toggle Thumbnail Visibility");
    try actionHotkey(draft, ini, "hotkeys", "suspendHotkey", "hotkeys.hotkeySuspend", "Toggle Suspend Hotkeys");
    try draft.setBool("hotkeys.requireEveFocus", qtBool(ini.get("hotkey", "onlyWhenEVEFocused")));
    try draft.setBool("hotkeys.resetGroupIndexOnNonGroupFocus", qtBool(ini.get("hotkey", "resetGroupIndexOnNonGroupFocus")));
}

fn characterList(draft: *Draft, raw: ?[]const u8, field: []const u8) !void {
    if (isInvalid(raw)) return;
    var names = std.mem.splitScalar(u8, unquote(raw).?, ',');
    while (names.next()) |raw_name| {
        const name = values.characterName(raw_name) orelse continue;
        try draft.put(try draft.character(name), field, .{ .bool = true });
    }
}

fn autoMinimize(draft: *Draft, ini: *const Ini) !void {
    try draft.setBool("autoMinimize.enabled", qtBool(ini.get("window", "minimizeInactiveClients")));
    try draft.setNumber("autoMinimize.delayMs", intValue(ini.get("window", "minimizeDelay")));
    try characterList(draft, ini.get("window", "neverMinimizeCharacters"), "excludeFromMinimize");
    try characterList(draft, ini.get("window", "neverCloseCharacters"), "excludeFromCloseAll");
}

fn snapping(draft: *Draft, ini: *const Ini) !void {
    try draft.setBool("snapping.enabled", qtBool(ini.get("position", "enableSnapping")));
    try draft.setNumber("snapping.threshold", intValue(ini.get("position", "snapDistance")));
    if (qtBool(ini.get("position", "lockPositions"))) |is_locked| try draft.setBool("interaction.enableDragging", !is_locked);
}

fn chatlog(draft: *Draft, ini: *const Ini) !void {
    const is_chatlog_enabled = qtBool(ini.get("chatlog", "enableMonitoring"));
    const is_gamelog_enabled = qtBool(ini.get("gamelog", "enableMonitoring"));
    if (is_chatlog_enabled != null or is_gamelog_enabled != null) try draft.setBool("chatlog.enabled", (is_chatlog_enabled orelse false) or (is_gamelog_enabled orelse false));
    if (unquote(ini.get("chatlog", "directory"))) |directory| {
        if (directory.len > 0) try draft.setString("chatlog.chatlogDir", directory);
    }
    if (unquote(ini.get("gamelog", "directory"))) |directory| {
        if (directory.len > 0) try draft.setString("chatlog.gamelogDir", directory);
    }
}

fn notifications(draft: *Draft, ini: *const Ini) !void {
    try draft.setBool("thumbnail.notifications.enabled", qtBool(ini.get("combatMessages", "enabled")));
    const default_duration = intValue(ini.get("combatMessages", "duration"));
    const color = values.rgbColor(ini.get("combatMessages", "color"));
    const suppresses_all = qtBool(ini.get("combatMessages", "suppressWhenFocused"));

    var events = std.mem.splitScalar(u8, ini.get("combatMessages", "enabledEventTypes") orelse "", ',');
    while (events.next()) |raw| {
        const event = std.mem.trim(u8, raw, " \t");
        if (event.len == 0) continue;
        const target = eventType(event) orelse {
            try draft.note("Event type \"{evt}\" has no equivalent notification in EVE-Maj Preview and was not imported.", &.{.{ .name = "evt", .value = event }});
            continue;
        };
        const base = try draft.arena.print("thumbnail.notifications.type_configs.{s}.", .{target});
        try draft.setBool(try concat(draft, base, "enabled"), true);
        const duration_key = try draft.arena.print("eventDurations\\{s}", .{event});
        try draft.setNumber(try concat(draft, base, "duration_ms"), intValue(ini.get("combatMessages", duration_key)) orelse default_duration);
        try draft.setColor(try concat(draft, base, "border_color"), color);
        const suppress_key = try draft.arena.print("suppressFocused\\{s}", .{event});
        try draft.setBool(try concat(draft, base, "suppress_when_focused"), qtBool(ini.get("combatMessages", suppress_key)) orelse suppresses_all);
    }
}

fn concat(draft: *Draft, prefix: []const u8, suffix: []const u8) ![]const u8 {
    return std.mem.concat(draft.arena, u8, &.{ prefix, suffix });
}
