//! Describes every saved setting to the config dialog, so its form takes kinds, defaults, bounds and options from the settings structs instead of repeating them.
const std = @import("std");
const vk = @import("../platform/virtual_keys.zig");
const wire = @import("wire.zig");
const patch = @import("patch.zig");
const key_list = @import("key_list.zig");
const profiles = @import("profiles.zig");
const config = @import("../config.zig");
const notification = @import("../notifications/notification.zig");

/// `{"fields": {path: spec}, "notificationTypes": [...], "keys": [{vk, name}], "modifiers": [{flag, name}], "maxKeys": n, "profileNameMaxLength": n}`.
/// A path is dotted field names, with `*` for a list item or map child and the global settings under `global.`.
/// A spec is `{kind, nullable?, default?, min?, max?, zeroMeansDefault?, options?, enumType?}`, where kind is one of
/// bool, int, float, string, enum, color, keys (leaves), or section, list, map (holding the paths under them).
pub fn write(jw: *std.json.Stringify) !void {
    @setEvalBranchQuota(1_000_000);
    try jw.beginObject();
    try jw.objectField("fields");
    try jw.beginObject();
    try writeFields(jw, config.Config, "");
    try writeFields(jw, config.GlobalConfig, "global.");
    try jw.endObject();
    try jw.objectField("notificationTypes");
    try writeNotificationTypes(jw);
    try jw.objectField("keys");
    try jw.write(vk.KEY_NAMES);
    try jw.objectField("modifiers");
    try jw.write(vk.MODIFIER_NAMES);
    try jw.objectField("maxKeys");
    try jw.write(key_list.MAX_KEYS);
    try jw.objectField("profileNameMaxLength");
    try jw.write(profiles.MAX_NAME_LEN);
    try jw.endObject();
}

fn writeFields(jw: *std.json.Stringify, comptime R: type, comptime prefix: []const u8) !void {
    @setEvalBranchQuota(100_000);
    inline for (comptime wire.savedFields(R)) |f| try writeField(jw, R, f, prefix ++ f.name);
}

fn writeField(jw: *std.json.Stringify, comptime R: type, comptime f: wire.SavedField, comptime path: []const u8) !void {
    const F = f.type;
    if (comptime wire.ListItem(F)) |Item| {
        try jw.objectField(path);
        try jw.beginObject();
        try writeKind(jw, "list");
        try jw.objectField("default");
        if (comptime wire.hasWireDefault(R, f.name)) {
            try jw.write(@field(R.wire_defaults, f.name));
        } else {
            try jw.beginArray();
            try jw.endArray();
        }
        try jw.endObject();
        if (comptime @typeInfo(Item) == .@"struct") try writeFields(jw, Item, path ++ ".*.");
        return;
    }
    if (comptime F == key_list.KeyList) return writeLeaf(jw, R, f, path);
    if (comptime @typeInfo(F) == .@"struct") {
        if (comptime patch.isKeyedMap(F)) {
            try jw.objectField(path);
            try jw.write(.{ .kind = "map" });
            return writeFields(jw, patch.ChildOf(F), path ++ ".*.");
        }
        return writeFields(jw, F, path ++ ".");
    }
    if (comptime @typeInfo(F) == .optional and @typeInfo(@typeInfo(F).optional.child) == .@"struct") {
        try jw.objectField(path);
        try jw.write(.{ .kind = "section", .nullable = true });
        return writeFields(jw, @typeInfo(F).optional.child, path ++ ".");
    }
    try writeLeaf(jw, R, f, path);
}

fn writeLeaf(jw: *std.json.Stringify, comptime R: type, comptime f: wire.SavedField, comptime path: []const u8) !void {
    const nullable = @typeInfo(f.type) == .optional;
    const Plain = if (nullable) @typeInfo(f.type).optional.child else f.type;

    try jw.objectField(path);
    try jw.beginObject();
    try writeKind(jw, comptime kindOf(Plain, f.name));
    if (nullable) {
        try jw.objectField("nullable");
        try jw.write(true);
    }
    if (f.defaultValue()) |default| {
        try jw.objectField("default");
        try jw.write(wire.fieldToWire(f.type, f.name, default));
    }
    if (comptime hasRange(R, f.name)) {
        const bounds = @field(R.ranges, f.name);
        try jw.objectField("min");
        try jw.write(bounds[0]);
        try jw.objectField("max");
        try jw.write(bounds[1]);
    }
    if (comptime isZeroMeansDefault(R, f.name)) {
        try jw.objectField("zeroMeansDefault");
        try jw.write(true);
    }
    if (comptime @typeInfo(Plain) == .@"enum") {
        try jw.objectField("options");
        try jw.write(@typeInfo(Plain).@"enum".field_names);
        try jw.objectField("enumType");
        try jw.write(comptime shortTypeName(Plain));
    }
    try jw.endObject();
}

fn writeKind(jw: *std.json.Stringify, kind: []const u8) !void {
    try jw.objectField("kind");
    try jw.write(kind);
}

fn kindOf(comptime T: type, comptime name: []const u8) []const u8 {
    if (T == bool) return "bool";
    if (T == []const u8) return "string";
    if (T == u32 and wire.isColorField(name)) return "color";
    if (T == key_list.KeyList) return "keys";
    return switch (@typeInfo(T)) {
        .int => "int",
        .float => "float",
        .@"enum" => "enum",
        else => @compileError("no schema kind for " ++ name ++ ": " ++ @typeName(T)),
    };
}

fn hasRange(comptime R: type, comptime name: []const u8) bool {
    if (!@hasDecl(R, "ranges")) return false;
    return @hasField(@TypeOf(R.ranges), name);
}

fn isZeroMeansDefault(comptime R: type, comptime name: []const u8) bool {
    if (!@hasDecl(R, "zero_means_default")) return false;
    inline for (R.zero_means_default) |zero_name| {
        if (std.mem.eql(u8, zero_name, name)) return true;
    }
    return false;
}

fn shortTypeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const dot = std.mem.findScalarLast(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// In category order, with `placeholders: [{name, sample}]` and a `texts` entry `{field, state, defaultText}` per custom text box.
fn writeNotificationTypes(jw: *std.json.Stringify) !void {
    try jw.beginArray();
    for (std.enums.values(notification.NotificationCategory)) |category| {
        for (std.enums.values(notification.NotificationType)) |ntype| {
            if (notification.notificationCategory(ntype) != category) continue;
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(@tagName(ntype));
            try jw.objectField("category");
            try jw.write(@tagName(category));
            try jw.objectField("userAction");
            try jw.write(notification.isUserAction(ntype));
            try jw.objectField("defaults");
            try jw.write(wire.encode(config.NotificationTypeConfig, config.NotificationTypeConfig.defaultFor(ntype)));
            try jw.objectField("placeholders");
            try writePlaceholders(jw, ntype);
            try jw.objectField("texts");
            try writeTexts(jw, ntype);
            try jw.endObject();
        }
    }
    try jw.endArray();
}

fn writePlaceholders(jw: *std.json.Stringify, ntype: notification.NotificationType) !void {
    const example = notification.sample(ntype);
    try jw.beginArray();
    for (notification.placeholders(ntype)) |placeholder| {
        const value: ?[]const u8 = switch (placeholder.field) {
            .source => example.source,
            .target => example.target,
            .character => notification.SAMPLE_CHARACTER,
        };
        try jw.write(.{ .name = placeholder.name, .sample = value });
    }
    try jw.endArray();
}

fn writeTexts(jw: *std.json.Stringify, ntype: notification.NotificationType) !void {
    var buf: [128]u8 = undefined;
    const primary = notification.sample(ntype);
    try jw.beginArray();
    try jw.write(.{
        .field = "custom_text",
        .state = if (primary.state) |state| @tagName(state) else null,
        .defaultText = notification.defaultText(primary, &buf),
    });
    if (notification.altState(ntype)) |alt_state| {
        var alt = primary;
        alt.state = alt_state;
        try jw.write(.{ .field = "custom_text_alt", .state = @tagName(alt_state), .defaultText = notification.defaultText(alt, &buf) });
    }
    try jw.endArray();
}
