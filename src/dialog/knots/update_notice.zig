//! The "Update Available!" prompt, shown when the window opens if the app's update check found a newer release, or from About's link to it; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const update = @import("../../update.zig");
const session = @import("session.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const lang = @import("../../lang/lang.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const slog = log.Scoped("dialog_knots");

/// The update check runs in the background, so a window opened at startup looks once more after this.
const RETRY_DELAY_MS = 4000;
const VERSION_SIZE = 64;
const URL_SIZE = 512;

const Check = enum { pending, retrying, done };

var g_allocator: std.mem.Allocator = undefined;
var g_check: Check = .pending;
var g_retry_at_ms: i64 = 0;
var g_is_open: bool = false;
var g_version_buf: [VERSION_SIZE]u8 = undefined;
var g_url_buf: [URL_SIZE]u8 = undefined;
/// Borrows from g_version_buf.
var g_version: [:0]const u8 = "";
/// Borrows from g_url_buf.
var g_url: [:0]const u8 = "";
/// Owned; freed in reset.
var g_notes: ?[]const u8 = null;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    g_check = .pending;
}

/// Once the window has closed.
pub fn reset() void {
    if (g_notes) |notes| g_allocator.free(notes);
    g_notes = null;
    g_is_open = false;
}

/// From About's link to a found release: opens the prompt if there's a release to show; the caller draws a frame.
pub fn openIfAvailable() void {
    _ = openWithRelease(session.runningApp().io);
}

pub fn show(context: *ui.Frame) !void {
    check(context);
    if (!g_is_open) return;
    const dialog = widgets.modal(.src(@src()), &g_is_open, &style.modal_wide);
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Update Available!"), .style = &style.heading });
    const line = Rect{ .key = .src(@src()), .style = &style.text_link_row };
    _ = try line.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("A new version is available:"), .style = &style.modal_text_inline });
    if ((try context.interact(Button{ .key = .src(@src()), .label = if (g_version.len > 0) g_version else g_url, .style = &style.link })).clicked) {
        if (!win32.shellOpenUrl(g_url)) slog.warn("Failed to open '{s}' in the browser", .{g_url});
    }
    try line.close(context);
    if (g_notes) |notes| try context.e(Text{ .selectable = false, .key = .src(@src()), .content = notes, .style = &style.modal_text });
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Close"), .style = &style.outline_button })).clicked) {
        g_is_open = false;
        context.requestRedraw();
    }
    try actions.close(context);
    try dialog.close(context);
}

/// Once when the window opens, and once more if the check hadn't finished yet.
fn check(context: *ui.Frame) void {
    const now = context.ui().input.now_ms;
    switch (g_check) {
        .done => return,
        .retrying => if (now < g_retry_at_ms) return,
        .pending => {},
    }
    if (session.global().get("disableUpdateChecks")) {
        g_check = .done;
        return;
    }
    if (!openWithRelease(session.runningApp().io)) {
        if (g_check == .pending) {
            g_check = .retrying;
            g_retry_at_ms = now + RETRY_DELAY_MS;
        } else {
            g_check = .done;
        }
        return;
    }
    g_check = .done;
    context.requestRedraw();
}

/// False while no release has been found.
fn openWithRelease(io: std.Io) bool {
    const version = update.g_update_status.copyVersionZ(io, &g_version_buf) orelse return false;
    const url = update.g_update_status.copyUrlZ(io, &g_url_buf) orelse return false;
    g_version = version;
    g_url = url;
    if (g_notes) |notes| g_allocator.free(notes);
    g_notes = update.g_update_status.dupeNotes(io, g_allocator);
    g_is_open = true;
    return true;
}
