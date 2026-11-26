//! The configuration window's About tab: wordmark, version and links, credits and licences; main thread only.
const ui = @import("ui");
const build_options = @import("build_options");
const win32 = @import("../../../platform/win32.zig");
const update = @import("../../../update.zig");
const session = @import("../session.zig");
const update_notice = @import("../update_notice.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const images = @import("../images.zig");
const lang = @import("../../../lang/lang.zig");
const window_mod = @import("../window.zig");
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Window = window_mod.Window;
const slog = log.Scoped("dialog_knots");

const REPOSITORY_URL = "https://github.com/mrmjstc/eve-maj-preview";
const DISCORD_URL = "https://discord.com/users/159459744170508288";

const THANKS = [_][]const u8{ "Aulis", "Cy", "Amaliana", "Technoprobe", "Yabu Kusanagi", "Sevey", "GlassBlunt", "The Llama", "khivus" };
const THANKS_COLUMNS = 3;
/// Holds a release's tag, e.g. "v1.0.9".
const VERSION_TEXT_MAX = 64;
/// A bold label then its value, inset like a row.
const FACT_ROW: ui.Style = .{ .direction = .row, .@"align" = .center, .gap = 6, .padding = .xy(style.ROW_INSET, 0) };

pub fn show(window: *Window, context: *ui.Frame) !void {
    try brand(window, context);
    try credits(window, context);
    try thanks(window, context);
    try license(window, context);
}

fn brand(window: *Window, context: *ui.Frame) !void {
    const section = Rect{ .key = .src(@src()), .style = &style.section };
    _ = try section.open(context);
    if (window.images.image(.wordmark, .src(@src()), &style.wordmark)) |wordmark| {
        const centre = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .justify = .center, .padding = .init(0, 0, 4, 0) } };
        _ = try centre.open(context);
        try context.e(wordmark);
        try centre.close(context);
    }
    try window.widgets.paragraph(context, .str("knots.about.description"), "A modern, lightweight window preview tool for EVE Online, built with Zig.");
    try versionFact(window, context);
    try fact(context, "Repository:", "github.com/mrmjstc/eve-maj-preview", REPOSITORY_URL);
    try fact(context, "Discord:", "mjstc", DISCORD_URL);
    try section.close(context);
}

/// A bold label and its value, which opens `url` in the browser when given.
fn fact(context: *ui.Frame, comptime label: []const u8, value: []const u8, url: ?[]const u8) !void {
    const row = Rect{ .key = .str("knots.about.fact:" ++ label), .style = &FACT_ROW };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = .str("knots.about.fact.label:" ++ label), .content = lang.text(label), .style = &style.fact_label });
    const target = url orelse {
        try context.e(Text{ .selectable = false, .key = .str("knots.about.fact.value:" ++ label), .content = value, .style = &style.hint_plain });
        try row.close(context);
        return;
    };
    if ((try context.interact(Button{ .key = .str("knots.about.fact.link:" ++ label), .label = value, .style = &style.link })).clicked) {
        if (!win32.shellOpenUrl(target)) slog.warn("Failed to open '{s}' in the browser", .{target});
    }
    try row.close(context);
}

/// The version, then a link to a newer release once a check has found one.
fn versionFact(window: *Window, context: *ui.Frame) !void {
    const row = Rect{ .key = .src(@src()), .style = &FACT_ROW };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Version:"), .style = &style.fact_label });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = build_options.version, .style = &style.hint_plain });
    var buf: [VERSION_TEXT_MAX]u8 = undefined;
    if (update.g_update_status.terminatedVersion(window.session.appContext().io, &buf)) |version| {
        const label = try lang.format(context.arena(), "{version} available", .{ .version = version });
        if ((try context.interact(Button{ .key = .src(@src()), .label = label, .style = &style.link })).clicked) {
            update_notice.openIfAvailable(window);
            context.requestRedraw();
        }
    }
    try row.close(context);
}

fn credits(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Credits", "", &style.section);
    try window.widgets.paragraph(context, .str("knots.about.made_by"), "Made by Mr Majestic for the APM special interest group in Goonswarm.");
    try window.widgets.paragraph(context, .str("knots.about.inspired_by"), "Heavily inspired by the original EVE-O Preview and related tools.");
    try section.close(context);
}

fn thanks(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Thanks", "", &style.section);
    try window.widgets.paragraph(context, .str("knots.about.thanks"), "Everyone in the APM special interest group for their feedback");
    var start: usize = 0;
    while (start < THANKS.len) : (start += THANKS_COLUMNS) {
        const row = Rect{ .key = ui.Key.str("knots.about.thanks.row").indexed(start), .style = &.{ .width = .grow(), .direction = .row, .gap = 16, .padding = .xy(style.ROW_INSET, 0) } };
        _ = try row.open(context);
        for (THANKS[start..@min(start + THANKS_COLUMNS, THANKS.len)], start..) |name, index| {
            try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.about.thanks.name").indexed(index), .content = name, .style = &style.thanks_name });
        }
        try row.close(context);
    }
    try section.close(context);
}

fn license(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "License", "", &style.section);
    try window.widgets.paragraph(context, .str("knots.about.license"), "This project is open source and released under the GNU General Public License v3.0 (GPLv3). A copy of the license is included with the application.");
    try window.widgets.paragraph(context, .str("knots.about.third_party"), "This application bundles third-party components: the Geist and Cascadia Code fonts (SIL Open Font License 1.1) and knots (MIT License). Their license texts are included with the application.");
    try section.close(context);
}
