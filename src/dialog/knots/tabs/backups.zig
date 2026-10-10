//! The configuration window's Backups tab: profiles kept when they were deleted or couldn't be read, each restored as a new profile or deleted for good; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const host = @import("../host.zig");
const profiles = @import("../profiles.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const log = @import("../../../log.zig");

const Text = ui.component.Text;
const Button = ui.component.Button;
const slog = log.scoped("dialog_knots");

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
    const section = try widgets.openSection(context, "Profile Backups", "A deleted profile, or one that couldn't be read, is kept here. Restoring one copies it into a new profile and keeps the backup.", &style.section);
    if (g_backups.len == 0) {
        try widgets.paragraph(context, .src(@src()), "No backups yet.");
    }
    const arena = context.arena();
    for (g_backups, 0..) |backup, index| {
        const row = try widgets.openRow(context, ROW_KEY.indexed(index));
        const parsed = config.parseBackupName(backup);
        try context.e(Text{ .selectable = false, .key = ROW_KEY.indexed(index).indexed(1), .content = try label(arena, parsed), .style = &style.label_aligned });
        if ((try context.interact(Button{ .key = ROW_KEY.indexed(index).indexed(2), .label = "Restore", .style = &style.plain_button })).clicked) {
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

/// "Main — 2026-10-10 02:40", or just the name for a backup saved without a time.
fn label(arena: std.mem.Allocator, backup: config.BackupName) ![]const u8 {
    const seconds = backup.saved_at_seconds orelse return backup.name;
    const day = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = day.getDaySeconds();
    return std.fmt.allocPrint(arena, "{s} \u{2014} {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        backup.name,
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
    const names = config.listProfileBackups(g_arena.?.allocator()) catch |err| {
        slog.err("Failed to list profile backups: {}", .{err});
        g_backups = &.{};
        return;
    };
    g_backups = names.items;
}
