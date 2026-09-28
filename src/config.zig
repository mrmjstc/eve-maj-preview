const std = @import("std");
const win32 = @import("platform/win32.zig");
const log = @import("log.zig");
const color = @import("util/color.zig");
const wire = @import("config/wire.zig");
const ranges_mod = @import("config/ranges.zig");
const files = @import("config/files.zig");
const global = @import("config/global.zig");
const characters = @import("config/characters.zig");
const system_colors = @import("config/system_colors.zig");
const hotkeys = @import("config/hotkeys.zig");
const chatlog = @import("config/chatlog.zig");
const activity = @import("config/activity.zig");
const notifications = @import("config/notifications.zig");
const window_filters = @import("config/window_filters.zig");
const thumbnail = @import("config/thumbnail.zig");
const display = @import("config/display.zig");
const behavior = @import("config/behavior.zig");
const auto_colors = @import("config/auto_colors.zig");

const slog = log.scoped("config");

pub const setIo = files.setIo;
pub const setEnvironMap = files.setEnvironMap;
pub const environMap = files.environMap;
pub const PROFILES_DIR = files.PROFILES_DIR;
pub const DEFAULT_PROFILE = files.DEFAULT_PROFILE;
pub const GLOBAL_SETTINGS_FILE = files.GLOBAL_SETTINGS_FILE;
pub const MAX_PROFILE_NAME_LEN: usize = 16;

/// Byte slicing is safe: the dialog only allows ASCII profile names.
pub fn clampProfileName(name: []const u8) []const u8 {
    return if (name.len > MAX_PROFILE_NAME_LEN) name[0..MAX_PROFILE_NAME_LEN] else name;
}

/// Independent of the release version; bump PROFILE_FORMAT_VERSION only for schema changes that need a migration.
pub const PROFILE_FORMAT_IDENTIFIER = "eve-maj-preview";
/// v2: character positions saved while this app was DPI-unaware are migrated to physical pixels on load - see Config.fromWire.
pub const PROFILE_FORMAT_VERSION: u32 = 2;

pub const clampValue = ranges_mod.clampValue;

pub const Argb = wire.Argb;

pub const OrePriceConfig = global.OrePriceConfig;
pub const DEFAULT_ORE_TABLE = global.DEFAULT_ORE_TABLE;
pub const GlobalConfig = global.GlobalConfig;
pub const Position = characters.Position;
pub const CharacterBorderColorsConfig = characters.CharacterBorderColorsConfig;
pub const CharacterThumbnailSizeConfig = characters.CharacterThumbnailSizeConfig;
pub const CharacterConfig = characters.CharacterConfig;
pub const buildCharacterOrderMap = characters.buildCharacterOrderMap;
pub const orderMapLessThan = characters.orderMapLessThan;
pub const SystemColorConfig = system_colors.SystemColorConfig;
pub const HotkeyGroupConfig = hotkeys.HotkeyGroupConfig;
pub const ChatlogConfig = chatlog.ChatlogConfig;
pub const CombatConfig = activity.CombatConfig;
pub const MiningConfig = activity.MiningConfig;
pub const BountyConfig = activity.BountyConfig;
pub const ResourcesConfig = activity.ResourcesConfig;
pub const TravelConfig = activity.TravelConfig;
pub const NotificationTypeConfig = notifications.NotificationTypeConfig;
pub const NotificationConfig = notifications.NotificationConfig;
pub const WindowFilterConfig = window_filters.WindowFilterConfig;
pub const StateVisualConfig = thumbnail.StateVisualConfig;
pub const ThumbnailConfig = thumbnail.ThumbnailConfig;
pub const DisplayConfig = display.DisplayConfig;
pub const TimerConfig = behavior.TimerConfig;
pub const SnappingConfig = behavior.SnappingConfig;
pub const InteractionConfig = behavior.InteractionConfig;
pub const AutoMinimizeConfig = behavior.AutoMinimizeConfig;
pub const AutoMovePositionConfig = behavior.AutoMovePositionConfig;
pub const ExclusionConfig = behavior.ExclusionConfig;
pub const CloseAllConfig = behavior.CloseAllConfig;
pub const HotkeysConfig = hotkeys.HotkeysConfig;

pub const Config = struct {
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    autoColors: auto_colors.AutoColorStore = .{},
    /// Reset to the current values after loading; formatVersion is only read to migrate older profiles.
    app: []const u8 = PROFILE_FORMAT_IDENTIFIER,
    formatVersion: u32 = PROFILE_FORMAT_VERSION,
    thumbnail: ThumbnailConfig = .{},
    timer: TimerConfig = .{},
    display: DisplayConfig = .{},
    snapping: SnappingConfig = .{},
    interaction: InteractionConfig = .{},
    autoMinimize: AutoMinimizeConfig = .{},
    autoMovePosition: AutoMovePositionConfig = .{},
    exclusion: ExclusionConfig = .{},
    closeAll: CloseAllConfig = .{},
    chatlog: ChatlogConfig = .{},
    combat: CombatConfig = .{},
    mining: MiningConfig = .{},
    bounty: BountyConfig = .{},
    resources: ResourcesConfig = .{},
    travel: TravelConfig = .{},
    accentColor: u32 = 0xFFD9A441,
    windowFilters: std.ArrayList(WindowFilterConfig) = .empty,
    characters: std.ArrayList(CharacterConfig) = .empty,
    systemColors: std.ArrayList(SystemColorConfig) = .empty,
    hotkeyGroups: std.ArrayList(HotkeyGroupConfig) = .empty,
    hotkeys: HotkeysConfig = .{},

    pub const runtime_fields = .{ "allocator", "profile_name", "autoColors" };

    /// A profile without a windowFilters key gets the EVE filter; an empty list stays empty.
    pub const wire_defaults = .{
        .windowFilters = &[_]WindowFilterConfig.Wire{WindowFilterConfig.DEFAULT},
    };

    pub const Wire = wire.Wire(Config);

    /// Allocate from an arena freed once the result is serialized.
    pub fn toWire(self: *const Config, allocator: std.mem.Allocator) !Wire {
        return wire.toWireAlloc(Config, allocator, self);
    }

    /// The only way a Config is built, so `fromWire(.{}, ...)` is also the default profile.
    pub fn fromWire(w: Wire, allocator: std.mem.Allocator, profile_name: []const u8) !Config {
        var cfg: Config = .{ .allocator = allocator, .profile_name = try allocator.dupe(u8, profile_name) };
        errdefer cfg.deinit();
        try wire.fromWireInto(Config, w, allocator, &cfg);

        if (cfg.chatlog.chatlogDir.len == 0 or cfg.chatlog.gamelogDir.len == 0) {
            const dirs = try defaultLogDirs(allocator);
            if (cfg.chatlog.chatlogDir.len == 0) {
                allocator.free(cfg.chatlog.chatlogDir);
                cfg.chatlog.chatlogDir = dirs.chatlog;
            } else allocator.free(dirs.chatlog);
            if (cfg.chatlog.gamelogDir.len == 0) {
                allocator.free(cfg.chatlog.gamelogDir);
                cfg.chatlog.gamelogDir = dirs.gamelog;
            } else allocator.free(dirs.gamelog);
        }

        if (cfg.formatVersion < 2) {
            for (cfg.characters.items) |*char| {
                if (char.position) |pos| char.position = pos.scaleFromLegacyDpiUnaware();
            }
        }

        wire.freeField([]const u8, &cfg.app, PROFILE_FORMAT_IDENTIFIER, allocator);
        cfg.app = PROFILE_FORMAT_IDENTIFIER;
        cfg.formatVersion = PROFILE_FORMAT_VERSION;

        return cfg;
    }

    fn ensureProfilesDir(allocator: std.mem.Allocator) !void {
        const cwd = std.Io.Dir.cwd();

        cwd.createDir(files.g_io, PROFILES_DIR, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const profile_path = try std.fs.path.join(allocator, &[_][]const u8{ PROFILES_DIR, DEFAULT_PROFILE });
        defer allocator.free(profile_path);

        cwd.access(files.g_io, profile_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                slog.debug("Default profile not found, creating: {s}", .{profile_path});
                try createDefaultProfile(allocator, profile_path);
                slog.info("Created default profile: {s}", .{profile_path});
            },
            else => return err,
        };
    }

    fn createDefaultProfile(allocator: std.mem.Allocator, path: []const u8) !void {
        var default_config = try getDefaultsWithProfile(allocator, DEFAULT_PROFILE);
        defer default_config.deinit();
        try saveToJsonFile(&default_config, allocator, path);
    }

    pub const atomicWriteFile = files.atomicWriteFile;

    /// Caller owns the returned slice.
    pub fn toJsonString(cfg: *const Config, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const saved = try cfg.toWire(arena.allocator());
        return std.json.Stringify.valueAlloc(allocator, saved, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        });
    }

    pub fn saveToJsonFile(cfg: *const Config, allocator: std.mem.Allocator, path: []const u8) !void {
        const json = try cfg.toJsonString(allocator);
        defer allocator.free(json);

        try atomicWriteFile(allocator, files.g_io, path, json);
        slog.info("Saved JSON config to: {s}", .{path});
    }

    /// A parse failure logs and falls back to this profile's defaults rather than propagating.
    fn loadProfileFromJson(allocator: std.mem.Allocator, profile_path: []const u8, profile_name: []const u8) !Config {
        const file = try std.Io.Dir.cwd().openFile(files.g_io, profile_path, .{});
        defer file.close(files.g_io);

        const file_size = try file.length(files.g_io);
        if (file_size > files.MAX_CONFIG_FILE_SIZE) {
            slog.err("Config file '{s}' too large: {} bytes (max: {} bytes)", .{ profile_path, file_size, files.MAX_CONFIG_FILE_SIZE });
            return error.ConfigFileTooLarge;
        }

        const content = try allocator.alloc(u8, file_size);
        defer allocator.free(content);
        const bytes_read = try file.readPositionalAll(files.g_io, content, 0);

        return buildConfigFromJson(allocator, content[0..bytes_read], profile_name) catch |err| {
            slog.err("Failed to parse config file '{s}' ({}), falling back to defaults", .{ profile_path, err });
            return getDefaultsWithProfile(allocator, profile_name);
        };
    }

    /// Unlike loadProfileFromJson it propagates parse errors, so the dialog can reject a malformed save.
    pub fn buildConfigFromJson(allocator: std.mem.Allocator, json_text: []const u8, profile_name: []const u8) !Config {
        const parsed = try wire.parse(Config.Wire, allocator, json_text);
        defer parsed.deinit();

        var config = try Config.fromWire(parsed.value, allocator, profile_name);
        config.validate();
        return config;
    }

    /// Accepts 0xRRGGBB, 0xAARRGGBB, #RRGGBB, or RRGGBB.
    pub const parseHexColor = wire.parseHexColor;

    pub fn loadProfile(allocator: std.mem.Allocator, profile_name: []const u8) !Config {
        try ensureProfilesDir(allocator);

        const profile_path = try std.fs.path.join(allocator, &[_][]const u8{ PROFILES_DIR, profile_name });
        defer allocator.free(profile_path);

        slog.info("Loading JSON config from: {s}", .{profile_path});
        return loadProfileFromJson(allocator, profile_path, profile_name) catch |err| {
            // ensureProfilesDir() above guarantees DEFAULT_PROFILE exists, so this can't recurse forever.
            if (err == error.FileNotFound and !std.mem.eql(u8, profile_name, DEFAULT_PROFILE)) {
                slog.warn("Profile '{s}' not found, falling back to default profile", .{profile_name});
                return loadProfile(allocator, DEFAULT_PROFILE);
            }
            return err;
        };
    }

    pub fn load(allocator: std.mem.Allocator) !Config {
        return loadProfile(allocator, DEFAULT_PROFILE);
    }

    const FOLDERID_Documents = win32.GUID{
        .Data1 = 0xFDD39AD0,
        .Data2 = 0x238F,
        .Data3 = 0x46AF,
        .Data4 = [8]u8{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 },
    };

    /// Asks the shell rather than assuming %USERPROFILE%/Documents, which OneDrive can redirect; EVE logs to wherever this resolves.
    fn getDocumentsDir(allocator: std.mem.Allocator) ![]u8 {
        const path_utf8 = try win32.getKnownFolderPath(allocator, FOLDERID_Documents);
        std.mem.replaceScalar(u8, path_utf8, '\\', '/');
        return path_utf8;
    }

    /// Resolved from the OS at runtime, so it can't be a field default.
    fn defaultLogDirs(allocator: std.mem.Allocator) !struct { chatlog: []u8, gamelog: []u8 } {
        const documents_dir = getDocumentsDir(allocator) catch blk: {
            slog.warn("Failed to resolve Documents known folder, falling back to USERPROFILE/Documents", .{});
            const userprofile_raw = files.g_environ_map.get("USERPROFILE") orelse {
                slog.warn("USERPROFILE environment variable not found", .{});
                return error.MissingEnvironmentVariable;
            };
            const documents_dir = try std.fmt.allocPrint(allocator, "{s}/Documents", .{userprofile_raw});
            std.mem.replaceScalar(u8, documents_dir, '\\', '/');
            break :blk documents_dir;
        };
        defer allocator.free(documents_dir);

        const chatlog_dir = try std.fmt.allocPrint(allocator, "{s}/EVE/logs/Chatlogs", .{documents_dir});
        errdefer allocator.free(chatlog_dir);
        const gamelog_dir = try std.fmt.allocPrint(allocator, "{s}/EVE/logs/Gamelogs", .{documents_dir});
        errdefer allocator.free(gamelog_dir);

        return .{ .chatlog = chatlog_dir, .gamelog = gamelog_dir };
    }

    pub fn getDefaultsWithProfile(allocator: std.mem.Allocator, profile_name: []const u8) !Config {
        return fromWire(.{}, allocator, profile_name);
    }

    fn characterIndex(self: *const Config, name: []const u8) ?usize {
        for (self.characters.items, 0..) |char, i| {
            if (std.mem.eql(u8, char.name, name)) return i;
        }
        return null;
    }

    pub fn findCharacter(self: *Config, name: []const u8) ?*CharacterConfig {
        return &self.characters.items[self.characterIndex(name) orelse return null];
    }

    pub fn findCharacterConst(self: *const Config, name: []const u8) ?*const CharacterConfig {
        return &self.characters.items[self.characterIndex(name) orelse return null];
    }

    fn characterSetting(self: *const Config, character_name: []const u8, comptime field: []const u8, default: @FieldType(CharacterConfig, field)) @FieldType(CharacterConfig, field) {
        const char = self.findCharacterConst(character_name) orelse return default;
        return @field(char, field);
    }

    pub fn getOrCreateCharacter(self: *Config, allocator: std.mem.Allocator, name: []const u8) !*CharacterConfig {
        if (self.findCharacter(name)) |char| {
            return char;
        }

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        try self.characters.append(allocator, .{ .name = owned_name });
        return &self.characters.items[self.characters.items.len - 1];
    }

    /// Exact names beat patterns regardless of row order; ties within each group go to the first row.
    pub fn findSystemColor(self: *const Config, name: []const u8) ?u32 {
        inline for (.{ false, true }) |wildcards| {
            for (self.systemColors.items) |sc| {
                if (sc.matches(name, wildcards)) return sc.color;
            }
        }
        return null;
    }

    pub fn getCharacterPosition(self: *const Config, character_name: []const u8) ?Position {
        return self.characterSetting(character_name, "position", null);
    }

    pub fn getCharacterWindowPosition(self: *const Config, character_name: []const u8) ?Position {
        return self.characterSetting(character_name, "windowPosition", null);
    }

    /// A character's own active border colour wins, else the unique auto colour if enabled; the inactive one is left as set.
    pub fn getCharacterBorderColors(self: *Config, character_name: []const u8) ?CharacterBorderColorsConfig {
        const configured = self.characterSetting(character_name, "borderColors", null);
        if (!self.thumbnail.useUniqueCharacterBorderColors) return configured;

        var colors = configured orelse CharacterBorderColorsConfig{};
        if (colors.activeBorderColor == null) colors.activeBorderColor = self.autoCharacterColorFor(character_name);
        return colors;
    }

    pub fn getCharacterSize(self: *const Config, character_name: []const u8) ?CharacterThumbnailSizeConfig {
        return self.characterSetting(character_name, "thumbnailSize", null);
    }

    pub fn isExcludedFromMinimize(self: *const Config, character_name: []const u8) bool {
        return self.characterSetting(character_name, "excludeFromMinimize", false);
    }

    pub fn isExcludedFromCloseAll(self: *const Config, character_name: []const u8) bool {
        return self.characterSetting(character_name, "excludeFromCloseAll", false);
    }

    pub fn isThumbnailHidden(self: *const Config, character_name: []const u8) bool {
        return self.characterSetting(character_name, "hideThumbnail", false);
    }

    pub fn isExcludedFromAutoMove(self: *const Config, character_name: []const u8) bool {
        return self.characterSetting(character_name, "excludeFromAutoMove", false);
    }

    pub fn isNotificationMuted(self: *const Config, character_name: []const u8) bool {
        return self.characterSetting(character_name, "notificationsMuted", false);
    }

    pub fn getCharacterOpacity(self: *const Config, character_name: []const u8) u8 {
        return self.characterSetting(character_name, "opacity", null) orelse self.thumbnail.thumbnailOpacity;
    }

    pub fn getDisplayName(self: *const Config, character_name: []const u8) []const u8 {
        return self.characterSetting(character_name, "displayName", null) orelse character_name;
    }

    /// Priority: custom color override, then unique generated color, then default.
    pub fn getSystemNameColor(self: *Config, system_name: []const u8) u32 {
        if (self.findSystemColor(system_name)) |custom_color| {
            return custom_color;
        }

        if (!self.thumbnail.useUniqueSystemColors) return self.thumbnail.systemNameColor;

        self.autoColors.load(self.allocator);

        var overrides: [color.AutoColors.max_avoided]u32 = undefined;
        const override_count = @min(self.systemColors.items.len, overrides.len);
        for (self.systemColors.items[0..override_count], 0..) |sc, i| overrides[i] = sc.color;

        return self.autoColors.system.colorFor(self.allocator, system_name, overrides[0..override_count]);
    }

    pub fn flushAutoColors(self: *Config) void {
        self.autoColors.flush(self.allocator);
    }

    /// The character's own override, then the unique auto colour if enabled; null means the caller's own default.
    pub fn getCharacterNameColor(self: *Config, character_name: []const u8) ?u32 {
        if (self.characterSetting(character_name, "nameColor", null)) |custom_color| return custom_color;
        if (!self.thumbnail.useUniqueCharacterNameColors) return null;

        return self.autoCharacterColorFor(character_name);
    }

    /// One stored color per character, shared by its name and border; steers clear of every character's own name and active border overrides.
    fn autoCharacterColorFor(self: *Config, character_name: []const u8) u32 {
        self.autoColors.load(self.allocator);

        var overrides: [color.AutoColors.max_avoided]u32 = undefined;
        var override_count: usize = 0;
        for (self.characters.items) |char| {
            if (char.nameColor) |custom_color| {
                if (override_count == overrides.len) break;
                overrides[override_count] = custom_color;
                override_count += 1;
            }
            if (char.borderColors) |border| {
                if (border.activeBorderColor) |custom_color| {
                    if (override_count == overrides.len) break;
                    overrides[override_count] = custom_color;
                    override_count += 1;
                }
            }
        }

        return self.autoColors.character.colorFor(self.allocator, character_name, overrides[0..override_count]);
    }

    pub fn validate(self: *Config) void {
        ranges_mod.clamp(Config, self);
        for (self.characters.items) |*char| char.validate();
    }

    /// Sections are keyed by config path, list items and per-type settings by kind (e.g. "characters.opacity").
    pub fn buildValidationRangesJson(allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, comptime ranges_mod.json(.{
            .{ "", Config },
            .{ "characters.", CharacterConfig },
            .{ "notificationType.", NotificationTypeConfig },
            .{ "oreTable.", OrePriceConfig },
            .{ "global.", GlobalConfig },
        }));
    }

    pub fn deinit(self: *Config) void {
        self.autoColors.deinit(self.allocator);
        wire.deinit(Config, self, self.allocator);
        self.allocator.free(self.profile_name);
    }

    /// One log call per JSON line, since the logger silently drops any single write over 2048 bytes.
    pub fn logSettings(self: *const Config) void {
        slog.info("Config loaded from profile: {s}", .{self.profile_name});

        const json = self.toJsonString(self.allocator) catch |err| {
            slog.warn("Failed to serialize config for logging: {}", .{err});
            return;
        };
        defer self.allocator.free(json);

        var lines = std.mem.splitScalar(u8, json, '\n');
        while (lines.next()) |line| {
            slog.debug("{s}", .{line});
        }
    }

    pub fn saveCurrentProfile(self: *const Config, allocator: std.mem.Allocator) !void {
        const profile_path = try std.fs.path.join(allocator, &[_][]const u8{ PROFILES_DIR, self.profile_name });
        defer allocator.free(profile_path);
        try saveToJsonFile(self, allocator, profile_path);
    }

    /// Persists the entire config as JSON, not just this one field.
    pub fn saveCharacterPosition(self: *Config, allocator: std.mem.Allocator, character_name: []const u8, pos: Position) !void {
        const char_config = try self.getOrCreateCharacter(allocator, character_name);
        const is_new = (char_config.position == null);
        char_config.position = pos;

        try self.saveCurrentProfile(allocator);

        if (is_new) {
            slog.debug("Created new position for '{s}' in profile '{s}': ({}, {})", .{ character_name, self.profile_name, pos.x, pos.y });
        } else {
            slog.debug("Updated position for '{s}' in profile '{s}': ({}, {})", .{ character_name, self.profile_name, pos.x, pos.y });
        }
    }

    pub fn saveCharacterWindowPosition(self: *Config, allocator: std.mem.Allocator, character_name: []const u8, pos: Position) !void {
        const char_config = try self.getOrCreateCharacter(allocator, character_name);
        char_config.windowPosition = pos;

        try self.saveCurrentProfile(allocator);
        slog.debug("Saved window position for '{s}' in profile '{s}': ({}, {})", .{ character_name, self.profile_name, pos.x, pos.y });
    }

    /// No-op if `character_name` has no saved window position (or doesn't exist yet).
    pub fn clearCharacterWindowPosition(self: *Config, allocator: std.mem.Allocator, character_name: []const u8) !void {
        const char_config = self.findCharacter(character_name) orelse return;
        if (char_config.windowPosition == null) return;
        char_config.windowPosition = null;

        try self.saveCurrentProfile(allocator);
        slog.debug("Cleared window position for '{s}' in profile '{s}'", .{ character_name, self.profile_name });
    }

    pub fn saveAllCharacterWindowPositions(self: *Config, allocator: std.mem.Allocator, pos: Position) !void {
        for (self.characters.items) |*char| {
            char.windowPosition = pos;
        }

        try self.saveCurrentProfile(allocator);
        slog.debug("Saved window position for all {} character(s) in profile '{s}': ({}, {})", .{ self.characters.items.len, self.profile_name, pos.x, pos.y });
    }

    pub fn clearAllCharacterWindowPositions(self: *Config, allocator: std.mem.Allocator) !void {
        for (self.characters.items) |*char| {
            char.windowPosition = null;
        }

        try self.saveCurrentProfile(allocator);
        slog.debug("Cleared window position for all {} character(s) in profile '{s}'", .{ self.characters.items.len, self.profile_name });
    }

    pub fn saveListViewPosition(self: *Config, allocator: std.mem.Allocator, pos: Position) !void {
        self.display.setLive("startX", pos.x);
        self.display.setLive("startY", pos.y);

        try self.saveCurrentProfile(allocator);
        slog.debug("Saved list view position for profile '{s}': ({}, {})", .{ self.profile_name, pos.x, pos.y });
    }

    pub fn saveHistoryPanelPosition(self: *Config, allocator: std.mem.Allocator, pos: Position) !void {
        self.display.setLive("notifInfoPanelX", pos.x);
        self.display.setLive("notifInfoPanelY", pos.y);

        try self.saveCurrentProfile(allocator);
        slog.debug("Saved History Panel position for profile '{s}': ({}, {})", .{ self.profile_name, pos.x, pos.y });
    }

    pub fn saveHistoryPanelCategoryFilter(self: *Config, allocator: std.mem.Allocator) !void {
        try self.saveCurrentProfile(allocator);
        slog.debug("Saved History Panel category filter for profile '{s}'", .{self.profile_name});
    }
};
