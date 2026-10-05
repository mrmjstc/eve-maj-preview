//! Folder and file pickers, run on a thread of their own since a picker's modal loop on the main thread would stall the input hooks.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog_knots");

/// What a picked path is for.
pub const Target = enum {
    chatlog_dir,
    gamelog_dir,
    /// A notification type's sound; Picked.index is the type.
    sound_file,
    /// A settings file for the Import dialog.
    import_file,
};

/// Sent to the main thread as WM_KNOTS_COMMAND's lParam.
pub const Picked = struct {
    target: Target,
    /// Which item the path is for, e.g. the notification type of a sound.
    index: usize,
    /// Owned; freed by the main thread with `deinit`.
    path: []const u8,

    pub fn deinit(self: *Picked) void {
        g_allocator.free(self.path);
        g_allocator.destroy(self);
    }
};

var g_allocator: std.mem.Allocator = undefined;
/// Set while a picker is open, so a second click doesn't stack another. Main thread sets it; the picker's thread clears it.
var g_busy: std.atomic.Value(bool) = .init(false);

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// `timer` receives `command` with the result, unless the user cancels.
pub fn browse(target: Target, index: usize, title: []const u8, owner: ?win32.HWND, timer: win32.HWND, command: usize) void {
    if (g_busy.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, pickerThread, .{ target, index, title, owner, timer, command }) catch |err| {
        slog.err("Failed to open the folder picker: {}", .{err});
        g_busy.store(false, .release);
        return;
    };
    thread.detach();
}

/// The picker's thread; touches nothing of the main thread's but the allocator and the posted message.
fn pickerThread(target: Target, index: usize, title: []const u8, owner: ?win32.HWND, timer: win32.HWND, command: usize) void {
    defer g_busy.store(false, .release);
    const shown = switch (target) {
        .chatlog_dir, .gamelog_dir => win32.showFolderPicker(g_allocator, title, owner),
        .sound_file => win32.showFilePicker(g_allocator, title, "Audio Files (*.wav, *.mp3)", "*.wav;*.mp3", owner),
        .import_file => win32.showFilePicker(g_allocator, title, "Settings Files (*.json, *.ini)", "*.json;*.ini", owner),
    };
    const path = shown catch |err| {
        slog.err("Failed to open the folder picker: {}", .{err});
        return;
    } orelse return;
    const picked = g_allocator.create(Picked) catch |err| {
        slog.err("Failed to pass on the picked folder: {}", .{err});
        g_allocator.free(path);
        return;
    };
    picked.* = .{ .target = target, .index = index, .path = path };
    if (!win32.toBool(win32.PostMessageA(timer, win32.WM_KNOTS_COMMAND, command, @bitCast(@intFromPtr(picked))))) {
        slog.err("Failed to pass on the picked folder: error {d}", .{win32.GetLastError()});
        picked.deinit();
    }
}
