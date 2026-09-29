//! Imports settings from other preview tools and other EVE-Maj profiles: `analyze` lists a file's sections, `build` turns the chosen ones into edits.
const std = @import("std");
const values = @import("values.zig");
const draft = @import("draft.zig");
const eve_x = @import("eve_x.zig");
const eve_apm = @import("eve_apm.zig");
const eve_o = @import("eve_o.zig");
const own = @import("own.zig");
const patch = @import("../patch.zig");
const profiles = @import("../profiles.zig");
const config = @import("../../config.zig");

const Value = std.json.Value;
const Draft = draft.Draft;

pub const Text = draft.Text;

pub const Built = struct {
    ops: []const patch.Op,
    notes: []const Text,
};

const Source = union(enum) {
    maj: Value,
    evex: Value,
    eveo: Value,
    apm: eve_apm.Ini,
};

/// Null for a file none of the formats recognise.
fn detect(arena: std.mem.Allocator, raw_text: []const u8) !?Source {
    const text = textOf(raw_text);
    if (std.json.parseFromSliceLeaky(Value, arena, text, .{ .duplicate_field_behavior = .use_last })) |root| {
        if (root != .object) return null;
        if (own.isFile(root)) return .{ .maj = root };
        if (eve_x.isFile(root)) return .{ .evex = root };
        if (eve_o.isFile(root)) return .{ .eveo = root };
        return null;
    } else |_| {}
    const ini = try eve_apm.Ini.parse(arena, text);
    if (ini.sections.count() == 0) return null;
    return .{ .apm = ini };
}

/// EVE-X Preview writes a UTF-8 byte-order mark.
fn textOf(raw_text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, raw_text, "\xEF\xBB\xBF")) raw_text[3..] else raw_text;
}

/// EVE-X keeps several profiles; the one to import is `requested` if it has it.
fn evexProfile(root: Value, requested: ?[]const u8) ?[]const u8 {
    if (requested) |name| {
        if (values.objectAt(values.objectAt(root, "_Profiles"), name) != null) return name;
    }
    return eve_x.defaultProfile(root);
}

/// `{format, profiles, sourceProfile, defaultName, sections}`, with `format` null for a file that isn't recognised.
pub fn analyze(jw: *std.json.Stringify, arena: std.mem.Allocator, text: []const u8, file_name: []const u8, source_profile: ?[]const u8) !void {
    var d = Draft.init(arena);
    try jw.beginObject();
    const source = try detect(arena, text) orelse {
        try jw.objectField("format");
        try jw.write(null);
        return jw.endObject();
    };

    try jw.objectField("format");
    try jw.write(@tagName(source));

    const stem = std.fs.path.stem(file_name);
    var name_source = stem;
    const sections = switch (source) {
        .maj => |root| try own.sections(&d, root),
        .eveo => |root| try eve_o.sections(&d, root),
        .apm => |*ini| try eve_apm.sections(&d, ini),
        .evex => |root| blk: {
            const profile = evexProfile(root, source_profile) orelse "";
            try jw.objectField("profiles");
            try jw.write(try eve_x.profileNames(arena, root));
            try jw.objectField("sourceProfile");
            try jw.write(profile);
            name_source = profile;
            break :blk try eve_x.sections(&d, root, profile);
        },
    };

    const default_name = try values.profileName(arena, name_source, profiles.MAX_NAME_LEN);
    try jw.objectField("defaultName");
    try jw.write(if (default_name.len > 0) default_name else "Imported");
    try jw.objectField("sections");
    try jw.write(sections);
    try jw.endObject();
}

/// Edits bringing the `chosen` sections of the file into `doc`. `cycle_group_name` names EVE-O Preview's unnamed groups ("Cycle Group {n}").
pub fn build(arena: std.mem.Allocator, text: []const u8, source_profile: ?[]const u8, chosen: []const []const u8, cycle_group_name: []const u8, doc: *const config.Config) !Built {
    var d = Draft.init(arena);
    const source = try detect(arena, text) orelse return error.UnrecognizedSettingsFile;
    switch (source) {
        .maj => |root| try own.build(&d, textOf(text), root, chosen),
        .evex => |root| try eve_x.build(&d, root, evexProfile(root, source_profile) orelse return error.ProfileNotInFile, chosen),
        .eveo => |root| try eve_o.build(&d, root, chosen, cycle_group_name),
        .apm => |*ini| try eve_apm.build(&d, ini, chosen),
    }
    // Imported positions come from a different setup, so ghost outlines of them would only clutter drags.
    if (chosen.len > 0) try d.setBool("snapping.showGhostPositionBorders", false);
    return .{ .ops = try draft.toOps(arena, &d, doc), .notes = d.notes.items };
}
