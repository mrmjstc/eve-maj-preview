//! The unique colours generated for systems and characters, kept in their own file.
const std = @import("std");
const log = @import("../log.zig");
const color = @import("../util/color.zig");
const wire = @import("wire.zig");
const files = @import("files.zig");

const slog = log.scoped("config");

const AUTO_COLORS_FILE = "colors.json";

/// Saved to AUTO_COLORS_FILE rather than the profile, so saving the profile mid live-preview can't leak unsaved edits.
pub const AutoColorStore = struct {
    system: color.AutoColors = .{},
    character: color.AutoColors = .{},
    loaded: bool = false,

    const File = struct {
        systemColors: []const Entry = &.{},
        characterColors: []const Entry = &.{},
    };

    const Entry = struct {
        name: []const u8,
        color: wire.Argb,
    };

    /// Reads the file on first use only; later calls do nothing.
    pub fn load(self: *AutoColorStore, allocator: std.mem.Allocator) void {
        if (self.loaded) return;
        self.loaded = true;

        const content = std.Io.Dir.cwd().readFileAlloc(files.g_io, AUTO_COLORS_FILE, allocator, .limited(files.MAX_CONFIG_FILE_SIZE)) catch |err| {
            if (err != error.FileNotFound) slog.warn("Failed to read '{s}': {}", .{ AUTO_COLORS_FILE, err });
            return;
        };
        defer allocator.free(content);

        const parsed = wire.parse(File, allocator, content) catch |err| {
            slog.warn("Failed to parse '{s}': {}", .{ AUTO_COLORS_FILE, err });
            return;
        };
        defer parsed.deinit();

        loadEntries(allocator, &self.system, parsed.value.systemColors);
        loadEntries(allocator, &self.character, parsed.value.characterColors);
    }

    fn loadEntries(allocator: std.mem.Allocator, store: *color.AutoColors, entries: []const Entry) void {
        for (entries) |entry| {
            store.put(allocator, entry.name, entry.color.value) catch |err| {
                slog.warn("Failed to load auto color '{s}': {}", .{ entry.name, err });
                return;
            };
        }
    }

    /// Writes pending colours; deferred to when the last thumbnail closes (and to deinit) so a session with EVE open never touches the disk for it.
    pub fn flush(self: *AutoColorStore, allocator: std.mem.Allocator) void {
        if (!self.system.dirty and !self.character.dirty) return;
        self.system.dirty = false;
        self.character.dirty = false;
        self.save(allocator);
    }

    fn save(self: *const AutoColorStore, allocator: std.mem.Allocator) void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const file = File{
            .systemColors = entriesToWire(arena.allocator(), &self.system) catch |err| {
                slog.warn("Failed to save system colors: {}", .{err});
                return;
            },
            .characterColors = entriesToWire(arena.allocator(), &self.character) catch |err| {
                slog.warn("Failed to save character colors: {}", .{err});
                return;
            },
        };

        const json = std.json.Stringify.valueAlloc(allocator, file, .{ .whitespace = .indent_2 }) catch |err| {
            slog.warn("Failed to serialize auto colors: {}", .{err});
            return;
        };
        defer allocator.free(json);

        files.atomicWriteFile(allocator, files.g_io, AUTO_COLORS_FILE, json) catch |err| {
            slog.warn("Failed to save '{s}': {}", .{ AUTO_COLORS_FILE, err });
        };
    }

    fn entriesToWire(allocator: std.mem.Allocator, store: *const color.AutoColors) ![]const Entry {
        const wires = try allocator.alloc(Entry, store.entries.items.len);
        for (store.entries.items, wires) |entry, *w| {
            w.* = .{ .name = entry.name, .color = .{ .value = entry.color } };
        }
        return wires;
    }

    /// Flushes first, so pending colours aren't lost.
    pub fn deinit(self: *AutoColorStore, allocator: std.mem.Allocator) void {
        self.flush(allocator);
        self.system.deinit(allocator);
        self.character.deinit(allocator);
    }
};
