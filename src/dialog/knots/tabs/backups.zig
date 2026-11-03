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
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const slog = log.Scoped("dialog_knots");

const ROW_KEY: ui.Key = .str("knots.backups.row");

var g_allocator: std.mem.Allocator = undefined;
/// Holds the backup names; replaced on each scan, freed in reset.
var g_arena: ?std.heap.ArenaAllocator = null;
/// Newest first; borrows from g_arena.
var g_backups: []const []const u8 = &.{};
/// profiles.revision() at the last scan, so a profile deleted since then shows up.
var g_scanned_revision: ?u32 = null;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    if (g_arena) |*arena| arena.deinit();
    g_arena = null;
    g_backups = &.{};
    g_scanned_revision = null;
}

pub fn show(context: *ui.Frame) !void {
    if (g_scanned_revision != profiles.revision()) scan();
    const section = try widgets.openSection(context, "Profile Backups", "Copies kept when a profile is deleted, reset, imported over or fails to load.", &style.section);
    try actions(context);
    const arena = context.arena();
    for (g_backups, 0..) |backup, index| {
        const row = try widgets.openRow(context, ROW_KEY.indexed(index));
        const parsed = config.parseBackupName(backup);
        try context.e(Text{ .selectable = false, .key = ROW_KEY.indexed(index).indexed(1), .content = parsed.name, .style = &style.label_aligned });
        if (parsed.saved_at_seconds) |seconds| try context.e(Text{ .selectable = false, .key = ROW_KEY.indexed(index).indexed(4), .content = try savedAt(arena, seconds), .style = &style.muted_text });
        if ((try context.interact(Button{ .key = ROW_KEY.indexed(index).indexed(2), .label = lang.text("Restore"), .style = &style.plain_button })).clicked) {
            host.restoreBackup(backup, parsed.name);
            // The prompt it opens is drawn by the header, which this frame has already drawn.
            context.requestRedraw();
        }
        if (try widgets.confirmButton(context, ROW_KEY.indexed(index).indexed(3), "\u{00D7}", "OK", &style.icon_button_danger_text, &style.icon_button_confirm)) {
            profiles.request(.delete_backup, backup, null);
        }
        try row.close(context);
    }
    try section.close(context);
}

/// Back Up for the running profile and Open Backups Folder, above the list.
fn actions(context: *ui.Frame) !void {
    const running = session.profile().ptr.profile_name;
    const row = try widgets.openRow(context, .src(@src()));
    // The empty state takes the row's spare width, pushing the buttons right as the spacer does.
    if (g_backups.len == 0) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("No backups yet."), .style = &style.empty_list_text });
    } else {
        try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    }
    const label = try lang.format(context.arena(), "Back Up '{name}'", .{ .name = profiles.displayName(running) });
    if ((try context.interact(Button{ .key = .src(@src()), .label = label, .style = &style.plain_button })).clicked) profiles.request(.back_up, running, null);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Open Backups Folder"), .style = &style.plain_button })).clicked) openFolder();
    try row.close(context);
    // A backup copies the profile's file, which holds only what was saved.
    if (session.isDirty()) try widgets.paragraph(context, .src(@src()), "Unsaved changes aren't in a backup until you save them.");
}

fn openFolder() void {
    showFolder() catch |err| {
        slog.err("Failed to open the backups folder: {}", .{err});
        status.show(.failure, "Failed to open the backups folder: {err}", .{ .err = err });
    };
}

/// Creates the folder first, so it opens before anything has been backed up.
fn showFolder() !void {
    const dir = try config.profileBackupDir(g_allocator, session.runningApp().io);
    defer g_allocator.free(dir);
    const terminated_dir = try g_allocator.dupeSentinel(u8, dir, 0);
    defer g_allocator.free(terminated_dir);
    if (!win32.shellOpen(terminated_dir.ptr, null)) return error.ShellOpenFailed;
}

/// "2026-10-10 02:40", in UTC.
fn savedAt(arena: std.mem.Allocator, seconds: u64) ![]const u8 {
    const day = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = day.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
    });
}

/// Done before the list is drawn, since it frees the names the last scan drew.
fn scan() void {
    g_scanned_revision = profiles.revision();
    if (g_arena) |*arena| arena.deinit();
    g_arena = .init(g_allocator);
    const names = config.listProfileBackups(g_arena.?.allocator(), session.runningApp().io) catch |err| {
        slog.err("Failed to list profile backups: {}", .{err});
        g_backups = &.{};
        return;
    };
    g_backups = names.items;
}
