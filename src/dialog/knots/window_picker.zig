//! The "Pick Running Window" dropdown that window filters and app hotkeys share: the open windows, scanned on request, until one is picked; main thread only.
const std = @import("std");
const ui = @import("ui");
const background = @import("../api/background.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const log = @import("../../log.zig");

const SelectInput = ui.component.SelectInput;
const RunningWindow = background.RunningWindow;
const slog = log.scoped("dialog_knots");

const PROMPT = "-- Select a running window --";

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
    const windows = background.getRunningWindows(arena.allocator()) catch |err| {
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
