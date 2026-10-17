//! Folder and file pickers, run on a thread of their own since a picker's modal loop on the main thread would stall the input hooks.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const lang = @import("../../lang/lang.zig");
const detached = @import("../../util/detached.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("dialog_knots");

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
var g_is_busy: std.atomic.Value(bool) = .init(false);

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// `timer_hwnd` receives `command` with the result, unless the user cancels; `title` is in English, and shown translated.
pub fn browse(target: Target, index: usize, title: []const u8, owner: ?win32.HWND, timer_hwnd: win32.HWND, command: usize) void {
    if (g_is_busy.swap(true, .acq_rel)) return;
    startPicker(target, index, title, owner, timer_hwnd, command) catch |err| {
        slog.err("Failed to open the picker: {}", .{err});
        g_is_busy.store(false, .release);
    };
}

/// Copies the wording, since the language module is the main thread's.
fn startPicker(target: Target, index: usize, title: []const u8, owner: ?win32.HWND, timer_hwnd: win32.HWND, command: usize) !void {
    const shown_title = try g_allocator.dupe(u8, lang.text(title));
    errdefer g_allocator.free(shown_title);
    const file_type_name = try g_allocator.dupe(u8, lang.text(fileTypeName(target)));
    errdefer g_allocator.free(file_type_name);
    try detached.spawn(pickerThread, .{ target, index, shown_title, file_type_name, owner, timer_hwnd, command });
}

/// Owns `title` and `file_type_name`; shares only the allocator and the posted message with the main thread.
fn pickerThread(target: Target, index: usize, title: []const u8, file_type_name: []const u8, owner: ?win32.HWND, timer_hwnd: win32.HWND, command: usize) void {
    defer g_is_busy.store(false, .release);
    defer g_allocator.free(title);
    defer g_allocator.free(file_type_name);
    const shown = switch (target) {
        .chatlog_dir, .gamelog_dir => win32.showFolderPicker(g_allocator, title, owner),
        .sound_file => win32.showFilePicker(g_allocator, title, file_type_name, "*.wav;*.mp3", owner),
        .import_file => win32.showFilePicker(g_allocator, title, file_type_name, "*.json;*.ini", owner),
    };
    const path = shown catch |err| {
        slog.err("Failed to open the picker: {}", .{err});
        return;
    } orelse return;
    const picked = g_allocator.create(Picked) catch |err| {
        slog.err("Failed to pass on the picked path: {}", .{err});
        g_allocator.free(path);
        return;
    };
    picked.* = .{ .target = target, .index = index, .path = path };
    if (!win32.toBool(win32.PostMessageA(timer_hwnd, win32.WM_KNOTS_COMMAND, command, @bitCast(@intFromPtr(picked))))) {
        slog.err("Failed to pass on the picked path: error {d}", .{win32.GetLastError()});
        picked.deinit();
    }
}

fn fileTypeName(target: Target) []const u8 {
    return switch (target) {
        .chatlog_dir, .gamelog_dir => "",
        .sound_file => "Audio Files (*.wav, *.mp3)",
        .import_file => "Settings Files (*.json, *.ini)",
    };
}
