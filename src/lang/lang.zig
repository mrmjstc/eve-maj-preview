//! The app's words in the chosen language, falling back to English; main thread only.
const std = @import("std");
const types = @import("../config/types.zig");
const wording = @import("wording.zig");
const log = @import("../log.zig");

const Language = types.Language;
const slog = log.Scoped("lang");

const Catalog = std.json.Parsed(std.json.Value);

var g_allocator: std.mem.Allocator = undefined;
var g_language: Language = .en;
/// g_language's file, owned until the language changes or deinit; null for English, which is the text itself.
var g_translated: ?Catalog = null;

pub fn init(allocator: std.mem.Allocator, language: Language) void {
    g_allocator = allocator;
    use(language);
}

/// At shutdown.
pub fn deinit() void {
    if (g_translated) |*catalog| catalog.deinit();
    g_translated = null;
    g_language = .en;
}

/// Switches language; the settings window calls it before each frame, so it changes as soon as one is picked.
pub fn use(language: Language) void {
    if (language == g_language) return;
    if (g_translated) |*catalog| catalog.deinit();
    g_translated = if (language == .en) null else parse(language);
    g_language = language;
}

/// `english` in the chosen language, or unchanged when it has no translation (e.g. a character's name); borrows from the language file until it changes.
pub fn text(english: []const u8) []const u8 {
    return lookup(english) orelse english;
}

/// `english` translated, with its {placeholders} filled from `args` (see wording.fill), made in `arena`.
pub fn format(arena: std.mem.Allocator, english: []const u8, args: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    // An allocating writer only fails when it runs out of memory.
    wording.fill(&out.writer, text(english), args) catch return error.OutOfMemory;
    return out.written();
}

/// Like format, into `writer`.
pub fn write(writer: *std.Io.Writer, english: []const u8, args: anytype) std.Io.Writer.Error!void {
    try wording.fill(writer, text(english), args);
}

/// A string the translator left empty counts as missing, so it falls back.
fn lookup(english: []const u8) ?[]const u8 {
    const strings = g_translated orelse return null;
    if (strings.value != .object) return null;
    const value = strings.value.object.get(english) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn parse(language: Language) ?Catalog {
    return std.json.parseFromSlice(std.json.Value, g_allocator, wording.file(language), .{}) catch |err| {
        slog.warn("Failed to read the '{s}' language file, showing English: {}", .{ @tagName(language), err });
        return null;
    };
}
