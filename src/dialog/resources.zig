//! The configuration window's files: the page, built per window, and the static modules, styles, font, image and language catalogs it loads.
const std = @import("std");

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

/// Caller owns the returned page.
pub fn buildPage(allocator: std.mem.Allocator, lang: Lang, ui_scale: f32) ![:0]u8 {
    var scale_buf: [16]u8 = undefined;
    const scale = std.fmt.bufPrint(&scale_buf, "{d:.2}", .{ui_scale}) catch unreachable;
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
    return allocator.dupeZ(u8, page);
}

/// webui's file handler: a complete HTTP response for one of the page's static files, or null to let webui handle the path.
pub fn serveFile(path: []const u8) ?[]const u8 {
    const name = std.mem.trimStart(u8, path, "/");
    for (static_files) |static| {
        if (std.mem.eql(u8, name, static.name)) return static.response;
    }
    return null;
}

/// Every module under ui/; one missing here is a 404 that stops the page loading.
const modules = [_][]const u8{
    "main",          "core",           "state",          "i18n",
    "colors",        "form",           "changes",        "binding",
    "layout",        "session",        "region",         "profiles",
    "import",        "hotkeys",        "update",         "snake",
    "widgets",       "window_filters", "characters",     "system_colors",
    "ultra_potato",  "hotkey_groups",  "global_settings", "global_hotkeys",
    "ore_table",     "notifications",  "options",        "overlay_layout",
    "search",        "color_picker",
};

const StaticFile = struct { name: []const u8, response: []const u8 };

/// Built at compile time, so serving a file is a lookup; webui never frees memory it didn't allocate itself.
const static_files = blk: {
    @setEvalBranchQuota(100_000);
    var list: []const StaticFile = &.{
        staticFile("style.css", "text/css; charset=utf-8", @embedFile("ui/style.css")),
        staticFile("catalogs.js", "text/javascript; charset=utf-8", catalogsModule()),
        staticFile("CascadiaCode.woff2", "font/woff2", @embedFile("../assets/fonts/CascadiaCode.woff2")),
        staticFile("layout_preview.jpg", "image/jpeg", @embedFile("../assets/layout_preview.jpg")),
    };
    for (modules) |module| {
        list = list ++ &[_]StaticFile{staticFile(module ++ ".js", "text/javascript; charset=utf-8", @embedFile("ui/" ++ module ++ ".js"))};
    }
    break :blk list;
};

fn staticFile(comptime name: []const u8, comptime content_type: []const u8, comptime body: []const u8) StaticFile {
    return .{
        .name = name,
        .response = "HTTP/1.1 200 OK\r\nContent-Type: " ++ content_type ++ "\r\nContent-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\nCache-Control: no-store\r\n\r\n" ++ body,
    };
}

/// Every catalog, so switching language needs no reload, plus each language's own name for the language list.
fn catalogsModule() []const u8 {
    comptime {
        var catalogs: []const u8 = "export const catalogs = {";
        var names: []const u8 = "export const languageNames = {";
        for (std.meta.fields(Lang), 0..) |field, i| {
            const lang: Lang = @enumFromInt(field.value);
            const separator = if (i == 0) "" else ",";
            catalogs = catalogs ++ separator ++ "\"" ++ field.name ++ "\":" ++ lang.catalog();
            names = names ++ separator ++ "\"" ++ field.name ++ "\":\"" ++ lang.displayName() ++ "\"";
        }
        return catalogs ++ "};\n" ++ names ++ "};\n";
    }
}

/// The app icon inlined as a data URL, encoded at compile time.
const FAVICON_TAG = blk: {
    const icon = @embedFile("../assets/icon.ico");
    const encoder = std.base64.standard.Encoder;
    @setEvalBranchQuota(1_000_000);
    var encoded: [encoder.calcSize(icon.len)]u8 = undefined;
    _ = encoder.encode(&encoded, icon);
    const final = encoded;
    break :blk "<link rel=\"icon\" type=\"image/x-icon\" href=\"data:image/x-icon;base64," ++ final ++ "\">";
};
