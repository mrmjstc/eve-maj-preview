const std = @import("std");
const log = @import("log.zig");
const vk = @import("virtual_keys.zig");
const state_mod = @import("state.zig");
const types = @import("types.zig");
const color = @import("color.zig");

const slog = log.scoped("config");

pub const PROFILES_DIR = "profiles";
pub const DEFAULT_PROFILE = "default.json";
const GLOBAL_SETTINGS_FILE = "profiles/global.settings.json";
const DEFAULT_FONT_NAME = "Segoe UI";
const MAX_CONFIG_FILE_SIZE: u64 = 30 * 1024;

/// Identifies a profile JSON as this app's own format, distinct from its release version; bump PROFILE_FORMAT_VERSION only when the schema change matters for parsing/migration.
pub const PROFILE_FORMAT_IDENTIFIER = "eve-maj-preview";
pub const PROFILE_FORMAT_VERSION: u32 = 1;

// Each `*Config`/etc. struct below nests a `pub const Wire = struct {...}` mirroring its persisted fields, giving std.json's reflection-based (de)serializer a JSON-native shape for values the runtime struct stores differently (e.g. raw integers).

/// ARGB color, serialized as an 8-digit hex string, e.g. "0xFF606060".
pub const Argb = struct {
    value: u32,

    pub fn jsonStringify(self: Argb, jw: anytype) !void {
        var buf: [10]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "0x{X:0>8}", .{self.value}) catch unreachable;
        try jw.write(s);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Argb {
        // jsonParseFromValue's error set must stay exactly std.json.ParseFromValueError, so parseHexColor's error.InvalidColorFormat has to be remapped rather than propagated with `try`.
        if (source != .string) return error.UnexpectedToken;
        const value = Config.parseHexColor(source.string) catch return error.UnexpectedToken;
        return .{ .value = value };
    }
};

/// Virtual-key hotkey code, serialized as a 2-digit hex string, e.g. "0x1B"; parsing is delegated to vk.parseVirtualKey, which also accepts combo strings like "Ctrl+F9" for hand-edited profiles.
pub const VkCode = struct {
    value: u32,

    pub fn jsonStringify(self: VkCode, jw: anytype) !void {
        var buf: [10]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "0x{X:0>2}", .{self.value}) catch unreachable;
        try jw.write(s);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !VkCode {
        // Same constraint as Argb.jsonParseFromValue above: an unparseable key maps to UnexpectedToken.
        if (source != .string) return error.UnexpectedToken;
        const parsed = vk.parseVirtualKey(source.string) orelse return error.UnexpectedToken;
        return .{ .value = parsed };
    }
};

fn wrapColor(c: ?u32) ?Argb {
    return if (c) |v| .{ .value = v } else null;
}
fn unwrapColor(c: ?Argb) ?u32 {
    return if (c) |v| v.value else null;
}
fn wrapVk(k: ?u32) ?VkCode {
    return if (k) |v| .{ .value = v } else null;
}
fn unwrapVk(k: ?VkCode) ?u32 {
    return if (k) |v| v.value else null;
}

/// String-to-string map, serialized as a JSON object (used for characterIdMap).
pub const StringMapWire = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn jsonStringify(self: StringMapWire, jw: anytype) !void {
        try jw.beginObject();
        for (self.entries) |e| {
            try jw.objectField(e.key);
            try jw.write(e.value);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !StringMapWire {
        if (source != .object) return .{};
        const entries = try allocator.alloc(Entry, source.object.count());
        var it = source.object.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            if (entry.value_ptr.* != .string) return error.UnexpectedToken;
            entries[i] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.string };
        }
        return .{ .entries = entries };
    }
};

/// Binding of a hotkey to a specific target profile ("quick switch")
pub const ProfileSwitchHotkey = struct {
    hotkey: ?u32,
    targetProfile: []const u8,

    pub fn deinit(self: *ProfileSwitchHotkey, allocator: std.mem.Allocator) void {
        allocator.free(self.targetProfile);
    }

    pub const Wire = struct {
        hotkey: ?VkCode = null,
        targetProfile: []const u8,
    };

    pub fn toWire(self: ProfileSwitchHotkey) Wire {
        return .{ .hotkey = wrapVk(self.hotkey), .targetProfile = self.targetProfile };
    }

    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !ProfileSwitchHotkey {
        return .{ .hotkey = unwrapVk(w.hotkey), .targetProfile = try allocator.dupe(u8, w.targetProfile) };
    }
};

pub const GlobalSettings = struct {
    allocator: std.mem.Allocator,
    lastUsedProfile: []const u8,
    logLevel: log.LogLevel,
    hotkeyNextProfile: ?u32,
    hotkeyPreviousProfile: ?u32,
    profileSwitchHotkeys: std.ArrayList(ProfileSwitchHotkey),
    hotkeyCycleAllClientsForward: ?u32,
    hotkeyCycleAllClientsBackward: ?u32,
    cycleAllClientsRespectExclusions: bool,
    hotkeyCycleNotLoggedInForward: ?u32,
    hotkeyCycleNotLoggedInBackward: ?u32,
    characterIdMap: std.StringHashMap([]const u8),
    disableUpdateChecks: bool,
    language: []const u8,
    needs_free: bool,

    pub fn init(allocator: std.mem.Allocator) GlobalSettings {
        return .{
            .allocator = allocator,
            .lastUsedProfile = "",
            .logLevel = .debug,
            .hotkeyNextProfile = null,
            .hotkeyPreviousProfile = null,
            .profileSwitchHotkeys = std.ArrayList(ProfileSwitchHotkey).empty,
            .hotkeyCycleAllClientsForward = null,
            .hotkeyCycleAllClientsBackward = null,
            .cycleAllClientsRespectExclusions = false,
            .hotkeyCycleNotLoggedInForward = null,
            .hotkeyCycleNotLoggedInBackward = null,
            .characterIdMap = std.StringHashMap([]const u8).init(allocator),
            .disableUpdateChecks = false,
            .language = "en",
            .needs_free = false,
        };
    }

    pub fn deinit(self: *GlobalSettings) void {
        if (self.needs_free and self.lastUsedProfile.len > 0) {
            self.allocator.free(self.lastUsedProfile);
        }
        if (self.needs_free and self.language.len > 0) {
            self.allocator.free(self.language);
        }

        for (self.profileSwitchHotkeys.items) |*psh| {
            psh.deinit(self.allocator);
        }
        self.profileSwitchHotkeys.deinit(self.allocator);

        var iter = self.characterIdMap.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.characterIdMap.deinit();
    }

    /// Load global settings from file, falling back to defaults on any missing/unreadable/malformed input, matching Config's load policy (see loadProfileFromJson).
    pub fn load(allocator: std.mem.Allocator) !GlobalSettings {
        const file = std.fs.cwd().openFile(GLOBAL_SETTINGS_FILE, .{}) catch |err| {
            if (err == error.FileNotFound) {
                slog.debug("No global settings file, using defaults", .{});
                return GlobalSettings.fromWire(.{}, allocator);
            }
            return err;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, MAX_CONFIG_FILE_SIZE) catch |err| {
            slog.err("Failed to read global settings file: {}", .{err});
            std.fs.cwd().deleteFile(GLOBAL_SETTINGS_FILE) catch {};
            return GlobalSettings.fromWire(.{}, allocator);
        };
        defer allocator.free(content);

        const settings = loadFromJson(allocator, content) catch |err| {
            slog.warn("Failed to parse global settings file ({}), using defaults and deleting corrupted file", .{err});
            std.fs.cwd().deleteFile(GLOBAL_SETTINGS_FILE) catch {};
            return GlobalSettings.fromWire(.{}, allocator);
        };

        slog.info("Loaded global settings: last profile = {s}", .{settings.lastUsedProfile});
        return settings;
    }

    fn loadFromJson(allocator: std.mem.Allocator, json_text: []const u8) !GlobalSettings {
        const parsed_value = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed_value.deinit();

        const parsed_wire = try std.json.parseFromValue(GlobalSettings.Wire, allocator, parsed_value.value, .{ .ignore_unknown_fields = true });
        defer parsed_wire.deinit();

        return GlobalSettings.fromWire(parsed_wire.value, allocator);
    }

    /// Caller owns the returned slice.
    pub fn toJsonString(self: *const GlobalSettings, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const wire = try self.toWire(arena.allocator());

        return std.json.Stringify.valueAlloc(allocator, wire, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        });
    }

    pub fn save(self: *const GlobalSettings) !void {
        const json = try self.toJsonString(self.allocator);
        defer self.allocator.free(json);

        try Config.atomicWriteFile(self.allocator, GLOBAL_SETTINGS_FILE, json);

        slog.debug("Saved global settings", .{});
    }

    /// Log all global settings for debugging; same line-per-JSON-line approach as Config.logSettings -- see that method's doc comment for why.
    pub fn logSettings(self: *const GlobalSettings) void {
        const json = self.toJsonString(self.allocator) catch |err| {
            slog.warn("Failed to serialize global settings for logging: {}", .{err});
            return;
        };
        defer self.allocator.free(json);

        var lines = std.mem.splitScalar(u8, json, '\n');
        while (lines.next()) |line| {
            slog.debug("{s}", .{line});
        }
    }

    pub fn updateLastUsed(self: *GlobalSettings, profile_name: []const u8) !void {
        const same_profile = self.lastUsedProfile.len > 0 and std.mem.eql(u8, self.lastUsedProfile, profile_name);

        if (!same_profile) {
            const new_profile = try self.allocator.dupe(u8, profile_name);
            errdefer self.allocator.free(new_profile);

            if (self.needs_free and self.lastUsedProfile.len > 0) {
                self.allocator.free(self.lastUsedProfile);
            }

            self.lastUsedProfile = new_profile;
            self.needs_free = true;

            try self.save();
        }
    }

    pub fn updateCharacterId(self: *GlobalSettings, character_name: []const u8, character_id: []const u8) !void {
        if (self.characterIdMap.get(character_name)) |existing_id| {
            if (std.mem.eql(u8, existing_id, character_id)) {
                return;
            }
        }

        const name_copy = try self.allocator.dupe(u8, character_name);
        errdefer self.allocator.free(name_copy);
        const id_copy = try self.allocator.dupe(u8, character_id);
        errdefer self.allocator.free(id_copy);

        if (try self.characterIdMap.fetchPut(name_copy, id_copy)) |old_entry| {
            self.allocator.free(old_entry.key);
            self.allocator.free(old_entry.value);
        }

        slog.info("Cached character ID: {s} -> {s}", .{ character_name, character_id });
        try self.save();
    }

    pub fn enumerateProfiles(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var profiles = std.ArrayList([]const u8).empty;
        errdefer {
            for (profiles.items) |profile| {
                allocator.free(profile);
            }
            profiles.deinit(allocator);
        }

        var dir = std.fs.cwd().openDir(PROFILES_DIR, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                slog.debug("Profiles directory not found", .{});
                return profiles;
            }
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                if (std.mem.eql(u8, entry.name, "global.settings.json")) {
                    continue;
                }
                const profile_name = try allocator.dupe(u8, entry.name);
                try profiles.append(allocator, profile_name);
            }
        }

        slog.debug("Found {} profile(s)", .{profiles.items.len});
        return profiles;
    }

    pub const Wire = struct {
        lastUsedProfile: []const u8 = DEFAULT_PROFILE,
        logLevel: log.LogLevel = .debug,
        hotkeyNextProfile: ?VkCode = null,
        hotkeyPreviousProfile: ?VkCode = null,
        hotkeyCycleAllClientsForward: ?VkCode = null,
        hotkeyCycleAllClientsBackward: ?VkCode = null,
        cycleAllClientsRespectExclusions: bool = false,
        hotkeyCycleNotLoggedInForward: ?VkCode = null,
        hotkeyCycleNotLoggedInBackward: ?VkCode = null,
        profileSwitchHotkeys: []const ProfileSwitchHotkey.Wire = &.{},
        characterIdMap: StringMapWire = .{},
        disableUpdateChecks: bool = false,
        language: []const u8 = "en",
    };

    pub fn toWire(self: *const GlobalSettings, allocator: std.mem.Allocator) !Wire {
        const psh = try allocator.alloc(ProfileSwitchHotkey.Wire, self.profileSwitchHotkeys.items.len);
        for (self.profileSwitchHotkeys.items, 0..) |item, i| psh[i] = item.toWire();

        const entries = try allocator.alloc(StringMapWire.Entry, self.characterIdMap.count());
        var it = self.characterIdMap.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            entries[i] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
        }

        return .{
            .lastUsedProfile = self.lastUsedProfile,
            .logLevel = self.logLevel,
            .hotkeyNextProfile = wrapVk(self.hotkeyNextProfile),
            .hotkeyPreviousProfile = wrapVk(self.hotkeyPreviousProfile),
            .hotkeyCycleAllClientsForward = wrapVk(self.hotkeyCycleAllClientsForward),
            .hotkeyCycleAllClientsBackward = wrapVk(self.hotkeyCycleAllClientsBackward),
            .cycleAllClientsRespectExclusions = self.cycleAllClientsRespectExclusions,
            .hotkeyCycleNotLoggedInForward = wrapVk(self.hotkeyCycleNotLoggedInForward),
            .hotkeyCycleNotLoggedInBackward = wrapVk(self.hotkeyCycleNotLoggedInBackward),
            .profileSwitchHotkeys = psh,
            .characterIdMap = .{ .entries = entries },
            .disableUpdateChecks = self.disableUpdateChecks,
            .language = self.language,
        };
    }

    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !GlobalSettings {
        var settings = GlobalSettings.init(allocator);
        errdefer settings.deinit();

        settings.lastUsedProfile = try allocator.dupe(u8, w.lastUsedProfile);
        errdefer allocator.free(settings.lastUsedProfile);
        settings.language = try allocator.dupe(u8, w.language);
        settings.needs_free = true;
        settings.logLevel = w.logLevel;
        settings.hotkeyNextProfile = unwrapVk(w.hotkeyNextProfile);
        settings.hotkeyPreviousProfile = unwrapVk(w.hotkeyPreviousProfile);
        settings.hotkeyCycleAllClientsForward = unwrapVk(w.hotkeyCycleAllClientsForward);
        settings.hotkeyCycleAllClientsBackward = unwrapVk(w.hotkeyCycleAllClientsBackward);
        settings.cycleAllClientsRespectExclusions = w.cycleAllClientsRespectExclusions;
        settings.hotkeyCycleNotLoggedInForward = unwrapVk(w.hotkeyCycleNotLoggedInForward);
        settings.hotkeyCycleNotLoggedInBackward = unwrapVk(w.hotkeyCycleNotLoggedInBackward);
        settings.disableUpdateChecks = w.disableUpdateChecks;

        for (w.profileSwitchHotkeys) |item_wire| {
            try settings.profileSwitchHotkeys.append(allocator, try ProfileSwitchHotkey.fromWire(item_wire, allocator));
        }

        for (w.characterIdMap.entries) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key);
            errdefer allocator.free(key_copy);
            const value_copy = try allocator.dupe(u8, entry.value);
            errdefer allocator.free(value_copy);
            try settings.characterIdMap.put(key_copy, value_copy);
        }

        return settings;
    }
};

pub const Position = struct {
    x: i32,
    y: i32,
};

pub const CharacterBorderColors = struct {
    activeBorderColor: ?u32 = null,
    inactiveBorderColor: ?u32 = null,

    pub const Wire = struct {
        activeBorderColor: ?Argb = null,
        inactiveBorderColor: ?Argb = null,
    };

    pub fn toWire(self: CharacterBorderColors) Wire {
        return .{ .activeBorderColor = wrapColor(self.activeBorderColor), .inactiveBorderColor = wrapColor(self.inactiveBorderColor) };
    }

    pub fn fromWire(w: Wire) CharacterBorderColors {
        return .{ .activeBorderColor = unwrapColor(w.activeBorderColor), .inactiveBorderColor = unwrapColor(w.inactiveBorderColor) };
    }
};

pub const CharacterThumbnailSize = struct {
    width: ?i32 = null,
    height: ?i32 = null,
};

pub const CharacterConfig = struct {
    name: []const u8,
    position: ?Position = null,
    windowPosition: ?Position = null,
    borderColors: ?CharacterBorderColors = null,
    nameColor: ?u32 = null,
    thumbnailSize: ?CharacterThumbnailSize = null,
    displayName: ?[]const u8 = null,
    hotkey: ?u32 = null,
    excludeFromMinimize: bool = false,
    excludeFromCloseAll: bool = false,
    hideThumbnail: bool = false,

    pub fn deinit(self: *CharacterConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.displayName) |dn| {
            allocator.free(dn);
        }
    }

    pub const Wire = struct {
        name: []const u8,
        position: ?Position = null,
        windowPosition: ?Position = null,
        borderColors: ?CharacterBorderColors.Wire = null,
        nameColor: ?Argb = null,
        thumbnailSize: ?CharacterThumbnailSize = null,
        displayName: ?[]const u8 = null,
        hotkey: ?VkCode = null,
        excludeFromMinimize: bool = false,
        excludeFromCloseAll: bool = false,
        hideThumbnail: bool = false,
    };

    pub fn toWire(self: CharacterConfig) Wire {
        return .{
            .name = self.name,
            .position = self.position,
            .windowPosition = self.windowPosition,
            .borderColors = if (self.borderColors) |bc| bc.toWire() else null,
            .nameColor = wrapColor(self.nameColor),
            .thumbnailSize = self.thumbnailSize,
            .displayName = self.displayName,
            .hotkey = wrapVk(self.hotkey),
            .excludeFromMinimize = self.excludeFromMinimize,
            .excludeFromCloseAll = self.excludeFromCloseAll,
            .hideThumbnail = self.hideThumbnail,
        };
    }

    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !CharacterConfig {
        return .{
            .name = try allocator.dupe(u8, w.name),
            .position = w.position,
            .windowPosition = w.windowPosition,
            .borderColors = if (w.borderColors) |bc| CharacterBorderColors.fromWire(bc) else null,
            .nameColor = unwrapColor(w.nameColor),
            .thumbnailSize = w.thumbnailSize,
            .displayName = if (w.displayName) |dn| try allocator.dupe(u8, dn) else null,
            .hotkey = unwrapVk(w.hotkey),
            .excludeFromMinimize = w.excludeFromMinimize,
            .excludeFromCloseAll = w.excludeFromCloseAll,
            .hideThumbnail = w.hideThumbnail,
        };
    }
};

pub const SystemColor = struct {
    name: []const u8,
    color: u32,

    pub fn deinit(self: *SystemColor, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }

    pub const Wire = struct {
        systemName: []const u8,
        color: Argb,
    };

    pub fn toWire(self: SystemColor) Wire {
        return .{ .systemName = self.name, .color = .{ .value = self.color } };
    }

    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !SystemColor {
        return .{ .name = try allocator.dupe(u8, w.systemName), .color = w.color.value };
    }
};

pub const HotkeyGroup = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    characters: std.ArrayList([]const u8),
    excluded_characters: std.ArrayList([]const u8),
    forwardKey: ?u32,
    backwardKey: ?u32,
    /// null = not yet cycled; see cycleGroup.
    currentIndex: ?usize = null,

    pub fn deinit(self: *HotkeyGroup) void {
        self.allocator.free(self.name);
        for (self.characters.items) |char_name| {
            self.allocator.free(char_name);
        }
        self.characters.deinit(self.allocator);
        for (self.excluded_characters.items) |char_name| {
            self.allocator.free(char_name);
        }
        self.excluded_characters.deinit(self.allocator);
    }

    // excluded_characters/currentIndex are deliberately not persisted — runtime-only cycling state that resets every launch.
    pub const Wire = struct {
        name: []const u8 = "",
        characters: []const []const u8 = &.{},
        forwardKey: ?VkCode = null,
        backwardKey: ?VkCode = null,
    };

    pub fn toWire(self: HotkeyGroup) Wire {
        return .{
            .name = self.name,
            .characters = self.characters.items,
            .forwardKey = wrapVk(self.forwardKey),
            .backwardKey = wrapVk(self.backwardKey),
        };
    }

    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !HotkeyGroup {
        var group = HotkeyGroup{
            .allocator = allocator,
            .name = try allocator.dupe(u8, w.name),
            .characters = std.ArrayList([]const u8).empty,
            .excluded_characters = std.ArrayList([]const u8).empty,
            .forwardKey = unwrapVk(w.forwardKey),
            .backwardKey = unwrapVk(w.backwardKey),
        };
        errdefer group.deinit();
        try group.characters.ensureTotalCapacity(allocator, w.characters.len);
        for (w.characters) |char_name| {
            group.characters.appendAssumeCapacity(try allocator.dupe(u8, char_name));
        }
        return group;
    }
};

/// Hover-assigned grouping; unlike HotkeyGroup, membership is never persisted.
pub const QuickGroup = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    assignKey: ?u32,
    forwardKey: ?u32,
    backwardKey: ?u32,
    characters: std.ArrayList([]const u8),
    /// null = not yet cycled; see cycleQuickGroup.
    currentIndex: ?usize = null,

    pub fn deinit(self: *QuickGroup) void {
        self.allocator.free(self.name);
        for (self.characters.items) |char_name| {
            self.allocator.free(char_name);
        }
        self.characters.deinit(self.allocator);
    }

    pub const Wire = struct {
        name: []const u8 = "",
        assignKey: ?VkCode = null,
        forwardKey: ?VkCode = null,
        backwardKey: ?VkCode = null,
    };

    pub fn toWire(self: QuickGroup) Wire {
        return .{
            .name = self.name,
            .assignKey = wrapVk(self.assignKey),
            .forwardKey = wrapVk(self.forwardKey),
            .backwardKey = wrapVk(self.backwardKey),
        };
    }

    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !QuickGroup {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, w.name),
            .assignKey = unwrapVk(w.assignKey),
            .forwardKey = unwrapVk(w.forwardKey),
            .backwardKey = unwrapVk(w.backwardKey),
            .characters = std.ArrayList([]const u8).empty,
        };
    }
};

pub const ChatlogConfig = struct {
    enabled: bool = false,
    chatlogDir: []const u8,
    gamelogDir: []const u8,
    pollIntervalMs: u32 = 500,
    idlePollThreshold: u32 = 600,
    maxPollMultiplier: u8 = 4,
    useThreading: bool = true,

    pub fn deinit(self: *ChatlogConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.chatlogDir);
        allocator.free(self.gamelogDir);
    }

    pub const POLL_INTERVAL_MS_MIN: u32 = 100;
    pub const POLL_INTERVAL_MS_MAX: u32 = 5000;
    pub const IDLE_POLL_THRESHOLD_MIN: u32 = 1;
    pub const IDLE_POLL_THRESHOLD_MAX: u32 = 1000;
    pub const MAX_POLL_MULTIPLIER_MIN: u8 = 1;
    /// Must be a power of 2 for exponential backoff.
    pub const MAX_POLL_MULTIPLIER_MAX: u8 = 32;

    pub fn validate(self: *ChatlogConfig) void {
        if (self.pollIntervalMs < POLL_INTERVAL_MS_MIN) {
            slog.warn("Chatlog poll interval {} ms too fast, clamping to {}", .{ self.pollIntervalMs, POLL_INTERVAL_MS_MIN });
            self.pollIntervalMs = POLL_INTERVAL_MS_MIN;
        } else if (self.pollIntervalMs > POLL_INTERVAL_MS_MAX) {
            slog.warn("Chatlog poll interval {} ms too slow, clamping to {}", .{ self.pollIntervalMs, POLL_INTERVAL_MS_MAX });
            self.pollIntervalMs = POLL_INTERVAL_MS_MAX;
        }

        if (self.idlePollThreshold < IDLE_POLL_THRESHOLD_MIN) {
            slog.warn("Idle poll threshold {} too low, clamping to {}", .{ self.idlePollThreshold, IDLE_POLL_THRESHOLD_MIN });
            self.idlePollThreshold = IDLE_POLL_THRESHOLD_MIN;
        } else if (self.idlePollThreshold > IDLE_POLL_THRESHOLD_MAX) {
            slog.warn("Idle poll threshold {} too high, clamping to {}", .{ self.idlePollThreshold, IDLE_POLL_THRESHOLD_MAX });
            self.idlePollThreshold = IDLE_POLL_THRESHOLD_MAX;
        }

        if (self.maxPollMultiplier < MAX_POLL_MULTIPLIER_MIN) {
            slog.warn("Max poll multiplier {} too low, clamping to {}", .{ self.maxPollMultiplier, MAX_POLL_MULTIPLIER_MIN });
            self.maxPollMultiplier = MAX_POLL_MULTIPLIER_MIN;
        } else if (self.maxPollMultiplier > MAX_POLL_MULTIPLIER_MAX) {
            slog.warn("Max poll multiplier {} too high, clamping to {}", .{ self.maxPollMultiplier, MAX_POLL_MULTIPLIER_MAX });
            self.maxPollMultiplier = MAX_POLL_MULTIPLIER_MAX;
        }

        if (self.enabled) {
            if (self.chatlogDir.len == 0) {
                slog.warn("Chatlog monitoring enabled but chatlogDir is empty", .{});
            } else {
                std.fs.cwd().access(self.chatlogDir, .{}) catch |err| {
                    slog.warn("Chatlog directory '{s}' does not exist or is not accessible: {}", .{ self.chatlogDir, err });
                };
            }

            if (self.gamelogDir.len == 0) {
                slog.warn("Chatlog monitoring enabled but gamelogDir is empty", .{});
            } else {
                std.fs.cwd().access(self.gamelogDir, .{}) catch |err| {
                    slog.warn("Gamelog directory '{s}' does not exist or is not accessible: {}", .{ self.gamelogDir, err });
                };
            }
        }
    }

    // chatlogDir/gamelogDir default to "" here since the real Documents/EVE/logs/... default is resolved from the OS Documents known folder at runtime; Config.fromWire substitutes it when empty.
    pub const Wire = struct {
        enabled: bool = false,
        chatlogDir: []const u8 = "",
        gamelogDir: []const u8 = "",
        pollIntervalMs: u32 = 500,
        idlePollThreshold: u32 = 600,
        maxPollMultiplier: u8 = 4,
        useThreading: bool = true,
    };

    pub fn toWire(self: ChatlogConfig) Wire {
        return .{
            .enabled = self.enabled,
            .chatlogDir = self.chatlogDir,
            .gamelogDir = self.gamelogDir,
            .pollIntervalMs = self.pollIntervalMs,
            .idlePollThreshold = self.idlePollThreshold,
            .maxPollMultiplier = self.maxPollMultiplier,
            .useThreading = self.useThreading,
        };
    }

    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !ChatlogConfig {
        return .{
            .enabled = w.enabled,
            .chatlogDir = try Config.expandEnvironmentVariables(allocator, w.chatlogDir),
            .gamelogDir = try Config.expandEnvironmentVariables(allocator, w.gamelogDir),
            .pollIntervalMs = w.pollIntervalMs,
            .idlePollThreshold = w.idlePollThreshold,
            .maxPollMultiplier = w.maxPollMultiplier,
            .useThreading = w.useThreading,
        };
    }
};

pub const CombatConfig = struct {
    enabled: bool = false,
    window_seconds: u32 = 60,
    show_incoming: bool = true,
    show_outgoing: bool = true,
    incoming_color: u32 = 0xFFFF4444,
    outgoing_color: u32 = 0xFF44FF44,
    font_size: i32 = 11,
    update_interval_ms: u32 = 1000,
    incoming_position: types.TextPosition = .TopCenter,
    outgoing_position: types.TextPosition = .BottomCenter,
    incoming_offset_x: i32 = 0,
    incoming_offset_y: i32 = 0,
    outgoing_offset_x: i32 = 0,
    outgoing_offset_y: i32 = 0,
    damage_alert_enabled: bool = false,
    damage_alert_repeat_seconds: u32 = 10,
    // Comma-separated, case-insensitive substring match against the parsed weapon name (see activity_tracker.parseCombatLine/isWeaponExcluded); matching hits still count toward DPS stats, just don't retrigger the Taking Damage alert.
    damage_alert_excluded_weapons: []const u8 = "",
    icon_enabled: bool = false,
    icon_color: u32 = 0xFFFF4444,
    icon_position: types.TextPosition = .TopRight,
    icon_offset_x: i32 = 0,
    icon_offset_y: i32 = 0,
    icon_font_size: i32 = 20,
    incoming_chart: SparkChartConfig = .{},
    outgoing_chart: SparkChartConfig = .{},

    pub const WINDOW_SECONDS_MIN: u32 = 1;
    pub const WINDOW_SECONDS_MAX: u32 = 3600;
    pub const FONT_SIZE_MIN: i32 = 6;
    pub const FONT_SIZE_MAX: i32 = 72;
    pub const UPDATE_INTERVAL_MS_MIN: u32 = 100;
    pub const UPDATE_INTERVAL_MS_MAX: u32 = 60000;
    pub const DAMAGE_ALERT_REPEAT_SECONDS_MIN: u32 = 1;
    pub const DAMAGE_ALERT_REPEAT_SECONDS_MAX: u32 = 3600;
    pub const OFFSET_MIN: i32 = -50;
    pub const OFFSET_MAX: i32 = 50;

    pub fn validate(self: *CombatConfig) void {
        if (self.window_seconds == 0) self.window_seconds = 60;
        if (self.window_seconds > WINDOW_SECONDS_MAX) self.window_seconds = WINDOW_SECONDS_MAX;
        if (self.font_size < FONT_SIZE_MIN) self.font_size = FONT_SIZE_MIN;
        if (self.font_size > FONT_SIZE_MAX) self.font_size = FONT_SIZE_MAX;
        if (self.update_interval_ms < UPDATE_INTERVAL_MS_MIN) self.update_interval_ms = UPDATE_INTERVAL_MS_MIN;
        if (self.update_interval_ms > UPDATE_INTERVAL_MS_MAX) self.update_interval_ms = UPDATE_INTERVAL_MS_MAX;
        if (self.damage_alert_repeat_seconds == 0) self.damage_alert_repeat_seconds = 1;
        if (self.damage_alert_repeat_seconds > DAMAGE_ALERT_REPEAT_SECONDS_MAX) self.damage_alert_repeat_seconds = DAMAGE_ALERT_REPEAT_SECONDS_MAX;
        if (self.icon_font_size < FONT_SIZE_MIN) self.icon_font_size = FONT_SIZE_MIN;
        if (self.icon_font_size > FONT_SIZE_MAX) self.icon_font_size = FONT_SIZE_MAX;

        if (self.incoming_offset_x < OFFSET_MIN) self.incoming_offset_x = OFFSET_MIN;
        if (self.incoming_offset_x > OFFSET_MAX) self.incoming_offset_x = OFFSET_MAX;
        if (self.incoming_offset_y < OFFSET_MIN) self.incoming_offset_y = OFFSET_MIN;
        if (self.incoming_offset_y > OFFSET_MAX) self.incoming_offset_y = OFFSET_MAX;
        if (self.outgoing_offset_x < OFFSET_MIN) self.outgoing_offset_x = OFFSET_MIN;
        if (self.outgoing_offset_x > OFFSET_MAX) self.outgoing_offset_x = OFFSET_MAX;
        if (self.outgoing_offset_y < OFFSET_MIN) self.outgoing_offset_y = OFFSET_MIN;
        if (self.outgoing_offset_y > OFFSET_MAX) self.outgoing_offset_y = OFFSET_MAX;
        if (self.icon_offset_x < OFFSET_MIN) self.icon_offset_x = OFFSET_MIN;
        if (self.icon_offset_x > OFFSET_MAX) self.icon_offset_x = OFFSET_MAX;
        if (self.icon_offset_y < OFFSET_MIN) self.icon_offset_y = OFFSET_MIN;
        if (self.icon_offset_y > OFFSET_MAX) self.icon_offset_y = OFFSET_MAX;

        self.incoming_chart.validate(self.window_seconds);
        self.outgoing_chart.validate(self.window_seconds);
    }

    pub fn deinit(self: *CombatConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.damage_alert_excluded_weapons);
    }

    pub const Wire = struct {
        enabled: bool = (CombatConfig{}).enabled,
        window_seconds: u32 = (CombatConfig{}).window_seconds,
        show_incoming: bool = (CombatConfig{}).show_incoming,
        show_outgoing: bool = (CombatConfig{}).show_outgoing,
        incoming_color: Argb = .{ .value = (CombatConfig{}).incoming_color },
        outgoing_color: Argb = .{ .value = (CombatConfig{}).outgoing_color },
        font_size: i32 = (CombatConfig{}).font_size,
        update_interval_ms: u32 = (CombatConfig{}).update_interval_ms,
        incoming_position: types.TextPosition = (CombatConfig{}).incoming_position,
        outgoing_position: types.TextPosition = (CombatConfig{}).outgoing_position,
        incoming_offset_x: i32 = (CombatConfig{}).incoming_offset_x,
        incoming_offset_y: i32 = (CombatConfig{}).incoming_offset_y,
        outgoing_offset_x: i32 = (CombatConfig{}).outgoing_offset_x,
        outgoing_offset_y: i32 = (CombatConfig{}).outgoing_offset_y,
        damage_alert_enabled: bool = (CombatConfig{}).damage_alert_enabled,
        damage_alert_repeat_seconds: u32 = (CombatConfig{}).damage_alert_repeat_seconds,
        damage_alert_excluded_weapons: []const u8 = (CombatConfig{}).damage_alert_excluded_weapons,
        icon_enabled: bool = (CombatConfig{}).icon_enabled,
        icon_color: Argb = .{ .value = (CombatConfig{}).icon_color },
        icon_position: types.TextPosition = (CombatConfig{}).icon_position,
        icon_offset_x: i32 = (CombatConfig{}).icon_offset_x,
        icon_offset_y: i32 = (CombatConfig{}).icon_offset_y,
        icon_font_size: i32 = (CombatConfig{}).icon_font_size,
        incoming_chart: SparkChartConfig.Wire = .{},
        outgoing_chart: SparkChartConfig.Wire = .{},
    };

    pub fn toWire(self: CombatConfig) Wire {
        return .{
            .enabled = self.enabled,
            .window_seconds = self.window_seconds,
            .show_incoming = self.show_incoming,
            .show_outgoing = self.show_outgoing,
            .incoming_color = .{ .value = self.incoming_color },
            .outgoing_color = .{ .value = self.outgoing_color },
            .font_size = self.font_size,
            .update_interval_ms = self.update_interval_ms,
            .incoming_position = self.incoming_position,
            .outgoing_position = self.outgoing_position,
            .incoming_offset_x = self.incoming_offset_x,
            .incoming_offset_y = self.incoming_offset_y,
            .outgoing_offset_x = self.outgoing_offset_x,
            .outgoing_offset_y = self.outgoing_offset_y,
            .damage_alert_enabled = self.damage_alert_enabled,
            .damage_alert_repeat_seconds = self.damage_alert_repeat_seconds,
            .damage_alert_excluded_weapons = self.damage_alert_excluded_weapons,
            .icon_enabled = self.icon_enabled,
            .icon_color = .{ .value = self.icon_color },
            .icon_position = self.icon_position,
            .icon_offset_x = self.icon_offset_x,
            .icon_offset_y = self.icon_offset_y,
            .icon_font_size = self.icon_font_size,
            .incoming_chart = self.incoming_chart.toWire(),
            .outgoing_chart = self.outgoing_chart.toWire(),
        };
    }

    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !CombatConfig {
        return .{
            .enabled = w.enabled,
            .window_seconds = w.window_seconds,
            .show_incoming = w.show_incoming,
            .show_outgoing = w.show_outgoing,
            .incoming_color = w.incoming_color.value,
            .outgoing_color = w.outgoing_color.value,
            .font_size = w.font_size,
            .update_interval_ms = w.update_interval_ms,
            .incoming_position = w.incoming_position,
            .outgoing_position = w.outgoing_position,
            .incoming_offset_x = w.incoming_offset_x,
            .incoming_offset_y = w.incoming_offset_y,
            .outgoing_offset_x = w.outgoing_offset_x,
            .outgoing_offset_y = w.outgoing_offset_y,
            .damage_alert_enabled = w.damage_alert_enabled,
            .damage_alert_repeat_seconds = w.damage_alert_repeat_seconds,
            .damage_alert_excluded_weapons = try allocator.dupe(u8, w.damage_alert_excluded_weapons),
            .icon_enabled = w.icon_enabled,
            .icon_color = w.icon_color.value,
            .icon_position = w.icon_position,
            .icon_offset_x = w.icon_offset_x,
            .icon_offset_y = w.icon_offset_y,
            .icon_font_size = w.icon_font_size,
            .incoming_chart = SparkChartConfig.fromWire(w.incoming_chart),
            .outgoing_chart = SparkChartConfig.fromWire(w.outgoing_chart),
        };
    }
};

/// Small spark line showing recent history for a rate-like value (mining units/sec, incoming/outgoing DPS); no color field - reuses the parent's color and the global text background.
pub const SparkChartConfig = struct {
    enabled: bool = false,
    /// Percentage of the thumbnail width, not a pixel count (unlike height).
    width: i32 = 100,
    height: i32 = 24,
    position: types.TextPosition = .Center,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    bucket_count: u32 = 20,
    show_background: bool = true,

    pub const WIDTH_MIN: i32 = 10;
    pub const WIDTH_MAX: i32 = 100;
    pub const HEIGHT_MIN: i32 = 10;
    pub const HEIGHT_MAX: i32 = 100;
    pub const OFFSET_MIN: i32 = -50;
    pub const OFFSET_MAX: i32 = 50;
    pub const BUCKET_COUNT_MIN: u32 = 5;
    /// Must match activity_tracker.MAX_CHART_BUCKETS.
    pub const BUCKET_COUNT_MAX: u32 = 60;

    /// window_seconds is the parent Mining/CombatConfig's rate window, needed to clamp bucket_count below.
    pub fn validate(self: *SparkChartConfig, window_seconds: u32) void {
        if (self.width < WIDTH_MIN) self.width = WIDTH_MIN;
        if (self.width > WIDTH_MAX) self.width = WIDTH_MAX;
        if (self.height < HEIGHT_MIN) self.height = HEIGHT_MIN;
        if (self.height > HEIGHT_MAX) self.height = HEIGHT_MAX;
        if (self.offset_x < OFFSET_MIN) self.offset_x = OFFSET_MIN;
        if (self.offset_x > OFFSET_MAX) self.offset_x = OFFSET_MAX;
        if (self.offset_y < OFFSET_MIN) self.offset_y = OFFSET_MIN;
        if (self.offset_y > OFFSET_MAX) self.offset_y = OFFSET_MAX;
        if (self.bucket_count < BUCKET_COUNT_MIN) self.bucket_count = BUCKET_COUNT_MIN;
        if (self.bucket_count > BUCKET_COUNT_MAX) self.bucket_count = BUCKET_COUNT_MAX;
        // More buckets than seconds of window gives sub-second, mostly-empty buckets.
        const max_useful = @max(BUCKET_COUNT_MIN, window_seconds);
        if (self.bucket_count > max_useful) self.bucket_count = max_useful;
    }

    pub const Wire = struct {
        enabled: bool = (SparkChartConfig{}).enabled,
        width: i32 = (SparkChartConfig{}).width,
        height: i32 = (SparkChartConfig{}).height,
        position: types.TextPosition = (SparkChartConfig{}).position,
        offset_x: i32 = (SparkChartConfig{}).offset_x,
        offset_y: i32 = (SparkChartConfig{}).offset_y,
        bucket_count: u32 = (SparkChartConfig{}).bucket_count,
        show_background: bool = (SparkChartConfig{}).show_background,
    };

    pub fn toWire(self: SparkChartConfig) Wire {
        return .{
            .enabled = self.enabled,
            .width = self.width,
            .height = self.height,
            .position = self.position,
            .offset_x = self.offset_x,
            .offset_y = self.offset_y,
            .bucket_count = self.bucket_count,
            .show_background = self.show_background,
        };
    }

    pub fn fromWire(w: Wire) SparkChartConfig {
        return .{
            .enabled = w.enabled,
            .width = w.width,
            .height = w.height,
            .position = w.position,
            .offset_x = w.offset_x,
            .offset_y = w.offset_y,
            .bucket_count = w.bucket_count,
            .show_background = w.show_background,
        };
    }
};

pub const MiningConfig = struct {
    enabled: bool = false,
    window_seconds: u32 = 60,
    color: u32 = 0xFF44AAFF,
    font_size: i32 = 11,
    update_interval_ms: u32 = 1000,
    position: types.TextPosition = .BottomRight,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    idle_alert_enabled: bool = false,
    idle_alert_window_seconds: u32 = 30,
    idle_alert_threshold: u32 = 1,
    stopped_alert_enabled: bool = false,
    stopped_alert_window_seconds: u32 = 60,
    chart: SparkChartConfig = .{},

    pub const WINDOW_SECONDS_MIN: u32 = 1;
    pub const WINDOW_SECONDS_MAX: u32 = 3600;
    pub const FONT_SIZE_MIN: i32 = 6;
    pub const FONT_SIZE_MAX: i32 = 72;
    pub const UPDATE_INTERVAL_MS_MIN: u32 = 100;
    pub const UPDATE_INTERVAL_MS_MAX: u32 = 60000;
    pub const ALERT_WINDOW_SECONDS_MIN: u32 = 1;
    pub const ALERT_WINDOW_SECONDS_MAX: u32 = 3600;
    pub const OFFSET_MIN: i32 = -50;
    pub const OFFSET_MAX: i32 = 50;
    pub const IDLE_ALERT_THRESHOLD_MIN: u32 = 0;
    pub const IDLE_ALERT_THRESHOLD_MAX: u32 = 60;

    pub fn validate(self: *MiningConfig) void {
        if (self.window_seconds == 0) self.window_seconds = 60;
        if (self.window_seconds > WINDOW_SECONDS_MAX) self.window_seconds = WINDOW_SECONDS_MAX;
        if (self.font_size < FONT_SIZE_MIN) self.font_size = FONT_SIZE_MIN;
        if (self.font_size > FONT_SIZE_MAX) self.font_size = FONT_SIZE_MAX;
        if (self.update_interval_ms < UPDATE_INTERVAL_MS_MIN) self.update_interval_ms = UPDATE_INTERVAL_MS_MIN;
        if (self.update_interval_ms > UPDATE_INTERVAL_MS_MAX) self.update_interval_ms = UPDATE_INTERVAL_MS_MAX;
        if (self.idle_alert_window_seconds == 0) self.idle_alert_window_seconds = 15;
        if (self.idle_alert_window_seconds > ALERT_WINDOW_SECONDS_MAX) self.idle_alert_window_seconds = ALERT_WINDOW_SECONDS_MAX;
        if (self.stopped_alert_window_seconds == 0) self.stopped_alert_window_seconds = 30;
        if (self.stopped_alert_window_seconds > ALERT_WINDOW_SECONDS_MAX) self.stopped_alert_window_seconds = ALERT_WINDOW_SECONDS_MAX;

        if (self.offset_x < OFFSET_MIN) self.offset_x = OFFSET_MIN;
        if (self.offset_x > OFFSET_MAX) self.offset_x = OFFSET_MAX;
        if (self.offset_y < OFFSET_MIN) self.offset_y = OFFSET_MIN;
        if (self.offset_y > OFFSET_MAX) self.offset_y = OFFSET_MAX;

        if (self.idle_alert_threshold > IDLE_ALERT_THRESHOLD_MAX) self.idle_alert_threshold = IDLE_ALERT_THRESHOLD_MAX;

        self.chart.validate(self.window_seconds);
    }

    pub const Wire = struct {
        enabled: bool = (MiningConfig{}).enabled,
        window_seconds: u32 = (MiningConfig{}).window_seconds,
        color: Argb = .{ .value = (MiningConfig{}).color },
        font_size: i32 = (MiningConfig{}).font_size,
        update_interval_ms: u32 = (MiningConfig{}).update_interval_ms,
        position: types.TextPosition = (MiningConfig{}).position,
        offset_x: i32 = (MiningConfig{}).offset_x,
        offset_y: i32 = (MiningConfig{}).offset_y,
        idle_alert_enabled: bool = (MiningConfig{}).idle_alert_enabled,
        idle_alert_window_seconds: u32 = (MiningConfig{}).idle_alert_window_seconds,
        idle_alert_threshold: u32 = (MiningConfig{}).idle_alert_threshold,
        stopped_alert_enabled: bool = (MiningConfig{}).stopped_alert_enabled,
        stopped_alert_window_seconds: u32 = (MiningConfig{}).stopped_alert_window_seconds,
        chart: SparkChartConfig.Wire = .{},
    };

    pub fn toWire(self: MiningConfig) Wire {
        return .{
            .enabled = self.enabled,
            .window_seconds = self.window_seconds,
            .color = .{ .value = self.color },
            .font_size = self.font_size,
            .update_interval_ms = self.update_interval_ms,
            .position = self.position,
            .offset_x = self.offset_x,
            .offset_y = self.offset_y,
            .idle_alert_enabled = self.idle_alert_enabled,
            .idle_alert_window_seconds = self.idle_alert_window_seconds,
            .idle_alert_threshold = self.idle_alert_threshold,
            .stopped_alert_enabled = self.stopped_alert_enabled,
            .stopped_alert_window_seconds = self.stopped_alert_window_seconds,
            .chart = self.chart.toWire(),
        };
    }

    pub fn fromWire(w: Wire) MiningConfig {
        return .{
            .enabled = w.enabled,
            .window_seconds = w.window_seconds,
            .color = w.color.value,
            .font_size = w.font_size,
            .update_interval_ms = w.update_interval_ms,
            .position = w.position,
            .offset_x = w.offset_x,
            .offset_y = w.offset_y,
            .idle_alert_enabled = w.idle_alert_enabled,
            .idle_alert_window_seconds = w.idle_alert_window_seconds,
            .idle_alert_threshold = w.idle_alert_threshold,
            .stopped_alert_enabled = w.stopped_alert_enabled,
            .stopped_alert_window_seconds = w.stopped_alert_window_seconds,
            .chart = SparkChartConfig.fromWire(w.chart),
        };
    }
};

pub const NotificationTypeConfig = struct {
    enabled: bool = true,
    duration_ms: u32 = 10000,
    suppress_when_focused: bool = false,
    suppress_when_clicked: bool = false,
    // 0 = no throttling; otherwise repeats of this type are dropped until this many ms have passed since the last one actually shown (per thumbnail).
    throttle_ms: u32 = 10000,
    // null = fall back to the Alert state's borderColor (or inactive border).
    border_color: ?u32 = null,
    // null = fall back to the thumbnail's normal textColor.
    text_color: ?u32 = null,
    // false suppresses the border entirely, overriding the Alert state's showBorder and any border_color above.
    show_border: bool = false,
    // Flashes on/off a few times on start, then settles into an always-on border; no effect when show_border is false.
    flash_border: bool = false,
    // Also requires the global NotificationConfig.tts_enabled master switch.
    tts_enabled: bool = false,

    pub const Wire = struct {
        enabled: bool = (NotificationTypeConfig{}).enabled,
        duration_ms: u32 = (NotificationTypeConfig{}).duration_ms,
        suppress_when_focused: bool = (NotificationTypeConfig{}).suppress_when_focused,
        suppress_when_clicked: bool = (NotificationTypeConfig{}).suppress_when_clicked,
        throttle_ms: u32 = (NotificationTypeConfig{}).throttle_ms,
        border_color: ?Argb = null,
        text_color: ?Argb = null,
        show_border: bool = (NotificationTypeConfig{}).show_border,
        flash_border: bool = (NotificationTypeConfig{}).flash_border,
        tts_enabled: bool = (NotificationTypeConfig{}).tts_enabled,
    };

    pub fn toWire(self: NotificationTypeConfig) Wire {
        return .{
            .enabled = self.enabled,
            .duration_ms = self.duration_ms,
            .suppress_when_focused = self.suppress_when_focused,
            .suppress_when_clicked = self.suppress_when_clicked,
            .throttle_ms = self.throttle_ms,
            .border_color = wrapColor(self.border_color),
            .text_color = wrapColor(self.text_color),
            .show_border = self.show_border,
            .flash_border = self.flash_border,
            .tts_enabled = self.tts_enabled,
        };
    }

    pub fn fromWire(w: Wire) NotificationTypeConfig {
        return .{
            .enabled = w.enabled,
            .duration_ms = w.duration_ms,
            .suppress_when_focused = w.suppress_when_focused,
            .suppress_when_clicked = w.suppress_when_clicked,
            .throttle_ms = w.throttle_ms,
            .border_color = unwrapColor(w.border_color),
            .text_color = unwrapColor(w.text_color),
            .show_border = w.show_border,
            .flash_border = w.flash_border,
            .tts_enabled = w.tts_enabled,
        };
    }
};

pub const TypeConfigMapWire = struct {
    map: std.enums.EnumArray(types.NotificationType, NotificationTypeConfig.Wire) = .initFill(.{}),

    pub fn jsonStringify(self: TypeConfigMapWire, jw: anytype) !void {
        try jw.beginObject();
        inline for (std.meta.fields(types.NotificationType)) |f| {
            try jw.objectField(f.name);
            try jw.write(self.map.get(@field(types.NotificationType, f.name)));
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, opts: std.json.ParseOptions) !TypeConfigMapWire {
        var result: TypeConfigMapWire = .{};
        if (source != .object) return result;
        var it = source.object.iterator();
        while (it.next()) |entry| {
            const ntype = std.meta.stringToEnum(types.NotificationType, entry.key_ptr.*) orelse continue;
            const type_wire = try std.json.parseFromValue(NotificationTypeConfig.Wire, allocator, entry.value_ptr.*, opts);
            defer type_wire.deinit();
            result.map.set(ntype, type_wire.value);
        }
        return result;
    }
};

pub const NotificationConfig = struct {
    enabled: bool = false,
    position: types.TextPosition = .Center,
    offset_x: i32 = 0,
    offset_y: i32 = 0,

    suppress_click_duration_ms: u32 = 5000,

    // A given alert only speaks when this master switch AND its NotificationTypeConfig.tts_enabled are both true.
    tts_enabled: bool = false,
    tts_volume: u8 = 100,
    tts_rate: i8 = 0,
    tts_speak_character_name: bool = true,
    // Only consulted when tts_speak_character_name is true; falls back to the character name if no Custom Display Name is set (see Config.getDisplayName).
    tts_use_display_name: bool = false,

    // Seconds a character stays eligible in the "cycle to recently notified character" queue after their last notification before aging out; re-notifying resets this window.
    notified_cycle_retention_seconds: u32 = 30,

    type_configs: std.enums.EnumArray(types.NotificationType, NotificationTypeConfig),

    pub fn init() NotificationConfig {
        return NotificationConfig{
            .type_configs = std.enums.EnumArray(types.NotificationType, NotificationTypeConfig).initFill(.{}),
        };
    }

    pub fn getTypeConfig(self: *const NotificationConfig, ntype: types.NotificationType) NotificationTypeConfig {
        return self.type_configs.get(ntype);
    }

    pub const Wire = struct {
        enabled: bool = NotificationConfig.init().enabled,
        position: types.TextPosition = NotificationConfig.init().position,
        offset_x: i32 = NotificationConfig.init().offset_x,
        offset_y: i32 = NotificationConfig.init().offset_y,
        suppress_click_duration_ms: u32 = NotificationConfig.init().suppress_click_duration_ms,
        tts_enabled: bool = NotificationConfig.init().tts_enabled,
        tts_volume: u8 = NotificationConfig.init().tts_volume,
        tts_rate: i8 = NotificationConfig.init().tts_rate,
        tts_speak_character_name: bool = NotificationConfig.init().tts_speak_character_name,
        tts_use_display_name: bool = NotificationConfig.init().tts_use_display_name,
        notified_cycle_retention_seconds: u32 = NotificationConfig.init().notified_cycle_retention_seconds,
        type_configs: TypeConfigMapWire = .{},
    };

    pub fn toWire(self: *const NotificationConfig) Wire {
        var map: std.enums.EnumArray(types.NotificationType, NotificationTypeConfig.Wire) = .initFill(.{});
        inline for (std.meta.fields(types.NotificationType)) |f| {
            const ntype = @field(types.NotificationType, f.name);
            map.set(ntype, self.type_configs.get(ntype).toWire());
        }
        return .{
            .enabled = self.enabled,
            .position = self.position,
            .offset_x = self.offset_x,
            .offset_y = self.offset_y,
            .suppress_click_duration_ms = self.suppress_click_duration_ms,
            .tts_enabled = self.tts_enabled,
            .tts_volume = self.tts_volume,
            .tts_rate = self.tts_rate,
            .tts_speak_character_name = self.tts_speak_character_name,
            .tts_use_display_name = self.tts_use_display_name,
            .notified_cycle_retention_seconds = self.notified_cycle_retention_seconds,
            .type_configs = .{ .map = map },
        };
    }

    pub fn fromWire(w: Wire) NotificationConfig {
        var map: std.enums.EnumArray(types.NotificationType, NotificationTypeConfig) = .initFill(.{});
        inline for (std.meta.fields(types.NotificationType)) |f| {
            const ntype = @field(types.NotificationType, f.name);
            map.set(ntype, NotificationTypeConfig.fromWire(w.type_configs.map.get(ntype)));
        }
        return .{
            .enabled = w.enabled,
            .position = w.position,
            .offset_x = w.offset_x,
            .offset_y = w.offset_y,
            .suppress_click_duration_ms = w.suppress_click_duration_ms,
            .tts_enabled = w.tts_enabled,
            .tts_volume = w.tts_volume,
            .tts_rate = w.tts_rate,
            .tts_speak_character_name = w.tts_speak_character_name,
            .tts_use_display_name = w.tts_use_display_name,
            .notified_cycle_retention_seconds = w.notified_cycle_retention_seconds,
            .type_configs = map,
        };
    }
};

pub const WindowFilter = struct {
    name: []const u8,
    class_names: []const []const u8,
    executable_names: []const []const u8,
    enabled: bool = true,

    // Single source of truth for the out-of-the-box EVE Online filter, referenced by both Config.Wire's field default and getDefaultsWithProfile so the strings are only typed once.
    pub const DEFAULT = WindowFilter{
        .name = "EVE Online",
        .class_names = &.{"trinityWindow"},
        .executable_names = &.{"exefile.exe"},
        .enabled = true,
    };

    pub fn deinit(self: *WindowFilter, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.class_names) |class_name| {
            allocator.free(class_name);
        }
        allocator.free(self.class_names);
        for (self.executable_names) |exe_name| {
            allocator.free(exe_name);
        }
        allocator.free(self.executable_names);
    }

    pub fn matchesClass(self: *const WindowFilter, class_name: []const u8) bool {
        if (!self.enabled) return false;
        // Empty defers to the executable check; both empty means no criteria, so match nothing.
        if (self.class_names.len == 0) return self.executable_names.len != 0;
        for (self.class_names) |filter_class| {
            if (std.mem.eql(u8, filter_class, class_name)) {
                return true;
            }
        }
        return false;
    }

    pub fn matchesExecutable(self: *const WindowFilter, exe_path: []const u8) bool {
        if (!self.enabled) return false;
        if (self.executable_names.len == 0) return self.class_names.len != 0;
        for (self.executable_names) |filter_exe| {
            if (exe_path.len >= filter_exe.len) {
                const path_end = exe_path[exe_path.len - filter_exe.len ..];
                if (std.ascii.eqlIgnoreCase(path_end, filter_exe)) {
                    return true;
                }
            }
        }
        return false;
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    thumbnail: ThumbnailConfig,
    timer: TimerConfig,
    display: DisplayConfig,
    snapping: SnappingConfig,
    interaction: InteractionConfig,
    autoMinimize: AutoMinimizeConfig,
    autoMovePosition: AutoMovePositionConfig,
    exclusion: ExclusionConfig,
    closeAll: CloseAllConfig,
    chatlog: ChatlogConfig,
    combat: CombatConfig,
    mining: MiningConfig,

    windowFilters: std.ArrayList(WindowFilter),

    characters: std.ArrayList(CharacterConfig),
    systemColors: std.ArrayList(SystemColor),

    // Runtime-only, not persisted to the config file.
    generatedColorCache: std.StringHashMap(u32),
    generatedCharacterColorCache: std.StringHashMap(u32),

    hotkeyGroups: std.ArrayList(HotkeyGroup),
    quickGroups: std.ArrayList(QuickGroup),
    requireEveFocus: bool = false,
    resetGroupIndexOnNonGroupFocus: bool = false,

    autoRegisterProtocol: bool = true,

    hotkeyMinimizeAll: ?u32 = null,
    hotkeyCloseAll: ?u32 = null,
    hotkeyToggleVisibility: ?u32 = null,
    hotkeyToggleAutoMinimize: ?u32 = null,
    hotkeyToggleExclusion: ?u32 = null,
    hotkeyNextExcluded: ?u32 = null,
    hotkeyPreviousExcluded: ?u32 = null,
    hotkeySuspend: ?u32 = null,
    hotkeyCycleNotified: ?u32 = null,
    hotkeyPreviousNotified: ?u32 = null,
    hotkeyMoveToSavedPositions: ?u32 = null,

    // profile_name/allocator/generatedColorCache/generatedCharacterColorCache are deliberately absent — either derived from the profile filename or pure runtime state, never persisted.
    pub const Wire = struct {
        app: []const u8 = PROFILE_FORMAT_IDENTIFIER,
        formatVersion: u32 = PROFILE_FORMAT_VERSION,
        thumbnail: ThumbnailConfig.Wire = .{},
        timer: TimerConfig = .{},
        display: DisplayConfig = .{},
        snapping: SnappingConfig = .{},
        interaction: InteractionConfig = .{},
        autoMinimize: AutoMinimizeConfig = .{},
        autoMovePosition: AutoMovePositionConfig = .{},
        exclusion: ExclusionConfig = .{},
        closeAll: CloseAllConfig = .{},
        chatlog: ChatlogConfig.Wire = .{},
        combat: CombatConfig.Wire = .{},
        mining: MiningConfig.Wire = .{},
        windowFilters: []const WindowFilter = &.{WindowFilter.DEFAULT},
        characters: []const CharacterConfig.Wire = &.{},
        systemColors: []const SystemColor.Wire = &.{},
        hotkeyGroups: []const HotkeyGroup.Wire = &.{},
        quickGroups: []const QuickGroup.Wire = &.{},
        // Nested (not flattened onto Config.Wire directly) because config_dialog.js's in-memory currentConfig object keeps these under a "hotkeys" sub-object throughout the file, not just in the wire JSON shape.
        hotkeys: HotkeysWire = .{},
    };

    pub const HotkeysWire = struct {
        requireEveFocus: bool = false,
        resetGroupIndexOnNonGroupFocus: bool = false,
        autoRegisterProtocol: bool = true,
        hotkeyMinimizeAll: ?VkCode = null,
        hotkeyCloseAll: ?VkCode = null,
        hotkeyToggleVisibility: ?VkCode = null,
        hotkeyToggleAutoMinimize: ?VkCode = null,
        hotkeyToggleExclusion: ?VkCode = null,
        hotkeyNextExcluded: ?VkCode = null,
        hotkeyPreviousExcluded: ?VkCode = null,
        hotkeySuspend: ?VkCode = null,
        hotkeyCycleNotified: ?VkCode = null,
        hotkeyPreviousNotified: ?VkCode = null,
        hotkeyMoveToSavedPositions: ?VkCode = null,
    };

    pub fn toWire(self: *const Config, allocator: std.mem.Allocator) !Wire {
        const window_filters = try allocator.alloc(WindowFilter, self.windowFilters.items.len);
        for (self.windowFilters.items, 0..) |item, i| window_filters[i] = item;

        const chars = try allocator.alloc(CharacterConfig.Wire, self.characters.items.len);
        for (self.characters.items, 0..) |item, i| chars[i] = item.toWire();

        const sys_colors = try allocator.alloc(SystemColor.Wire, self.systemColors.items.len);
        for (self.systemColors.items, 0..) |item, i| sys_colors[i] = item.toWire();

        const groups = try allocator.alloc(HotkeyGroup.Wire, self.hotkeyGroups.items.len);
        for (self.hotkeyGroups.items, 0..) |item, i| groups[i] = item.toWire();

        const quick_groups = try allocator.alloc(QuickGroup.Wire, self.quickGroups.items.len);
        for (self.quickGroups.items, 0..) |item, i| quick_groups[i] = item.toWire();

        return .{
            .app = PROFILE_FORMAT_IDENTIFIER,
            .formatVersion = PROFILE_FORMAT_VERSION,
            .thumbnail = self.thumbnail.toWire(),
            .timer = self.timer,
            .display = self.display,
            .snapping = self.snapping,
            .interaction = self.interaction,
            .autoMinimize = self.autoMinimize,
            .autoMovePosition = self.autoMovePosition,
            .exclusion = self.exclusion,
            .closeAll = self.closeAll,
            .chatlog = self.chatlog.toWire(),
            .combat = self.combat.toWire(),
            .mining = self.mining.toWire(),
            .windowFilters = window_filters,
            .characters = chars,
            .systemColors = sys_colors,
            .hotkeyGroups = groups,
            .quickGroups = quick_groups,
            .hotkeys = .{
                .requireEveFocus = self.requireEveFocus,
                .resetGroupIndexOnNonGroupFocus = self.resetGroupIndexOnNonGroupFocus,
                .autoRegisterProtocol = self.autoRegisterProtocol,
                .hotkeyMinimizeAll = wrapVk(self.hotkeyMinimizeAll),
                .hotkeyCloseAll = wrapVk(self.hotkeyCloseAll),
                .hotkeyToggleVisibility = wrapVk(self.hotkeyToggleVisibility),
                .hotkeyToggleAutoMinimize = wrapVk(self.hotkeyToggleAutoMinimize),
                .hotkeyToggleExclusion = wrapVk(self.hotkeyToggleExclusion),
                .hotkeyNextExcluded = wrapVk(self.hotkeyNextExcluded),
                .hotkeyPreviousExcluded = wrapVk(self.hotkeyPreviousExcluded),
                .hotkeySuspend = wrapVk(self.hotkeySuspend),
                .hotkeyCycleNotified = wrapVk(self.hotkeyCycleNotified),
                .hotkeyPreviousNotified = wrapVk(self.hotkeyPreviousNotified),
                .hotkeyMoveToSavedPositions = wrapVk(self.hotkeyMoveToSavedPositions),
            },
        };
    }

    /// Build a runtime Config from a parsed Wire (`profile_name` comes from the filename, not the JSON body); starts from getDefaultsWithProfile and replaces fields in place, rather than building a struct literal from scratch, so a single `errdefer cfg.deinit()` covers cleanup no matter which field's conversion fails partway through.
    pub fn fromWire(w: Wire, allocator: std.mem.Allocator, profile_name: []const u8) !Config {
        var cfg = try getDefaultsWithProfile(allocator, profile_name);
        errdefer cfg.deinit();

        cfg.thumbnail = try ThumbnailConfig.fromWire(w.thumbnail, allocator);
        cfg.timer = w.timer;
        // DisplayConfig.listViewFontName would otherwise be left pointing into parsed_wire's arena (freed once buildConfigFromJson returns) — give it its own heap-owned copy, same as ThumbnailConfig.fromWire does for thumbnail.textFontName.
        cfg.display = w.display;
        cfg.display.listViewFontName = try allocator.dupe(u8, w.display.listViewFontName);
        cfg.snapping = w.snapping;
        cfg.interaction = w.interaction;
        cfg.autoMinimize = w.autoMinimize;
        cfg.autoMovePosition = w.autoMovePosition;
        cfg.exclusion = w.exclusion;
        cfg.closeAll = w.closeAll;
        cfg.combat = try CombatConfig.fromWire(w.combat, allocator);
        cfg.mining = MiningConfig.fromWire(w.mining);
        cfg.requireEveFocus = w.hotkeys.requireEveFocus;
        cfg.resetGroupIndexOnNonGroupFocus = w.hotkeys.resetGroupIndexOnNonGroupFocus;
        cfg.autoRegisterProtocol = w.hotkeys.autoRegisterProtocol;
        cfg.hotkeyMinimizeAll = unwrapVk(w.hotkeys.hotkeyMinimizeAll);
        cfg.hotkeyCloseAll = unwrapVk(w.hotkeys.hotkeyCloseAll);
        cfg.hotkeyToggleVisibility = unwrapVk(w.hotkeys.hotkeyToggleVisibility);
        cfg.hotkeyToggleAutoMinimize = unwrapVk(w.hotkeys.hotkeyToggleAutoMinimize);
        cfg.hotkeyToggleExclusion = unwrapVk(w.hotkeys.hotkeyToggleExclusion);
        cfg.hotkeyNextExcluded = unwrapVk(w.hotkeys.hotkeyNextExcluded);
        cfg.hotkeyPreviousExcluded = unwrapVk(w.hotkeys.hotkeyPreviousExcluded);
        cfg.hotkeySuspend = unwrapVk(w.hotkeys.hotkeySuspend);
        cfg.hotkeyCycleNotified = unwrapVk(w.hotkeys.hotkeyCycleNotified);
        cfg.hotkeyPreviousNotified = unwrapVk(w.hotkeys.hotkeyPreviousNotified);
        cfg.hotkeyMoveToSavedPositions = unwrapVk(w.hotkeys.hotkeyMoveToSavedPositions);

        cfg.chatlog.deinit(allocator);
        cfg.chatlog = try ChatlogConfig.fromWire(w.chatlog, allocator);
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

        for (cfg.windowFilters.items) |*wf| wf.deinit(allocator);
        cfg.windowFilters.deinit(allocator);
        cfg.windowFilters = std.ArrayList(WindowFilter).empty;
        try cfg.windowFilters.ensureTotalCapacity(allocator, w.windowFilters.len);
        for (w.windowFilters) |wf| {
            const class_names = try allocator.alloc([]const u8, wf.class_names.len);
            for (wf.class_names, 0..) |cn, i| class_names[i] = try allocator.dupe(u8, cn);
            const exe_names = try allocator.alloc([]const u8, wf.executable_names.len);
            for (wf.executable_names, 0..) |en, i| exe_names[i] = try allocator.dupe(u8, en);
            cfg.windowFilters.appendAssumeCapacity(.{
                .name = try allocator.dupe(u8, wf.name),
                .class_names = class_names,
                .executable_names = exe_names,
                .enabled = wf.enabled,
            });
        }

        try cfg.characters.ensureTotalCapacity(allocator, w.characters.len);
        for (w.characters) |cw| cfg.characters.appendAssumeCapacity(try CharacterConfig.fromWire(cw, allocator));

        try cfg.systemColors.ensureTotalCapacity(allocator, w.systemColors.len);
        for (w.systemColors) |scw| cfg.systemColors.appendAssumeCapacity(try SystemColor.fromWire(scw, allocator));

        try cfg.hotkeyGroups.ensureTotalCapacity(allocator, w.hotkeyGroups.len);
        for (w.hotkeyGroups) |hgw| cfg.hotkeyGroups.appendAssumeCapacity(try HotkeyGroup.fromWire(hgw, allocator));

        try cfg.quickGroups.ensureTotalCapacity(allocator, w.quickGroups.len);
        for (w.quickGroups) |qgw| cfg.quickGroups.appendAssumeCapacity(try QuickGroup.fromWire(qgw, allocator));

        return cfg;
    }

    pub const StateVisualConfig = struct {
        borderWidth: ?u8 = null,
        borderColor: ?u32 = null,
        borderStyle: ?types.BorderStyle = null,
        textColor: ?u32 = null,
        textBgColor: ?u32 = null,
        showBorder: ?bool = null,
        showThumbnail: ?bool = null,

        pub fn getBorderWidth(self: StateVisualConfig, default: u8) u8 {
            return self.borderWidth orelse default;
        }

        pub fn getBorderColor(self: StateVisualConfig, default: u32) u32 {
            return self.borderColor orelse default;
        }

        pub fn getBorderStyle(self: StateVisualConfig, default: types.BorderStyle) types.BorderStyle {
            return self.borderStyle orelse default;
        }

        pub fn getTextColor(self: StateVisualConfig, default: u32) u32 {
            return self.textColor orelse default;
        }

        pub fn getTextBgColor(self: StateVisualConfig, default: u32) u32 {
            return self.textBgColor orelse default;
        }

        pub fn getShowBorder(self: StateVisualConfig, default: bool) bool {
            return self.showBorder orelse default;
        }

        pub fn getShowThumbnail(self: StateVisualConfig, default: bool) bool {
            return self.showThumbnail orelse default;
        }

        pub const Wire = struct {
            borderWidth: ?u8 = null,
            borderColor: ?Argb = null,
            borderStyle: ?types.BorderStyle = null,
            textColor: ?Argb = null,
            textBgColor: ?Argb = null,
            showBorder: ?bool = null,
            showThumbnail: ?bool = null,
        };

        pub fn toWire(self: StateVisualConfig) StateVisualConfig.Wire {
            return .{
                .borderWidth = self.borderWidth,
                .borderColor = wrapColor(self.borderColor),
                .borderStyle = self.borderStyle,
                .textColor = wrapColor(self.textColor),
                .textBgColor = wrapColor(self.textBgColor),
                .showBorder = self.showBorder,
                .showThumbnail = self.showThumbnail,
            };
        }

        pub fn fromWire(w: StateVisualConfig.Wire) StateVisualConfig {
            return .{
                .borderWidth = w.borderWidth,
                .borderColor = unwrapColor(w.borderColor),
                .borderStyle = w.borderStyle,
                .textColor = unwrapColor(w.textColor),
                .textBgColor = unwrapColor(w.textBgColor),
                .showBorder = w.showBorder,
                .showThumbnail = w.showThumbnail,
            };
        }
    };

    pub const ThumbnailConfig = struct {
        width: i32 = 200,
        height: i32 = 112,

        showBorderWhenFocused: bool = true,
        borderWidth: u8 = 2,
        borderColor: u32 = 0xFFE4E4E4,
        borderStyle: types.BorderStyle = .Solid,
        showBorderWhenInactive: bool = false,
        inactiveBorderWidth: u8 = 2,
        inactiveBorderColor: u32 = 0xFF606060,
        inactiveBorderStyle: types.BorderStyle = .Solid,
        showText: bool = true,
        showCharacterName: bool = true,
        showSystemName: bool = false,
        textColor: u32 = 0xFFFFFF,
        useUniqueCharacterNameColors: bool = false,
        textBgColor: u32 = 0x80000000,
        textBgColorInheritBorderColor: bool = false,
        textFontName: []const u8 = DEFAULT_FONT_NAME,
        textFontSize: i32 = 12,
        textFontWeight: types.FontWeight = .Regular,
        useUniqueSystemColors: bool = false,
        systemNameColor: u32 = 0xFFFFFF,
        characterNamePosition: types.TextPosition = .TopLeft,
        characterNameOffsetX: i32 = 0,
        characterNameOffsetY: i32 = 0,
        systemNamePosition: types.TextPosition = .BottomLeft,
        systemNameOffsetX: i32 = 0,
        systemNameOffsetY: i32 = 0,
        showQuickGroupBadge: bool = true,
        quickGroupBadgeColor: u32 = 0xFF44FF44,
        quickGroupBadgePosition: types.TextPosition = .RightCenter,
        quickGroupBadgeOffsetX: i32 = 0,
        quickGroupBadgeOffsetY: i32 = 0,
        exclusionOverlayStyle: types.ExclusionOverlayStyle = .X,
        exclusionOverlayColor: u32 = 0x33FF0000,
        notifications: NotificationConfig = NotificationConfig.init(),
        thumbnailOpacity: u8 = 255,
        applyOpacityToOverlayTexts: bool = false,
        activeThumbnailHidden: bool = false,
        hideWhenNoEveFocus: bool = false,
        hideDebounceMs: u32 = 500,

        // Defaults set here (not at declaration alone) so null on `active` means "use activeThumbnailHidden" instead of a fixed true/false.
        active: StateVisualConfig = .{ .showThumbnail = null },
        inactive: StateVisualConfig = .{ .showThumbnail = true },
        hover: StateVisualConfig = .{ .showThumbnail = true },
        alert: StateVisualConfig = .{ .showThumbnail = true },
        minimized: StateVisualConfig = .{ .showThumbnail = true },
        dragging: StateVisualConfig = .{ .showThumbnail = true },
        hidden: StateVisualConfig = .{ .showThumbnail = false },

        pub fn getStateConfig(self: *const ThumbnailConfig, state: state_mod.ThumbnailState) StateVisualConfig {
            return switch (state) {
                .Active => self.active,
                .Inactive => self.inactive,
                .Hover => self.hover,
                .Alert => self.alert,
                .Minimized => self.minimized,
                .Dragging => self.dragging,
                .Hidden => self.hidden,
            };
        }

        // Also read by Config.buildValidationRangesJson() so the config dialog's inputs share these exact limits instead of a copy that can drift.
        pub const WIDTH_MIN: i32 = 50;
        pub const WIDTH_MAX: i32 = 3840;
        pub const HEIGHT_MIN: i32 = 50;
        pub const HEIGHT_MAX: i32 = 2160;
        pub const BORDER_WIDTH_MIN: u8 = 1;
        pub const BORDER_WIDTH_MAX: u8 = 50;
        pub const FONT_SIZE_MIN: i32 = 6;
        pub const FONT_SIZE_MAX: i32 = 72;
        pub const OFFSET_MIN: i32 = -500;
        pub const OFFSET_MAX: i32 = 500;
        pub const TTS_VOLUME_MAX: u8 = 100;
        /// SAPI native range.
        pub const TTS_RATE_MIN: i8 = -10;
        pub const TTS_RATE_MAX: i8 = 10;
        pub const CYCLE_RETENTION_MIN: u32 = 5;
        pub const CYCLE_RETENTION_MAX: u32 = 600;
        pub const HIDE_DEBOUNCE_MS_MAX: u32 = 5000;
        pub const SUPPRESS_CLICK_DURATION_MS_MAX: u32 = 60000;
        pub const NOTIFICATION_DURATION_MS_MAX: u32 = 60000;
        pub const NOTIFICATION_THROTTLE_MS_MAX: u32 = 300000;

        pub fn validate(self: *ThumbnailConfig) void {
            if (self.width < WIDTH_MIN) {
                slog.warn("Thumbnail width {} too small, clamping to {}", .{ self.width, WIDTH_MIN });
                self.width = WIDTH_MIN;
            } else if (self.width > WIDTH_MAX) {
                slog.warn("Thumbnail width {} too large, clamping to {}", .{ self.width, WIDTH_MAX });
                self.width = WIDTH_MAX;
            }

            if (self.height < HEIGHT_MIN) {
                slog.warn("Thumbnail height {} too small, clamping to {}", .{ self.height, HEIGHT_MIN });
                self.height = HEIGHT_MIN;
            } else if (self.height > HEIGHT_MAX) {
                slog.warn("Thumbnail height {} too large, clamping to {}", .{ self.height, HEIGHT_MAX });
                self.height = HEIGHT_MAX;
            }

            if (self.borderWidth < BORDER_WIDTH_MIN) self.borderWidth = BORDER_WIDTH_MIN;
            if (self.borderWidth > BORDER_WIDTH_MAX) {
                slog.warn("Border width {} too large, clamping to {}", .{ self.borderWidth, BORDER_WIDTH_MAX });
                self.borderWidth = BORDER_WIDTH_MAX;
            }
            if (self.inactiveBorderWidth < BORDER_WIDTH_MIN) self.inactiveBorderWidth = BORDER_WIDTH_MIN;
            if (self.inactiveBorderWidth > BORDER_WIDTH_MAX) {
                slog.warn("Inactive border width {} too large, clamping to {}", .{ self.inactiveBorderWidth, BORDER_WIDTH_MAX });
                self.inactiveBorderWidth = BORDER_WIDTH_MAX;
            }

            if (self.textFontSize < FONT_SIZE_MIN) {
                slog.warn("Font size {} too small, clamping to {}", .{ self.textFontSize, FONT_SIZE_MIN });
                self.textFontSize = FONT_SIZE_MIN;
            } else if (self.textFontSize > FONT_SIZE_MAX) {
                slog.warn("Font size {} too large, clamping to {}", .{ self.textFontSize, FONT_SIZE_MAX });
                self.textFontSize = FONT_SIZE_MAX;
            }

            if (self.characterNameOffsetX < OFFSET_MIN) self.characterNameOffsetX = OFFSET_MIN;
            if (self.characterNameOffsetX > OFFSET_MAX) self.characterNameOffsetX = OFFSET_MAX;
            if (self.characterNameOffsetY < OFFSET_MIN) self.characterNameOffsetY = OFFSET_MIN;
            if (self.characterNameOffsetY > OFFSET_MAX) self.characterNameOffsetY = OFFSET_MAX;
            if (self.systemNameOffsetX < OFFSET_MIN) self.systemNameOffsetX = OFFSET_MIN;
            if (self.systemNameOffsetX > OFFSET_MAX) self.systemNameOffsetX = OFFSET_MAX;
            if (self.systemNameOffsetY < OFFSET_MIN) self.systemNameOffsetY = OFFSET_MIN;
            if (self.systemNameOffsetY > OFFSET_MAX) self.systemNameOffsetY = OFFSET_MAX;
            if (self.quickGroupBadgeOffsetX < OFFSET_MIN) self.quickGroupBadgeOffsetX = OFFSET_MIN;
            if (self.quickGroupBadgeOffsetX > OFFSET_MAX) self.quickGroupBadgeOffsetX = OFFSET_MAX;
            if (self.quickGroupBadgeOffsetY < OFFSET_MIN) self.quickGroupBadgeOffsetY = OFFSET_MIN;
            if (self.quickGroupBadgeOffsetY > OFFSET_MAX) self.quickGroupBadgeOffsetY = OFFSET_MAX;

            if (self.notifications.offset_x < OFFSET_MIN) self.notifications.offset_x = OFFSET_MIN;
            if (self.notifications.offset_x > OFFSET_MAX) self.notifications.offset_x = OFFSET_MAX;
            if (self.notifications.offset_y < OFFSET_MIN) self.notifications.offset_y = OFFSET_MIN;
            if (self.notifications.offset_y > OFFSET_MAX) self.notifications.offset_y = OFFSET_MAX;

            if (self.notifications.tts_volume > TTS_VOLUME_MAX) self.notifications.tts_volume = TTS_VOLUME_MAX;
            if (self.notifications.tts_rate < TTS_RATE_MIN) self.notifications.tts_rate = TTS_RATE_MIN;
            if (self.notifications.tts_rate > TTS_RATE_MAX) self.notifications.tts_rate = TTS_RATE_MAX;

            if (self.notifications.notified_cycle_retention_seconds < CYCLE_RETENTION_MIN) self.notifications.notified_cycle_retention_seconds = CYCLE_RETENTION_MIN;
            if (self.notifications.notified_cycle_retention_seconds > CYCLE_RETENTION_MAX) self.notifications.notified_cycle_retention_seconds = CYCLE_RETENTION_MAX;

            if (self.notifications.suppress_click_duration_ms > SUPPRESS_CLICK_DURATION_MS_MAX) {
                self.notifications.suppress_click_duration_ms = SUPPRESS_CLICK_DURATION_MS_MAX;
            }

            inline for (std.meta.fields(types.NotificationType)) |field| {
                const ntype = @field(types.NotificationType, field.name);
                var type_config = self.notifications.type_configs.get(ntype);
                var changed = false;
                if (type_config.duration_ms > NOTIFICATION_DURATION_MS_MAX) {
                    type_config.duration_ms = NOTIFICATION_DURATION_MS_MAX;
                    changed = true;
                }
                if (type_config.throttle_ms > NOTIFICATION_THROTTLE_MS_MAX) {
                    type_config.throttle_ms = NOTIFICATION_THROTTLE_MS_MAX;
                    changed = true;
                }
                if (changed) self.notifications.type_configs.set(ntype, type_config);
            }

            if (self.hideDebounceMs > HIDE_DEBOUNCE_MS_MAX) {
                slog.warn("Hide debounce {} ms too long, clamping to {}", .{ self.hideDebounceMs, HIDE_DEBOUNCE_MS_MAX });
                self.hideDebounceMs = HIDE_DEBOUNCE_MS_MAX;
            }
        }

        pub const Wire = struct {
            width: i32 = (ThumbnailConfig{}).width,
            height: i32 = (ThumbnailConfig{}).height,
            showBorderWhenFocused: bool = (ThumbnailConfig{}).showBorderWhenFocused,
            borderWidth: u8 = (ThumbnailConfig{}).borderWidth,
            borderColor: Argb = .{ .value = (ThumbnailConfig{}).borderColor },
            borderStyle: types.BorderStyle = (ThumbnailConfig{}).borderStyle,
            showBorderWhenInactive: bool = (ThumbnailConfig{}).showBorderWhenInactive,
            inactiveBorderWidth: u8 = (ThumbnailConfig{}).inactiveBorderWidth,
            inactiveBorderColor: Argb = .{ .value = (ThumbnailConfig{}).inactiveBorderColor },
            inactiveBorderStyle: types.BorderStyle = (ThumbnailConfig{}).inactiveBorderStyle,
            showText: bool = (ThumbnailConfig{}).showText,
            showCharacterName: bool = (ThumbnailConfig{}).showCharacterName,
            showSystemName: bool = (ThumbnailConfig{}).showSystemName,
            textColor: Argb = .{ .value = (ThumbnailConfig{}).textColor },
            useUniqueCharacterNameColors: bool = (ThumbnailConfig{}).useUniqueCharacterNameColors,
            textBgColor: Argb = .{ .value = (ThumbnailConfig{}).textBgColor },
            textBgColorInheritBorderColor: bool = (ThumbnailConfig{}).textBgColorInheritBorderColor,
            textFontName: []const u8 = DEFAULT_FONT_NAME,
            textFontSize: i32 = (ThumbnailConfig{}).textFontSize,
            textFontWeight: types.FontWeight = (ThumbnailConfig{}).textFontWeight,
            useUniqueSystemColors: bool = (ThumbnailConfig{}).useUniqueSystemColors,
            systemNameColor: Argb = .{ .value = (ThumbnailConfig{}).systemNameColor },
            characterNamePosition: types.TextPosition = (ThumbnailConfig{}).characterNamePosition,
            characterNameOffsetX: i32 = (ThumbnailConfig{}).characterNameOffsetX,
            characterNameOffsetY: i32 = (ThumbnailConfig{}).characterNameOffsetY,
            systemNamePosition: types.TextPosition = (ThumbnailConfig{}).systemNamePosition,
            systemNameOffsetX: i32 = (ThumbnailConfig{}).systemNameOffsetX,
            systemNameOffsetY: i32 = (ThumbnailConfig{}).systemNameOffsetY,
            showQuickGroupBadge: bool = (ThumbnailConfig{}).showQuickGroupBadge,
            quickGroupBadgeColor: Argb = .{ .value = (ThumbnailConfig{}).quickGroupBadgeColor },
            quickGroupBadgePosition: types.TextPosition = (ThumbnailConfig{}).quickGroupBadgePosition,
            quickGroupBadgeOffsetX: i32 = (ThumbnailConfig{}).quickGroupBadgeOffsetX,
            quickGroupBadgeOffsetY: i32 = (ThumbnailConfig{}).quickGroupBadgeOffsetY,
            exclusionOverlayStyle: types.ExclusionOverlayStyle = (ThumbnailConfig{}).exclusionOverlayStyle,
            exclusionOverlayColor: Argb = .{ .value = (ThumbnailConfig{}).exclusionOverlayColor },
            notifications: NotificationConfig.Wire = .{},
            thumbnailOpacity: u8 = (ThumbnailConfig{}).thumbnailOpacity,
            applyOpacityToOverlayTexts: bool = (ThumbnailConfig{}).applyOpacityToOverlayTexts,
            activeThumbnailHidden: bool = (ThumbnailConfig{}).activeThumbnailHidden,
            hideWhenNoEveFocus: bool = (ThumbnailConfig{}).hideWhenNoEveFocus,
            hideDebounceMs: u32 = (ThumbnailConfig{}).hideDebounceMs,
            active: StateVisualConfig.Wire = .{ .showThumbnail = null },
            inactive: StateVisualConfig.Wire = .{ .showThumbnail = true },
            hover: StateVisualConfig.Wire = .{ .showThumbnail = true },
            alert: StateVisualConfig.Wire = .{ .showThumbnail = true },
            minimized: StateVisualConfig.Wire = .{ .showThumbnail = true },
            dragging: StateVisualConfig.Wire = .{ .showThumbnail = true },
            hidden: StateVisualConfig.Wire = .{ .showThumbnail = false },
        };

        pub fn toWire(self: *const ThumbnailConfig) ThumbnailConfig.Wire {
            return .{
                .width = self.width,
                .height = self.height,
                .showBorderWhenFocused = self.showBorderWhenFocused,
                .borderWidth = self.borderWidth,
                .borderColor = .{ .value = self.borderColor },
                .borderStyle = self.borderStyle,
                .showBorderWhenInactive = self.showBorderWhenInactive,
                .inactiveBorderWidth = self.inactiveBorderWidth,
                .inactiveBorderColor = .{ .value = self.inactiveBorderColor },
                .inactiveBorderStyle = self.inactiveBorderStyle,
                .showText = self.showText,
                .showCharacterName = self.showCharacterName,
                .showSystemName = self.showSystemName,
                .textColor = .{ .value = self.textColor },
                .useUniqueCharacterNameColors = self.useUniqueCharacterNameColors,
                .textBgColor = .{ .value = self.textBgColor },
                .textBgColorInheritBorderColor = self.textBgColorInheritBorderColor,
                .textFontName = self.textFontName,
                .textFontSize = self.textFontSize,
                .textFontWeight = self.textFontWeight,
                .useUniqueSystemColors = self.useUniqueSystemColors,
                .systemNameColor = .{ .value = self.systemNameColor },
                .characterNamePosition = self.characterNamePosition,
                .characterNameOffsetX = self.characterNameOffsetX,
                .characterNameOffsetY = self.characterNameOffsetY,
                .systemNamePosition = self.systemNamePosition,
                .systemNameOffsetX = self.systemNameOffsetX,
                .systemNameOffsetY = self.systemNameOffsetY,
                .showQuickGroupBadge = self.showQuickGroupBadge,
                .quickGroupBadgeColor = .{ .value = self.quickGroupBadgeColor },
                .quickGroupBadgePosition = self.quickGroupBadgePosition,
                .quickGroupBadgeOffsetX = self.quickGroupBadgeOffsetX,
                .quickGroupBadgeOffsetY = self.quickGroupBadgeOffsetY,
                .exclusionOverlayStyle = self.exclusionOverlayStyle,
                .exclusionOverlayColor = .{ .value = self.exclusionOverlayColor },
                .notifications = self.notifications.toWire(),
                .thumbnailOpacity = self.thumbnailOpacity,
                .applyOpacityToOverlayTexts = self.applyOpacityToOverlayTexts,
                .activeThumbnailHidden = self.activeThumbnailHidden,
                .hideWhenNoEveFocus = self.hideWhenNoEveFocus,
                .hideDebounceMs = self.hideDebounceMs,
                .active = self.active.toWire(),
                .inactive = self.inactive.toWire(),
                .hover = self.hover.toWire(),
                .alert = self.alert.toWire(),
                .minimized = self.minimized.toWire(),
                .dragging = self.dragging.toWire(),
                .hidden = self.hidden.toWire(),
            };
        }

        pub fn fromWire(w: ThumbnailConfig.Wire, allocator: std.mem.Allocator) !ThumbnailConfig {
            return .{
                .width = w.width,
                .height = w.height,
                .showBorderWhenFocused = w.showBorderWhenFocused,
                .borderWidth = w.borderWidth,
                .borderColor = w.borderColor.value,
                .borderStyle = w.borderStyle,
                .showBorderWhenInactive = w.showBorderWhenInactive,
                .inactiveBorderWidth = w.inactiveBorderWidth,
                .inactiveBorderColor = w.inactiveBorderColor.value,
                .inactiveBorderStyle = w.inactiveBorderStyle,
                .showText = w.showText,
                .showCharacterName = w.showCharacterName,
                .showSystemName = w.showSystemName,
                .textColor = w.textColor.value,
                .useUniqueCharacterNameColors = w.useUniqueCharacterNameColors,
                .textBgColor = w.textBgColor.value,
                .textBgColorInheritBorderColor = w.textBgColorInheritBorderColor,
                .textFontName = try allocator.dupe(u8, w.textFontName),
                .textFontSize = w.textFontSize,
                .textFontWeight = w.textFontWeight,
                .useUniqueSystemColors = w.useUniqueSystemColors,
                .systemNameColor = w.systemNameColor.value,
                .characterNamePosition = w.characterNamePosition,
                .characterNameOffsetX = w.characterNameOffsetX,
                .characterNameOffsetY = w.characterNameOffsetY,
                .systemNamePosition = w.systemNamePosition,
                .systemNameOffsetX = w.systemNameOffsetX,
                .systemNameOffsetY = w.systemNameOffsetY,
                .showQuickGroupBadge = w.showQuickGroupBadge,
                .quickGroupBadgeColor = w.quickGroupBadgeColor.value,
                .quickGroupBadgePosition = w.quickGroupBadgePosition,
                .quickGroupBadgeOffsetX = w.quickGroupBadgeOffsetX,
                .quickGroupBadgeOffsetY = w.quickGroupBadgeOffsetY,
                .exclusionOverlayStyle = w.exclusionOverlayStyle,
                .exclusionOverlayColor = w.exclusionOverlayColor.value,
                .notifications = NotificationConfig.fromWire(w.notifications),
                .thumbnailOpacity = w.thumbnailOpacity,
                .applyOpacityToOverlayTexts = w.applyOpacityToOverlayTexts,
                .activeThumbnailHidden = w.activeThumbnailHidden,
                .hideWhenNoEveFocus = w.hideWhenNoEveFocus,
                .hideDebounceMs = w.hideDebounceMs,
                .active = StateVisualConfig.fromWire(w.active),
                .inactive = StateVisualConfig.fromWire(w.inactive),
                .hover = StateVisualConfig.fromWire(w.hover),
                .alert = StateVisualConfig.fromWire(w.alert),
                .minimized = StateVisualConfig.fromWire(w.minimized),
                .dragging = StateVisualConfig.fromWire(w.dragging),
                .hidden = StateVisualConfig.fromWire(w.hidden),
            };
        }
    };

    pub const TimerConfig = struct {
        scanIntervalMs: u32 = 50,

        pub const SCAN_INTERVAL_MS_MIN: u32 = 50;
        pub const SCAN_INTERVAL_MS_MAX: u32 = 10000;

        pub fn validate(self: *TimerConfig) void {
            if (self.scanIntervalMs < SCAN_INTERVAL_MS_MIN) {
                slog.warn("Scan interval {} ms too fast, clamping to {}", .{ self.scanIntervalMs, SCAN_INTERVAL_MS_MIN });
                self.scanIntervalMs = SCAN_INTERVAL_MS_MIN;
            } else if (self.scanIntervalMs > SCAN_INTERVAL_MS_MAX) {
                slog.warn("Scan interval {} ms too slow, clamping to {}", .{ self.scanIntervalMs, SCAN_INTERVAL_MS_MAX });
                self.scanIntervalMs = SCAN_INTERVAL_MS_MAX;
            }
        }
    };

    pub const DisplayConfig = struct {
        startX: i32 = 10,
        startY: i32 = 10,
        spacing: i32 = 10,

        viewMode: types.ViewMode = .Thumbnails,
        listViewOrder: types.ListViewOrder = .Tracked,
        rememberListViewPosition: bool = true,
        listViewOpacity: u8 = 255,
        listViewColumns: u32 = 1,
        listViewFontName: []const u8 = DEFAULT_FONT_NAME,
        listViewFontSize: i32 = 13,
        listViewFontWeight: types.FontWeight = .Regular,

        layoutMode: types.LayoutMode = .HorizontalList,
        layoutDirection: types.LayoutDirection = .RowFirst_LTR_TTB,

        gridColumns: u32 = 4,
        gridRows: ?u32 = null,

        stackOffset: i32 = 10,
        stackAlignment: types.TextPosition = .TopLeft,

        spacingX: ?i32 = null,
        spacingY: ?i32 = null,

        monitorIndex: ?u32 = null,
        useMonitorWorkArea: bool = true,

        honorSavedPositions: bool = true,

        pub const START_X_MIN: i32 = -3840;
        pub const START_X_MAX: i32 = 7680;
        pub const START_Y_MIN: i32 = -2160;
        pub const START_Y_MAX: i32 = 4320;
        pub const SPACING_MIN: i32 = 0;
        pub const SPACING_MAX: i32 = 500;
        pub const GRID_COLUMNS_MIN: u32 = 1;
        pub const GRID_COLUMNS_MAX: u32 = 20;
        pub const GRID_ROWS_MIN: u32 = 1;
        pub const GRID_ROWS_MAX: u32 = 20;
        pub const STACK_OFFSET_MIN: i32 = -500;
        pub const STACK_OFFSET_MAX: i32 = 500;
        pub const MONITOR_INDEX_MAX: u32 = 9;
        pub const LIST_VIEW_COLUMNS_MIN: u32 = 1;
        pub const LIST_VIEW_COLUMNS_MAX: u32 = 15;
        pub const LIST_VIEW_FONT_SIZE_MIN: i32 = 6;
        pub const LIST_VIEW_FONT_SIZE_MAX: i32 = 72;

        pub fn validate(self: *DisplayConfig) void {
            if (self.startX < START_X_MIN) self.startX = START_X_MIN;
            if (self.startX > START_X_MAX) self.startX = START_X_MAX;
            if (self.startY < START_Y_MIN) self.startY = START_Y_MIN;
            if (self.startY > START_Y_MAX) self.startY = START_Y_MAX;

            if (self.spacing < SPACING_MIN) self.spacing = SPACING_MIN;
            if (self.spacing > SPACING_MAX) {
                slog.warn("Spacing {} too large, clamping to {}", .{ self.spacing, SPACING_MAX });
                self.spacing = SPACING_MAX;
            }

            if (self.gridColumns < GRID_COLUMNS_MIN) self.gridColumns = GRID_COLUMNS_MIN;
            if (self.gridColumns > GRID_COLUMNS_MAX) self.gridColumns = GRID_COLUMNS_MAX;
            if (self.gridRows) |*rows| {
                if (rows.* < GRID_ROWS_MIN) rows.* = GRID_ROWS_MIN;
                if (rows.* > GRID_ROWS_MAX) rows.* = GRID_ROWS_MAX;
            }
            if (self.stackOffset < STACK_OFFSET_MIN) self.stackOffset = STACK_OFFSET_MIN;
            if (self.stackOffset > STACK_OFFSET_MAX) self.stackOffset = STACK_OFFSET_MAX;

            if (self.spacingX) |*sx| {
                if (sx.* < SPACING_MIN) sx.* = SPACING_MIN;
                if (sx.* > SPACING_MAX) sx.* = SPACING_MAX;
            }
            if (self.spacingY) |*sy| {
                if (sy.* < SPACING_MIN) sy.* = SPACING_MIN;
                if (sy.* > SPACING_MAX) sy.* = SPACING_MAX;
            }

            if (self.monitorIndex) |*idx| {
                if (idx.* > MONITOR_INDEX_MAX) {
                    slog.warn("Monitor index {} too high, clamping to {} (max {} monitors)", .{ idx.*, MONITOR_INDEX_MAX, MONITOR_INDEX_MAX + 1 });
                    idx.* = MONITOR_INDEX_MAX;
                }
            }

            if (self.listViewColumns < LIST_VIEW_COLUMNS_MIN) self.listViewColumns = LIST_VIEW_COLUMNS_MIN;
            if (self.listViewColumns > LIST_VIEW_COLUMNS_MAX) self.listViewColumns = LIST_VIEW_COLUMNS_MAX;

            if (self.listViewFontSize < LIST_VIEW_FONT_SIZE_MIN) {
                slog.warn("List view font size {} too small, clamping to {}", .{ self.listViewFontSize, LIST_VIEW_FONT_SIZE_MIN });
                self.listViewFontSize = LIST_VIEW_FONT_SIZE_MIN;
            } else if (self.listViewFontSize > LIST_VIEW_FONT_SIZE_MAX) {
                slog.warn("List view font size {} too large, clamping to {}", .{ self.listViewFontSize, LIST_VIEW_FONT_SIZE_MAX });
                self.listViewFontSize = LIST_VIEW_FONT_SIZE_MAX;
            }

            // Uses a typical 200x150 thumbnail size to estimate whether this grid configuration would spawn thumbnails off-screen.
            const typical_thumb_width = 200;
            const typical_thumb_height = 150;
            const spacing_x = self.spacingX orelse self.spacing;
            const spacing_y = self.spacingY orelse self.spacing;

            const estimated_width = @as(i32, @intCast(self.gridColumns)) * (typical_thumb_width + spacing_x);
            const max_reasonable_width = 7680;

            if (estimated_width > max_reasonable_width) {
                slog.warn("Grid configuration may spawn thumbnails off-screen: {} columns × {}px ≈ {}px width (max reasonable: {}px)", .{ self.gridColumns, typical_thumb_width + spacing_x, estimated_width, max_reasonable_width });
            }

            if (self.gridRows) |rows| {
                const estimated_height = @as(i32, @intCast(rows)) * (typical_thumb_height + spacing_y);
                const max_reasonable_height = 4320;

                if (estimated_height > max_reasonable_height) {
                    slog.warn("Grid configuration may spawn thumbnails off-screen: {} rows × {}px ≈ {}px height (max reasonable: {}px)", .{ rows, typical_thumb_height + spacing_y, estimated_height, max_reasonable_height });
                }
            }
        }

        pub fn getSpacingX(self: *const DisplayConfig) i32 {
            return self.spacingX orelse self.spacing;
        }

        pub fn getSpacingY(self: *const DisplayConfig) i32 {
            return self.spacingY orelse self.spacing;
        }
    };

    pub const SnappingConfig = struct {
        enabled: bool = true,
        threshold: i32 = 10,
        screenEdges: bool = true,
        thumbnailEdges: bool = true,
        ghostPositions: bool = true,

        pub const THRESHOLD_MIN: i32 = 0;
        pub const THRESHOLD_MAX: i32 = 100;

        pub fn validate(self: *SnappingConfig) void {
            if (self.threshold < THRESHOLD_MIN) self.threshold = THRESHOLD_MIN;
            if (self.threshold > THRESHOLD_MAX) {
                slog.warn("Snap threshold {} too large, clamping to {}", .{ self.threshold, THRESHOLD_MAX });
                self.threshold = THRESHOLD_MAX;
            }
        }
    };

    pub const InteractionConfig = struct {
        enableDragging: bool = true,
        animationStyle: types.AnimationStyle = .NoAnimation,
        clickTrigger: types.ClickTrigger = .MouseDown,
    };

    pub const AutoMinimizeConfig = struct {
        enabled: bool = false,
        delayMs: u32 = 5000,

        pub const DELAY_MS_MAX: u32 = 10000;

        pub fn validate(self: *AutoMinimizeConfig) void {
            if (self.delayMs > DELAY_MS_MAX) {
                slog.warn("Auto-minimize delay {} ms too long, clamping to {}", .{ self.delayMs, DELAY_MS_MAX });
                self.delayMs = DELAY_MS_MAX;
            }
        }
    };

    pub const AutoMovePositionConfig = struct {
        enabled: bool = false,
    };

    pub const ExclusionConfig = struct {
        enableShiftClickExclude: bool = true,
        autoMinimizeExcluded: bool = false,
    };

    pub const CloseAllConfig = struct {};

    /// Expand %VAR% patterns in a path string. Caller owns the returned slice.
    fn expandEnvironmentVariables(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (std.mem.indexOfScalar(u8, path, '%') == null) {
            return allocator.dupe(u8, path);
        }

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < path.len) {
            if (path[i] == '%') {
                const start = i + 1;
                const end = std.mem.indexOfScalarPos(u8, path, start, '%') orelse {
                    try result.append(allocator, '%');
                    i += 1;
                    continue;
                };

                const var_name = path[start..end];
                if (var_name.len == 0) {
                    try result.append(allocator, '%');
                    i += 1;
                    continue;
                }

                const var_value = std.process.getEnvVarOwned(allocator, var_name) catch |err| {
                    slog.warn("Failed to expand environment variable '{s}': {}", .{ var_name, err });
                    try result.appendSlice(allocator, path[i .. end + 1]);
                    i = end + 1;
                    continue;
                };
                defer allocator.free(var_value);

                for (var_value) |c| {
                    try result.append(allocator, if (c == '\\') '/' else c);
                }

                i = end + 1;
            } else {
                try result.append(allocator, path[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn ensureProfilesDir(allocator: std.mem.Allocator) !void {
        const cwd = std.fs.cwd();

        cwd.makeDir(PROFILES_DIR) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const profile_path = try std.fs.path.join(allocator, &[_][]const u8{ PROFILES_DIR, DEFAULT_PROFILE });
        defer allocator.free(profile_path);

        cwd.access(profile_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                slog.debug("Default profile not found, creating: {s}", .{profile_path});
                try createDefaultProfile(allocator, profile_path);
                slog.info("Created default profile: {s}", .{profile_path});
            },
            else => return err,
        };
    }

    fn createDefaultProfile(allocator: std.mem.Allocator, path: []const u8) !void {
        var defaults = try getDefaultsWithProfile(allocator, DEFAULT_PROFILE);
        defer defaults.deinit();
        try saveToJsonFile(&defaults, allocator, path);
    }

    /// Writes via a temp file + rename so a failed write can't corrupt the profile.
    fn atomicWriteFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
        // Unique per call so overlapping saves of the same profile can't share a temp file.
        const unique = std.crypto.random.int(u64);
        const temp_path = try std.fmt.allocPrint(allocator, "{s}.{x}.tmp", .{ path, unique });
        defer allocator.free(temp_path);

        const temp_file = std.fs.cwd().createFile(temp_path, .{}) catch |err| {
            slog.err("Failed to create temp file '{s}' ({} bytes): {}", .{ temp_path, content.len, err });
            return err;
        };
        defer temp_file.close();

        temp_file.writeAll(content) catch |err| {
            slog.err("Failed to write {} bytes to temp file '{s}': {}", .{ content.len, temp_path, err });
            std.fs.cwd().deleteFile(temp_path) catch |cleanup_err| {
                slog.err("Failed to cleanup temp file '{s}' after write failure (original error: {}): {}", .{ temp_path, err, cleanup_err });
            };
            return err;
        };

        std.fs.cwd().rename(temp_path, path) catch |err| {
            slog.err("Failed to rename temp file '{s}' to '{s}' ({} bytes): {}", .{ temp_path, path, content.len, err });
            std.fs.cwd().deleteFile(temp_path) catch |cleanup_err| {
                slog.err("Failed to cleanup temp file '{s}' after rename failure (original error: {}): {}", .{ temp_path, err, cleanup_err });
            };
            return err;
        };
    }

    /// Caller owns the returned slice.
    pub fn toJsonString(cfg: *const Config, allocator: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const wire = try cfg.toWire(arena.allocator());
        return std.json.Stringify.valueAlloc(allocator, wire, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        });
    }

    pub fn saveToJsonFile(cfg: *const Config, allocator: std.mem.Allocator, path: []const u8) !void {
        const json = try cfg.toJsonString(allocator);
        defer allocator.free(json);

        try atomicWriteFile(allocator, path, json);
        slog.info("Saved JSON config to: {s}", .{path});
    }

    /// A parse failure anywhere in the tree (syntax error or a hard-required field failure, e.g. a character entry missing "name") logs and falls back to defaults for this profile rather than propagating the error.
    fn loadProfileFromJson(allocator: std.mem.Allocator, profile_path: []const u8, profile_name: []const u8) !Config {
        const file = try std.fs.cwd().openFile(profile_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size > MAX_CONFIG_FILE_SIZE) {
            slog.err("Config file '{s}' too large: {} bytes (max: {} bytes)", .{ profile_path, file_size, MAX_CONFIG_FILE_SIZE });
            return error.ConfigFileTooLarge;
        }

        const content = try file.readToEndAlloc(allocator, file_size);
        defer allocator.free(content);

        return buildConfigFromJson(allocator, content, profile_name) catch |err| {
            slog.err("Failed to parse config file '{s}' ({}), falling back to defaults", .{ profile_path, err });
            return getDefaultsWithProfile(allocator, profile_name);
        };
    }

    /// pub: also called directly by config_dialog.zig's saveConfig, which needs the raw parse/validate error surfaced so a malformed save can be rejected instead of overwriting the profile with defaults.
    pub fn buildConfigFromJson(allocator: std.mem.Allocator, json_text: []const u8, profile_name: []const u8) !Config {
        const parsed_value = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed_value.deinit();

        const parsed_wire = try std.json.parseFromValue(Config.Wire, allocator, parsed_value.value, .{ .ignore_unknown_fields = true });
        defer parsed_wire.deinit();

        var config = try Config.fromWire(parsed_wire.value, allocator, profile_name);
        config.validate();
        return config;
    }

    // The helpers below aren't used by the load/save path above (which goes through Config.Wire); they're kept for main.zig's live thumbnail-preview IPC path, which parses partial JSON *fragments* that Config.Wire can't handle since it requires a complete, valid profile.

    /// Merge only the fields present in `obj` into `thumb`, leaving the rest untouched; pub since main.zig also calls it directly to apply an in-memory, unsaved thumbnail appearance patch from the config dialog's live preview (see PROTOCOL_PREVIEW_THUMBNAIL).
    pub fn parseJsonThumbnailConfig(thumb: *ThumbnailConfig, obj: std.json.ObjectMap, allocator: std.mem.Allocator) !void {
        if (obj.get("width")) |v| {
            if (v == .integer) thumb.width = std.math.cast(i32, v.integer) orelse thumb.width;
        }
        if (obj.get("height")) |v| {
            if (v == .integer) thumb.height = std.math.cast(i32, v.integer) orelse thumb.height;
        }
        if (obj.get("showBorderWhenFocused")) |v| {
            if (v == .bool) thumb.showBorderWhenFocused = v.bool;
        }
        if (obj.get("borderWidth")) |v| {
            if (v == .integer) {
                if (std.math.cast(u8, v.integer)) |val| thumb.borderWidth = val;
            }
        }
        if (obj.get("borderColor")) |v| {
            if (v == .string) thumb.borderColor = try parseHexColor(v.string);
        }
        if (obj.get("borderStyle")) |v| {
            if (v == .string) {
                thumb.borderStyle = std.meta.stringToEnum(types.BorderStyle, v.string) orelse .Solid;
            }
        }
        if (obj.get("showBorderWhenInactive")) |v| {
            if (v == .bool) thumb.showBorderWhenInactive = v.bool;
        }
        if (obj.get("inactiveBorderWidth")) |v| {
            if (v == .integer) {
                if (std.math.cast(u8, v.integer)) |val| thumb.inactiveBorderWidth = val;
            }
        }
        if (obj.get("inactiveBorderColor")) |v| {
            if (v == .string) thumb.inactiveBorderColor = try parseHexColor(v.string);
        }
        if (obj.get("inactiveBorderStyle")) |v| {
            if (v == .string) {
                thumb.inactiveBorderStyle = std.meta.stringToEnum(types.BorderStyle, v.string) orelse .Solid;
            }
        }
        if (obj.get("showText")) |v| {
            if (v == .bool) thumb.showText = v.bool;
        }
        if (obj.get("showCharacterName")) |v| {
            if (v == .bool) thumb.showCharacterName = v.bool;
        }
        if (obj.get("showSystemName")) |v| {
            if (v == .bool) thumb.showSystemName = v.bool;
        }
        if (obj.get("textColor")) |v| {
            if (v == .string) thumb.textColor = try parseHexColor(v.string);
        }
        if (obj.get("useUniqueCharacterNameColors")) |v| {
            if (v == .bool) thumb.useUniqueCharacterNameColors = v.bool;
        }
        if (obj.get("textBgColor")) |v| {
            if (v == .string) thumb.textBgColor = try parseHexColor(v.string);
        }
        if (obj.get("textBgColorInheritBorderColor")) |v| {
            if (v == .bool) thumb.textBgColorInheritBorderColor = v.bool;
        }
        if (obj.get("textFontName")) |v| {
            if (v == .string) {
                const old_font = thumb.textFontName;
                thumb.textFontName = try allocator.dupe(u8, v.string);
                if (old_font.ptr != DEFAULT_FONT_NAME.ptr) {
                    allocator.free(old_font);
                }
            }
        }
        if (obj.get("textFontSize")) |v| {
            if (v == .integer) thumb.textFontSize = std.math.cast(i32, v.integer) orelse thumb.textFontSize;
        }
        if (obj.get("textFontWeight")) |v| {
            if (v == .string) {
                thumb.textFontWeight = std.meta.stringToEnum(types.FontWeight, v.string) orelse .Regular;
            }
        }
        if (obj.get("useUniqueSystemColors")) |v| {
            if (v == .bool) thumb.useUniqueSystemColors = v.bool;
        }
        if (obj.get("systemNameColor")) |v| {
            if (v == .string) thumb.systemNameColor = try parseHexColor(v.string);
        }
        if (obj.get("thumbnailOpacity")) |v| {
            if (v == .integer) {
                if (std.math.cast(u8, v.integer)) |val| thumb.thumbnailOpacity = val;
            }
        }
        if (obj.get("applyOpacityToOverlayTexts")) |v| {
            if (v == .bool) thumb.applyOpacityToOverlayTexts = v.bool;
        }
        if (obj.get("activeThumbnailHidden")) |v| {
            if (v == .bool) thumb.activeThumbnailHidden = v.bool;
        }
        if (obj.get("hideWhenNoEveFocus")) |v| {
            if (v == .bool) thumb.hideWhenNoEveFocus = v.bool;
        }
        if (obj.get("hideDebounceMs")) |v| {
            if (v == .integer) thumb.hideDebounceMs = std.math.cast(u32, v.integer) orelse thumb.hideDebounceMs;
        }

        if (obj.get("characterNamePosition")) |v| {
            if (v == .string) {
                thumb.characterNamePosition = std.meta.stringToEnum(types.TextPosition, v.string) orelse .TopLeft;
            }
        }
        if (obj.get("systemNamePosition")) |v| {
            if (v == .string) {
                thumb.systemNamePosition = std.meta.stringToEnum(types.TextPosition, v.string) orelse .BottomLeft;
            }
        }

        if (obj.get("characterNameOffsetX")) |v| {
            if (v == .integer) thumb.characterNameOffsetX = std.math.cast(i32, v.integer) orelse thumb.characterNameOffsetX;
        }
        if (obj.get("characterNameOffsetY")) |v| {
            if (v == .integer) thumb.characterNameOffsetY = std.math.cast(i32, v.integer) orelse thumb.characterNameOffsetY;
        }
        if (obj.get("systemNameOffsetX")) |v| {
            if (v == .integer) thumb.systemNameOffsetX = std.math.cast(i32, v.integer) orelse thumb.systemNameOffsetX;
        }
        if (obj.get("systemNameOffsetY")) |v| {
            if (v == .integer) thumb.systemNameOffsetY = std.math.cast(i32, v.integer) orelse thumb.systemNameOffsetY;
        }

        if (obj.get("showQuickGroupBadge")) |v| {
            if (v == .bool) thumb.showQuickGroupBadge = v.bool;
        }
        if (obj.get("quickGroupBadgeColor")) |v| {
            if (v == .string) thumb.quickGroupBadgeColor = try parseHexColor(v.string);
        }
        if (obj.get("quickGroupBadgePosition")) |v| {
            if (v == .string) {
                thumb.quickGroupBadgePosition = std.meta.stringToEnum(types.TextPosition, v.string) orelse .RightCenter;
            }
        }
        if (obj.get("quickGroupBadgeOffsetX")) |v| {
            if (v == .integer) thumb.quickGroupBadgeOffsetX = std.math.cast(i32, v.integer) orelse thumb.quickGroupBadgeOffsetX;
        }
        if (obj.get("quickGroupBadgeOffsetY")) |v| {
            if (v == .integer) thumb.quickGroupBadgeOffsetY = std.math.cast(i32, v.integer) orelse thumb.quickGroupBadgeOffsetY;
        }
        if (obj.get("exclusionOverlayStyle")) |v| {
            if (v == .string) {
                thumb.exclusionOverlayStyle = std.meta.stringToEnum(types.ExclusionOverlayStyle, v.string) orelse .X;
            }
        }
        if (obj.get("exclusionOverlayColor")) |v| {
            if (v == .string) thumb.exclusionOverlayColor = try parseHexColor(v.string);
        }

        if (obj.get("notifications")) |notif_val| {
            if (notif_val == .object) {
                try parseJsonNotificationConfig(&thumb.notifications, notif_val.object);
            }
        }
    }

    fn parseJsonNotificationConfig(notif: *NotificationConfig, obj: std.json.ObjectMap) !void {
        if (obj.get("enabled")) |v| {
            if (v == .bool) notif.enabled = v.bool;
        }
        if (obj.get("position")) |v| {
            if (v == .string) {
                notif.position = std.meta.stringToEnum(types.TextPosition, v.string) orelse .Center;
            }
        }
        if (obj.get("offset_x")) |v| {
            if (v == .integer) notif.offset_x = std.math.cast(i32, v.integer) orelse notif.offset_x;
        }
        if (obj.get("offset_y")) |v| {
            if (v == .integer) notif.offset_y = std.math.cast(i32, v.integer) orelse notif.offset_y;
        }
        if (obj.get("suppress_click_duration_ms")) |v| {
            if (v == .integer) notif.suppress_click_duration_ms = std.math.cast(u32, v.integer) orelse notif.suppress_click_duration_ms;
        }
        if (obj.get("tts_enabled")) |v| {
            if (v == .bool) notif.tts_enabled = v.bool;
        }
        if (obj.get("tts_volume")) |v| {
            if (v == .integer) {
                if (std.math.cast(u8, v.integer)) |val| notif.tts_volume = val;
            }
        }
        if (obj.get("tts_rate")) |v| {
            if (v == .integer) {
                if (std.math.cast(i8, v.integer)) |val| notif.tts_rate = val;
            }
        }
        if (obj.get("tts_speak_character_name")) |v| {
            if (v == .bool) notif.tts_speak_character_name = v.bool;
        }
        if (obj.get("tts_use_display_name")) |v| {
            if (v == .bool) notif.tts_use_display_name = v.bool;
        }
        if (obj.get("notified_cycle_retention_seconds")) |v| {
            if (v == .integer) notif.notified_cycle_retention_seconds = std.math.cast(u32, v.integer) orelse notif.notified_cycle_retention_seconds;
        }

        if (obj.get("type_configs")) |type_configs_val| {
            if (type_configs_val == .object) {
                inline for (std.meta.fields(types.NotificationType)) |field| {
                    if (type_configs_val.object.get(field.name)) |type_val| {
                        if (type_val == .object) {
                            const ntype = @field(types.NotificationType, field.name);
                            var type_config = notif.type_configs.get(ntype);

                            if (type_val.object.get("enabled")) |v| {
                                if (v == .bool) type_config.enabled = v.bool;
                            }
                            if (type_val.object.get("duration_ms")) |v| {
                                if (v == .integer) type_config.duration_ms = std.math.cast(u32, v.integer) orelse type_config.duration_ms;
                            }
                            if (type_val.object.get("suppress_when_focused")) |v| {
                                if (v == .bool) type_config.suppress_when_focused = v.bool;
                            }
                            if (type_val.object.get("suppress_when_clicked")) |v| {
                                if (v == .bool) type_config.suppress_when_clicked = v.bool;
                            }
                            if (type_val.object.get("throttle_ms")) |v| {
                                if (v == .integer) type_config.throttle_ms = std.math.cast(u32, v.integer) orelse type_config.throttle_ms;
                            }
                            if (type_val.object.get("tts_enabled")) |v| {
                                if (v == .bool) type_config.tts_enabled = v.bool;
                            }
                            if (type_val.object.get("show_border")) |v| {
                                if (v == .bool) type_config.show_border = v.bool;
                            }
                            if (type_val.object.get("flash_border")) |v| {
                                if (v == .bool) type_config.flash_border = v.bool;
                            }
                            if (type_val.object.get("border_color")) |v| {
                                if (v == .string) {
                                    type_config.border_color = try parseHexColor(v.string);
                                } else if (v == .null) {
                                    type_config.border_color = null;
                                }
                            }
                            if (type_val.object.get("text_color")) |v| {
                                if (v == .string) {
                                    type_config.text_color = try parseHexColor(v.string);
                                } else if (v == .null) {
                                    type_config.text_color = null;
                                }
                            }

                            notif.type_configs.set(ntype, type_config);
                        }
                    }
                }
            }
        }
    }

    pub fn parseJsonDisplayConfig(display: *DisplayConfig, obj: std.json.ObjectMap, allocator: std.mem.Allocator) !void {
        if (obj.get("startX")) |v| {
            if (v == .integer) display.startX = std.math.cast(i32, v.integer) orelse display.startX;
        }
        if (obj.get("startY")) |v| {
            if (v == .integer) display.startY = std.math.cast(i32, v.integer) orelse display.startY;
        }
        if (obj.get("spacing")) |v| {
            if (v == .integer) display.spacing = std.math.cast(i32, v.integer) orelse display.spacing;
        }
        if (obj.get("layoutMode")) |v| {
            if (v == .string) {
                if (std.meta.stringToEnum(types.LayoutMode, v.string)) |mode| {
                    display.layoutMode = mode;
                }
            }
        }
        if (obj.get("layoutDirection")) |v| {
            if (v == .string) {
                if (std.meta.stringToEnum(types.LayoutDirection, v.string)) |dir| {
                    display.layoutDirection = dir;
                }
            }
        }
        if (obj.get("gridColumns")) |v| {
            if (v == .integer) {
                if (std.math.cast(u32, v.integer)) |val| display.gridColumns = val;
            }
        }
        if (obj.get("gridRows")) |v| {
            if (v == .integer) {
                if (std.math.cast(u32, v.integer)) |val| display.gridRows = val;
            } else if (v == .null) {
                display.gridRows = null;
            }
        }
        if (obj.get("stackOffset")) |v| {
            if (v == .integer) display.stackOffset = std.math.cast(i32, v.integer) orelse display.stackOffset;
        }
        if (obj.get("stackAlignment")) |v| {
            if (v == .string) {
                if (std.meta.stringToEnum(types.TextPosition, v.string)) |alignment| {
                    display.stackAlignment = alignment;
                }
            }
        }
        if (obj.get("spacingX")) |v| {
            if (v == .integer) {
                display.spacingX = std.math.cast(i32, v.integer) orelse display.spacingX;
            } else if (v == .null) {
                display.spacingX = null;
            }
        }
        if (obj.get("spacingY")) |v| {
            if (v == .integer) {
                display.spacingY = std.math.cast(i32, v.integer) orelse display.spacingY;
            } else if (v == .null) {
                display.spacingY = null;
            }
        }
        if (obj.get("monitorIndex")) |v| {
            if (v == .integer) {
                if (std.math.cast(u32, v.integer)) |val| display.monitorIndex = val;
            } else if (v == .null) {
                display.monitorIndex = null;
            }
        }
        if (obj.get("useMonitorWorkArea")) |v| {
            if (v == .bool) display.useMonitorWorkArea = v.bool;
        }
        if (obj.get("honorSavedPositions")) |v| {
            if (v == .bool) display.honorSavedPositions = v.bool;
        }
        if (obj.get("viewMode")) |v| {
            if (v == .string) {
                if (std.meta.stringToEnum(types.ViewMode, v.string)) |mode| {
                    display.viewMode = mode;
                }
            }
        }
        if (obj.get("listViewOrder")) |v| {
            if (v == .string) {
                if (std.meta.stringToEnum(types.ListViewOrder, v.string)) |order| {
                    display.listViewOrder = order;
                }
            }
        }
        if (obj.get("rememberListViewPosition")) |v| {
            if (v == .bool) display.rememberListViewPosition = v.bool;
        }
        if (obj.get("listViewOpacity")) |v| {
            if (v == .integer) {
                if (std.math.cast(u8, v.integer)) |val| display.listViewOpacity = val;
            }
        }
        if (obj.get("listViewColumns")) |v| {
            if (v == .integer) {
                if (std.math.cast(u32, v.integer)) |val| display.listViewColumns = val;
            }
        }
        if (obj.get("listViewFontName")) |v| {
            if (v == .string) {
                const old_font = display.listViewFontName;
                display.listViewFontName = try allocator.dupe(u8, v.string);
                if (old_font.ptr != DEFAULT_FONT_NAME.ptr) {
                    allocator.free(old_font);
                }
            }
        }
        if (obj.get("listViewFontSize")) |v| {
            if (v == .integer) display.listViewFontSize = std.math.cast(i32, v.integer) orelse display.listViewFontSize;
        }
        if (obj.get("listViewFontWeight")) |v| {
            if (v == .string) {
                display.listViewFontWeight = std.meta.stringToEnum(types.FontWeight, v.string) orelse .Regular;
            }
        }
    }

    /// CharacterConfig.thumbnailSize isn't covered by ThumbnailConfig.validate(), and std.math.cast at the JSON parse site only rejects values too large for i32, not e.g. -5, which would still panic when narrowed to usize downstream — this closes that gap.
    fn clampCharacterThumbnailSize(size: *CharacterThumbnailSize) void {
        if (size.width) |*w| w.* = std.math.clamp(w.*, ThumbnailConfig.WIDTH_MIN, ThumbnailConfig.WIDTH_MAX);
        if (size.height) |*h| h.* = std.math.clamp(h.*, ThumbnailConfig.HEIGHT_MIN, ThumbnailConfig.HEIGHT_MAX);
    }

    pub fn parseJsonSystemColor(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !SystemColor {
        const name_val = obj.get("systemName") orelse return error.MissingSystemName;
        const color_val = obj.get("color") orelse return error.MissingSystemColor;

        if (name_val != .string or color_val != .string) {
            return error.InvalidSystemColor;
        }

        return SystemColor{
            .name = try allocator.dupe(u8, name_val.string),
            .color = try parseHexColor(color_val.string),
        };
    }

    /// Accepts 0xRRGGBB, 0xAARRGGBB, #RRGGBB, or RRGGBB.
    fn parseHexColor(str: []const u8) !u32 {
        if (str.len < 3) return error.InvalidColorFormat;

        const start: usize = if (std.mem.startsWith(u8, str, "0x") or std.mem.startsWith(u8, str, "0X"))
            2
        else if (std.mem.startsWith(u8, str, "#"))
            1
        else
            0;
        const hex_str = str[start..];

        return std.fmt.parseInt(u32, hex_str, 16) catch error.InvalidColorFormat;
    }

    pub fn loadProfile(allocator: std.mem.Allocator, profile_name: []const u8) !Config {
        try ensureProfilesDir(allocator);

        const profile_path = try std.fs.path.join(allocator, &[_][]const u8{ PROFILES_DIR, profile_name });
        defer allocator.free(profile_path);

        slog.info("Loading JSON config from: {s}", .{profile_path});
        return loadProfileFromJson(allocator, profile_path, profile_name);
    }

    pub fn load(allocator: std.mem.Allocator) !Config {
        return loadProfile(allocator, DEFAULT_PROFILE);
    }

    const windows = std.os.windows;

    const FOLDERID_Documents = windows.GUID{
        .Data1 = 0xFDD39AD0,
        .Data2 = 0x238F,
        .Data3 = 0x46AF,
        .Data4 = [8]u8{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 },
    };

    extern "shell32" fn SHGetKnownFolderPath(
        rfid: *const windows.GUID,
        dwFlags: u32,
        hToken: ?windows.HANDLE,
        ppszPath: *?[*:0]u16,
    ) callconv(.c) c_long;

    extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.c) void;

    /// Resolves the real Documents folder via the shell known-folder API rather than assuming `%USERPROFILE%/Documents`, since OneDrive's Known Folder Move can silently redirect it and EVE itself writes logs to wherever this API resolves.
    fn getDocumentsDir(allocator: std.mem.Allocator) ![]u8 {
        var path_ptr: ?[*:0]u16 = null;
        const hr = SHGetKnownFolderPath(&FOLDERID_Documents, 0, null, &path_ptr);
        if (hr < 0 or path_ptr == null) return error.KnownFolderUnavailable;
        defer CoTaskMemFree(path_ptr);

        const path_utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(path_ptr.?));
        for (path_utf8) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        return path_utf8;
    }

    /// Not a comptime constant since it depends on runtime shell/env state, so it can't be a plain struct field default; used by both getDefaultsWithProfile and Config.fromWire's chatlog-section-missing fallback.
    fn defaultLogDirs(allocator: std.mem.Allocator) !struct { chatlog: []u8, gamelog: []u8 } {
        const documents_dir = getDocumentsDir(allocator) catch blk: {
            slog.warn("Failed to resolve Documents known folder, falling back to USERPROFILE/Documents", .{});
            const userprofile = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| {
                slog.warn("Failed to get USERPROFILE env var: {}", .{err});
                return error.MissingEnvironmentVariable;
            };
            defer allocator.free(userprofile);
            for (userprofile) |*c| {
                if (c.* == '\\') c.* = '/';
            }
            break :blk try std.fmt.allocPrint(allocator, "{s}/Documents", .{userprofile});
        };
        defer allocator.free(documents_dir);

        return .{
            .chatlog = try std.fmt.allocPrint(allocator, "{s}/EVE/logs/Chatlogs", .{documents_dir}),
            .gamelog = try std.fmt.allocPrint(allocator, "{s}/EVE/logs/Gamelogs", .{documents_dir}),
        };
    }

    pub fn getDefaultsWithProfile(allocator: std.mem.Allocator, profile_name: []const u8) !Config {
        const log_dirs = try defaultLogDirs(allocator);

        var default_filters = std.ArrayList(WindowFilter).empty;
        const eve_class_names = try allocator.alloc([]const u8, WindowFilter.DEFAULT.class_names.len);
        for (WindowFilter.DEFAULT.class_names, 0..) |cn, i| eve_class_names[i] = try allocator.dupe(u8, cn);
        const eve_exe_names = try allocator.alloc([]const u8, WindowFilter.DEFAULT.executable_names.len);
        for (WindowFilter.DEFAULT.executable_names, 0..) |en, i| eve_exe_names[i] = try allocator.dupe(u8, en);
        try default_filters.append(allocator, .{
            .name = try allocator.dupe(u8, WindowFilter.DEFAULT.name),
            .class_names = eve_class_names,
            .executable_names = eve_exe_names,
            .enabled = WindowFilter.DEFAULT.enabled,
        });

        return Config{
            .allocator = allocator,
            .profile_name = try allocator.dupe(u8, profile_name),
            .thumbnail = .{},
            .timer = .{},
            .display = .{},
            .snapping = .{},
            .interaction = .{},
            .autoMinimize = .{},
            .autoMovePosition = .{},
            .exclusion = .{},
            .closeAll = .{},
            .chatlog = .{
                .chatlogDir = log_dirs.chatlog,
                .gamelogDir = log_dirs.gamelog,
            },
            .combat = .{},
            .mining = .{},
            .windowFilters = default_filters,
            .characters = std.ArrayList(CharacterConfig).empty,
            .systemColors = std.ArrayList(SystemColor).empty,
            .generatedColorCache = std.StringHashMap(u32).init(allocator),
            .generatedCharacterColorCache = std.StringHashMap(u32).init(allocator),
            .hotkeyGroups = std.ArrayList(HotkeyGroup).empty,
            .quickGroups = std.ArrayList(QuickGroup).empty,
            .autoRegisterProtocol = false,
            .hotkeyMinimizeAll = null,
            .hotkeyCloseAll = null,
            .hotkeyToggleVisibility = null,
            .hotkeyToggleAutoMinimize = null,
            .hotkeyToggleExclusion = null,
            .hotkeyNextExcluded = null,
            .hotkeyPreviousExcluded = null,
            .hotkeySuspend = null,
            .hotkeyCycleNotified = null,
            .hotkeyPreviousNotified = null,
            .hotkeyMoveToSavedPositions = null,
        };
    }

    pub fn findCharacter(self: *Config, name: []const u8) ?*CharacterConfig {
        for (self.characters.items) |*char| {
            if (std.mem.eql(u8, char.name, name)) {
                return char;
            }
        }
        return null;
    }

    pub fn findCharacterConst(self: *const Config, name: []const u8) ?*const CharacterConfig {
        for (self.characters.items) |*char| {
            if (std.mem.eql(u8, char.name, name)) {
                return char;
            }
        }
        return null;
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

    pub fn findSystemColor(self: *const Config, name: []const u8) ?u32 {
        for (self.systemColors.items) |*sc| {
            if (std.mem.eql(u8, sc.name, name)) {
                return sc.color;
            }
        }
        return null;
    }

    pub fn getCharacterPosition(self: *const Config, character_name: []const u8) ?Position {
        if (self.findCharacterConst(character_name)) |char| {
            return char.position;
        }
        return null;
    }

    pub fn getCharacterWindowPosition(self: *const Config, character_name: []const u8) ?Position {
        if (self.findCharacterConst(character_name)) |char| {
            return char.windowPosition;
        }
        return null;
    }

    pub fn getCharacterBorderColors(self: *const Config, character_name: []const u8) ?CharacterBorderColors {
        if (self.findCharacterConst(character_name)) |char| {
            return char.borderColors;
        }
        return null;
    }

    pub fn getCharacterSize(self: *const Config, character_name: []const u8) ?CharacterThumbnailSize {
        if (self.findCharacterConst(character_name)) |char| {
            return char.thumbnailSize;
        }
        return null;
    }

    pub fn isExcludedFromMinimize(self: *const Config, character_name: []const u8) bool {
        if (self.findCharacterConst(character_name)) |char| {
            return char.excludeFromMinimize;
        }
        return false;
    }

    pub fn isExcludedFromCloseAll(self: *const Config, character_name: []const u8) bool {
        if (self.findCharacterConst(character_name)) |char| {
            return char.excludeFromCloseAll;
        }
        return false;
    }

    pub fn isThumbnailHidden(self: *const Config, character_name: []const u8) bool {
        if (self.findCharacterConst(character_name)) |char| {
            return char.hideThumbnail;
        }
        return false;
    }

    pub fn getDisplayName(self: *const Config, character_name: []const u8) []const u8 {
        if (self.findCharacterConst(character_name)) |char| {
            if (char.displayName) |dn| {
                return dn;
            }
        }
        return character_name;
    }

    /// Snapshot of every color already generated in `cache`, so a new color can be checked against the full active set instead of a small recency window; caller owns the returned slice and must free it with `allocator`.
    fn collectCachedColors(allocator: std.mem.Allocator, cache: *const std.StringHashMap(u32)) ![]const u32 {
        const colors = try allocator.alloc(u32, cache.count());
        var it = cache.valueIterator();
        var i: usize = 0;
        while (it.next()) |value| : (i += 1) {
            colors[i] = value.*;
        }
        return colors;
    }

    /// Priority: custom color override, then unique generated color, then default.
    pub fn getSystemNameColor(self: *Config, system_name: []const u8) u32 {
        if (self.findSystemColor(system_name)) |custom_color| {
            return custom_color;
        }

        if (self.thumbnail.useUniqueSystemColors) {
            const allocator = self.generatedColorCache.allocator;

            if (self.generatedColorCache.get(system_name)) |cached_color| {
                return cached_color;
            }

            const similarity_threshold: f32 = 0.35;
            const existing_colors = collectCachedColors(allocator, &self.generatedColorCache) catch |err| blk: {
                slog.warn("Failed to snapshot existing system colors: {}", .{err});
                break :blk &[_]u32{};
            };
            defer allocator.free(existing_colors);

            const generated_color = color.generateUniqueColorWithAvoidance(
                system_name,
                existing_colors,
                similarity_threshold,
            );

            const gop = self.generatedColorCache.getOrPut(system_name) catch |err| {
                slog.err("Failed to cache color for system '{s}': {}", .{ system_name, err });
                return generated_color;
            };

            if (!gop.found_existing) {
                const name_copy = allocator.dupe(u8, system_name) catch |err| {
                    slog.err("Failed to allocate key for system '{s}': {}", .{ system_name, err });
                    _ = self.generatedColorCache.remove(system_name);
                    return generated_color;
                };
                gop.key_ptr.* = name_copy;
                gop.value_ptr.* = generated_color;
            }

            return gop.value_ptr.*;
        }

        return self.thumbnail.systemNameColor;
    }

    /// Priority: manual per-character override, then auto-generated unique color (if enabled), else null; unlike getSystemNameColor, there's no dedicated default-color field here, so callers fall back to their own existing default when this returns null.
    pub fn getCharacterNameColor(self: *Config, character_name: []const u8) ?u32 {
        if (self.findCharacterConst(character_name)) |char| {
            if (char.nameColor) |custom_color| return custom_color;
        }

        if (!self.thumbnail.useUniqueCharacterNameColors) return null;

        const allocator = self.generatedCharacterColorCache.allocator;

        if (self.generatedCharacterColorCache.get(character_name)) |cached_color| {
            return cached_color;
        }

        const similarity_threshold: f32 = 0.35;
        const existing_colors = collectCachedColors(allocator, &self.generatedCharacterColorCache) catch |err| blk: {
            slog.warn("Failed to snapshot existing character colors: {}", .{err});
            break :blk &[_]u32{};
        };
        defer allocator.free(existing_colors);

        const generated_color = color.generateUniqueColorWithAvoidance(
            character_name,
            existing_colors,
            similarity_threshold,
        );

        const gop = self.generatedCharacterColorCache.getOrPut(character_name) catch |err| {
            slog.err("Failed to cache color for character '{s}': {}", .{ character_name, err });
            return generated_color;
        };

        if (!gop.found_existing) {
            const name_copy = allocator.dupe(u8, character_name) catch |err| {
                slog.err("Failed to allocate key for character '{s}': {}", .{ character_name, err });
                _ = self.generatedCharacterColorCache.remove(character_name);
                return generated_color;
            };
            gop.key_ptr.* = name_copy;
            gop.value_ptr.* = generated_color;
        }

        return gop.value_ptr.*;
    }

    pub fn validate(self: *Config) void {
        self.thumbnail.validate();
        self.timer.validate();
        self.display.validate();
        self.snapping.validate();
        self.autoMinimize.validate();
        self.chatlog.validate();
        self.combat.validate();
        self.mining.validate();

        // Per-character thumbnail size overrides live on CharacterConfig, not ThumbnailConfig, so they bypass validate() above and need clamping here too.
        for (self.characters.items) |*char| {
            if (char.thumbnailSize) |*size| clampCharacterThumbnailSize(size);
        }
    }

    /// Serializes every clamp bound the validate() functions above enforce, keyed by the same dotted config path config_dialog.js's CONFIG_SCHEMA uses, so the dialog can set matching HTML min/max without those bounds being hand-copied into JS.
    pub fn buildValidationRangesJson(allocator: std.mem.Allocator) ![]u8 {
        const Range = struct { min: i64, max: i64 };
        const ranges = .{
            .@"timer.scanIntervalMs" = Range{ .min = TimerConfig.SCAN_INTERVAL_MS_MIN, .max = TimerConfig.SCAN_INTERVAL_MS_MAX },

            .@"thumbnail.width" = Range{ .min = ThumbnailConfig.WIDTH_MIN, .max = ThumbnailConfig.WIDTH_MAX },
            .@"thumbnail.height" = Range{ .min = ThumbnailConfig.HEIGHT_MIN, .max = ThumbnailConfig.HEIGHT_MAX },
            .@"thumbnail.borderWidth" = Range{ .min = ThumbnailConfig.BORDER_WIDTH_MIN, .max = ThumbnailConfig.BORDER_WIDTH_MAX },
            .@"thumbnail.inactiveBorderWidth" = Range{ .min = ThumbnailConfig.BORDER_WIDTH_MIN, .max = ThumbnailConfig.BORDER_WIDTH_MAX },
            .@"thumbnail.textFontSize" = Range{ .min = ThumbnailConfig.FONT_SIZE_MIN, .max = ThumbnailConfig.FONT_SIZE_MAX },
            .@"thumbnail.characterNameOffsetX" = Range{ .min = ThumbnailConfig.OFFSET_MIN, .max = ThumbnailConfig.OFFSET_MAX },
            .@"thumbnail.characterNameOffsetY" = Range{ .min = ThumbnailConfig.OFFSET_MIN, .max = ThumbnailConfig.OFFSET_MAX },
            .@"thumbnail.systemNameOffsetX" = Range{ .min = ThumbnailConfig.OFFSET_MIN, .max = ThumbnailConfig.OFFSET_MAX },
            .@"thumbnail.systemNameOffsetY" = Range{ .min = ThumbnailConfig.OFFSET_MIN, .max = ThumbnailConfig.OFFSET_MAX },
            .@"thumbnail.quickGroupBadgeOffsetX" = Range{ .min = ThumbnailConfig.OFFSET_MIN, .max = ThumbnailConfig.OFFSET_MAX },
            .@"thumbnail.quickGroupBadgeOffsetY" = Range{ .min = ThumbnailConfig.OFFSET_MIN, .max = ThumbnailConfig.OFFSET_MAX },
            .@"thumbnail.hideDebounceMs" = Range{ .min = 0, .max = ThumbnailConfig.HIDE_DEBOUNCE_MS_MAX },
            .@"thumbnail.notifications.offset_x" = Range{ .min = ThumbnailConfig.OFFSET_MIN, .max = ThumbnailConfig.OFFSET_MAX },
            .@"thumbnail.notifications.offset_y" = Range{ .min = ThumbnailConfig.OFFSET_MIN, .max = ThumbnailConfig.OFFSET_MAX },
            .@"thumbnail.notifications.tts_volume" = Range{ .min = 0, .max = ThumbnailConfig.TTS_VOLUME_MAX },
            .@"thumbnail.notifications.tts_rate" = Range{ .min = ThumbnailConfig.TTS_RATE_MIN, .max = ThumbnailConfig.TTS_RATE_MAX },
            .@"thumbnail.notifications.notified_cycle_retention_seconds" = Range{ .min = ThumbnailConfig.CYCLE_RETENTION_MIN, .max = ThumbnailConfig.CYCLE_RETENTION_MAX },
            .@"thumbnail.notifications.suppress_click_duration_ms" = Range{ .min = 0, .max = ThumbnailConfig.SUPPRESS_CLICK_DURATION_MS_MAX },

            .@"display.spacing" = Range{ .min = DisplayConfig.SPACING_MIN, .max = DisplayConfig.SPACING_MAX },
            .@"display.spacingX" = Range{ .min = DisplayConfig.SPACING_MIN, .max = DisplayConfig.SPACING_MAX },
            .@"display.spacingY" = Range{ .min = DisplayConfig.SPACING_MIN, .max = DisplayConfig.SPACING_MAX },
            .@"display.gridColumns" = Range{ .min = DisplayConfig.GRID_COLUMNS_MIN, .max = DisplayConfig.GRID_COLUMNS_MAX },
            .@"display.gridRows" = Range{ .min = DisplayConfig.GRID_ROWS_MIN, .max = DisplayConfig.GRID_ROWS_MAX },
            .@"display.stackOffset" = Range{ .min = DisplayConfig.STACK_OFFSET_MIN, .max = DisplayConfig.STACK_OFFSET_MAX },
            .@"display.monitorIndex" = Range{ .min = 0, .max = DisplayConfig.MONITOR_INDEX_MAX },
            .@"display.listViewColumns" = Range{ .min = DisplayConfig.LIST_VIEW_COLUMNS_MIN, .max = DisplayConfig.LIST_VIEW_COLUMNS_MAX },
            .@"display.listViewFontSize" = Range{ .min = DisplayConfig.LIST_VIEW_FONT_SIZE_MIN, .max = DisplayConfig.LIST_VIEW_FONT_SIZE_MAX },

            .@"snapping.threshold" = Range{ .min = SnappingConfig.THRESHOLD_MIN, .max = SnappingConfig.THRESHOLD_MAX },

            .@"autoMinimize.delayMs" = Range{ .min = 0, .max = AutoMinimizeConfig.DELAY_MS_MAX },

            .@"chatlog.pollIntervalMs" = Range{ .min = ChatlogConfig.POLL_INTERVAL_MS_MIN, .max = ChatlogConfig.POLL_INTERVAL_MS_MAX },
            .@"chatlog.idlePollThreshold" = Range{ .min = ChatlogConfig.IDLE_POLL_THRESHOLD_MIN, .max = ChatlogConfig.IDLE_POLL_THRESHOLD_MAX },
            .@"chatlog.maxPollMultiplier" = Range{ .min = ChatlogConfig.MAX_POLL_MULTIPLIER_MIN, .max = ChatlogConfig.MAX_POLL_MULTIPLIER_MAX },

            .@"combat.window_seconds" = Range{ .min = CombatConfig.WINDOW_SECONDS_MIN, .max = CombatConfig.WINDOW_SECONDS_MAX },
            .@"combat.update_interval_ms" = Range{ .min = CombatConfig.UPDATE_INTERVAL_MS_MIN, .max = CombatConfig.UPDATE_INTERVAL_MS_MAX },
            .@"combat.damage_alert_repeat_seconds" = Range{ .min = CombatConfig.DAMAGE_ALERT_REPEAT_SECONDS_MIN, .max = CombatConfig.DAMAGE_ALERT_REPEAT_SECONDS_MAX },
            .@"combat.font_size" = Range{ .min = CombatConfig.FONT_SIZE_MIN, .max = CombatConfig.FONT_SIZE_MAX },
            .@"combat.icon_font_size" = Range{ .min = CombatConfig.FONT_SIZE_MIN, .max = CombatConfig.FONT_SIZE_MAX },
            .@"combat.incoming_offset_x" = Range{ .min = CombatConfig.OFFSET_MIN, .max = CombatConfig.OFFSET_MAX },
            .@"combat.incoming_offset_y" = Range{ .min = CombatConfig.OFFSET_MIN, .max = CombatConfig.OFFSET_MAX },
            .@"combat.outgoing_offset_x" = Range{ .min = CombatConfig.OFFSET_MIN, .max = CombatConfig.OFFSET_MAX },
            .@"combat.outgoing_offset_y" = Range{ .min = CombatConfig.OFFSET_MIN, .max = CombatConfig.OFFSET_MAX },
            .@"combat.icon_offset_x" = Range{ .min = CombatConfig.OFFSET_MIN, .max = CombatConfig.OFFSET_MAX },
            .@"combat.icon_offset_y" = Range{ .min = CombatConfig.OFFSET_MIN, .max = CombatConfig.OFFSET_MAX },
            .@"combat.incoming_chart.width" = Range{ .min = SparkChartConfig.WIDTH_MIN, .max = SparkChartConfig.WIDTH_MAX },
            .@"combat.incoming_chart.height" = Range{ .min = SparkChartConfig.HEIGHT_MIN, .max = SparkChartConfig.HEIGHT_MAX },
            .@"combat.incoming_chart.offset_x" = Range{ .min = SparkChartConfig.OFFSET_MIN, .max = SparkChartConfig.OFFSET_MAX },
            .@"combat.incoming_chart.offset_y" = Range{ .min = SparkChartConfig.OFFSET_MIN, .max = SparkChartConfig.OFFSET_MAX },
            .@"combat.incoming_chart.bucket_count" = Range{ .min = SparkChartConfig.BUCKET_COUNT_MIN, .max = SparkChartConfig.BUCKET_COUNT_MAX },
            .@"combat.outgoing_chart.width" = Range{ .min = SparkChartConfig.WIDTH_MIN, .max = SparkChartConfig.WIDTH_MAX },
            .@"combat.outgoing_chart.height" = Range{ .min = SparkChartConfig.HEIGHT_MIN, .max = SparkChartConfig.HEIGHT_MAX },
            .@"combat.outgoing_chart.offset_x" = Range{ .min = SparkChartConfig.OFFSET_MIN, .max = SparkChartConfig.OFFSET_MAX },
            .@"combat.outgoing_chart.offset_y" = Range{ .min = SparkChartConfig.OFFSET_MIN, .max = SparkChartConfig.OFFSET_MAX },
            .@"combat.outgoing_chart.bucket_count" = Range{ .min = SparkChartConfig.BUCKET_COUNT_MIN, .max = SparkChartConfig.BUCKET_COUNT_MAX },

            .@"mining.window_seconds" = Range{ .min = MiningConfig.WINDOW_SECONDS_MIN, .max = MiningConfig.WINDOW_SECONDS_MAX },
            .@"mining.update_interval_ms" = Range{ .min = MiningConfig.UPDATE_INTERVAL_MS_MIN, .max = MiningConfig.UPDATE_INTERVAL_MS_MAX },
            .@"mining.font_size" = Range{ .min = MiningConfig.FONT_SIZE_MIN, .max = MiningConfig.FONT_SIZE_MAX },
            .@"mining.idle_alert_window_seconds" = Range{ .min = MiningConfig.ALERT_WINDOW_SECONDS_MIN, .max = MiningConfig.ALERT_WINDOW_SECONDS_MAX },
            .@"mining.stopped_alert_window_seconds" = Range{ .min = MiningConfig.ALERT_WINDOW_SECONDS_MIN, .max = MiningConfig.ALERT_WINDOW_SECONDS_MAX },
            .@"mining.offset_x" = Range{ .min = MiningConfig.OFFSET_MIN, .max = MiningConfig.OFFSET_MAX },
            .@"mining.offset_y" = Range{ .min = MiningConfig.OFFSET_MIN, .max = MiningConfig.OFFSET_MAX },
            .@"mining.idle_alert_threshold" = Range{ .min = MiningConfig.IDLE_ALERT_THRESHOLD_MIN, .max = MiningConfig.IDLE_ALERT_THRESHOLD_MAX },
            .@"mining.chart.width" = Range{ .min = SparkChartConfig.WIDTH_MIN, .max = SparkChartConfig.WIDTH_MAX },
            .@"mining.chart.height" = Range{ .min = SparkChartConfig.HEIGHT_MIN, .max = SparkChartConfig.HEIGHT_MAX },
            .@"mining.chart.offset_x" = Range{ .min = SparkChartConfig.OFFSET_MIN, .max = SparkChartConfig.OFFSET_MAX },
            .@"mining.chart.offset_y" = Range{ .min = SparkChartConfig.OFFSET_MIN, .max = SparkChartConfig.OFFSET_MAX },
            .@"mining.chart.bucket_count" = Range{ .min = SparkChartConfig.BUCKET_COUNT_MIN, .max = SparkChartConfig.BUCKET_COUNT_MAX },
        };

        return std.json.Stringify.valueAlloc(allocator, ranges, .{});
    }

    pub fn deinit(self: *Config) void {
        const allocator = self.allocator;
        allocator.free(self.profile_name);

        for (self.windowFilters.items) |*filter| {
            filter.deinit(allocator);
        }
        self.windowFilters.deinit(allocator);

        // textFontName may still point at the DEFAULT_FONT_NAME literal; only heap-owned copies get freed.
        if (self.thumbnail.textFontName.ptr != DEFAULT_FONT_NAME.ptr) {
            allocator.free(self.thumbnail.textFontName);
        }
        if (self.display.listViewFontName.ptr != DEFAULT_FONT_NAME.ptr) {
            allocator.free(self.display.listViewFontName);
        }

        for (self.characters.items) |*char| {
            char.deinit(allocator);
        }
        self.characters.deinit(allocator);

        for (self.systemColors.items) |*sc| {
            sc.deinit(allocator);
        }
        self.systemColors.deinit(allocator);

        var cache_it = self.generatedColorCache.iterator();
        while (cache_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.generatedColorCache.deinit();

        var char_cache_it = self.generatedCharacterColorCache.iterator();
        while (char_cache_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.generatedCharacterColorCache.deinit();

        for (self.hotkeyGroups.items) |*group| {
            group.deinit();
        }
        self.hotkeyGroups.deinit(allocator);

        for (self.quickGroups.items) |*group| {
            group.deinit();
        }
        self.quickGroups.deinit(allocator);

        self.chatlog.deinit(allocator);
        self.combat.deinit(allocator);
    }

    /// Discard the in-memory thumbnail appearance, layout, and system color overrides, replacing them with a fresh read of this profile from disk, to revert an unsaved live-preview patch (see PROTOCOL_REVERT_PREVIEW); startX/startY are left untouched.
    pub fn reloadThumbnailConfigFromDisk(self: *Config, allocator: std.mem.Allocator) !void {
        var fresh = try loadProfile(allocator, self.profile_name);

        const new_thumb = fresh.thumbnail;
        // Detach the thumbnail we're keeping before fresh.deinit() runs, so its owned textFontName isn't freed out from under new_thumb.
        fresh.thumbnail = ThumbnailConfig{};

        const new_colors = fresh.systemColors;
        fresh.systemColors = .empty;

        // Same detach dance for the List View opacity/font fields, which ride along in the same live-preview patch (see PROTOCOL_PREVIEW_THUMBNAIL).
        const new_list_view_opacity = fresh.display.listViewOpacity;
        const new_list_view_font_name = fresh.display.listViewFontName;
        const new_list_view_font_size = fresh.display.listViewFontSize;
        const new_list_view_font_weight = fresh.display.listViewFontWeight;
        fresh.display.listViewFontName = DEFAULT_FONT_NAME;

        // Grid/stack/list layout fields ride along too, but never startX/startY - those can be live-dragged in the running app.
        const new_spacing = fresh.display.spacing;
        const new_spacing_x = fresh.display.spacingX;
        const new_spacing_y = fresh.display.spacingY;
        const new_layout_mode = fresh.display.layoutMode;
        const new_layout_direction = fresh.display.layoutDirection;
        const new_grid_columns = fresh.display.gridColumns;
        const new_grid_rows = fresh.display.gridRows;
        const new_stack_offset = fresh.display.stackOffset;
        const new_stack_alignment = fresh.display.stackAlignment;
        const new_monitor_index = fresh.display.monitorIndex;
        const new_use_monitor_work_area = fresh.display.useMonitorWorkArea;
        const new_honor_saved_positions = fresh.display.honorSavedPositions;

        // Restore per-character overrides by matching on name; displayName is duped before fresh.deinit() frees it, and characters with no match in `fresh` (created live but never saved) are removed entirely so reverting leaves no residue.
        var char_index: usize = self.characters.items.len;
        while (char_index > 0) {
            char_index -= 1;
            const char = &self.characters.items[char_index];
            if (fresh.findCharacterConst(char.name)) |fresh_char| {
                char.thumbnailSize = fresh_char.thumbnailSize;
                char.borderColors = fresh_char.borderColors;
                char.nameColor = fresh_char.nameColor;
                char.hideThumbnail = fresh_char.hideThumbnail;
                char.position = fresh_char.position;

                const new_display_name = if (fresh_char.displayName) |dn| try allocator.dupe(u8, dn) else null;
                if (char.displayName) |old| allocator.free(old);
                char.displayName = new_display_name;
            } else {
                char.deinit(allocator);
                _ = self.characters.orderedRemove(char_index);
            }
        }

        fresh.deinit();

        if (self.thumbnail.textFontName.ptr != DEFAULT_FONT_NAME.ptr) {
            allocator.free(self.thumbnail.textFontName);
        }
        self.thumbnail = new_thumb;

        for (self.systemColors.items) |*sc| sc.deinit(allocator);
        self.systemColors.deinit(allocator);
        self.systemColors = new_colors;

        if (self.display.listViewFontName.ptr != DEFAULT_FONT_NAME.ptr) {
            allocator.free(self.display.listViewFontName);
        }
        self.display.listViewFontName = new_list_view_font_name;
        self.display.listViewOpacity = new_list_view_opacity;
        self.display.listViewFontSize = new_list_view_font_size;
        self.display.listViewFontWeight = new_list_view_font_weight;

        self.display.spacing = new_spacing;
        self.display.spacingX = new_spacing_x;
        self.display.spacingY = new_spacing_y;
        self.display.layoutMode = new_layout_mode;
        self.display.layoutDirection = new_layout_direction;
        self.display.gridColumns = new_grid_columns;
        self.display.gridRows = new_grid_rows;
        self.display.stackOffset = new_stack_offset;
        self.display.stackAlignment = new_stack_alignment;
        self.display.monitorIndex = new_monitor_index;
        self.display.useMonitorWorkArea = new_use_monitor_work_area;
        self.display.honorSavedPositions = new_honor_saved_positions;
    }

    /// Replace the system color override list from a JSON array of {systemName, color} objects, freeing the old entries only after the new list parses successfully.
    pub fn replaceSystemColorsFromJson(self: *Config, allocator: std.mem.Allocator, colors_array: []const std.json.Value) !void {
        var new_list: std.ArrayList(SystemColor) = .empty;
        errdefer {
            for (new_list.items) |*sc| sc.deinit(allocator);
            new_list.deinit(allocator);
        }
        for (colors_array) |color_val| {
            if (color_val != .object) continue;
            const sc = try parseJsonSystemColor(allocator, color_val.object);
            try new_list.append(allocator, sc);
        }

        for (self.systemColors.items) |*sc| sc.deinit(allocator);
        self.systemColors.deinit(allocator);
        self.systemColors = new_list;
    }

    /// Apply per-character border-color/name-color/thumbnail-size/display-name/hidden/position overrides from a JSON array, matched against existing characters by name; uses getOrCreateCharacter rather than a plain lookup so an unsaved "Populate from Open Clients" character still gets a live entry to preview against, which reloadThumbnailConfigFromDisk() removes again on revert if it never got saved.
    pub fn applyCharacterOverridesFromJson(self: *Config, allocator: std.mem.Allocator, overrides_array: []const std.json.Value) !void {
        for (overrides_array) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const name_val = obj.get("name") orelse continue;
            if (name_val != .string) continue;
            const char = self.getOrCreateCharacter(allocator, name_val.string) catch |err| {
                slog.err("Failed to create live-preview entry for character '{s}': {}", .{ name_val.string, err });
                continue;
            };

            if (obj.get("displayName")) |v| {
                if (v == .string and v.string.len > 0) {
                    const new_display_name = try allocator.dupe(u8, v.string);
                    if (char.displayName) |old| allocator.free(old);
                    char.displayName = new_display_name;
                } else {
                    if (char.displayName) |old| allocator.free(old);
                    char.displayName = null;
                }
            }

            if (obj.get("thumbnailSize")) |size_val| {
                if (size_val == .object) {
                    var size: CharacterThumbnailSize = .{};
                    if (size_val.object.get("width")) |v| {
                        if (v == .integer) size.width = std.math.cast(i32, v.integer);
                    }
                    if (size_val.object.get("height")) |v| {
                        if (v == .integer) size.height = std.math.cast(i32, v.integer);
                    }
                    clampCharacterThumbnailSize(&size);
                    char.thumbnailSize = if (size.width != null or size.height != null) size else null;
                } else {
                    char.thumbnailSize = null;
                }
            }

            if (obj.get("borderColors")) |colors_val| {
                if (colors_val == .object) {
                    var colors: CharacterBorderColors = .{};
                    if (colors_val.object.get("activeBorderColor")) |v| {
                        if (v == .string) colors.activeBorderColor = try parseHexColor(v.string);
                    }
                    if (colors_val.object.get("inactiveBorderColor")) |v| {
                        if (v == .string) colors.inactiveBorderColor = try parseHexColor(v.string);
                    }
                    char.borderColors = if (colors.activeBorderColor != null or colors.inactiveBorderColor != null) colors else null;
                } else {
                    char.borderColors = null;
                }
            }

            if (obj.get("nameColor")) |v| {
                if (v == .string) {
                    char.nameColor = try parseHexColor(v.string);
                } else {
                    char.nameColor = null;
                }
            }

            if (obj.get("hideThumbnail")) |v| {
                if (v == .bool) char.hideThumbnail = v.bool;
            }

            // Only sent by the post-import preview (see buildCharacterOverridesPreviewPatch in config_dialog.js), never the general per-edit debounce.
            if (obj.get("position")) |pos_val| {
                if (pos_val == .object) {
                    var x: ?i32 = null;
                    var y: ?i32 = null;
                    if (pos_val.object.get("x")) |v| {
                        if (v == .integer) x = std.math.cast(i32, v.integer);
                    }
                    if (pos_val.object.get("y")) |v| {
                        if (v == .integer) y = std.math.cast(i32, v.integer);
                    }
                    if (x != null and y != null) char.position = .{ .x = x.?, .y = y.? };
                }
            }
        }
    }

    /// Dumps the full config as pretty-printed JSON, one log line per JSON line, since the file logger's line buffer is capped at 2048 bytes per call and a single-call dump would blow past that and get silently dropped.
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

    /// Persists the entire config as JSON to this profile's file.
    fn saveCurrentProfile(self: *const Config, allocator: std.mem.Allocator) !void {
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
        self.display.startX = pos.x;
        self.display.startY = pos.y;

        try self.saveCurrentProfile(allocator);
        slog.debug("Saved list view position for profile '{s}': ({}, {})", .{ self.profile_name, pos.x, pos.y });
    }
};
