//! Settings shared by every profile (`profiles/global.settings.json`).
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const wire = @import("wire.zig");
const key_list = @import("key_list.zig");
const files = @import("files.zig");
const ranges_mod = @import("ranges.zig");
const readable = @import("readable.zig");
const migrate = @import("migrate.zig");
const types = @import("types.zig");
const chatlog_mod = @import("chatlog.zig");
const atomic_file = @import("../util/atomic_file.zig");
const log = @import("../log.zig");

const KeyList = key_list.KeyList;
const ChatlogConfig = chatlog_mod.ChatlogConfig;
const slog = log.Scoped("config");

/// An unreadable file is kept as `<file>.<unix seconds>.bak`: not ".json", which would list it as a profile.
const UNREADABLE_BACKUP_EXTENSION = ".bak";
/// Room for the file's name, an i64 and the extension, so formatting it can't fail.
const BACKUP_PATH_SIZE = files.GLOBAL_SETTINGS_FILE.len + 32;
/// Ties the token's encryption to this app, so a tool unprotecting blobs without entropy can't read it.
const TOKEN_ENTROPY = "EVE-Maj Preview evestarsToken";

/// Only the price is saved; the rest comes from ores.CATALOG.
pub const OrePriceConfig = struct {
    name: []const u8 = "",
    price: f64 = 0,

    pub const ranges = .{
        // Far above any real price, but finite so the dialog's JSON can carry it.
        .price = .{ 0, 1e12 },
    };

    pub fn validate(self: *OrePriceConfig) void {
        ranges_mod.clamp(OrePriceConfig, self);
    }

    pub const Wire = wire.Wire(OrePriceConfig);
};

pub const ProfileSwitchHotkeyConfig = struct {
    hotkey: KeyList = .empty,
    targetProfile: []const u8 = "",

    pub const Wire = wire.Wire(ProfileSwitchHotkeyConfig);
};

/// Matched by executable name at press time.
pub const AppHotkeyConfig = struct {
    hotkey: KeyList = .empty,
    executableName: []const u8 = "",

    pub const Wire = wire.Wire(AppHotkeyConfig);
};

/// With uploadClipboard, the clipboard is POSTed as a paste first (see paste_upload.zig).
pub const UrlHotkeyConfig = struct {
    hotkey: KeyList = .empty,
    url: []const u8 = "",
    uploadClipboard: bool = false,

    pub const Wire = wire.Wire(UrlHotkeyConfig);
};

/// Each off by default, since any web page can open a protocol link.
pub const ProtocolLinksConfig = struct {
    allowCloseAll: bool = false,
    allowCloseActive: bool = false,
    allowCloseGroup: bool = false,
    allowExitApp: bool = false,

    pub const Wire = wire.Wire(ProtocolLinksConfig);
};

const LoadOutcome = enum { loaded, missing, unreadable, malformed };

/// What GlobalConfig.load found, which finishLoading reports once the log level is set.
const LoadReport = struct {
    outcome: LoadOutcome = .loaded,
    /// Why the file couldn't be read or parsed.
    err: ?anyerror = null,
    /// The Unix seconds in an unreadable file's backup name.
    backup_seconds: i64 = 0,
    /// Why an unreadable file couldn't be moved aside; while set, nothing saves over it.
    move_error: ?anyerror = null,
    /// The file predates shared Log Monitoring, so a profile's is still to be taken.
    needs_profile_chatlog: bool = false,
    /// Why the file couldn't be checked for a chatlog section.
    chatlog_check_error: ?anyerror = null,
    /// Why the saved token couldn't be decrypted, e.g. the file came from another Windows account.
    token_error: ?anyerror = null,
    /// The file held the token unencrypted, so finishLoading saves to encrypt it.
    has_plain_token: bool = false,
};

pub const GlobalConfig = struct {
    allocator: std.mem.Allocator,
    lastUsedProfile: []const u8 = files.DEFAULT_PROFILE,
    logLevel: log.LogLevel = .err,
    language: types.Language = .en,
    chatlog: ChatlogConfig = .{},
    hotkeyNextProfile: KeyList = .empty,
    hotkeyPreviousProfile: KeyList = .empty,
    hotkeyCycleAllClientsForward: KeyList = .empty,
    hotkeyCycleAllClientsBackward: KeyList = .empty,
    cycleAllClientsRespectExclusions: bool = false,
    hotkeyCycleNotLoggedInForward: KeyList = .empty,
    hotkeyCycleNotLoggedInBackward: KeyList = .empty,
    hotkeyReturnToLastApp: KeyList = .empty,
    hotkeyCycleAppsForward: KeyList = .empty,
    hotkeyCycleAppsBackward: KeyList = .empty,
    profileSwitchHotkeys: std.ArrayList(ProfileSwitchHotkeyConfig) = .empty,
    appHotkeys: std.ArrayList(AppHotkeyConfig) = .empty,
    urlHotkeys: std.ArrayList(UrlHotkeyConfig) = .empty,
    disableUpdateChecks: bool = false,
    runOnStartup: bool = false,
    autoRegisterProtocol: bool = true,
    protocolLinks: ProtocolLinksConfig = .{},
    alwaysOnTop: bool = true,
    advancedMode: bool = false,
    moveOnProfileSwitch: bool = false,
    oreTable: std.ArrayList(OrePriceConfig) = .empty,
    /// Unix seconds of the last successful price fetch, or 0 if never.
    orePricesFetchedAtSeconds: i64 = 0,
    evestarsEnabled: bool = true,
    /// Here rather than in a profile, since profiles get shared; never logged, and saved only as evestarsTokenProtected.
    evestarsToken: []const u8 = "",
    /// On disk only: evestarsToken encrypted to the Windows account (DPAPI), in base64; empty in memory.
    evestarsTokenProtected: []const u8 = "",
    dialogX: ?i32 = null,
    dialogY: ?i32 = null,
    load_report: LoadReport = .{},

    pub const runtime_fields = .{ "allocator", "load_report" };

    /// Saved, but changed by the app as it runs rather than by the settings form.
    pub const running_fields = .{ "lastUsedProfile", "dialogX", "dialogY" };

    pub fn validate(self: *GlobalConfig) void {
        ranges_mod.clamp(GlobalConfig, self);
        for (self.oreTable.items) |*entry| entry.validate();
    }

    pub fn deinit(self: *GlobalConfig) void {
        wire.deinit(GlobalConfig, self, self.allocator);
    }

    /// Falls back to defaults on a missing, unreadable or malformed file; logs nothing until finishLoading, since the log level isn't set yet.
    pub fn load(allocator: std.mem.Allocator, io: std.Io) !GlobalConfig {
        const content = files.readSettingsFile(allocator, io, files.GLOBAL_SETTINGS_FILE) catch |err| {
            if (err == error.FileNotFound) return defaults(allocator, .{ .outcome = .missing, .needs_profile_chatlog = true });
            return defaults(allocator, keepUnreadable(io, .unreadable, err));
        };
        defer allocator.free(content);

        var settings = loadFromJson(allocator, content) catch |err| return defaults(allocator, keepUnreadable(io, .malformed, err));
        settings.readProtectedToken();
        const has_chatlog = hasChatlog(allocator, content) catch |err| blk: {
            settings.load_report.chatlog_check_error = err;
            // True keeps what loaded rather than overwriting it from a profile.
            break :blk true;
        };
        settings.load_report.needs_profile_chatlog = !has_chatlog;
        return settings;
    }

    /// Once the log level is set: reports how load went, then takes a profile's Log Monitoring if the file predates sharing it.
    pub fn finishLoading(self: *GlobalConfig, io: std.Io) void {
        const report = &self.load_report;
        switch (report.outcome) {
            .loaded => slog.info("Loaded global settings: last profile = {s}", .{self.lastUsedProfile}),
            .missing => slog.debug("No global settings file, using defaults", .{}),
            .unreadable => slog.err("Failed to read global settings file, using defaults: {?}", .{report.err}),
            .malformed => slog.warn("Failed to parse global settings file, using defaults: {?}", .{report.err}),
        }
        switch (report.outcome) {
            .loaded, .missing => {},
            .unreadable, .malformed => {
                var path_buffer: [BACKUP_PATH_SIZE]u8 = undefined;
                const backup_path = backupPath(&path_buffer, report.backup_seconds);
                if (report.move_error) |err| {
                    slog.err("Failed to move the unreadable global settings to '{s}', so nothing saves over them until the next start: {}", .{ backup_path, err });
                } else {
                    slog.info("Kept the unreadable global settings as '{s}'", .{backup_path});
                }
            },
        }
        if (report.chatlog_check_error) |err| slog.warn("Failed to check the global settings for Log Monitoring: {}", .{err});
        if (report.needs_profile_chatlog) self.adoptProfileChatlog(io);
        if (report.token_error) |err| slog.warn("Failed to decrypt the Eve Stars token, which only the Windows account that saved it can read, so it needs entering again: {}", .{err});
        if (report.has_plain_token) {
            if (self.save(io)) {
                slog.info("Encrypted the Eve Stars token in the global settings", .{});
            } else |err| {
                slog.warn("Failed to encrypt the Eve Stars token in the global settings, which still hold it unencrypted: {}", .{err});
            }
        }
        self.chatlog.warnUnreachableDirs(io);
    }

    /// Decrypts evestarsTokenProtected into evestarsToken and empties it; a token the file holds unencrypted wins, as it was typed in by hand.
    fn readProtectedToken(self: *GlobalConfig) void {
        const protected = self.evestarsTokenProtected;
        if (protected.len == 0) {
            self.load_report.has_plain_token = self.evestarsToken.len > 0;
            return;
        }
        defer {
            self.allocator.free(protected);
            self.evestarsTokenProtected = "";
        }
        if (self.evestarsToken.len > 0) {
            self.load_report.has_plain_token = true;
            return;
        }
        self.evestarsToken = unprotectToken(self.allocator, protected) catch |err| {
            self.load_report.token_error = err;
            return;
        };
    }

    fn defaults(allocator: std.mem.Allocator, report: LoadReport) !GlobalConfig {
        var settings = try GlobalConfig.fromWire(.{}, allocator);
        settings.load_report = report;
        return settings;
    }

    /// Moved aside rather than deleted, since running on defaults saves over it; one that won't move stays, and saves refuse to replace it.
    fn keepUnreadable(io: std.Io, outcome: LoadOutcome, err: anyerror) LoadReport {
        var report: LoadReport = .{
            .outcome = outcome,
            .err = err,
            .backup_seconds = std.Io.Clock.real.now(io).toSeconds(),
            .needs_profile_chatlog = true,
        };
        var path_buffer: [BACKUP_PATH_SIZE]u8 = undefined;
        const cwd = std.Io.Dir.cwd();
        cwd.rename(files.GLOBAL_SETTINGS_FILE, cwd, backupPath(&path_buffer, report.backup_seconds), io) catch |move_err| {
            report.move_error = move_err;
            // Taking a profile's Log Monitoring saves, which mustn't replace the kept file.
            report.needs_profile_chatlog = false;
        };
        return report;
    }

    /// Log Monitoring was a profile setting before it was shared; the profile that last ran brings its own along, once it's taken or found to have none.
    fn adoptProfileChatlog(self: *GlobalConfig, io: std.Io) void {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = std.Io.Dir.path.join(arena, &.{ files.PROFILES_DIR, self.lastUsedProfile }) catch |err| {
            slog.warn("Failed to move Log Monitoring from profile '{s}' into the global settings, trying again next start: {}", .{ self.lastUsedProfile, err });
            return;
        };
        const content = files.readSettingsFile(arena, io, path) catch |err| {
            if (err == error.FileNotFound) {
                // A first run has no profile yet, so the defaults stand.
                self.load_report.needs_profile_chatlog = false;
                return;
            }
            slog.warn("Failed to move Log Monitoring from profile '{s}' into the global settings, trying again next start: {}", .{ self.lastUsedProfile, err });
            return;
        };
        const saved = profileChatlog(arena, content) catch |err| {
            slog.warn("Failed to move Log Monitoring from profile '{s}' into the global settings, trying again next start: {}", .{ self.lastUsedProfile, err });
            return;
        } orelse {
            self.load_report.needs_profile_chatlog = false;
            return;
        };
        const chatlog = ChatlogConfig.fromWire(saved, self.allocator) catch |err| {
            slog.warn("Failed to move Log Monitoring from profile '{s}' into the global settings, trying again next start: {}", .{ self.lastUsedProfile, err });
            return;
        };
        wire.deinit(ChatlogConfig, &self.chatlog, self.allocator);
        self.chatlog = chatlog;
        self.chatlog.validate();
        self.load_report.needs_profile_chatlog = false;
        slog.info("Moved Log Monitoring from profile '{s}' into the global settings", .{self.lastUsedProfile});
        self.save(io) catch |err| {
            slog.warn("Failed to save the global settings after moving Log Monitoring into them: {}", .{err});
        };
    }

    fn loadFromJson(allocator: std.mem.Allocator, json_text: []const u8) !GlobalConfig {
        const parsed = try wire.parse(GlobalConfig.Wire, allocator, json_text);
        defer parsed.deinit();
        return GlobalConfig.fromWire(parsed.value, allocator);
    }

    /// Caller owns the returned slice.
    pub fn toJsonString(self: *const GlobalConfig, allocator: std.mem.Allocator) ![]u8 {
        return wire.toJsonAlloc(allocator, self);
    }

    /// Refused while an unreadable file couldn't be moved aside, so it survives until a start that can read it.
    pub fn save(self: *const GlobalConfig, io: std.Io) !void {
        if (self.load_report.move_error != null) {
            slog.warn("Failed to save the global settings: the unreadable file they'd replace is kept until the next start", .{});
            return error.UnreadableSettingsKept;
        }
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const json = try self.savedJson(arena_state.allocator());
        try atomic_file.write(self.allocator, io, files.GLOBAL_SETTINGS_FILE, json);

        slog.debug("Saved global settings", .{});
    }

    pub fn logSettings(self: *const GlobalConfig) void {
        var shown = self.*;
        shown.evestarsToken = "";
        wire.logJson(self.allocator, &shown);
    }

    pub fn updateLastUsed(self: *GlobalConfig, io: std.Io, profile_name: []const u8) !void {
        const is_same_profile = self.lastUsedProfile.len > 0 and std.mem.eql(u8, self.lastUsedProfile, profile_name);
        if (is_same_profile) return;

        const new_profile = try self.allocator.dupe(u8, profile_name);
        errdefer self.allocator.free(new_profile);

        self.allocator.free(self.lastUsedProfile);
        self.lastUsedProfile = new_profile;

        try self.save(io);
    }

    /// After profile `old_name` was renamed `new_name`: its switch hotkeys follow it, saved if any did.
    pub fn retargetProfileSwitches(self: *GlobalConfig, io: std.Io, old_name: []const u8, new_name: []const u8) !void {
        var is_changed = false;
        for (self.profileSwitchHotkeys.items) |*entry| {
            if (!std.mem.eql(u8, entry.targetProfile, old_name)) continue;
            const owned = try self.allocator.dupe(u8, new_name);
            self.allocator.free(entry.targetProfile);
            entry.targetProfile = owned;
            is_changed = true;
        }
        if (is_changed) try self.save(io);
    }

    pub fn saveDialogPosition(self: *GlobalConfig, io: std.Io, x: i32, y: i32) !void {
        self.dialogX = x;
        self.dialogY = y;
        try self.save(io);
    }

    /// Takes all but running_fields, leaving `edited` holding the old values to free; only while the chatlog worker is stopped.
    pub fn adopt(self: *GlobalConfig, edited: *GlobalConfig) void {
        // Log Monitoring set by hand replaces whatever a profile still had to bring.
        if (!isSameChatlog(&self.chatlog, &edited.chatlog)) self.load_report.needs_profile_chatlog = false;
        inline for (comptime wire.savedFields(GlobalConfig)) |f| {
            if (comptime !isRunningField(f.name)) std.mem.swap(f.type, &@field(self, f.name), &@field(edited, f.name));
        }
    }

    /// Saves the token encrypted, and leaves chatlog out while a profile's is still to be taken, so a move that failed is tried again next start.
    fn savedJson(self: *const GlobalConfig, arena: std.mem.Allocator) ![]const u8 {
        var stored = self.*;
        stored.evestarsToken = "";
        stored.evestarsTokenProtected = try protectToken(arena, self.evestarsToken);
        const json = try stored.toJsonString(arena);
        if (!self.load_report.needs_profile_chatlog) return json;
        var value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
        if (value == .object) _ = value.object.orderedRemove("chatlog");
        return std.json.Stringify.valueAlloc(arena, value, .{ .whitespace = .indent_2 });
    }

    fn isRunningField(comptime name: []const u8) bool {
        inline for (running_fields) |running| {
            if (comptime std.mem.eql(u8, name, running)) return true;
        }
        return false;
    }

    pub const Wire = wire.Wire(GlobalConfig);

    pub fn toWire(self: *const GlobalConfig, allocator: std.mem.Allocator) !Wire {
        return wire.toWireAlloc(GlobalConfig, allocator, self);
    }

    /// The only way a GlobalConfig is built, so its strings are always owned (see updateLastUsed).
    pub fn fromWire(saved: Wire, allocator: std.mem.Allocator) !GlobalConfig {
        var settings: GlobalConfig = .{ .allocator = allocator };
        errdefer settings.deinit();
        try wire.fromWireInto(GlobalConfig, saved, allocator, &settings);
        settings.validate();
        return settings;
    }

    /// Leaves out load_report.
    pub fn clone(self: *const GlobalConfig, allocator: std.mem.Allocator) !GlobalConfig {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        return fromWire(try self.toWire(arena.allocator()), allocator);
    }
};

/// True when the global settings file's JSON has the shared chatlog section.
fn hasChatlog(allocator: std.mem.Allocator, content: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{ .duplicate_field_behavior = .use_last });
    defer parsed.deinit();
    return migrate.hasSharedChatlog(parsed.value);
}

/// Base64 of the DPAPI blob, in `arena`; empty for no token.
fn protectToken(arena: std.mem.Allocator, token: []const u8) ![]const u8 {
    if (token.len == 0) return "";
    const blob = try win32.protectData(arena, token, TOKEN_ENTROPY);
    const encoder = std.base64.standard.Encoder;
    return encoder.encode(try arena.alloc(u8, encoder.calcSize(blob.len)), blob);
}

/// Caller frees; `text` is evestarsTokenProtected as saved.
fn unprotectToken(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const blob = try allocator.alloc(u8, try decoder.calcSizeForSlice(text));
    defer allocator.free(blob);
    try decoder.decode(blob, text);
    return win32.unprotectData(allocator, blob, TOKEN_ENTROPY);
}

/// `<file>.<seconds>.bak` in `buffer`.
fn backupPath(buffer: *[BACKUP_PATH_SIZE]u8, seconds: i64) []const u8 {
    return std.mem.print(buffer, "{s}.{d}{s}", .{ files.GLOBAL_SETTINGS_FILE, seconds, UNREADABLE_BACKUP_EXTENSION }) catch unreachable;
}

fn isSameChatlog(first: *const ChatlogConfig, second: *const ChatlogConfig) bool {
    inline for (comptime wire.savedFields(ChatlogConfig)) |f| {
        const first_value = @field(first, f.name);
        const second_value = @field(second, f.name);
        const is_same = if (f.type == []const u8) std.mem.eql(u8, first_value, second_value) else first_value == second_value;
        if (!is_same) return false;
    }
    return true;
}

/// A profile's own chatlog section, typed; null when it has none.
fn profileChatlog(arena: std.mem.Allocator, content: []const u8) !?ChatlogConfig.Wire {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{ .duplicate_field_behavior = .use_last });
    var section = migrate.profileChatlog(root) orelse return null;
    if (!readable.dropUnreadable(ChatlogConfig.Wire, arena, &section, null)) return null;
    return try std.json.parseFromValueLeaky(ChatlogConfig.Wire, arena, section, readable.PARSE_OPTIONS);
}
