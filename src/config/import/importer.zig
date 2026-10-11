//! Imports settings from other preview tools and other EVE-Maj profiles: `analyze` lists a file's sections, `build` turns the chosen ones into edits.
const std = @import("std");
const values = @import("values.zig");
const draft_mod = @import("draft.zig");
const eve_x = @import("eve_x.zig");
const eve_apm = @import("eve_apm.zig");
const eve_o = @import("eve_o.zig");
const own = @import("own.zig");
const patch = @import("../patch.zig");
const profiles = @import("../profiles.zig");
const config = @import("../../config.zig");

const Value = std.json.Value;
const Draft = draft_mod.Draft;

pub const Text = draft_mod.Text;

/// The byte-order mark EVE-X Preview writes.
const UTF8_BOM = "\xEF\xBB\xBF";

pub const Built = struct {
    ops: []const patch.Op,
    notes: []const Text,
    /// See Draft.skipped.
    skipped: []const []const u8,
};

const Source = union(enum) {
    maj: Value,
    evex: Value,
    eveo: Value,
    apm: eve_apm.Ini,
};

/// `{format, profiles, sourceProfile, defaultName, sections}`, with `format` null for a file that isn't recognised.
pub fn analyze(json_writer: *std.json.Stringify, arena: std.mem.Allocator, text: []const u8, file_name: []const u8, source_profile: ?[]const u8) !void {
    var draft: Draft = .init(arena);
    try json_writer.beginObject();
    const source = try detect(arena, text) orelse {
        try json_writer.objectField("format");
        try json_writer.write(null);
        return json_writer.endObject();
    };

    try json_writer.objectField("format");
    try json_writer.write(@tagName(source));

    const stem = std.Io.Dir.path.stem(file_name);
    var name_source = stem;
    const sections = switch (source) {
        .maj => |root| try own.sections(&draft, root),
        .eveo => |root| try eve_o.sections(&draft, root),
        .apm => |*ini| try eve_apm.sections(&draft, ini),
        .evex => |root| blk: {
            const profile = evexProfile(root, source_profile) orelse "";
            try json_writer.objectField("profiles");
            try json_writer.write(try eve_x.profileNames(arena, root));
            try json_writer.objectField("sourceProfile");
            try json_writer.write(profile);
            name_source = profile;
            break :blk try eve_x.sections(&draft, root, profile);
        },
    };

    const default_name = try values.profileName(arena, name_source, profiles.MAX_NAME_LENGTH);
    try json_writer.objectField("defaultName");
    try json_writer.write(if (default_name.len > 0) default_name else "Imported");
    try json_writer.objectField("sections");
    try json_writer.write(sections);
    try json_writer.endObject();
}

/// Edits bringing the `chosen` sections of the file into `doc`. `cycle_group_name` names EVE-O Preview's unnamed groups ("Cycle Group {n}").
pub fn build(arena: std.mem.Allocator, text: []const u8, source_profile: ?[]const u8, chosen: []const []const u8, cycle_group_name: []const u8, doc: *const config.Config) !Built {
    var draft: Draft = .init(arena);
    const source = try detect(arena, text) orelse return error.InvalidSettingsFile;
    switch (source) {
        .maj => |root| try own.build(&draft, textOf(text), root, chosen),
        .evex => |root| try eve_x.build(&draft, root, evexProfile(root, source_profile) orelse return error.MissingProfile, chosen),
        .eveo => |root| try eve_o.build(&draft, root, chosen, cycle_group_name),
        .apm => |*ini| try eve_apm.build(&draft, ini, chosen),
    }
    // Imported positions come from a different setup, so ghost outlines of them would only clutter drags.
    if (chosen.len > 0) try draft.setBool("snapping.showGhostPositionBorders", false);
    return .{ .ops = try draft_mod.toOps(arena, &draft, doc), .notes = draft.notes.items, .skipped = draft.skipped.items };
}

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

fn textOf(raw_text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, raw_text, UTF8_BOM)) raw_text[UTF8_BOM.len..] else raw_text;
}

/// EVE-X keeps several profiles; the one to import is `requested` if it has it.
fn evexProfile(root: Value, requested: ?[]const u8) ?[]const u8 {
    if (requested) |name| {
        if (values.objectAt(values.objectAt(root, "_Profiles"), name) != null) return name;
    }
    return eve_x.defaultProfile(root);
}
