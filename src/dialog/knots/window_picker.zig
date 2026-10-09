//! The "Pick Running Window" dropdown that window filters and app hotkeys share: the open windows, scanned on request, until one is picked; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const log = @import("../../log.zig");

const SelectInput = ui.component.SelectInput;
const slog = log.scoped("dialog_knots");

const PROMPT = "-- Select a running window --";

/// A visible top-level window, one per class and executable.
pub const RunningWindow = struct { class: []const u8, exe: []const u8, title: []const u8 };

const WindowScan = struct {
    arena: std.mem.Allocator,
    windows: std.ArrayList(RunningWindow) = .empty,
    failed: ?anyerror = null,
};

/// One list's open picker, for the item at `index`.
pub const Picker = struct {
    index: usize,
    arena: std.heap.ArenaAllocator,
    /// Borrows from `arena`.
    windows: []const RunningWindow,
};

/// Scans the open windows for the item at `index`, replacing `picker`'s earlier scan; leaves it closed when there are none.
pub fn open(allocator: std.mem.Allocator, picker: *?Picker, index: usize) void {
    close(picker);
    var arena = std.heap.ArenaAllocator.init(allocator);
    const windows = runningWindows(arena.allocator()) catch |err| {
        arena.deinit();
        slog.err("Failed to scan running windows: {}", .{err});
        status.show(.failure, "Failed to scan clients: {}", .{err});
        return;
    };
    if (windows.len == 0) {
        arena.deinit();
        status.show(.failure, "No running windows found", .{});
        return;
    }
    picker.* = .{ .index = index, .arena = arena, .windows = windows };
}

pub fn close(picker: *?Picker) void {
    if (picker.*) |*open_picker| open_picker.arena.deinit();
    picker.* = null;
}

/// The dropdown under the item at `index`, while its picker is open; returns the window picked, which borrows from the picker until `close`.
pub fn select(context: *ui.Frame, picker: *const ?Picker, key: ui.Key, index: usize) !?RunningWindow {
    const open_picker = picker.* orelse return null;
    if (open_picker.index != index) return null;
    const arena = context.arena();
    const labels = try arena.alloc([]const u8, open_picker.windows.len + 1);
    const values = try arena.alloc(u32, open_picker.windows.len + 1);
    labels[0] = PROMPT;
    values[0] = 0;
    for (open_picker.windows, 1..) |window, option| {
        labels[option] = try std.fmt.allocPrint(arena, "{s} \u{2014} {s}", .{ window.title, window.exe });
        values[option] = @intCast(option);
    }
    const response = try context.interact(SelectInput(u32){
        .key = key.indexed(index),
        .labels = labels,
        .values = values,
        .initial_selected = 0,
        .style = &style.select_fill,
        .parts = .{ .popup = &style.select_popup },
    });
    const selected = response.selected orelse return null;
    if (selected.value == 0) return null;
    return open_picker.windows[selected.value - 1];
}

/// Sorted by executable name; everything borrows from `arena`.
fn runningWindows(arena: std.mem.Allocator) ![]const RunningWindow {
    var scan = WindowScan{ .arena = arena };
    _ = win32.EnumWindows(collectWindow, win32.ptrToLparam(&scan));
    if (scan.failed) |err| return err;
    std.sort.pdq(RunningWindow, scan.windows.items, {}, struct {
        fn lessThan(_: void, a: RunningWindow, b: RunningWindow) bool {
            return std.mem.lessThan(u8, a.exe, b.exe);
        }
    }.lessThan);
    return scan.windows.items;
}

fn collectWindow(window: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const scan: *WindowScan = win32.lparamToPtr(WindowScan, lParam);
    if (!win32.toBool(win32.IsWindowVisible(window))) return win32.TRUE;

    var title_buf: [win32.WINDOW_TITLE_MAX_UNITS * 3]u8 = undefined;
    // UTF-8, since the dialog's text, picked labels included, must be.
    const title = win32.getWindowTitleUtf8(window, &title_buf) orelse return win32.TRUE;
    var class_buf: [64:0]u8 = undefined;
    const class = win32.getClassNameBuf(window, &class_buf) orelse return win32.TRUE;
    var exe_buf: [260:0]u8 = undefined;
    const exe = win32.windowExeName(window, &exe_buf) orelse return win32.TRUE;
    if (exe.len == 0) return win32.TRUE;

    for (scan.windows.items) |existing| {
        if (std.mem.eql(u8, existing.class, class) and std.ascii.eqlIgnoreCase(existing.exe, exe)) return win32.TRUE;
    }
    const entry = RunningWindow{
        .class = scan.arena.dupe(u8, class) catch |err| return stopScan(scan, err),
        .exe = scan.arena.dupe(u8, exe) catch |err| return stopScan(scan, err),
        .title = scan.arena.dupe(u8, title) catch |err| return stopScan(scan, err),
    };
    scan.windows.append(scan.arena, entry) catch |err| return stopScan(scan, err);
    return win32.TRUE;
}

fn stopScan(scan: *WindowScan, err: anyerror) win32.BOOL {
    scan.failed = err;
    return win32.FALSE;
}
