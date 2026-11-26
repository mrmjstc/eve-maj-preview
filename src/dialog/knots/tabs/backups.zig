//! The configuration window's Backups tab: backing up the running profile, and profiles kept when they were backed up, deleted, reset, imported over or couldn't be read, each restored or deleted for good; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../../platform/win32.zig");
const config = @import("../../../config.zig");
const host = @import("../host.zig");
const profiles = @import("../profiles.zig");
const session = @import("../session.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const lang = @import("../../../lang/lang.zig");
const window_mod = @import("../window.zig");
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Window = window_mod.Window;
const slog = log.Scoped("dialog_knots");

const ROW_KEY: ui.Key = .str("knots.backups.row");

/// One window's, reset as each opens.
pub const State = struct {
    /// Holds the backup names; replaced on each scan, freed in deinit.
    arena: ?std.heap.ArenaAllocator = null,
    /// Newest first; borrows from arena.
    backups: []const []const u8 = &.{},
    /// profiles.revision at the last scan, so a profile deleted since then shows up.
    scanned_revision: ?u32 = null,

    pub fn deinit(self: *State) void {
        if (self.arena) |*arena| arena.deinit();
    }
};

pub fn show(window: *Window, context: *ui.Frame) !void {
    if (window.backups.scanned_revision != profiles.revision(window)) scan(window);
    const section = try window.widgets.openSection(context, "Profile Backups", "Copies kept when a profile is deleted, reset, imported over or fails to load.", &style.section);
    try actions(window, context);
    const arena = context.arena();
    for (window.backups.backups, 0..) |backup, index| {
        const row = try window.widgets.openRow(context, ROW_KEY.indexed(index));
        const parsed = config.parseBackupName(backup);
        try context.e(Text{ .selectable = false, .key = ROW_KEY.indexed(index).indexed(1), .content = parsed.name, .style = &style.label_aligned });
        if (parsed.saved_at_seconds) |seconds| try context.e(Text{ .selectable = false, .key = ROW_KEY.indexed(index).indexed(4), .content = try savedAt(arena, seconds), .style = &style.muted_text });
        if ((try context.interact(Button{ .key = ROW_KEY.indexed(index).indexed(2), .label = lang.text("Restore"), .style = &style.plain_button })).clicked) {
            window.host.restoreBackup(backup, parsed.name);
            // The prompt it opens is drawn by the header, which this frame has already drawn.
            context.requestRedraw();
        }
        if (try window.widgets.confirmButton(context, ROW_KEY.indexed(index).indexed(3), "\u{00D7}", "OK", &style.icon_button_danger_text, &style.icon_button_confirm)) {
            profiles.request(window, .delete_backup, backup, null);
        }
        try row.close(context);
    }
    try section.close(context);
}

/// Back Up for the running profile and Open Backups Folder, above the list.
fn actions(window: *Window, context: *ui.Frame) !void {
    const running = window.session.profile().ptr.profile_name;
    const row = try window.widgets.openRow(context, .src(@src()));
    // The empty state takes the row's spare width, pushing the buttons right as the spacer does.
    if (window.backups.backups.len == 0) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("No backups yet."), .style = &style.empty_list_text });
    } else {
        try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    }
    const label = try lang.format(context.arena(), "Back Up '{name}'", .{ .name = profiles.displayName(running) });
    if ((try context.interact(Button{ .key = .src(@src()), .label = label, .style = &style.plain_button })).clicked) profiles.request(window, .back_up, running, null);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Open Backups Folder"), .style = &style.plain_button })).clicked) openFolder(window);
    try row.close(context);
    // A backup copies the profile's file, which holds only what was saved.
    if (window.session.isDirty()) try window.widgets.paragraph(context, .src(@src()), "Unsaved changes aren't in a backup until you save them.");
}

fn openFolder(window: *Window) void {
    showFolder(window) catch |err| {
        slog.err("Failed to open the backups folder: {}", .{err});
        window.status.show(.failure, "Failed to open the backups folder: {err}", .{ .err = err });
    };
}

/// Creates the folder first, so it opens before anything has been backed up.
fn showFolder(window: *Window) !void {
    const dir = try config.profileBackupDir(window.allocator, window.session.appContext().io);
    defer window.allocator.free(dir);
    const terminated_dir = try window.allocator.dupeSentinel(u8, dir, 0);
    defer window.allocator.free(terminated_dir);
    if (!win32.shellOpen(terminated_dir.ptr, null)) return error.ShellOpenFailed;
}

/// "2026-10-10 02:40", in UTC.
fn savedAt(arena: std.mem.Allocator, seconds: u64) ![]const u8 {
    const day = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = day.getDaySeconds();
    return arena.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
    });
}

/// Done before the list is drawn, since it frees the names the last scan drew.
fn scan(window: *Window) void {
    window.backups.scanned_revision = profiles.revision(window);
    if (window.backups.arena) |*arena| arena.deinit();
    window.backups.arena = .init(window.allocator);
    const names = config.listProfileBackups(window.backups.arena.?.allocator(), window.session.appContext().io) catch |err| {
        slog.err("Failed to list profile backups: {}", .{err});
        window.backups.backups = &.{};
        return;
    };
    window.backups.backups = names.items;
}
