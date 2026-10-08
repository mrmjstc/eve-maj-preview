//! The unique colours generated for systems and characters, kept in their own file.
const std = @import("std");
const color = @import("../util/color.zig");
const wire = @import("wire.zig");
const files = @import("files.zig");
const config = @import("../config.zig");
const log = @import("../log.zig");

const slog = log.scoped("config");

const AUTO_COLORS_FILE = files.AUTO_COLORS_FILE;

/// Runtime state owned by Painter, not a setting; saved to AUTO_COLORS_FILE rather than the profile so saving the profile mid live-preview can't leak unsaved edits.
pub const AutoColorStore = struct {
    allocator: std.mem.Allocator,
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

    pub fn init(allocator: std.mem.Allocator) AutoColorStore {
        return .{ .allocator = allocator };
    }

    /// Flushes first, so pending colours aren't lost.
    pub fn deinit(self: *AutoColorStore) void {
        self.flush();
        self.system.deinit(self.allocator);
        self.character.deinit(self.allocator);
    }

    /// A custom override first, then the unique generated colour if enabled, then the configured default.
    pub fn systemNameColor(self: *AutoColorStore, cfg: *const config.Config, system_name: []const u8) u32 {
        if (cfg.findSystemColor(system_name)) |custom_color| return custom_color;
        const shown = cfg.shownColors();
        if (!shown.uses_unique_system_colors) return shown.system_name_color;

        self.load();

        var overrides: [color.AutoColors.MAX_AVOIDED]u32 = undefined;
        const override_count = @min(cfg.systemColors.items.len, overrides.len);
        for (cfg.systemColors.items[0..override_count], 0..) |sc, i| overrides[i] = sc.color;

        return self.system.colorFor(self.allocator, system_name, overrides[0..override_count]);
    }

    /// The character's own override, then the unique colour if enabled; null means the caller's own default.
    pub fn characterNameColor(self: *AutoColorStore, cfg: *const config.Config, character_name: []const u8) ?u32 {
        if (cfg.findCharacterConst(character_name)) |char| {
            if (char.nameColor) |custom_color| return custom_color;
        }
        if (!cfg.shownColors().uses_unique_name_colors) return null;

        return self.characterColor(cfg, character_name);
    }

    /// The character's own active border colour, else the unique colour if enabled; the inactive one is left as set.
    pub fn characterBorderColors(self: *AutoColorStore, cfg: *const config.Config, character_name: []const u8) ?config.CharacterBorderColorsConfig {
        const configured = if (cfg.findCharacterConst(character_name)) |char| char.borderColors else null;
        if (!cfg.shownColors().uses_unique_border_colors) return configured;

        var colors = configured orelse config.CharacterBorderColorsConfig{};
        if (colors.activeBorderColor == null) colors.activeBorderColor = self.characterColor(cfg, character_name);
        return colors;
    }

    /// One stored colour per character, shared by its name and border; steers clear of every character's own name and active border overrides.
    fn characterColor(self: *AutoColorStore, cfg: *const config.Config, character_name: []const u8) u32 {
        self.load();

        var overrides: [color.AutoColors.MAX_AVOIDED]u32 = undefined;
        var override_count: usize = 0;
        collect: for (cfg.characters.items) |char| {
            const border_color = if (char.borderColors) |border| border.activeBorderColor else null;
            for ([_]?u32{ char.nameColor, border_color }) |maybe_color| {
                const custom_color = maybe_color orelse continue;
                if (override_count == overrides.len) break :collect;
                overrides[override_count] = custom_color;
                override_count += 1;
            }
        }

        return self.character.colorFor(self.allocator, character_name, overrides[0..override_count]);
    }

    /// Reads the file on first use only; later calls do nothing.
    fn load(self: *AutoColorStore) void {
        if (self.loaded) return;
        self.loaded = true;

        const content = std.Io.Dir.cwd().readFileAlloc(files.g_io, AUTO_COLORS_FILE, self.allocator, .limited(files.MAX_CONFIG_FILE_SIZE)) catch |err| {
            if (err != error.FileNotFound) slog.warn("Failed to read '{s}': {}", .{ AUTO_COLORS_FILE, err });
            return;
        };
        defer self.allocator.free(content);

        const parsed = wire.parse(File, self.allocator, content) catch |err| {
            slog.warn("Failed to parse '{s}': {}", .{ AUTO_COLORS_FILE, err });
            return;
        };
        defer parsed.deinit();

        self.loadEntries(&self.system, parsed.value.systemColors);
        self.loadEntries(&self.character, parsed.value.characterColors);
    }

    fn loadEntries(self: *AutoColorStore, store: *color.AutoColors, entries: []const Entry) void {
        for (entries) |entry| {
            store.put(self.allocator, entry.name, entry.color.value) catch |err| {
                slog.warn("Failed to load auto color '{s}': {}", .{ entry.name, err });
                return;
            };
        }
    }

    /// Writes pending colours; deferred to when the last thumbnail closes (and to deinit) so a session with EVE open never touches the disk for it.
    pub fn flush(self: *AutoColorStore) void {
        if (!self.system.dirty and !self.character.dirty) return;
        self.system.dirty = false;
        self.character.dirty = false;
        self.save();
    }

    fn save(self: *const AutoColorStore) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
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

        const json = std.json.Stringify.valueAlloc(self.allocator, file, .{ .whitespace = .indent_2 }) catch |err| {
            slog.warn("Failed to serialize auto colors: {}", .{err});
            return;
        };
        defer self.allocator.free(json);

        files.atomicWriteFile(self.allocator, files.g_io, AUTO_COLORS_FILE, json) catch |err| {
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
};
