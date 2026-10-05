//! Settings shared by every profile (`profiles/global.settings.json`).
const std = @import("std");
const wire = @import("wire.zig");
const key_list = @import("key_list.zig");
const files = @import("files.zig");
const ranges_mod = @import("ranges.zig");
const log = @import("../log.zig");

const KeyList = key_list.KeyList;
const slog = log.scoped("config");

/// Not ".json", which would list it as a profile.
const UNREADABLE_BACKUP_FILE = files.GLOBAL_SETTINGS_FILE ++ ".bak";

/// Fallback prices are a Jita snapshot and will drift - re-fetch via "Fetch Prices" for current numbers.
pub const DEFAULT_ORE_TABLE = [_]OreEntry{
    .{ .name = "Veldspar", .category = "Ore", .volumeM3 = 0.10, .price = 11.53 },
    .{ .name = "Mordunium", .category = "Ore", .volumeM3 = 0.10, .price = 12.83 },
    .{ .name = "Scordite", .category = "Ore", .volumeM3 = 0.15, .price = 22.05 },
    .{ .name = "Pyroxeres", .category = "Ore", .volumeM3 = 0.30, .price = 32 },
    .{ .name = "Plagioclase", .category = "Ore", .volumeM3 = 0.35, .price = 33.4 },
    .{ .name = "Omber", .category = "Ore", .volumeM3 = 0.60, .price = 112.5 },
    .{ .name = "Ytirium", .category = "Ore", .volumeM3 = 0.60, .price = 350.9 },
    .{ .name = "Griemeer", .category = "Ore", .volumeM3 = 0.80, .price = 111.1 },
    .{ .name = "Kernite", .category = "Ore", .volumeM3 = 1.20, .price = 207 },
    .{ .name = "Kylixium", .category = "Ore", .volumeM3 = 1.20, .price = 252.5 },
    .{ .name = "Jaspet", .category = "Ore", .volumeM3 = 2.00, .price = 374.5 },
    .{ .name = "Hedbergite", .category = "Ore", .volumeM3 = 3.00, .price = 627.6 },
    .{ .name = "Hemorphite", .category = "Ore", .volumeM3 = 3.00, .price = 808.9 },
    .{ .name = "Talassonite", .category = "Ore", .volumeM3 = 3.00, .price = 8421 },
    .{ .name = "Nocxite", .category = "Ore", .volumeM3 = 4.00, .price = 605.3 },
    .{ .name = "Gneiss", .category = "Ore", .volumeM3 = 5.00, .price = 2100 },
    .{ .name = "Hezorime", .category = "Ore", .volumeM3 = 5.00, .price = 957.1 },
    .{ .name = "Rakovene", .category = "Ore", .volumeM3 = 5.00, .price = 7520 },
    .{ .name = "Ueganite", .category = "Ore", .volumeM3 = 5.00, .price = 900 },
    .{ .name = "Bezdnacine", .category = "Ore", .volumeM3 = 8.00, .price = 9220 },
    .{ .name = "Dark Ochre", .category = "Ore", .volumeM3 = 8.00, .price = 4200 },

    .{ .name = "Bitumens", .category = "Moons", .volumeM3 = 10.00, .price = 1164 },
    .{ .name = "Coesite", .category = "Moons", .volumeM3 = 10.00, .price = 0 },
    .{ .name = "Evaporite Deposits", .category = "Moons", .volumeM3 = 10.00, .price = 0 },
    .{ .name = "Sylvite", .category = "Moons", .volumeM3 = 10.00, .price = 801 },
    .{ .name = "Cobaltite", .category = "Moons", .volumeM3 = 10.00, .price = 285.8 },
    .{ .name = "Euxenite", .category = "Moons", .volumeM3 = 10.00, .price = 900.6 },
    .{ .name = "Scheelite", .category = "Moons", .volumeM3 = 10.00, .price = 253.1 },
    .{ .name = "Titanite", .category = "Moons", .volumeM3 = 10.00, .price = 211.1 },
    .{ .name = "Chromite", .category = "Moons", .volumeM3 = 10.00, .price = 1611 },
    .{ .name = "Otavite", .category = "Moons", .volumeM3 = 10.00, .price = 1439 },
    .{ .name = "Sperrylite", .category = "Moons", .volumeM3 = 10.00, .price = 1548 },
    .{ .name = "Vanadinite", .category = "Moons", .volumeM3 = 10.00, .price = 634.6 },
    .{ .name = "Carnotite", .category = "Moons", .volumeM3 = 10.00, .price = 4706 },
    .{ .name = "Cinnabar", .category = "Moons", .volumeM3 = 10.00, .price = 600.3 },
    .{ .name = "Pollucite", .category = "Moons", .volumeM3 = 10.00, .price = 1644 },
    .{ .name = "Zircon", .category = "Moons", .volumeM3 = 10.00, .price = 439.7 },
    .{ .name = "Monazite", .category = "Moons", .volumeM3 = 10.00, .price = 9800 },
    .{ .name = "Loparite", .category = "Moons", .volumeM3 = 10.00, .price = 8060 },
    .{ .name = "Xenotime", .category = "Moons", .volumeM3 = 10.00, .price = 8166 },
    .{ .name = "Ytterbite", .category = "Moons", .volumeM3 = 10.00, .price = 4728 },
    .{ .name = "Zeolites", .category = "Moons", .volumeM3 = 10.00, .price = 1360 },
    .{ .name = "Arkonor", .category = "Ore", .volumeM3 = 16.00, .price = 4264 },
    .{ .name = "Bistot", .category = "Ore", .volumeM3 = 16.00, .price = 3613 },
    .{ .name = "Crokite", .category = "Ore", .volumeM3 = 16.00, .price = 5300 },
    .{ .name = "Ducinium", .category = "Ore", .volumeM3 = 16.00, .price = 3629 },
    .{ .name = "Eifyrium", .category = "Ore", .volumeM3 = 16.00, .price = 2889 },
    .{ .name = "Spodumain", .category = "Ore", .volumeM3 = 16.00, .price = 8507 },
    .{ .name = "Mercoxit", .category = "Ore", .volumeM3 = 40.00, .price = 18460 },
    .{ .name = "Prismaticite", .category = "Ore", .volumeM3 = 40.00, .price = 18740 },

    .{ .name = "Fullerite-C50", .category = "Gas", .volumeM3 = 1.00, .price = 4707 },
    .{ .name = "Fullerite-C60", .category = "Gas", .volumeM3 = 1.00, .price = 4683 },
    .{ .name = "Fullerite-C70", .category = "Gas", .volumeM3 = 1.00, .price = 8211 },
    .{ .name = "Fullerite-C28", .category = "Gas", .volumeM3 = 2.00, .price = 13100 },
    .{ .name = "Fullerite-C72", .category = "Gas", .volumeM3 = 2.00, .price = 6990 },
    .{ .name = "Fullerite-C84", .category = "Gas", .volumeM3 = 2.00, .price = 9896 },
    .{ .name = "Fullerite-C32", .category = "Gas", .volumeM3 = 5.00, .price = 20000 },
    .{ .name = "Fullerite-C320", .category = "Gas", .volumeM3 = 5.00, .price = 32400 },
    .{ .name = "Fullerite-C540", .category = "Gas", .volumeM3 = 10.00, .price = 47410 },
    .{ .name = "Amber Cytoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 30600 },
    .{ .name = "Azure Cytoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 19150 },
    .{ .name = "Celadon Cytoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 26130 },
    .{ .name = "Golden Cytoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 36220 },
    .{ .name = "Lime Cytoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 31100 },
    .{ .name = "Malachite Cytoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 133300 },
    .{ .name = "Vermillion Cytoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 25120 },
    .{ .name = "Viridian Cytoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 51080 },
    .{ .name = "Amber Mykoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 95230 },
    .{ .name = "Azure Mykoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 48370 },
    .{ .name = "Celadon Mykoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 83500 },
    .{ .name = "Golden Mykoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 97940 },
    .{ .name = "Lime Mykoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 77980 },
    .{ .name = "Malachite Mykoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 88850 },
    .{ .name = "Vermillion Mykoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 77970 },
    .{ .name = "Viridian Mykoserocin", .category = "Gas", .volumeM3 = 10.00, .price = 91090 },

    .{ .name = "Clear Icicle", .category = "Ice", .volumeM3 = 1000.00, .price = 234300 },
    .{ .name = "Blue Ice", .category = "Ice", .volumeM3 = 1000.00, .price = 187200 },
    .{ .name = "Glacial Mass", .category = "Ice", .volumeM3 = 1000.00, .price = 170800 },
    .{ .name = "White Glaze", .category = "Ice", .volumeM3 = 1000.00, .price = 196600 },
    .{ .name = "Dark Glitter", .category = "Ice", .volumeM3 = 1000.00, .price = 332000 },
    .{ .name = "Gelidus", .category = "Ice", .volumeM3 = 1000.00, .price = 350100 },
    .{ .name = "Krystallos", .category = "Ice", .volumeM3 = 1000.00, .price = 592500 },
    .{ .name = "Glare Crust", .category = "Ice", .volumeM3 = 1000.00, .price = 220200 },
};

/// Built-in reference data, never saved; OrePriceConfig holds the user's price overrides.
pub const OreEntry = struct {
    name: []const u8,
    category: []const u8 = "Ore",
    volumeM3: f64,
    price: f64 = 0,
};

/// The only per-ore state GlobalConfig actually persists - name/category/volumeM3 come from DEFAULT_ORE_TABLE instead, since those never vary by user.
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

/// Binding of a hotkey to a specific target profile ("quick switch")
pub const ProfileSwitchHotkeyConfig = struct {
    hotkey: KeyList = .empty,
    targetProfile: []const u8 = "",

    pub const Wire = wire.Wire(ProfileSwitchHotkeyConfig);
};

/// Binding of a hotkey to an external application, matched by executable name at press time (mirrors AutoHotkey's ahk_exe).
pub const AppHotkeyConfig = struct {
    hotkey: KeyList = .empty,
    executableName: []const u8 = "",

    pub const Wire = wire.Wire(AppHotkeyConfig);
};

/// Binding of a hotkey to a URL, opened via ShellExecute (or, with uploadClipboard, POSTed as a paste upload first - see paste_upload.zig).
pub const UrlHotkeyConfig = struct {
    hotkey: KeyList = .empty,
    url: []const u8 = "",
    uploadClipboard: bool = false,

    pub const Wire = wire.Wire(UrlHotkeyConfig);
};

pub const GlobalConfig = struct {
    allocator: std.mem.Allocator,
    lastUsedProfile: []const u8 = files.DEFAULT_PROFILE,
    logLevel: log.LogLevel = .err,
    hotkeyNextProfile: KeyList = .empty,
    hotkeyPreviousProfile: KeyList = .empty,
    hotkeyCycleAllClientsForward: KeyList = .empty,
    hotkeyCycleAllClientsBackward: KeyList = .empty,
    cycleAllClientsRespectExclusions: bool = false,
    hotkeyCycleNotLoggedInForward: KeyList = .empty,
    hotkeyCycleNotLoggedInBackward: KeyList = .empty,
    hotkeyReturnToLastApp: KeyList = .empty,
    profileSwitchHotkeys: std.ArrayList(ProfileSwitchHotkeyConfig) = .empty,
    appHotkeys: std.ArrayList(AppHotkeyConfig) = .empty,
    urlHotkeys: std.ArrayList(UrlHotkeyConfig) = .empty,
    disableUpdateChecks: bool = false,
    runOnStartup: bool = false,
    autoRegisterProtocol: bool = true,
    alwaysOnTop: bool = true,
    advancedMode: bool = false,
    language: []const u8 = "en",
    oreTable: std.ArrayList(OrePriceConfig) = .empty,
    dialogX: ?i32 = null,
    dialogY: ?i32 = null,
    dialogScale: u16 = 0,

    pub const runtime_fields = .{"allocator"};

    /// Saved, but changed by the app as it runs rather than by the settings form.
    pub const running_fields = .{ "lastUsedProfile", "dialogX", "dialogY", "dialogScale" };

    pub const ranges = .{
        .dialogScale = .{ 50, 300 },
    };
    /// 0 is "auto": the dialog picks a scale from the monitor.
    pub const zero_means_default = .{"dialogScale"};

    pub fn validate(self: *GlobalConfig) void {
        ranges_mod.clamp(GlobalConfig, self);
        for (self.oreTable.items) |*entry| entry.validate();
    }

    pub fn deinit(self: *GlobalConfig) void {
        wire.deinit(GlobalConfig, self, self.allocator);
    }

    /// Volume never varies by user, so this reads DEFAULT_ORE_TABLE directly rather than the persisted oreTable.
    pub fn oreVolume(self: *const GlobalConfig, name: []const u8) ?f64 {
        _ = self;
        inline for (.{ true, false }) |exact| {
            if (findOre(&DEFAULT_ORE_TABLE, name, exact)) |entry| return entry.volumeM3;
        }
        return null;
    }

    /// An exact name beats a grade variant; within each, the persisted price override beats DEFAULT_ORE_TABLE's snapshot price.
    pub fn orePrice(self: *const GlobalConfig, name: []const u8) ?f64 {
        inline for (.{ true, false }) |exact| {
            if (findOre(self.oreTable.items, name, exact)) |entry| return entry.price;
            if (findOre(&DEFAULT_ORE_TABLE, name, exact)) |entry| return entry.price;
        }
        return null;
    }

    fn findOre(table: anytype, name: []const u8, comptime exact: bool) ?@TypeOf(table[0]) {
        for (table) |entry| {
            const matches = if (exact) std.mem.eql(u8, entry.name, name) else isGradeVariant(name, entry.name);
            if (matches) return entry;
        }
        return null;
    }

    /// Falls back to defaults on a missing, unreadable or malformed file.
    pub fn load(allocator: std.mem.Allocator) !GlobalConfig {
        const content = std.Io.Dir.cwd().readFileAlloc(files.g_io, files.GLOBAL_SETTINGS_FILE, allocator, .limited(files.MAX_CONFIG_FILE_SIZE)) catch |err| {
            if (err == error.FileNotFound) {
                slog.debug("No global settings file, using defaults", .{});
                return GlobalConfig.fromWire(.{}, allocator);
            }
            slog.err("Failed to read global settings file: {}", .{err});
            std.Io.Dir.cwd().deleteFile(files.g_io, files.GLOBAL_SETTINGS_FILE) catch |del_err| {
                slog.warn("Failed to delete unreadable global settings file: {}", .{del_err});
            };
            return GlobalConfig.fromWire(.{}, allocator);
        };
        defer allocator.free(content);

        const settings = loadFromJson(allocator, content) catch |err| {
            slog.warn("Failed to parse global settings file ({}), using defaults and keeping it as '{s}'", .{ err, UNREADABLE_BACKUP_FILE });
            const cwd = std.Io.Dir.cwd();
            cwd.rename(files.GLOBAL_SETTINGS_FILE, cwd, UNREADABLE_BACKUP_FILE, files.g_io) catch |rename_err| {
                slog.err("Failed to keep unreadable global settings as '{s}': {}", .{ UNREADABLE_BACKUP_FILE, rename_err });
            };
            return GlobalConfig.fromWire(.{}, allocator);
        };

        slog.info("Loaded global settings: last profile = {s}", .{settings.lastUsedProfile});
        return settings;
    }

    fn loadFromJson(allocator: std.mem.Allocator, json_text: []const u8) !GlobalConfig {
        const parsed = try wire.parse(GlobalConfig.Wire, allocator, json_text);
        defer parsed.deinit();
        return GlobalConfig.fromWire(parsed.value, allocator);
    }

    /// Caller owns the returned slice.
    pub fn toJsonString(self: *GlobalConfig, allocator: std.mem.Allocator) ![]u8 {
        return wire.toJsonAlloc(allocator, self);
    }

    pub fn save(self: *GlobalConfig) !void {
        const json = try self.toJsonString(self.allocator);
        defer self.allocator.free(json);

        try files.atomicWriteFile(self.allocator, files.g_io, files.GLOBAL_SETTINGS_FILE, json);

        slog.debug("Saved global settings", .{});
    }

    pub fn logSettings(self: *GlobalConfig) void {
        wire.logJson(self.allocator, self);
    }

    pub fn updateLastUsed(self: *GlobalConfig, profile_name: []const u8) !void {
        const same_profile = self.lastUsedProfile.len > 0 and std.mem.eql(u8, self.lastUsedProfile, profile_name);

        if (!same_profile) {
            const new_profile = try self.allocator.dupe(u8, profile_name);
            errdefer self.allocator.free(new_profile);

            self.allocator.free(self.lastUsedProfile);
            self.lastUsedProfile = new_profile;

            try self.save();
        }
    }

    pub fn saveDialogPosition(self: *GlobalConfig, x: i32, y: i32) !void {
        self.dialogX = x;
        self.dialogY = y;
        try self.save();
    }

    /// Takes `edited`'s settings other than running_fields, leaving it holding the replaced values to free.
    /// Only while the chatlog worker is stopped, since it reads the ore prices.
    pub fn adopt(self: *GlobalConfig, edited: *GlobalConfig) void {
        inline for (comptime wire.savedFields(GlobalConfig)) |f| {
            if (comptime !isRunningField(f.name)) std.mem.swap(f.type, &@field(self, f.name), &@field(edited, f.name));
        }
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
    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !GlobalConfig {
        var settings: GlobalConfig = .{ .allocator = allocator };
        errdefer settings.deinit();
        try wire.fromWireInto(GlobalConfig, w, allocator, &settings);
        settings.validate();
        return settings;
    }
};

/// True if `name` is `base` with a quality word before or after it, e.g. "Shining Loparite" or "Nocxite II-Grade".
fn isGradeVariant(name: []const u8, base: []const u8) bool {
    if (base.len == 0 or base.len >= name.len) return false;
    var search_start: usize = 0;
    while (std.mem.findPos(u8, name, search_start, base)) |pos| {
        const before_ok = pos == 0 or name[pos - 1] == ' ';
        const after_pos = pos + base.len;
        const after_ok = after_pos == name.len or name[after_pos] == ' ';
        if (before_ok and after_ok) return true;
        search_start = pos + 1;
    }
    return false;
}
