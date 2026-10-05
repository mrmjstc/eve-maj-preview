//! The configuration window's files: the page, built per window, and the static MODULES, styles, font, image and language catalogs it loads.
const std = @import("std");

/// Every module under ui/; one missing here is a 404 that stops the page loading.
const MODULES = [_][]const u8{
    "main",         "core",           "state",           "i18n",
    "colors",       "form",           "changes",         "binding",
    "layout",       "session",        "region",          "profiles",
    "import",       "hotkeys",        "update",          "snake",
    "widgets",      "window_filters", "characters",      "system_colors",
    "ultra_potato", "hotkey_groups",  "global_settings", "global_hotkeys",
    "ore_table",    "notifications",  "options",         "overlay_layout",
    "search",       "color_picker",   "thumbnail_size",
};

/// Built at compile time, so serving a file is a lookup.
const STATIC_FILES = blk: {
    @setEvalBranchQuota(100_000);
    var list: []const StaticFile = &.{
        embedded("style.css", "text/css; charset=utf-8", @embedFile("ui/style.css")),
        embedded("catalogs.js", "text/javascript; charset=utf-8", catalogsModule()),
        embedded("CascadiaCode.woff2", "font/woff2", @embedFile("../assets/fonts/CascadiaCode.woff2")),
        embedded("layout_preview.jpg", "image/jpeg", @embedFile("../assets/layout_preview.jpg")),
        embedded("icon.svg", "image/svg+xml", @embedFile("../assets/icon.svg")),
        embedded("wordmark.svg", "image/svg+xml", @embedFile("../assets/wordmark.svg")),
    };
    for (MODULES) |module| {
        list = list ++ &[_]StaticFile{embedded(module ++ ".js", "text/javascript; charset=utf-8", @embedFile("ui/" ++ module ++ ".js"))};
    }
    break :blk list;
};

/// The app icon inlined as a data URL, encoded at compile time.
const FAVICON_TAG = blk: {
    const icon = @embedFile("../assets/icon.svg");
    const encoder = std.base64.standard.Encoder;
    @setEvalBranchQuota(1_000_000);
    var encoded: [encoder.calcSize(icon.len)]u8 = undefined;
    _ = encoder.encode(&encoded, icon);
    const final = encoded;
    break :blk "<link rel=\"icon\" type=\"image/svg+xml\" href=\"data:image/svg+xml;base64," ++ final ++ "\">";
};

/// Add a language by dropping src/lang/xx.json in and adding one variant here plus one arm each in `catalog()` and `displayName()`.
pub const Lang = enum {
    en,
    de,
    ru,
    zh,
    pt,
    es,
    fr,
    pl,

    pub fn fromCode(code: []const u8) Lang {
        return std.meta.stringToEnum(Lang, code) orelse .en;
    }

    fn catalog(self: Lang) []const u8 {
        return switch (self) {
            .en => @embedFile("../lang/en.json"),
            .de => @embedFile("../lang/de.json"),
            .ru => @embedFile("../lang/ru.json"),
            .zh => @embedFile("../lang/zh.json"),
            .pt => @embedFile("../lang/pt.json"),
            .es => @embedFile("../lang/es.json"),
            .fr => @embedFile("../lang/fr.json"),
            .pl => @embedFile("../lang/pl.json"),
        };
    }

    fn displayName(self: Lang) []const u8 {
        return switch (self) {
            .en => "English",
            .de => "Deutsch",
            .ru => "Русский",
            .zh => "简体中文",
            .pt => "Português",
            .es => "Español",
            .fr => "Français",
            .pl => "Polski",
        };
    }
};

pub const File = struct { content_type: [:0]const u8, body: []const u8 };

const StaticFile = struct { name: []const u8, file: File };

/// Caller owns the returned page.
pub fn buildPage(allocator: std.mem.Allocator, lang: Lang, ui_scale: f32) ![:0]u8 {
    var scale_buf: [16]u8 = undefined;
    const scale = std.mem.print(&scale_buf, "{d:.2}", .{ui_scale}) catch unreachable;
    const replacements = [_][2][]const u8{
        .{ "LANG_PLACEHOLDER", @tagName(lang) },
        .{ "UI_SCALE_PLACEHOLDER", scale },
        .{ "FAVICON_PLACEHOLDER", FAVICON_TAG },
    };
    var page: []u8 = try allocator.dupe(u8, @embedFile("ui/index.html"));
    defer allocator.free(page);
    for (replacements) |r| {
        const replaced = try std.mem.replaceOwned(u8, allocator, page, r[0], r[1]);
        allocator.free(page);
        page = replaced;
    }
    return allocator.dupeSentinel(u8, page, 0);
}

pub fn staticFile(name: []const u8) ?File {
    for (STATIC_FILES) |static| {
        if (std.mem.eql(u8, name, static.name)) return static.file;
    }
    return null;
}

fn embedded(comptime name: []const u8, comptime content_type: [:0]const u8, comptime body: []const u8) StaticFile {
    return .{ .name = name, .file = .{ .content_type = content_type, .body = body } };
}

/// Every catalog, so switching language needs no reload, plus each language's own name for the language list.
fn catalogsModule() []const u8 {
    comptime {
        var catalogs: []const u8 = "export const catalogs = {";
        var names: []const u8 = "export const languageNames = {";
        for (@typeInfo(Lang).@"enum".field_names, 0..) |name, i| {
            const lang = @field(Lang, name);
            const separator = if (i == 0) "" else ",";
            catalogs = catalogs ++ separator ++ "\"" ++ name ++ "\":" ++ lang.catalog();
            names = names ++ separator ++ "\"" ++ name ++ "\":\"" ++ lang.displayName() ++ "\"";
        }
        return catalogs ++ "};\n" ++ names ++ "};\n";
    }
}
