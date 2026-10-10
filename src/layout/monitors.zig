//! Monitor bounds and DPI lookups.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config = @import("../config.zig");
const log = @import("../log.zig");

const slog = log.scoped("monitors");

const MonitorEnumData = struct {
    target_index: u32,
    current_index: u32,
    found_monitor: ?win32.HMONITOR,
};

pub const MonitorPlacement = struct {
    bounds: win32.RECT,
    monitor: win32.HMONITOR,
};

pub const MonitorBounds = struct { bounds: win32.RECT, monitor: ?win32.HMONITOR };

const RectList = struct {
    /// Borrows monitorRects' caller's buffer.
    buffer: []win32.RECT,
    count: usize = 0,
};

/// Bounds of the monitor nearest `hwnd`, falling back to primary-monitor metrics (GetSystemMetrics only reports the primary monitor) if the lookup fails; also returns the resolved monitor handle, if any, for a DPI lookup.
pub fn nearestMonitorBounds(hwnd: win32.HWND) MonitorBounds {
    return monitorBounds(win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST));
}

pub fn cursorMonitorBounds() MonitorBounds {
    var cursor = win32.POINT{ .x = 0, .y = 0 };
    _ = win32.GetCursorPos(&cursor);
    return monitorBounds(win32.nearestMonitor(cursor));
}

/// DPI for a specific monitor; used before a window exists on it yet.
pub fn getMonitorDpi(hmonitor: win32.HMONITOR) u32 {
    return win32.monitorDpi(hmonitor);
}

/// DPI of whichever monitor a window currently sits on; queried live, nothing to invalidate.
pub fn getWindowDpi(hwnd: win32.HWND) u32 {
    return win32.GetDpiForWindow(hwnd);
}

/// `monitor`'s DPI, or the system DPI when there isn't one.
pub fn dpiForMonitor(monitor: ?win32.HMONITOR) u32 {
    return if (monitor) |m| getMonitorDpi(m) else defaultDpi();
}

/// DPI for the system default monitor; used as a fallback when no target monitor is configured.
pub fn defaultDpi() u32 {
    return win32.GetDpiForSystem();
}

/// Every monitor's full bounds, up to `buffer.len` of them, primary first; borrows from `buffer`.
pub fn monitorRects(buffer: []win32.RECT) []win32.RECT {
    var list = RectList{ .buffer = buffer };
    if (!win32.toBool(win32.EnumDisplayMonitors(null, null, rectEnumProc, win32.ptrToLparam(&list)))) {
        slog.warn("Failed to enumerate monitors", .{});
    }
    const rects = buffer[0..list.count];
    // The primary monitor is the one at the desktop's origin.
    for (rects, 0..) |rect, index| {
        if (rect.left != 0 or rect.top != 0) continue;
        std.mem.rotate(win32.RECT, rects[0 .. index + 1], index);
        break;
    }
    return rects;
}

pub fn resolveMonitorPlacement(display: *const config.DisplayConfig) ?MonitorPlacement {
    return if (display.monitorIndex) |monitor_index| getMonitorPlacement(monitor_index, display.useMonitorWorkArea) else null;
}

/// By 0-based index; null if out of range.
fn getMonitorPlacement(monitor_index: u32, use_work_area: bool) ?MonitorPlacement {
    var enum_data = MonitorEnumData{
        .target_index = monitor_index,
        .current_index = 0,
        .found_monitor = null,
    };

    // Returns FALSE when the callback stops it early on a match, so the result says nothing about errors.
    _ = win32.EnumDisplayMonitors(null, null, monitorEnumProc, win32.ptrToLparam(&enum_data));

    if (enum_data.found_monitor == null) {
        slog.warn("Failed to find monitor {} ({} available)", .{ monitor_index, enum_data.current_index });
        return null;
    }

    var monitor_info = win32.MONITORINFO{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };

    if (!win32.toBool(win32.GetMonitorInfoA(enum_data.found_monitor.?, &monitor_info))) {
        slog.err("Failed to get monitor info for monitor index {}", .{monitor_index});
        return null;
    }

    return .{
        .bounds = if (use_work_area) monitor_info.rcWork else monitor_info.rcMonitor,
        .monitor = enum_data.found_monitor.?,
    };
}

fn monitorBounds(nearest: ?win32.HMONITOR) MonitorBounds {
    var bounds = win32.RECT{
        .left = 0,
        .top = 0,
        .right = win32.GetSystemMetrics(win32.SM_CXSCREEN),
        .bottom = win32.GetSystemMetrics(win32.SM_CYSCREEN),
    };
    var monitor: ?win32.HMONITOR = null;
    if (nearest) |m| {
        if (win32.monitorRect(m)) |rect| {
            bounds = rect;
            monitor = m;
        }
    }
    return .{ .bounds = bounds, .monitor = monitor };
}

fn rectEnumProc(_: win32.HMONITOR, _: ?win32.HDC, rect: ?*win32.RECT, lparam: win32.LPARAM) callconv(.c) win32.BOOL {
    const list: *RectList = win32.lparamToPtr(RectList, lparam);
    const bounds = rect orelse return win32.TRUE;
    if (list.count == list.buffer.len) return win32.TRUE;
    list.buffer[list.count] = bounds.*;
    list.count += 1;
    return win32.TRUE;
}

fn monitorEnumProc(monitor: win32.HMONITOR, _: ?win32.HDC, _: ?*win32.RECT, lparam: win32.LPARAM) callconv(.c) win32.BOOL {
    const data: *MonitorEnumData = win32.lparamToPtr(MonitorEnumData, lparam);
    if (data.current_index == data.target_index) {
        data.found_monitor = monitor;
        return win32.FALSE;
    }
    data.current_index += 1;
    return win32.TRUE;
}
