//! The configuration window's General tab: log monitoring, app-wide preferences, startup and protocol links, then, in Advanced Mode, logging; main thread only.
const ui = @import("ui");
const win32 = @import("../../../platform/win32.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const chatlog = @import("chatlog.zig");
const window_mod = @import("../window.zig");
const log = @import("../../../log.zig");

const Window = window_mod.Window;
const slog = log.Scoped("dialog_knots");

const PROTOCOL_DOCS_URL = "https://github.com/mrmjstc/eve-maj-preview/blob/main/docs/CONFIGURATION.md#command-line-and-protocol";

pub fn show(window: *Window, context: *ui.Frame) !void {
    // First, so the "Go to Log Monitoring" notices land on it.
    try chatlog.show(window, context);
    try preferences(window, context);
    try startup(window, context);
    try protocolLinks(window, context);
    if (window.session.global().get("advancedMode")) try logging(window, context);
}

fn preferences(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSharedSection(context, "Preferences", "Settings for the app itself.", &style.section);
    const global = window.session.global();
    try window.bind.choice(context, global, "language", "Language");
    try window.widgets.hintText(context, .src(@src()), "Also used for the app's on-screen messages.");
    try window.bind.toggle(context, global, "advancedMode", "Advanced Mode");
    try window.widgets.hintText(context, .src(@src()), "Shows extra, rarely changed settings and tabs.");
    const was_on_top = global.get("alwaysOnTop");
    try window.bind.toggle(context, global, "alwaysOnTop", "Always on Top");
    try window.widgets.hintText(context, .src(@src()), "Keeps this window above other windows.");
    if (global.get("alwaysOnTop") != was_on_top) window.host.setAlwaysOnTop(!was_on_top);
    try section.close(context);
}

fn startup(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSharedSection(context, "Startup", "Starting with Windows and update checks.", &style.section);
    const global = window.session.global();
    try window.bind.toggle(context, global, "runOnStartup", "Run on Startup");
    try window.widgets.hintText(context, .src(@src()), "Starts EVE-Maj Preview when you sign in to Windows.");
    try window.bind.invertedToggle(context, global, "disableUpdateChecks", "Check for Updates");
    try window.widgets.hintText(context, .src(@src()), "Looks online for a new version at startup.");
    try section.close(context);
}

fn protocolLinks(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSharedSection(context, "Protocol Links", "Links in other apps, like Stream Deck buttons, that control EVE-Maj Preview.", &style.section);
    const global = window.session.global();
    var is_registering: bool = global.get("autoRegisterProtocol");
    const clicked = try window.widgets.switchRowWithLink(context, .src(@src()), "Auto-Register Protocol Handler", "Learn more", &is_registering);
    if (clicked.is_flipped) global.set("autoRegisterProtocol", is_registering);
    if (clicked.is_link_clicked and !win32.shellOpenUrl(PROTOCOL_DOCS_URL)) slog.warn("Failed to open '{s}' in the browser", .{PROTOCOL_DOCS_URL});
    try window.widgets.hintText(context, .src(@src()), "Lets links in other apps control EVE-Maj Preview.");
    const links = global.child("protocolLinks");
    try window.bind.toggle(context, links, "allowCloseAll", "Allow Links to Close All Clients");
    try window.widgets.hintText(context, .src(@src()), "Lets a link close every client; any web page can open one.");
    try window.bind.toggle(context, links, "allowCloseActive", "Allow Links to Close the Focused Client");
    try window.widgets.hintText(context, .src(@src()), "Lets a link close the client you're in; any web page can open one.");
    try window.bind.toggle(context, links, "allowCloseGroup", "Allow Links to Close a Group");
    try window.widgets.hintText(context, .src(@src()), "Lets a link close a hotkey group's clients; any web page can open one.");
    try window.bind.toggle(context, links, "allowExitApp", "Allow Links to Exit the App");
    try window.widgets.hintText(context, .src(@src()), "Lets a link exit EVE-Maj Preview; any web page can open one.");
    try section.close(context);
}

fn logging(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSharedSection(context, "Logging", "How much detail is written to the log file.", &style.section);
    try window.bind.choice(context, window.session.global(), "logLevel", "Log Level");
    try window.widgets.hintText(context, .src(@src()), "Use Debug when reporting a problem.");
    try section.close(context);
}
