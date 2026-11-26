//! The "Update Available!" prompt, shown when the window opens if the app's update check found a newer release, or from About's link to it; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const update = @import("../../update.zig");
const session = @import("session.zig");
const release_notes = @import("release_notes.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const lang = @import("../../lang/lang.zig");
const window_mod = @import("window.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Window = window_mod.Window;
const slog = log.Scoped("dialog_knots");

/// The update check runs in the background, so a window opened at startup looks once more after this.
const RETRY_DELAY_MS = 4000;
const VERSION_SIZE = 64;
const URL_SIZE = 512;

const Check = enum { pending, retrying, done };

/// One window's, reset as each opens.
pub const State = struct {
    check: Check = .pending,
    retry_at_ms: i64 = 0,
    is_open: bool = false,
    version_buf: [VERSION_SIZE]u8 = undefined,
    url_buf: [URL_SIZE]u8 = undefined,
    /// Borrows from version_buf.
    version: [:0]const u8 = "",
    /// Borrows from url_buf.
    url: [:0]const u8 = "",
    /// Owned; freed in deinit.
    notes: ?[]const u8 = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.notes) |notes| allocator.free(notes);
    }
};

/// From About's link to a found release: opens the prompt if there's a release to show; the caller draws a frame.
pub fn openIfAvailable(window: *Window) void {
    _ = openWithRelease(window, window.session.appContext().io);
}

pub fn show(window: *Window, context: *ui.Frame) !void {
    check(window, context);
    if (!window.update_notice.is_open) return;
    const dialog = try widgets.openModal(context, .src(@src()), &window.update_notice.is_open, &style.modal_wide, lang.text("Update Available!"));
    const line = Rect{ .key = .src(@src()), .style = &style.text_link_row };
    _ = try line.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("A new version is available:"), .style = &style.modal_text_inline });
    if ((try context.interact(Button{ .key = .src(@src()), .label = if (window.update_notice.version.len > 0) window.update_notice.version else window.update_notice.url, .style = &style.link })).clicked) {
        if (!win32.shellOpenUrl(window.update_notice.url)) slog.warn("Failed to open '{s}' in the browser", .{window.update_notice.url});
    }
    try line.close(context);
    if (window.update_notice.notes) |notes| try notesColumn(context, notes);
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Close"), .style = &style.outline_button })).clicked) {
        window.update_notice.is_open = false;
        context.requestRedraw();
    }
    try actions.close(context);
    try dialog.close(context);
}

/// A Text a line, its Markdown drawn as headings and bullets, since knots shows text as typed.
fn notesColumn(context: *ui.Frame, notes: []const u8) !void {
    const column = Rect{ .key = .src(@src()), .style = &style.release_notes };
    _ = try column.open(context);
    var lines: release_notes.Lines = .init(notes);
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        const key = ui.Key.str("knots.update.note").indexed(index);
        try context.e(switch (line.kind) {
            .heading => Text{ .selectable = false, .key = key, .content = line.text, .style = &style.subheading },
            .bullet => Text{ .selectable = false, .key = key, .content = try context.arena().print("\u{2022}  {s}", .{line.text}), .style = &style.modal_text },
            .text => Text{ .selectable = false, .key = key, .content = line.text, .style = &style.modal_text },
        });
    }
    try column.close(context);
}

/// Once when the window opens, and once more if the check hadn't finished yet.
fn check(window: *Window, context: *ui.Frame) void {
    const now_ms = context.ui().input.now_ms;
    switch (window.update_notice.check) {
        .done => return,
        .retrying => if (now_ms < window.update_notice.retry_at_ms) return,
        .pending => {},
    }
    if (window.session.global().get("disableUpdateChecks")) {
        window.update_notice.check = .done;
        return;
    }
    if (!openWithRelease(window, window.session.appContext().io)) {
        if (window.update_notice.check == .pending) {
            window.update_notice.check = .retrying;
            window.update_notice.retry_at_ms = now_ms + RETRY_DELAY_MS;
        } else {
            window.update_notice.check = .done;
        }
        return;
    }
    window.update_notice.check = .done;
    context.requestRedraw();
}

/// False while no release has been found.
fn openWithRelease(window: *Window, io: std.Io) bool {
    const version = update.g_update_status.terminatedVersion(io, &window.update_notice.version_buf) orelse return false;
    const url = update.g_update_status.terminatedUrl(io, &window.update_notice.url_buf) orelse return false;
    window.update_notice.version = version;
    window.update_notice.url = url;
    if (window.update_notice.notes) |notes| window.allocator.free(notes);
    window.update_notice.notes = update.g_update_status.dupeNotes(io, window.allocator);
    window.update_notice.is_open = true;
    return true;
}
