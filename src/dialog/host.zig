//! The configuration window, hosted in the main app so it edits the same in-memory config the app runs on.
//! Window lifecycle runs on the main thread; webui shows it and calls into it from its own threads (see rpc.zig).
const std = @import("std");
const webui = @import("webui");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");
const main_mod = @import("../main.zig");
const config_store = @import("../config/store.zig");
const rpc = @import("rpc.zig");
const events = @import("events.zig");
const session = @import("session.zig");
const resources = @import("resources.zig");

const slog = log.scoped("dialog");

/// The window's design size at 96 DPI; scaled by the monitor's DPI and the dialog scale before display.
const DESIGN_WIDTH: f32 = 800.0;
const DESIGN_HEIGHT: f32 = 950.0;

/// x isn't 0, since webui treats that as "unset" and centers the window instead.
const DEFAULT_POSITION: win32.POINT = .{ .x = 20, .y = 20 };

const State = enum { closed, opening, open };
const ShowResult = enum(u8) { pending, shown, failed };

var g_allocator: std.mem.Allocator = undefined;
var g_state: State = .closed;
var g_window: ?webui = null;
/// webui serves the page from this buffer rather than copying it, so it lives until the window is destroyed.
var g_page: ?[:0]u8 = null;
var g_show_result: std.atomic.Value(ShowResult) = .init(.pending);
/// Read by rpc.zig's worker-thread handlers (file pickers' owner) and the window's own thread.
var g_hwnd: std.atomic.Value(usize) = .init(0);
/// The dialog scale as f32 bits; the DPI handler reads it on the window's thread.
var g_ui_scale_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 1.0)));
var g_orig_wndproc: isize = 0;
/// Which profile the window edits; the live profile unless the user picked another.
var g_editing_profile: ?[]u8 = null;

pub fn init(allocator_: std.mem.Allocator) void {
    g_allocator = allocator_;
    config_store.on_runtime_change = events.liveProfileChanged;
}

pub fn allocator() std.mem.Allocator {
    return g_allocator;
}

pub fn isOpen() bool {
    return g_state == .open;
}

/// Opens the window, or focuses it if it's already open.
pub fn open() void {
    switch (g_state) {
        .closed => {},
        .opening => return,
        .open => {
            focus();
            return;
        },
    }
    openWindow() catch |err| {
        slog.err("Failed to open the configuration window: {}", .{err});
        resetWindow();
    };
}

/// Call every tick: finishes an open that the show thread completed, and notices the window closing.
pub fn tick() void {
    switch (g_state) {
        .closed => {},
        .opening => switch (g_show_result.load(.acquire)) {
            .pending => {},
            .shown => g_state = .open,
            .failed => resetWindow(),
        },
        .open => if (!g_window.?.isShown()) onClosed(),
    }
}

/// Doesn't wait for webui to clean up: its threads may be blocked sending to the main thread, which is exiting.
pub fn shutdown() void {
    if (g_window) |win| win.close();
}

pub fn close() void {
    if (g_window) |win| win.close();
}

pub fn runScript(script: [:0]const u8) void {
    if (g_window) |win| win.run(script);
}

pub fn hwnd() ?win32.HWND {
    const raw = g_hwnd.load(.acquire);
    return if (raw == 0) null else @ptrFromInt(raw);
}

pub fn editingProfile() []const u8 {
    return g_editing_profile orelse main_mod.g_store.live.profile_name;
}

pub fn setEditingProfile(name: []const u8) !void {
    const owned = try g_allocator.dupe(u8, name);
    if (g_editing_profile) |old| g_allocator.free(old);
    g_editing_profile = owned;
}

/// Whether the window edits the profile the app is running, so its edits can preview live.
pub fn editsLiveProfile() bool {
    return std.mem.eql(u8, editingProfile(), main_mod.g_store.live.profile_name);
}

pub fn setAlwaysOnTop(enabled: bool) void {
    const window = hwnd() orelse return;
    const insert_after = if (enabled) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST;
    _ = win32.SetWindowPos(window, insert_after, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
}

/// `percent` 0 is "auto"; returns the scale now applied.
pub fn applyScale(percent: u16) f32 {
    const window = hwnd() orelse {
        slog.warn("Configuration window not available yet, UI scale not applied", .{});
        return uiScale();
    };
    var rect: win32.RECT = undefined;
    if (win32.GetWindowRect(window, &rect) == 0) {
        slog.warn("Failed to read the configuration window's position, UI scale not applied", .{});
        return uiScale();
    }
    setUiScale(resolveScale(percent, win32.rectCenter(rect)));
    const target = targetSize(win32.GetDpiForWindow(window));
    _ = win32.SetWindowPos(window, win32.HWND_NOTOPMOST, 0, 0, @intCast(target.width), @intCast(target.height), win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    return uiScale();
}

/// Sent from the window's own thread when a move ends, so the position is saved on the main thread.
pub fn onMoved(lParam: win32.LPARAM) void {
    const packed_pos: u64 = @bitCast(@as(i64, lParam));
    const x: i32 = @bitCast(@as(u32, @truncate(packed_pos)));
    const y: i32 = @bitCast(@as(u32, @truncate(packed_pos >> 32)));
    main_mod.g_global_settings.saveDialogPosition(x, y) catch |err| {
        slog.warn("Failed to save the configuration window's position: {}", .{err});
    };
}

fn openWindow() !void {
    const settings = &main_mod.g_global_settings;
    const position: win32.POINT = if (settings.dialogX != null and settings.dialogY != null)
        .{ .x = settings.dialogX.?, .y = settings.dialogY.? }
    else
        DEFAULT_POSITION;
    setUiScale(resolveScale(settings.dialogScale, position));

    try setEditingProfile(main_mod.g_store.live.profile_name);

    const win = webui.newWindow();
    g_window = win;
    const size = targetSize(win32.dpiForPoint(position));
    win.setSize(size.width, size.height);
    win.setKiosk(false);
    win.setResizable(true);
    // Before showing, since webui reads the position at creation, so the first paint lands here instead of jumping.
    if (position.x >= 0 and position.y >= 0) win.setPosition(@intCast(position.x), @intCast(position.y));
    try rpc.bind(win);
    win.setFileHandler(resources.serveFile);

    g_page = try resources.buildPage(g_allocator, resources.Lang.fromCode(settings.language), uiScale());
    g_show_result.store(.pending, .release);
    // showWv waits for WebView2 to connect, which would stall every thumbnail on the main thread.
    const thread = try std.Thread.spawn(.{}, showWindow, .{ win, g_page.?, settings.alwaysOnTop });
    thread.detach();
    g_state = .opening;
}

fn showWindow(win: webui, page: [:0]const u8, always_on_top: bool) void {
    win.showWv(page) catch |err| {
        slog.err("Failed to show the configuration window: {}", .{err});
        g_show_result.store(.failed, .release);
        return;
    };

    if (win.win32GetHwnd()) |window| {
        const raw: win32.HWND = @ptrCast(window);
        g_hwnd.store(@intFromPtr(raw), .release);
        g_orig_wndproc = win32.SetWindowLongPtrA(raw, win32.GWLP_WNDPROC, @as(isize, @bitCast(@intFromPtr(&windowProc))));
        // Re-derived against the window's actual monitor, in case the startup guess was a different one.
        const target = targetSize(win32.GetDpiForWindow(raw));
        win.setSize(target.width, target.height);
        if (always_on_top) setAlwaysOnTop(true);
    } else |err| {
        slog.warn("Failed to get the configuration window's HWND: {}", .{err});
    }

    win.run("document.documentElement.classList.remove('pre-init');");
    g_show_result.store(.shown, .release);
}

/// Subclasses webui's window, which never surfaces WM_DPICHANGED or the end of a move otherwise.
fn windowProc(window: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_DPICHANGED => {
            const target = targetSize(win32.GetDpiForWindow(window));
            const suggested = win32.lparamToPtr(win32.RECT, lParam);
            _ = win32.SetWindowPos(window, win32.HWND_NOTOPMOST, suggested.left, suggested.top, @intCast(target.width), @intCast(target.height), win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            var rect: win32.RECT = undefined;
            if (win32.GetWindowRect(window, &rect) != 0) {
                if (main_mod.g_timer_hwnd) |timer| {
                    const packed_pos = (@as(u64, @as(u32, @bitCast(rect.top))) << 32) | @as(u32, @bitCast(rect.left));
                    _ = win32.PostMessageA(timer, win32.WM_DIALOG_MOVED, 0, @bitCast(@as(i64, @bitCast(packed_pos))));
                }
            }
        },
        else => {},
    }
    if (g_orig_wndproc != 0) return win32.CallWindowProcA(g_orig_wndproc, window, msg, wParam, lParam);
    return win32.DefWindowProcA(window, msg, wParam, lParam);
}

fn onClosed() void {
    slog.info("Configuration window closed", .{});
    session.end();
    main_mod.onDialogClosed();
    resetWindow();
}

fn resetWindow() void {
    if (g_window) |win| win.destroy();
    g_window = null;
    if (g_page) |page| g_allocator.free(page);
    g_page = null;
    g_hwnd.store(0, .release);
    g_orig_wndproc = 0;
    if (g_editing_profile) |name| g_allocator.free(name);
    g_editing_profile = null;
    g_state = .closed;
}

fn focus() void {
    const window = hwnd() orelse return;
    if (win32.IsIconic(window) != 0) _ = win32.ShowWindow(window, win32.SW_RESTORE);
    _ = win32.SetForegroundWindow(window);
}

fn uiScale() f32 {
    return @bitCast(g_ui_scale_bits.load(.acquire));
}

fn setUiScale(scale: f32) void {
    g_ui_scale_bits.store(@bitCast(scale), .release);
}

const Size = struct { width: u32, height: u32 };

fn targetSize(dpi: u32) Size {
    const scale = win32.dpiToScale(dpi) * uiScale();
    return .{
        .width = @intFromFloat(@round(DESIGN_WIDTH * scale)),
        .height = @intFromFloat(@round(DESIGN_HEIGHT * scale)),
    };
}

/// Only 96-DPI monitors get an automatic bump, since Windows already scales the rest.
fn autoScalePercent(point: win32.POINT, dpi: u32) u16 {
    if (dpi != win32.USER_DEFAULT_SCREEN_DPI) return 100;
    const monitor = win32.nearestMonitor(point) orelse return 100;
    const rect = win32.monitorRect(monitor) orelse {
        slog.warn("Failed to read monitor bounds for the automatic dialog scale", .{});
        return 100;
    };
    // Height, not width: super-ultrawides are 5120 wide but only 1440 tall.
    const height = win32.rectHeight(rect);
    if (height >= 2160) return 150;
    if (height >= 1440) return 125;
    return 100;
}

fn resolveScale(percent: u16, point: win32.POINT) f32 {
    const resolved = if (percent == 0) autoScalePercent(point, win32.dpiForPoint(point)) else percent;
    return @as(f32, @floatFromInt(resolved)) / 100.0;
}
