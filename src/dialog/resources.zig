//! The configuration window's page, assembled from the embedded HTML, CSS, JS, fonts and language catalogs.
const std = @import("std");
const files = @import("../config/files.zig");
const log = @import("../log.zig");

const slog = log.scoped("dialog");

const page_html = @embedFile("../config_dialog.html");
const page_css = @embedFile("../config_dialog.css");
const page_js = @embedFile("../config_dialog.js");
const layout_preview_jpg = @embedFile("../assets/layout_preview.jpg");
const cascadia_code_woff2 = @embedFile("../assets/fonts/CascadiaCode.woff2");

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
    var html: []u8 = try allocator.dupe(u8, page_html);
    defer allocator.free(html);

    var scale_buf: [16]u8 = undefined;
    const scale_str = std.fmt.bufPrint(&scale_buf, "{d:.2}", .{ui_scale}) catch unreachable;

    const layout_preview = try base64(allocator, layout_preview_jpg);
    defer allocator.free(layout_preview);
    const font = try base64(allocator, cascadia_code_woff2);
    defer allocator.free(font);

    const catalog_js = try std.fmt.allocPrint(allocator, "window.__I18N__ = {s};", .{lang.catalog()});
    defer allocator.free(catalog_js);
    const langs_js = try buildLangListScript(allocator);
    defer allocator.free(langs_js);
    const all_catalogs_js = try buildAllCatalogsScript(allocator);
    defer allocator.free(all_catalogs_js);
    const html_lang = try std.fmt.allocPrint(allocator, "<html lang=\"{s}\" class=\"pre-init\">", .{@tagName(lang)});
    defer allocator.free(html_lang);

    const favicon = faviconTag(allocator) catch |err| blk: {
        slog.warn("Failed to load icon.ico for favicon: {}", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(favicon);

    const replacements = [_][2][]const u8{
        .{ "/* Styles will be injected here by WebUI */", page_css },
        .{ "UI_SCALE_PLACEHOLDER", scale_str },
        .{ "LAYOUT_PREVIEW_IMAGE_PLACEHOLDER", layout_preview },
        .{ "CASCADIA_CODE_WOFF2_PLACEHOLDER", font },
        .{ "// Script will be injected here by WebUI", page_js },
        .{ "<!-- Favicon will be injected here by WebUI -->", favicon },
        .{ "window.__I18N__ = {}; /* Translations will be injected here by WebUI */", catalog_js },
        .{ "window.__I18N_LANGS__ = {}; /* Language list will be injected here by WebUI */", langs_js },
        .{ "window.__I18N_ALL__ = {}; /* All translations will be injected here by WebUI */", all_catalogs_js },
        .{ "<html lang=\"en\" class=\"pre-init\">", html_lang },
    };
    for (replacements) |r| {
        const replaced = try std.mem.replaceOwned(u8, allocator, html, r[0], r[1]);
        allocator.free(html);
        html = replaced;
    }

    return allocator.dupeZ(u8, html);
}

fn base64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(data.len));
    _ = encoder.encode(encoded, data);
    return encoded;
}

fn faviconTag(allocator: std.mem.Allocator) ![]u8 {
    const icon_data = try std.Io.Dir.cwd().readFileAlloc(files.g_io, "icon.ico", allocator, .limited(1024 * 1024));
    defer allocator.free(icon_data);
    const encoded = try base64(allocator, icon_data);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "<link rel=\"icon\" type=\"image/x-icon\" href=\"data:image/x-icon;base64,{s}\">", .{encoded});
}

/// `{"en":"English",...}` from every Lang variant, so the language dropdown can't drift from `catalog()`.
fn buildLangListScript(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "window.__I18N_LANGS__ = {");
    inline for (std.meta.fields(Lang), 0..) |field, i| {
        if (i != 0) try buf.append(allocator, ',');
        const lang: Lang = @enumFromInt(field.value);
        try buf.print(allocator, "\"{s}\":\"{s}\"", .{ field.name, lang.displayName() });
    }
    try buf.appendSlice(allocator, "};");
    return buf.toOwnedSlice(allocator);
}

/// Every catalog at once, so switching language needs no reload.
fn buildAllCatalogsScript(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "window.__I18N_ALL__ = {");
    inline for (std.meta.fields(Lang), 0..) |field, i| {
        if (i != 0) try buf.append(allocator, ',');
        const lang: Lang = @enumFromInt(field.value);
        try buf.print(allocator, "\"{s}\":{s}", .{ field.name, lang.catalog() });
    }
    try buf.appendSlice(allocator, "};");
    return buf.toOwnedSlice(allocator);
}
