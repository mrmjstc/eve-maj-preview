//! The configuration window's General tab: log monitoring, app-wide preferences and startup, then, in Advanced Mode, logging; main thread only.
const ui = @import("ui");
const win32 = @import("../../../platform/win32.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const chatlog = @import("chatlog.zig");
const log = @import("../../../log.zig");

const slog = log.Scoped("dialog_knots");

const PROTOCOL_DOCS_URL = "https://github.com/mrmjstc/eve-maj-preview/blob/main/docs/CONFIGURATION.md#command-line-and-protocol";

pub fn show(context: *ui.Frame) !void {
    // First, so the "Go to Log Monitoring" notices land on it.
    try chatlog.show(context);
    try preferences(context);
    try startup(context);
    if (session.global().get("advancedMode")) try logging(context);
}

fn preferences(context: *ui.Frame) !void {
    const section = try widgets.openSharedSection(context, "Preferences", "Settings for the app itself.", &style.section);
    const global = session.global();
    try bind.choice(context, global, "language", "Language");
    try widgets.hintText(context, .src(@src()), "Also used for the app's on-screen messages.");
    try bind.toggle(context, global, "advancedMode", "Advanced Mode");
    try widgets.hintText(context, .src(@src()), "Shows extra, rarely changed settings and tabs.");
    const was_on_top = global.get("alwaysOnTop");
    try bind.toggle(context, global, "alwaysOnTop", "Always on Top");
    try widgets.hintText(context, .src(@src()), "Keeps this window above other windows.");
    if (global.get("alwaysOnTop") != was_on_top) host.setAlwaysOnTop(!was_on_top);
    try section.close(context);
}

fn startup(context: *ui.Frame) !void {
    const section = try widgets.openSharedSection(context, "Startup", "Starting with Windows, control from other apps, and update checks.", &style.section);
    const global = session.global();
    try bind.toggle(context, global, "runOnStartup", "Run on Startup");
    try widgets.hintText(context, .src(@src()), "Starts EVE-Maj Preview when you sign in to Windows.");
    var is_registering: bool = global.get("autoRegisterProtocol");
    const clicked = try widgets.switchRowWithLink(context, .src(@src()), "Auto-Register Protocol Handler", "Learn more", &is_registering);
    if (clicked.is_flipped) global.set("autoRegisterProtocol", is_registering);
    if (clicked.is_link_clicked and !win32.shellOpenUrl(PROTOCOL_DOCS_URL)) slog.warn("Failed to open '{s}' in the browser", .{PROTOCOL_DOCS_URL});
    try widgets.hintText(context, .src(@src()), "Lets links in other apps control EVE-Maj Preview.");
    try bind.invertedToggle(context, global, "disableUpdateChecks", "Check for Updates");
    try widgets.hintText(context, .src(@src()), "Looks online for a new version at startup.");
    try section.close(context);
}

fn logging(context: *ui.Frame) !void {
    const section = try widgets.openSharedSection(context, "Logging", "How much detail is written to the log file.", &style.section);
    try bind.choice(context, session.global(), "logLevel", "Log Level");
    try widgets.hintText(context, .src(@src()), "Use Debug when reporting a problem.");
    try section.close(context);
}
