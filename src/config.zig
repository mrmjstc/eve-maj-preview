//! Every setting in a profile (Config), and the one module the rest of the app imports settings types and profile helpers from.
const std = @import("std");
const wire = @import("config/wire.zig");
const key_list = @import("config/key_list.zig");
const ranges = @import("config/ranges.zig");
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
const profiles = @import("config/profiles.zig");
const store = @import("config/store.zig");
const strings = @import("util/strings.zig");
const log = @import("log.zig");

const slog = log.scoped("config");

pub const setIo = files.setIo;
pub const setEnvironMap = files.setEnvironMap;
pub const environMap = files.environMap;
pub const PROFILES_DIR = files.PROFILES_DIR;
pub const DEFAULT_PROFILE = files.DEFAULT_PROFILE;
pub const GLOBAL_SETTINGS_FILE = files.GLOBAL_SETTINGS_FILE;
pub const atomicWriteFile = files.atomicWriteFile;
pub const migrateLegacyLayout = files.migrateLegacyLayout;
pub const profilePath = profiles.path;
pub const loadProfile = profiles.load;
pub const listProfiles = profiles.list;
pub const saveProfile = profiles.save;
pub const writeDefaultProfile = profiles.writeDefault;
pub const createProfile = profiles.create;
pub const copyProfile = profiles.copy;
pub const restoreProfileBackup = profiles.restoreBackup;
pub const deleteProfileToBackup = profiles.deleteToBackup;
pub const checkProfileDeletable = profiles.checkDeletable;
pub const listProfileBackups = profiles.listBackups;
pub const profileFileName = profiles.fileNameFor;
pub const ProfileStore = store.ProfileStore;
pub const applyWindowPosition = store.applyWindowPosition;

/// Independent of the release version; bump PROFILE_FORMAT_VERSION only for schema changes that need a migration.
pub const PROFILE_FORMAT_IDENTIFIER = "eve-maj-preview";
/// v2: character positions saved while this app was DPI-unaware are migrated to physical pixels on load - see Config.fromWire.
pub const PROFILE_FORMAT_VERSION: u32 = 2;

pub const clampValue = ranges.clampValue;

pub const Argb = wire.Argb;
pub const KeyList = key_list.KeyList;
pub const parseHexColor = wire.parseHexColor;

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
pub const AutoColorStore = auto_colors.AutoColorStore;

pub const Config = struct {
    allocator: std.mem.Allocator,
    profile_name: []const u8,
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

    pub const runtime_fields = .{ "allocator", "profile_name" };

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

    /// Caller owns the returned slice.
    pub fn toJsonString(self: *const Config, allocator: std.mem.Allocator) ![]u8 {
        return wire.toJsonAlloc(allocator, self);
    }

    /// Unlike loadProfile, fails on a file that isn't JSON instead of falling back to defaults.
    pub fn buildConfigFromJson(allocator: std.mem.Allocator, json_text: []const u8, profile_name: []const u8) !Config {
        const parsed = try wire.parse(Config.Wire, allocator, json_text);
        defer parsed.deinit();

        var config = try Config.fromWire(parsed.value, allocator, profile_name);
        config.validate();
        return config;
    }

    pub fn getDefaultsWithProfile(allocator: std.mem.Allocator, profile_name: []const u8) !Config {
        return fromWire(.{}, allocator, profile_name);
    }

    pub fn characterIndex(self: *const Config, name: []const u8) ?usize {
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

    /// The badge-enabled groups `character_name` is in, comma-joined by name or 1-based number ("1, Miners"); "" when none. Owned by the caller.
    pub fn groupBadgeLabel(self: *const Config, allocator: std.mem.Allocator, character_name: []const u8) ![]const u8 {
        var label: std.Io.Writer.Allocating = .init(allocator);
        errdefer label.deinit();
        for (self.hotkeyGroups.items, 1..) |*group, number| {
            if (!group.showBadge or strings.indexOfString(group.characters.items, character_name) == null) continue;
            if (label.written().len > 0) try label.writer.writeAll(", ");
            if (group.name.len > 0) try label.writer.writeAll(group.name) else try label.writer.print("{}", .{number});
        }
        return label.toOwnedSlice();
    }

    pub fn validate(self: *Config) void {
        ranges.clamp(Config, self);
        for (self.characters.items) |*char| char.validate();
    }

    pub fn deinit(self: *Config) void {
        wire.deinit(Config, self, self.allocator);
        self.allocator.free(self.profile_name);
    }

    pub fn logSettings(self: *const Config) void {
        slog.info("Config loaded from profile: {s}", .{self.profile_name});
        wire.logJson(self.allocator, self);
    }

    pub fn clone(self: *const Config, allocator: std.mem.Allocator) !Config {
        var out: Config = .{ .allocator = allocator, .profile_name = try allocator.dupe(u8, self.profile_name) };
        errdefer out.deinit();
        try wire.cloneInto(Config, self, allocator, &out);
        return out;
    }
};
