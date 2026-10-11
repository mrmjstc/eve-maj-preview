//! Every setting in a profile (Config), and the one module the rest of the app imports settings types and profile helpers from.
const std = @import("std");
const wire = @import("config/wire.zig");
const key_list = @import("config/key_list.zig");
const ranges = @import("config/ranges.zig");
const files = @import("config/files.zig");
const global = @import("config/global.zig");
const characters_mod = @import("config/characters.zig");
const system_colors = @import("config/system_colors.zig");
const hotkeys_mod = @import("config/hotkeys.zig");
const spaces = @import("config/spaces.zig");
const migrate = @import("config/migrate.zig");
const chatlog_mod = @import("config/chatlog.zig");
const activity = @import("config/activity.zig");
const notifications = @import("config/notifications.zig");
const window_filters = @import("config/window_filters.zig");
const thumbnail_mod = @import("config/thumbnail.zig");
const display_mod = @import("config/display.zig");
const behavior = @import("config/behavior.zig");
const auto_colors = @import("config/auto_colors.zig");
const profiles = @import("config/profiles.zig");
const store = @import("config/store.zig");
const strings = @import("util/strings.zig");
const log = @import("log.zig");

const slog = log.Scoped("config");

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
pub const deleteProfileBackup = profiles.deleteBackup;
pub const deleteProfileToBackup = profiles.deleteToBackup;
pub const checkProfileDeletable = profiles.checkDeletable;
pub const listProfileBackups = profiles.listBackups;
pub const BackupName = profiles.BackupName;
pub const parseBackupName = profiles.parseBackupName;
pub const profileFileName = profiles.fileNameFor;
pub const ProfileStore = store.ProfileStore;
pub const applyWindowPosition = store.applyWindowPosition;
pub const clampValue = ranges.clampValue;
pub const Argb = wire.Argb;
pub const KeyList = key_list.KeyList;
pub const parseHexColor = wire.parseHexColor;

pub const OrePriceConfig = global.OrePriceConfig;
pub const DEFAULT_ORE_TABLE = global.DEFAULT_ORE_TABLE;
pub const OreEntry = global.OreEntry;
pub const GlobalConfig = global.GlobalConfig;
pub const Position = characters_mod.Position;
pub const WindowSize = characters_mod.WindowSize;
pub const CharacterBorderColorsConfig = characters_mod.CharacterBorderColorsConfig;
pub const CharacterThumbnailSizeConfig = characters_mod.CharacterThumbnailSizeConfig;
pub const CharacterConfig = characters_mod.CharacterConfig;
pub const buildCharacterOrderMap = characters_mod.buildCharacterOrderMap;
pub const orderMapLessThan = characters_mod.orderMapLessThan;
pub const SystemColorConfig = system_colors.SystemColorConfig;
pub const HotkeyGroupConfig = hotkeys_mod.HotkeyGroupConfig;
pub const ThumbnailSpace = spaces.ThumbnailSpace;
pub const migrateProfileJson = migrate.profile;
pub const ChatlogConfig = chatlog_mod.ChatlogConfig;
pub const CombatConfig = activity.CombatConfig;
pub const MiningConfig = activity.MiningConfig;
pub const BountyConfig = activity.BountyConfig;
pub const ResourcesConfig = activity.ResourcesConfig;
pub const TravelConfig = activity.TravelConfig;
pub const IskRateUnit = activity.IskRateUnit;
pub const NotificationTypeConfig = notifications.NotificationTypeConfig;
pub const NotificationConfig = notifications.NotificationConfig;
pub const WindowFilterConfig = window_filters.WindowFilterConfig;
pub const StateVisualConfig = thumbnail_mod.StateVisualConfig;
pub const ThumbnailConfig = thumbnail_mod.ThumbnailConfig;
pub const DisplayConfig = display_mod.DisplayConfig;
pub const TimerConfig = behavior.TimerConfig;
pub const SnappingConfig = behavior.SnappingConfig;
pub const InteractionConfig = behavior.InteractionConfig;
pub const AutoMinimizeConfig = behavior.AutoMinimizeConfig;
pub const AutoMovePositionConfig = behavior.AutoMovePositionConfig;
pub const ExclusionConfig = behavior.ExclusionConfig;
pub const CloseAllConfig = behavior.CloseAllConfig;
pub const HotkeysConfig = hotkeys_mod.HotkeysConfig;
pub const AutoColorStore = auto_colors.AutoColorStore;

pub const PROFILE_FORMAT_IDENTIFIER = "eve-maj-preview";
/// Bumped only for schema changes needing a migration, independent of the release version; see config/migrate.zig and Config.fromWire.
pub const PROFILE_FORMAT_VERSION: u32 = migrate.SPACES_VERSION;

pub const ShownColors = struct {
    system_name_color: u32,
    uses_unique_system_colors: bool,
    uses_unique_name_colors: bool,
    /// For thumbnails their active border; for the client list its active colour.
    uses_unique_border_colors: bool,
};

/// Hidden after `delay_ms` without EVE focus, while enabled.
pub const AutoHide = struct { is_enabled: bool, delay_ms: u32 };

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Owned; freed in deinit.
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
    thumbnailSpaces: std.ArrayList(ThumbnailSpace) = .empty,
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
    pub fn fromWire(wire_value: Wire, allocator: std.mem.Allocator, profile_name: []const u8) !Config {
        var config: Config = .{ .allocator = allocator, .profile_name = try allocator.dupe(u8, profile_name) };
        errdefer config.deinit();
        try wire.fromWireInto(Config, wire_value, allocator, &config);
        try spaces.ensureSpecialSpaces(allocator, &config.thumbnailSpaces);
        spaces.keepSpecialSpacesFirst(config.thumbnailSpaces.items);

        if (config.formatVersion < 2) {
            for (config.characters.items) |*character| {
                if (character.position) |position| character.position = position.scaleFromLegacyDpiUnaware();
            }
        }

        wire.freeField([]const u8, &config.app, PROFILE_FORMAT_IDENTIFIER, allocator);
        config.app = PROFILE_FORMAT_IDENTIFIER;
        config.formatVersion = PROFILE_FORMAT_VERSION;

        return config;
    }

    /// Caller owns the returned slice.
    pub fn toJsonString(self: *const Config, allocator: std.mem.Allocator) ![]u8 {
        return wire.toJsonAlloc(allocator, self);
    }

    /// Unlike loadProfile, fails on a file that isn't JSON instead of falling back to defaults.
    pub fn buildConfigFromJson(allocator: std.mem.Allocator, json_text: []const u8, profile_name: []const u8) !Config {
        const parsed = try wire.parseMigrated(Config.Wire, allocator, json_text, migrate.profile);
        defer parsed.deinit();

        var config = try Config.fromWire(parsed.value, allocator, profile_name);
        config.validate();
        return config;
    }

    pub fn getDefaultsWithProfile(allocator: std.mem.Allocator, profile_name: []const u8) !Config {
        return fromWire(.{}, allocator, profile_name);
    }

    pub fn characterIndex(self: *const Config, name: []const u8) ?usize {
        for (self.characters.items, 0..) |character, i| {
            if (std.mem.eql(u8, character.name, name)) return i;
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
        const character = self.findCharacterConst(character_name) orelse return default;
        return @field(character, field);
    }

    pub fn getOrCreateCharacter(self: *Config, name: []const u8) !*CharacterConfig {
        if (self.findCharacter(name)) |character| {
            return character;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.characters.append(self.allocator, .{ .name = owned_name });
        return &self.characters.items[self.characters.items.len - 1];
    }

    /// Exact names beat patterns regardless of row order; ties within each group go to the first row.
    pub fn findSystemColor(self: *const Config, name: []const u8) ?u32 {
        inline for (.{ false, true }) |uses_wildcards| {
            for (self.systemColors.items) |system_color| {
                if (system_color.matches(name, uses_wildcards)) return system_color.color;
            }
        }
        return null;
    }

    pub fn hasHotkeyGroupNamed(self: *const Config, name: []const u8) bool {
        for (self.hotkeyGroups.items) |group| {
            if (std.mem.eql(u8, group.name, name)) return true;
        }
        return false;
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

    /// A hand-placed thumbnail's size before DPI scaling: its own if set, else the configured one.
    pub fn handPlacedSize(self: *const Config, character_name: []const u8) struct { width: i32, height: i32 } {
        const own_size = self.getCharacterSize(character_name) orelse return .{ .width = self.thumbnail.width, .height = self.thumbnail.height };
        return .{
            .width = own_size.width orelse self.thumbnail.width,
            .height = own_size.height orelse self.thumbnail.height,
        };
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

    /// The colour settings of whichever view is shown, since the client list has its own.
    pub fn shownColors(self: *const Config) ShownColors {
        return switch (self.display.viewMode) {
            .ClientList => .{
                .system_name_color = self.display.listViewSystemNameColor,
                .uses_unique_system_colors = self.display.listViewUseUniqueSystemColors,
                .uses_unique_name_colors = self.display.listViewUseUniqueCharacterNameColors,
                .uses_unique_border_colors = self.display.listViewUseUniqueActiveColors,
            },
            .Thumbnails, .Nothing => .{
                .system_name_color = self.thumbnail.systemNameColor,
                .uses_unique_system_colors = self.thumbnail.useUniqueSystemColors,
                .uses_unique_name_colors = self.thumbnail.useUniqueCharacterNameColors,
                .uses_unique_border_colors = self.thumbnail.useUniqueCharacterBorderColors,
            },
        };
    }

    /// The focus auto-hide of whichever view is shown, since the client list has its own.
    pub fn shownAutoHide(self: *const Config) AutoHide {
        return switch (self.display.viewMode) {
            .ClientList => .{ .is_enabled = self.display.listViewHideWhenNoEveFocus, .delay_ms = self.display.listViewHideDebounceMs },
            .Thumbnails, .Nothing => .{ .is_enabled = self.thumbnail.hideWhenNoEveFocus, .delay_ms = self.thumbnail.hideDebounceMs },
        };
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
        for (self.characters.items) |*character| character.validate();
        for (self.thumbnailSpaces.items) |*space| space.validate();
        spaces.keepOneOfEachSpecialSpace(self.thumbnailSpaces.items);
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
