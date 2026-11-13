//! The unique colours generated for systems and characters, kept in their own file.
const std = @import("std");
const color_mod = @import("../util/color.zig");
const wire = @import("wire.zig");
const files = @import("files.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");

const slog = log.Scoped("config");

const AUTO_COLORS_FILE = files.AUTO_COLORS_FILE;

/// Runtime state, not a setting: saved to AUTO_COLORS_FILE so a profile save mid-preview can't leak unsaved edits.
pub const AutoColorStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    system: color_mod.AutoColors = .{},
    character: color_mod.AutoColors = .{},
    is_loaded: bool = false,
    /// The file couldn't be read or parsed, so saving would replace every colour in it with this run's few.
    is_file_unreadable: bool = false,

    const File = struct {
        systemColors: []const Entry = &.{},
        characterColors: []const Entry = &.{},
    };

    const Entry = struct {
        name: []const u8,
        color: wire.Argb,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) AutoColorStore {
        return .{ .allocator = allocator, .io = io };
    }

    /// Flushes first, so pending colours aren't lost.
    pub fn deinit(self: *AutoColorStore) void {
        self.flush();
        self.system.deinit(self.allocator);
        self.character.deinit(self.allocator);
    }

    /// A custom override first, then the unique generated colour if enabled, then the configured default.
    pub fn systemNameColor(self: *AutoColorStore, config: *const config_mod.Config, system_name: []const u8) u32 {
        if (config.findSystemColor(system_name)) |custom_color| return custom_color;
        const shown = config.shownColors();
        if (!shown.uses_unique_system_colors) return shown.system_name_color;

        self.load();

        var overrides: [color_mod.AutoColors.MAX_AVOIDED]u32 = undefined;
        const override_count = @min(config.systemColors.items.len, overrides.len);
        for (config.systemColors.items[0..override_count], 0..) |system_color, i| overrides[i] = system_color.color;

        return self.system.colorFor(self.allocator, system_name, overrides[0..override_count]);
    }

    /// As systemNameColor, but a system with no unique colour yet gets the configured default rather than a new one.
    pub fn knownSystemNameColor(self: *AutoColorStore, config: *const config_mod.Config, system_name: []const u8) u32 {
        if (config.findSystemColor(system_name)) |custom_color| return custom_color;
        const shown = config.shownColors();
        if (!shown.uses_unique_system_colors) return shown.system_name_color;

        self.load();
        return self.system.existingColor(system_name) orelse shown.system_name_color;
    }

    /// The character's own override, then the unique colour if enabled; null means the caller's own default.
    pub fn characterNameColor(self: *AutoColorStore, config: *const config_mod.Config, character_name: []const u8) ?u32 {
        return self.nameColor(config, character_name, config.shownColors().uses_unique_name_colors);
    }

    /// characterNameColor for the client list, whose unique name colours are its own setting in every view mode.
    pub fn listNameColor(self: *AutoColorStore, config: *const config_mod.Config, character_name: []const u8) ?u32 {
        return self.nameColor(config, character_name, config.listView.useUniqueCharacterNameColors);
    }

    /// The character's own active border colour, else the unique colour if enabled; the inactive one is left as set.
    pub fn characterBorderColors(self: *AutoColorStore, config: *const config_mod.Config, character_name: []const u8) ?config_mod.CharacterBorderColorsConfig {
        const configured = if (config.findCharacterConst(character_name)) |character| character.borderColors else null;
        if (!config.shownColors().uses_unique_border_colors) return configured;

        var colors = configured orelse config_mod.CharacterBorderColorsConfig{};
        if (colors.activeBorderColor == null) colors.activeBorderColor = self.characterColor(config, character_name);
        return colors;
    }

    fn nameColor(self: *AutoColorStore, config: *const config_mod.Config, character_name: []const u8, uses_unique: bool) ?u32 {
        if (config.findCharacterConst(character_name)) |character| {
            if (character.nameColor) |custom_color| return custom_color;
        }
        if (!uses_unique) return null;

        return self.characterColor(config, character_name);
    }

    /// Shared by the character's name and border; avoids every character's own name and active border colours.
    fn characterColor(self: *AutoColorStore, config: *const config_mod.Config, character_name: []const u8) u32 {
        self.load();

        var overrides: [color_mod.AutoColors.MAX_AVOIDED]u32 = undefined;
        var override_count: usize = 0;
        collect: for (config.characters.items) |character| {
            const border_color = if (character.borderColors) |border| border.activeBorderColor else null;
            for ([_]?u32{ character.nameColor, border_color }) |maybe_color| {
                const custom_color = maybe_color orelse continue;
                if (override_count == overrides.len) break :collect;
                overrides[override_count] = custom_color;
                override_count += 1;
            }
        }

        return self.character.colorFor(self.allocator, character_name, overrides[0..override_count]);
    }

    fn load(self: *AutoColorStore) void {
        if (self.is_loaded) return;
        self.is_loaded = true;

        const content = std.Io.Dir.cwd().readFileAlloc(self.io, AUTO_COLORS_FILE, self.allocator, .limited(files.MAX_CONFIG_FILE_SIZE)) catch |err| {
            if (err == error.FileNotFound) return;
            slog.warn("Failed to read '{s}', so it isn't saved over: {}", .{ AUTO_COLORS_FILE, err });
            self.is_file_unreadable = true;
            return;
        };
        defer self.allocator.free(content);

        const parsed = wire.parse(File, self.allocator, content) catch |err| {
            slog.warn("Failed to parse '{s}', so it isn't saved over: {}", .{ AUTO_COLORS_FILE, err });
            self.is_file_unreadable = true;
            return;
        };
        defer parsed.deinit();

        self.loadEntries(&self.system, parsed.value.systemColors);
        self.loadEntries(&self.character, parsed.value.characterColors);
    }

    fn loadEntries(self: *AutoColorStore, store: *color_mod.AutoColors, entries: []const Entry) void {
        for (entries) |entry| {
            store.put(self.allocator, entry.name, entry.color.value) catch |err| {
                slog.warn("Failed to load auto color '{s}': {}", .{ entry.name, err });
                return;
            };
        }
    }

    /// Deferred to when the last thumbnail closes, and deinit, so a session with EVE open never writes.
    pub fn flush(self: *AutoColorStore) void {
        if (!self.system.is_dirty and !self.character.is_dirty) return;
        self.system.is_dirty = false;
        self.character.is_dirty = false;
        self.save();
    }

    fn save(self: *const AutoColorStore) void {
        if (self.is_file_unreadable) {
            slog.info("Left '{s}' as it was: it couldn't be read, so this run's colours aren't saved", .{AUTO_COLORS_FILE});
            return;
        }
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

        files.atomicWriteFile(self.allocator, self.io, AUTO_COLORS_FILE, json) catch return;
    }

    fn entriesToWire(allocator: std.mem.Allocator, store: *const color_mod.AutoColors) ![]const Entry {
        const saved = try allocator.alloc(Entry, store.entries.items.len);
        for (store.entries.items, saved) |entry, *saved_entry| {
            saved_entry.* = .{ .name = entry.name, .color = .{ .value = entry.color } };
        }
        return saved;
    }
};
