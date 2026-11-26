//! The configuration window's Performance tab: Client Speed, which sets each client's CPU priority and efficiency mode; main thread only.
const ui = @import("ui");
const style = @import("../style.zig");
const window_mod = @import("../window.zig");

const Window = window_mod.Window;

pub fn show(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSharedSection(context, "Client Speed", "How much of the PC each EVE client gets. Undone when EVE-Maj Preview exits.", &style.section);
    const speed = window.session.global().child("clientSpeed");
    try window.bind.toggle(context, speed, "raiseFocusedClient", "Raise the Focused Client's Priority");
    try window.widgets.hintText(context, .src(@src()), "Above Normal CPU priority for the client you're in.");
    try window.bind.toggle(context, speed, "lowerBackgroundClients", "Lower Background Clients' Priority");
    try window.widgets.hintText(context, .src(@src()), "Below Normal CPU priority for the others, once you stop switching.");
    try window.bind.toggle(context, speed, "backgroundEfficiencyMode", "Efficiency Mode for Background Clients");
    try window.widgets.hintText(context, .src(@src()), "Less power and heat; their thumbnails may update less smoothly.");
    try window.widgets.hintText(context, .src(@src()), "Characters set to Keep at Full Speed are never slowed down.");
    try section.close(context);
}
