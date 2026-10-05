//! The configuration window's Behavior tab; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

pub fn show(context: *ui.Frame) !void {
    try startup(context);
    try interaction(context);
    try autoMinimize(context);
    try exclusion(context);
    try windowPosition(context);
    if (session.global().get("advancedMode")) try ultraPotato(context);
}

fn startup(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Startup", "Launch on Windows login, and register the evemajpreview:// URL protocol for external control (Stream Deck, scripts, etc.).", .global, &style.section);
    const global = session.global();
    try bind.toggle(context, global, "runOnStartup", "Run on Startup");
    try bind.toggle(context, global, "autoRegisterProtocol", "Auto-Register Protocol Handler");
    try widgets.hintText(context, .src(@src()), "Needed once for links like evemajpreview://cycle-next to work from other apps.");
    try bind.toggle(context, global, "disableUpdateChecks", "Disable Update Checks");
    try section.close(context);
}

fn interaction(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Interaction", "Mouse behavior for repositioning and activating thumbnails, including when to activate the EVE client window on left-click, and whether client windows animate when restored or minimized.", .profile, &style.section);
    const ref = session.profile().child("interaction");
    try bind.toggle(context, ref, "clickThrough", "Click Through Thumbnails");
    try widgets.hintText(context, .src(@src()), "Thumbnails ignore all mouse input and let clicks/drags pass through to whatever is behind them; disables click-to-focus, exclusion toggling, and dragging.");
    try bind.toggle(context, ref, "enableDragging", "Enable Dragging");
    try widgets.hintText(context, .src(@src()), "Has no effect while Thumbnail Space is enabled, since it places every thumbnail.");
    try bind.choice(context, ref, "clickTrigger", "Click Trigger");
    try widgets.hintText(context, .src(@src()), "Mouse Up avoids accidental drags from a quick click.");
    try bind.choice(context, ref, "hoverCursor", "Hover Cursor");
    try widgets.hintText(context, .src(@src()), "Mouse cursor shown while hovering a thumbnail.");
    try bind.choice(context, ref, "animationStyle", "Animation Style");
    try widgets.hintText(context, .src(@src()), "No Animation restores and minimizes clients instantly; Original Animation keeps Windows' native effect.");
    try bind.toggle(context, ref, "hoverZoomEnabled", "Zoom on Hover");
    try widgets.hintText(context, .src(@src()), "Shows an enlarged copy of a thumbnail, with its overlay text, while the cursor rests on it.");
    try bind.number(context, ref, "hoverZoomPercent", "Zoom Size (%)", .{});
    try widgets.hintText(context, .src(@src()), "Size of the zoom relative to the thumbnail, shrunk if needed to fit its monitor.");
    try bind.choice(context, ref, "hoverZoomAnchor", "Zoom Anchor");
    try widgets.hintText(context, .src(@src()), "The point of the thumbnail that stays in place as the zoom grows.");
    try section.close(context);
}

fn autoMinimize(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Auto-Minimize", "Minimizes an EVE client window after it's been unfocused for the configured delay.", .profile, &style.section);
    const ref = session.profile().child("autoMinimize");
    try bind.toggle(context, ref, "enabled", "Enable Auto-Minimize");
    try bind.toggle(context, ref, "exemptLastActiveOnFocusLoss", "Keep Last-Active Client Visible");
    try widgets.hintText(context, .src(@src()), "Exempts whichever client you focused most recently, even past the delay.");
    try bind.number(context, ref, "delayMs", "Delay (s)", .{ .ms_as_seconds = true });
    try widgets.hintText(context, .src(@src()), "How long a client can sit unfocused before it's minimized.");
    try section.close(context);
}

fn exclusion(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Character Exclusion", "Controls Shift+Click exclusion of characters from hotkey cycling.", .profile, &style.section);
    const ref = session.profile().child("exclusion");
    try bind.toggle(context, ref, "enableShiftClickExclude", "Enable Shift+Click to Exclude");
    try bind.toggle(context, ref, "autoMinimizeExcluded", "Auto-Minimize Excluded Characters");
    try widgets.hintText(context, .src(@src()), "Minimizes immediately on exclusion, not on the Auto-Minimize delay above.");
    try bind.toggle(context, ref, "logoutClearsExclusion", "Logging Out Clears Exclusion");
    try widgets.hintText(context, .src(@src()), "Includes a character again once its client returns to the login screen.");
    const thumbnail = session.profile().child("thumbnail");
    try bind.choice(context, thumbnail, "exclusionOverlayStyle", "Overlay Style");
    try bind.colorAndOpacity(context, thumbnail, "exclusionOverlayColor", "Overlay Color", "Overlay Opacity");
    try section.close(context);
}

fn windowPosition(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Window Position", "Saves each character's real EVE client window position, restored via the Move to Saved Positions hotkey or automatically on login.", .profile, &style.section);
    const ref = session.profile().child("autoMovePosition");
    try bind.toggle(context, ref, "enabled", "Restore Saved Position on Login");
    try widgets.hintText(context, .src(@src()), "Moves a client to its saved position when its character logs in.");
    try bind.toggle(context, ref, "moveOnStartup", "Restore Saved Position on App Startup");
    try widgets.hintText(context, .src(@src()), "Moves clients already logged in when the app launches.");
    try bind.number(context, ref, "verifyIntervalMs", "Re-check Interval (s)", .{ .ms_as_seconds = true });
    try widgets.hintText(context, .src(@src()), "How often a moved client's position is re-checked; EVE can shift its own window while loading.");
    try bind.number(context, ref, "verifyCount", "Re-check Count", .{});
    try widgets.hintText(context, .src(@src()), "How many times to re-check and re-apply the position after a move. 0 disables re-checking.");
    try widgets.notPorted(context, .src(@src()), "Set All and Clear All for saved positions");
    try section.close(context);
}

fn ultraPotato(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Ultra Potato Mode", "Forces EVE Online's heaviest graphics settings (shaders, shadows, textures, reflections, post-processing, cloth, ambient occlusion, volumetrics) to their lowest quality. Close all EVE clients first - the client overwrites these files on exit. A .bak backup of each file is made before its first edit.", .none, &style.section);
    try widgets.notPorted(context, .src(@src()), "Ultra Potato Mode");
    try section.close(context);
}
