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
const legacy_dpi = @import("config/legacy_dpi.zig");
const chatlog = @import("config/chatlog.zig");
const activity = @import("config/activity.zig");
const notifications_mod = @import("config/notifications.zig");
const window_filters = @import("config/window_filters.zig");
const chat_alerts = @import("config/chat_alerts.zig");
const thumbnail_mod = @import("config/thumbnail.zig");
const display_mod = @import("config/display.zig");
const panels = @import("config/panels.zig");
const intel_mod = @import("config/intel.zig");
const behavior = @import("config/behavior.zig");
const profiles = @import("config/profiles.zig");
const store = @import("config/store.zig");
const log = @import("log.zig");

const slog = log.Scoped("config");

pub const setEnvironMap = files.setEnvironMap;
pub const environMap = files.environMap;
pub const DEFAULT_PROFILE = files.DEFAULT_PROFILE;
pub const migrateLegacyLayout = files.migrateLegacyLayout;
pub const sweepTempFiles = files.sweepTempFiles;
pub const loadProfile = profiles.load;
pub const listProfiles = profiles.list;
pub const writeDefaultProfile = profiles.writeDefault;
pub const createProfile = profiles.create;
pub const copyProfile = profiles.copy;
pub const restoreProfileBackup = profiles.restoreBackup;
pub const replaceProfileWithBackup = profiles.replaceWithBackup;
pub const readProfileAccent = profiles.readAccent;
pub const readProfileBackupAccent = profiles.readBackupAccent;
pub const deleteProfileBackup = profiles.deleteBackup;
pub const deleteProfileToBackup = profiles.deleteToBackup;
pub const renameProfile = profiles.rename;
pub const backUpProfile = profiles.backUp;
pub const checkProfileDeletable = profiles.checkDeletable;
pub const listProfileBackups = profiles.listBackups;
pub const profileBackupDir = profiles.backupDir;
pub const parseBackupName = profiles.parseBackupName;
pub const profileFileName = profiles.fileNameFor;
pub const profileDisplayName = profiles.displayName;
pub const ProfileStore = store.ProfileStore;
pub const KeyList = key_list.KeyList;
pub const parseHexColor = wire.parseHexColor;

pub const GlobalConfig = global.GlobalConfig;
pub const ProtocolLinksConfig = global.ProtocolLinksConfig;
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
pub const migrateProfileChatlog = migrate.profileChatlog;
pub const ChatlogConfig = chatlog.ChatlogConfig;
pub const CombatConfig = activity.CombatConfig;
pub const MiningConfig = activity.MiningConfig;
pub const BountyConfig = activity.BountyConfig;
pub const ResourcesConfig = activity.ResourcesConfig;
pub const PingConfig = activity.PingConfig;
pub const TravelConfig = activity.TravelConfig;
pub const RateUnit = activity.RateUnit;
pub const NotificationTypeConfig = notifications_mod.NotificationTypeConfig;
pub const NotificationConfig = notifications_mod.NotificationConfig;
pub const WindowFilterConfig = window_filters.WindowFilterConfig;
pub const ChatAlertConfig = chat_alerts.ChatAlertConfig;
pub const StateVisualConfig = thumbnail_mod.StateVisualConfig;
pub const ThumbnailState = thumbnail_mod.ThumbnailState;
pub const ThumbnailConfig = thumbnail_mod.ThumbnailConfig;
pub const AlertTextStyle = thumbnail_mod.AlertTextStyle;
pub const CombatTextStyle = thumbnail_mod.CombatTextStyle;
pub const MiningTextStyle = thumbnail_mod.MiningTextStyle;
pub const BountyTextStyle = thumbnail_mod.BountyTextStyle;
pub const ResourcesTextStyle = thumbnail_mod.ResourcesTextStyle;
pub const PingTextStyle = thumbnail_mod.PingTextStyle;
pub const DisplayConfig = display_mod.DisplayConfig;
pub const ListViewConfig = panels.ListViewConfig;
pub const HistoryPanelConfig = panels.HistoryPanelConfig;
pub const MapPanelConfig = panels.MapPanelConfig;
pub const IntelPanelConfig = panels.IntelPanelConfig;
pub const IntelConfig = intel_mod.IntelConfig;
pub const TimerConfig = behavior.TimerConfig;
pub const SnappingConfig = behavior.SnappingConfig;
pub const PanelSnappingConfig = behavior.PanelSnappingConfig;
pub const InteractionConfig = behavior.InteractionConfig;
pub const AutoMinimizeConfig = behavior.AutoMinimizeConfig;
pub const AutoMovePositionConfig = behavior.AutoMovePositionConfig;
pub const ExclusionConfig = behavior.ExclusionConfig;
pub const CloseAllConfig = behavior.CloseAllConfig;
pub const HotkeysConfig = hotkeys_mod.HotkeysConfig;

pub const PROFILE_FORMAT_IDENTIFIER = "eve-maj-preview";
/// Bumped only for schema changes needing a migration, independent of the release version; see config/migrate.zig and Config.fromWire.
pub const PROFILE_FORMAT_VERSION: u32 = migrate.REGROUP_VERSION;

pub const ShownColors = struct {
    system_name_color: u32,
    /// The thumbnails' focused border, which the client list also uses beside them; alone, the list's own.
    active_color: u32,
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
    notifications: NotificationConfig = .{},
    timer: TimerConfig = .{},
    display: DisplayConfig = .{},
    listView: ListViewConfig = .{},
    historyPanel: HistoryPanelConfig = .{},
    mapPanel: MapPanelConfig = .{},
    intelPanel: IntelPanelConfig = .{},
    intel: IntelConfig = .{},
    snapping: SnappingConfig = .{},
    panelSnapping: PanelSnappingConfig = .{},
    interaction: InteractionConfig = .{},
    autoMinimize: AutoMinimizeConfig = .{},
    autoMovePosition: AutoMovePositionConfig = .{},
    exclusion: ExclusionConfig = .{},
    closeAll: CloseAllConfig = .{},
    combat: CombatConfig = .{},
    mining: MiningConfig = .{},
    bounty: BountyConfig = .{},
    resources: ResourcesConfig = .{},
    ping: PingConfig = .{},
    travel: TravelConfig = .{},
    accentColor: u32 = 0xFFD9A441,
    windowFilters: std.ArrayList(WindowFilterConfig) = .empty,
    characters: std.ArrayList(CharacterConfig) = .empty,
    systemColors: std.ArrayList(SystemColorConfig) = .empty,
    hotkeyGroups: std.ArrayList(HotkeyGroupConfig) = .empty,
    thumbnailSpaces: std.ArrayList(ThumbnailSpace) = .empty,
    chatAlerts: std.ArrayList(ChatAlertConfig) = .empty,
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

        if (config.formatVersion < migrate.DPI_AWARE_VERSION) {
            for (config.characters.items) |*character| {
                if (character.position) |position| character.position = legacy_dpi.scalePosition(position);
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

    fn characterIndex(self: *const Config, name: []const u8) ?usize {
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

    /// Ignores case, as typed names in URLs do; the first match wins.
    pub fn hotkeyGroupIndex(self: *const Config, name: []const u8) ?usize {
        for (self.hotkeyGroups.items, 0..) |group, index| {
            if (std.ascii.eqlIgnoreCase(group.name, name)) return index;
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

    pub fn isHiddenFromClientList(self: *const Config, character_name: []const u8) bool {
        return self.characterSetting(character_name, "hideFromClientList", false);
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

    pub fn showsLivePreview(self: *const Config, character_name: []const u8) bool {
        return self.characterSetting(character_name, "preview", .Default).showsLive(self.thumbnail.showLivePreview);
    }

    /// `active_border_color` is the character's focused border colour, which blankDimsBorder dims.
    pub fn getBlankThumbnailColor(self: *const Config, character_name: []const u8, active_border_color: u32) u32 {
        return self.characterSetting(character_name, "blankThumbnailColor", null) orelse self.thumbnail.blankFill(active_border_color);
    }

    pub fn getDisplayName(self: *const Config, character_name: []const u8) []const u8 {
        return self.characterSetting(character_name, "displayName", null) orelse character_name;
    }

    pub fn listActiveColor(self: *const Config) u32 {
        return self.listView.activeColor orelse self.accentColor;
    }

    pub fn focusedBorderColor(self: *const Config) u32 {
        return self.thumbnail.borderColor orelse self.accentColor;
    }

    /// The colour settings of whichever view is shown, since the client list alone has its own.
    pub fn shownColors(self: *const Config) ShownColors {
        return switch (self.display.viewMode) {
            .ClientList => .{
                .system_name_color = self.listView.systemNameColor,
                .active_color = self.listActiveColor(),
                .uses_unique_system_colors = self.listView.useUniqueSystemColors,
                .uses_unique_name_colors = self.listView.useUniqueCharacterNameColors,
                .uses_unique_border_colors = self.listView.useUniqueActiveColors,
            },
            .Thumbnails, .ThumbnailsAndList, .Nothing => .{
                .system_name_color = self.thumbnail.systemNameColor,
                .active_color = self.focusedBorderColor(),
                .uses_unique_system_colors = self.thumbnail.useUniqueSystemColors,
                .uses_unique_name_colors = self.thumbnail.useUniqueCharacterNameColors,
                .uses_unique_border_colors = self.thumbnail.useUniqueCharacterBorderColors,
            },
        };
    }

    /// The focus auto-hide of whichever view is shown, since the client list alone has its own.
    pub fn shownAutoHide(self: *const Config) AutoHide {
        return switch (self.display.viewMode) {
            .ClientList => .{ .is_enabled = self.listView.hideWhenNoEveFocus, .delay_ms = self.listView.hideDebounceMs },
            .Thumbnails, .ThumbnailsAndList, .Nothing => .{ .is_enabled = self.thumbnail.hideWhenNoEveFocus, .delay_ms = self.thumbnail.hideDebounceMs },
        };
    }

    /// The thumbnails' overlay or the shown client list wants damage, so its tracker runs.
    pub fn tracksCombat(self: *const Config) bool {
        const list_view = &self.listView;
        return self.thumbnail.combatText.shown or (self.display.viewMode.showsClientList() and (list_view.showIncomingDps or list_view.showOutgoingDps));
    }

    pub fn tracksMining(self: *const Config) bool {
        return self.thumbnail.miningText.shown or (self.display.viewMode.showsClientList() and self.listView.showMiningRate);
    }

    /// Only the thumbnails show them.
    pub fn tracksResources(self: *const Config) bool {
        return self.thumbnail.resourcesText.shown;
    }

    /// Only the thumbnails show it.
    pub fn tracksPing(self: *const Config) bool {
        return self.thumbnail.pingText.shown;
    }

    pub fn tracksBounty(self: *const Config) bool {
        return self.thumbnail.bountyText.shown or (self.display.viewMode.showsClientList() and self.listView.showBountyRate);
    }

    pub fn validate(self: *Config) void {
        ranges.clamp(Config, self);
        for (self.characters.items) |*character| character.validate();
        for (self.thumbnailSpaces.items) |*space| space.validate();
        for (self.chatAlerts.items) |*rule| rule.validate();
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

const testing = std.testing;

fn testConfig(json_text: []const u8) !Config {
    return Config.buildConfigFromJson(testing.allocator, json_text, "Test");
}

test "findSystemColor prefers an exact name over an earlier pattern" {
    var config = try testConfig(
        \\{"systemColors": [{"systemName": "J*", "color": "0xFF000001"}, {"systemName": "Jita", "color": "0xFF000002"}]}
    );
    defer config.deinit();

    try testing.expectEqual(@as(?u32, 0xFF000002), config.findSystemColor("Jita"));
    try testing.expectEqual(@as(?u32, 0xFF000001), config.findSystemColor("J123456"));
    try testing.expectEqual(@as(?u32, null), config.findSystemColor("Amarr"));
}

test "hotkeyGroupIndex ignores case but hasHotkeyGroupNamed doesn't" {
    var config = try testConfig(
        \\{"hotkeyGroups": [{"name": "Miners"}, {"name": "miners"}]}
    );
    defer config.deinit();

    try testing.expectEqual(@as(?usize, 0), config.hotkeyGroupIndex("MINERS"));
    try testing.expectEqual(@as(?usize, null), config.hotkeyGroupIndex("Scouts"));
    try testing.expect(!config.hasHotkeyGroupNamed("MINERS"));
    try testing.expect(config.hasHotkeyGroupNamed("miners"));
}

test "a character's own settings override the profile's, which apply to unknown characters" {
    var config = try testConfig(
        \\{"characters": [{"name": "Alpha", "displayName": "Main", "opacity": 128, "thumbnailSize": {"width": 300}}]}
    );
    defer config.deinit();

    try testing.expectEqualStrings("Main", config.getDisplayName("Alpha"));
    try testing.expectEqualStrings("Bravo", config.getDisplayName("Bravo"));
    try testing.expectEqual(@as(u8, 128), config.getCharacterOpacity("Alpha"));
    try testing.expectEqual(config.thumbnail.thumbnailOpacity, config.getCharacterOpacity("Bravo"));

    const own_size = config.handPlacedSize("Alpha");
    try testing.expectEqual(@as(i32, 300), own_size.width);
    try testing.expectEqual(config.thumbnail.height, own_size.height);
    const default_size = config.handPlacedSize("Bravo");
    try testing.expectEqual(config.thumbnail.width, default_size.width);
    try testing.expectEqual(config.thumbnail.height, default_size.height);
}

test "a character's preview choice overrides the profile's, and Default follows it" {
    var config = try testConfig(
        \\{"thumbnail": {"showLivePreview": false, "blankThumbnailColor": "0xFF102030"},
        \\ "characters": [{"name": "Alpha", "preview": "Live"}, {"name": "Bravo", "blankThumbnailColor": "0xFF405060"}]}
    );
    defer config.deinit();

    try testing.expect(config.showsLivePreview("Alpha"));
    try testing.expect(!config.showsLivePreview("Bravo"));
    try testing.expect(!config.showsLivePreview("Charlie"));
    try testing.expectEqual(@as(u32, 0xFF405060), config.getBlankThumbnailColor("Bravo", 0xFFFFFFFF));
    try testing.expectEqual(@as(u32, 0xFF102030), config.getBlankThumbnailColor("Charlie", 0xFFFFFFFF));
}

test "a dimmed border fill darkens the border colour, but a character's own colour still wins" {
    var config = try testConfig(
        \\{"thumbnail": {"blankDimsBorder": true}, "characters": [{"name": "Bravo", "blankThumbnailColor": "0xFF405060"}]}
    );
    defer config.deinit();

    try testing.expectEqual(@as(u32, 0xFF3F2010), config.getBlankThumbnailColor("Alpha", 0xFFFF8040));
    try testing.expectEqual(@as(u32, 0xFF405060), config.getBlankThumbnailColor("Bravo", 0xFFFF8040));
}

test "shownColors follows the client list's own settings in its view" {
    var config = try testConfig(
        \\{"display": {"viewMode": "ClientList"}, "listView": {"systemNameColor": "0xFF000003"}, "thumbnail": {"systemNameColor": "0xFF000004"}}
    );
    defer config.deinit();

    try testing.expectEqual(@as(u32, 0xFF000003), config.shownColors().system_name_color);
    config.display.viewMode = .Thumbnails;
    try testing.expectEqual(@as(u32, 0xFF000004), config.shownColors().system_name_color);
}

test "shownColors follows the thumbnails when the list is shown beside them" {
    var config = try testConfig(
        \\{"display": {"viewMode": "ThumbnailsAndList"}, "listView": {"activeColor": "0xFF000001"}, "thumbnail": {"borderColor": "0xFF000002"}}
    );
    defer config.deinit();

    try testing.expectEqual(@as(u32, 0xFF000002), config.shownColors().active_color);
}

test "an unset active colour and focused border follow the accent" {
    var config = try testConfig(
        \\{"accentColor": "0xFFD97AA0"}
    );
    defer config.deinit();

    try testing.expectEqual(@as(u32, 0xFFD97AA0), config.listActiveColor());
    try testing.expectEqual(@as(u32, 0xFFD97AA0), config.focusedBorderColor());
}

test "a tracker runs for the shown client list's rate without the thumbnails' overlay" {
    var config = try testConfig(
        \\{"formatVersion": 6, "display": {"viewMode": "ClientList"}, "listView": {"showMiningRate": true}}
    );
    defer config.deinit();

    try testing.expect(config.tracksMining());
    try testing.expect(!config.tracksCombat());
    config.display.viewMode = .Thumbnails;
    try testing.expect(!config.tracksMining());
    config.thumbnail.miningText.shown = true;
    try testing.expect(config.tracksMining());
}

test "an alert type given in part keeps its own defaults for the fields left out" {
    var config = try testConfig(
        \\{"notifications": {"type_configs": {"CycleExclusion": {"custom_text": "Out"}}}}
    );
    defer config.deinit();

    const type_config = config.notifications.getTypeConfig(.CycleExclusion);
    try testing.expectEqualStrings("Out", type_config.custom_text orelse "");
    try testing.expectEqual(@as(u32, 0), type_config.throttle_ms);
    try testing.expectEqual(@as(u32, 3000), type_config.duration_ms);
}

test "getOrCreateCharacter returns an existing character rather than adding another" {
    var config = try Config.getDefaultsWithProfile(testing.allocator, "Test");
    defer config.deinit();

    (try config.getOrCreateCharacter("Alpha")).opacity = 100;
    const again = try config.getOrCreateCharacter("Alpha");
    try testing.expectEqual(@as(?u8, 100), again.opacity);
    try testing.expectEqual(@as(usize, 1), config.characters.items.len);
}

test "clone copies every setting into memory of its own" {
    var config = try testConfig(
        \\{"characters": [{"name": "Alpha", "displayName": "Main"}], "hotkeyGroups": [{"name": "Miners", "characters": ["Alpha"]}]}
    );
    defer config.deinit();
    var copy = try config.clone(testing.allocator);
    defer copy.deinit();

    const original_json = try config.toJsonString(testing.allocator);
    defer testing.allocator.free(original_json);
    const copy_json = try copy.toJsonString(testing.allocator);
    defer testing.allocator.free(copy_json);
    try testing.expectEqualStrings(original_json, copy_json);
    try testing.expect(config.characters.items[0].name.ptr != copy.characters.items[0].name.ptr);
}
