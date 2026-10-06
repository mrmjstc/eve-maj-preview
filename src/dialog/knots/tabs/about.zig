//! The configuration window's About tab: wordmark, version and links, credits, licences and the window's own preferences; main thread only.
const ui = @import("ui");
const build_options = @import("build_options");
const win32 = @import("../../../platform/win32.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const images = @import("../images.zig");
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const slog = log.scoped("dialog_knots");

const REPOSITORY_URL = "https://github.com/mrmjstc/eve-maj-preview";
const DISCORD_URL = "https://discord.com/users/159459744170508288";

const THANKS = [_][]const u8{ "Aulis", "Cy", "Amaliana", "Technoprobe", "Yabu Kusanagi", "Sevey", "GlassBlunt", "The Llama", "khivus" };
const THANKS_COLUMNS = 3;

pub fn show(context: *ui.Frame) !void {
    try brand(context);
    try credits(context);
    try thanks(context);
    try license(context);
    try preferences(context);
}

fn brand(context: *ui.Frame) !void {
    const section = Rect{ .key = .src(@src()), .style = &style.section };
    _ = try section.open(context);
    if (images.g_wordmark.image(.src(@src()), &style.wordmark)) |wordmark| {
        const centre = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .justify = .center, .padding = .init(0, 0, 4, 0) } };
        _ = try centre.open(context);
        try context.e(wordmark);
        try centre.close(context);
    }
    try widgets.paragraph(context, .str("knots.about.description"), "A modern, lightweight window preview tool for EVE Online, built with Zig.");
    try fact(context, "Version:", build_options.version, null);
    try fact(context, "Repository:", "github.com/mrmjstc/eve-maj-preview", REPOSITORY_URL);
    try fact(context, "Discord:", "mjstc", DISCORD_URL);
    try section.close(context);
}

/// A bold label and its value, which opens `url` in the browser when given.
fn fact(context: *ui.Frame, comptime label: []const u8, value: []const u8, url: ?[]const u8) !void {
    const row = Rect{ .key = .str("knots.about.fact:" ++ label), .style = &.{ .direction = .row, .@"align" = .center, .gap = 6 } };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = .str("knots.about.fact.label:" ++ label), .content = label, .style = &style.fact_label });
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

fn credits(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Credits", "", &style.section);
    try widgets.paragraph(context, .str("knots.about.made_by"), "Made by Mr Majestic for the APM special interest group in Goonswarm.");
    try widgets.paragraph(context, .str("knots.about.inspired_by"), "Heavily inspired by the original EVE-O Preview and related tools.");
    try section.close(context);
}

fn thanks(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Thanks", "", &style.section);
    try widgets.paragraph(context, .str("knots.about.thanks"), "Everyone in the APM special interest group for their feedback");
    var start: usize = 0;
    while (start < THANKS.len) : (start += THANKS_COLUMNS) {
        const row = Rect{ .key = ui.Key.str("knots.about.thanks.row").indexed(start), .style = &.{ .width = .grow(), .direction = .row, .gap = 16 } };
        _ = try row.open(context);
        for (THANKS[start..@min(start + THANKS_COLUMNS, THANKS.len)], start..) |name, index| {
            try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.about.thanks.name").indexed(index), .content = name, .style = &style.thanks_name });
        }
        try row.close(context);
    }
    try section.close(context);
}

fn license(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "License", "", &style.section);
    try widgets.paragraph(context, .str("knots.about.license"), "This project is open source and released under the GNU General Public License v3.0 (GPLv3). A copy of the license is included with the application.");
    try widgets.paragraph(context, .str("knots.about.third_party"), "This application bundles third-party components: the Geist and Cascadia Code fonts (SIL Open Font License 1.1) and knots (MIT License). Their license texts are included with the application.");
    try section.close(context);
}

fn preferences(context: *ui.Frame) !void {
    const section = try widgets.openSection(
        context,
        "Preferences",
        "Reveals power-user settings across the app (extra tabs, position/spacing parameters, snapping, layout system, and more). These preferences are global and apply across all profiles.",
        &style.section,
    );
    const global = session.global();
    try bind.toggle(context, global, "advancedMode", "Advanced Mode");
    const was_on_top = global.get("alwaysOnTop");
    try bind.toggle(context, global, "alwaysOnTop", "Always on Top");
    if (global.get("alwaysOnTop") != was_on_top) host.setAlwaysOnTop(!was_on_top);
    try section.close(context);
}
