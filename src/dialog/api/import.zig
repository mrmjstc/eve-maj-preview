//! Importing another preview tool's settings file, or another EVE-Maj profile, into the profile the window edits (see config/import/).
const std = @import("std");
const importer = @import("../../config/import/importer.zig");
const session = @import("../session.zig");
const rpc = @import("../rpc.zig");

/// The file's format, the sections it has for the user to choose from, and a profile name to suggest; `sourceProfile` picks one of an EVE-X file's profiles.
pub fn analyzeImport(arena: std.mem.Allocator, args: struct { text: []const u8, fileName: []const u8, sourceProfile: ?[]const u8 = null }) !rpc.RawJson {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try importer.analyze(&jw, arena, args.text, args.fileName, args.sourceProfile);
    return .{ .text = out.written() };
}

/// Applies the chosen sections as unsaved edits and returns notes on what was and wasn't brought in.
pub fn applyImport(arena: std.mem.Allocator, args: struct {
    text: []const u8,
    sourceProfile: ?[]const u8 = null,
    sections: []const []const u8,
    cycleGroupName: []const u8,
}) !struct { notes: []const importer.Text } {
    const built = try importer.build(arena, args.text, args.sourceProfile, args.sections, args.cycleGroupName, session.profile());
    try session.apply(null, arena, .profile, built.ops);
    return .{ .notes = built.notes };
}
