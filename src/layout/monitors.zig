const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");
const slog = log.scoped("monitors");

const MonitorEnumData = struct {
    target_index: u32,
    current_index: u32,
    found_monitor: ?win32.HMONITOR,
};

fn monitorEnumProc(
    hMonitor: win32.HMONITOR,
    hdcMonitor: ?win32.HDC,
    lprcMonitor: ?*win32.RECT,
    dwData: win32.LPARAM,
) callconv(.c) win32.BOOL {
    _ = hdcMonitor;
    _ = lprcMonitor;

    const data: *MonitorEnumData = win32.lparamToPtr(MonitorEnumData, dwData);

    if (data.current_index == data.target_index) {
        data.found_monitor = hMonitor;
        // FALSE stops EnumDisplayMonitors.
        return win32.FALSE;
    }

    data.current_index += 1;
    // TRUE continues enumeration.
    return win32.TRUE;
}

pub const MonitorPlacement = struct {
    bounds: win32.RECT,
    monitor: win32.HMONITOR,
};

/// Get monitor bounds and handle by 0-based index; null if out of range.
fn getMonitorPlacement(monitor_index: u32, use_work_area: bool) ?MonitorPlacement {
    var enum_data = MonitorEnumData{
        .target_index = monitor_index,
        .current_index = 0,
        .found_monitor = null,
    };

    const result = win32.EnumDisplayMonitors(
        null,
        null,
        monitorEnumProc,
        win32.ptrToLparam(&enum_data),
    );
    _ = result;

    // result is FALSE whenever we stopped enumeration early on a match, not an error.
    if (enum_data.found_monitor == null) {
        slog.warn("Monitor index {} not found (total monitors available: {})", .{ monitor_index, enum_data.current_index });
        return null;
    }

    var monitor_info = win32.MONITORINFO{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };

    if (win32.GetMonitorInfoA(enum_data.found_monitor.?, &monitor_info) == win32.FALSE) {
        slog.err("Failed to get monitor info for monitor index {}", .{monitor_index});
        return null;
    }

    return .{
        // Work area (excludes taskbar) or full monitor bounds
        .bounds = if (use_work_area) monitor_info.rcWork else monitor_info.rcMonitor,
        .monitor = enum_data.found_monitor.?,
    };
}

/// Bounds of the monitor nearest `hwnd`, falling back to primary-monitor metrics (GetSystemMetrics only reports the primary monitor) if the lookup fails; also returns the resolved monitor handle, if any, for a DPI lookup.
pub fn nearestMonitorBounds(hwnd: win32.HWND) MonitorBounds {
    return monitorBounds(win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST));
}

pub const MonitorBounds = struct { bounds: win32.RECT, monitor: ?win32.HMONITOR };

pub fn cursorMonitorBounds() MonitorBounds {
    var cursor = win32.POINT{ .x = 0, .y = 0 };
    _ = win32.GetCursorPos(&cursor);
    return monitorBounds(win32.nearestMonitor(cursor));
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

pub fn resolveMonitorPlacement(cfg: *const config_mod.DisplayConfig) ?MonitorPlacement {
    return if (cfg.monitorIndex) |monitor_idx| getMonitorPlacement(monitor_idx, cfg.useMonitorWorkArea) else null;
}
