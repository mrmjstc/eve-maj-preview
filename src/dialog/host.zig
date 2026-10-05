//! The configuration window, hosted in the main app so it edits the config the app runs on; its lifecycle is main-thread only, while the window and its WebView2 control live on a thread of their own.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const webview = @import("../platform/webview.zig");
const main = @import("../main.zig");
const config = @import("../config.zig");
const config_store = @import("../config/store.zig");
const rpc = @import("rpc.zig");
const events = @import("events.zig");
const session = @import("session.zig");
const resources = @import("resources.zig");
const log = @import("../log.zig");

const GlobalConfig = config.GlobalConfig;
const slog = log.scoped("dialog");

/// The window's design size at 96 DPI; scaled by the monitor's DPI and the dialog scale before display.
const DESIGN_WIDTH: f32 = 800.0;
const DESIGN_HEIGHT: f32 = 950.0;

const DEFAULT_POSITION: win32.POINT = .{ .x = 20, .y = 20 };

const BROWSER_ARGS_VAR = "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS";

const WINDOW_CLASS = "EveMajConfigWindow";
const WINDOW_TITLE = "EVE-Maj Preview Configuration";
const APP_ICON_ID = 101;
const COINIT_APARTMENTTHREADED: u32 = 0x2;
const WA_INACTIVE = 0;

/// eve_webview_serve answers every request here, so the page never touches the network; `.invalid` can't resolve.
const ORIGIN = "https://eve-maj.invalid/";
const PAGE_NAME = "index.html";

const State = enum { closed, open };

const Size = struct { width: u32, height: u32 };

var g_allocator: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;
var g_state: State = .closed;
/// Set by the window's thread as it exits, after which nothing of the window's is in use.
var g_thread_done: std.atomic.Value(bool) = .init(false);
/// Served by the window's thread until it exits; freed in resetWindow.
var g_page: ?[:0]u8 = null;
/// Read by rpc.zig's worker-thread handlers (file pickers' owner) and the window's own thread.
var g_hwnd: std.atomic.Value(usize) = .init(0);
/// The dialog scale as f32 bits; the DPI handler reads it on the window's thread.
var g_ui_scale_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 1.0)));
/// Which profile the window edits; the live profile unless the user picked another.
var g_editing_profile: ?[]u8 = null;

/// Guards g_webview and g_generation. The window's thread clears g_webview before destroying it, so no other thread uses a destroyed one.
var g_webview_mutex: std.Io.Mutex = .init;
var g_webview: ?webview.Webview = null;
/// Bumped per window, so a reply meant for a closed one is dropped.
var g_generation: u32 = 0;

pub fn init(allocator_: std.mem.Allocator, io: std.Io) void {
    g_allocator = allocator_;
    g_io = io;
    disableProxyDetection();
    registerWindowClass();
    config_store.g_on_runtime_change = events.liveProfileChanged;
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

/// Call every tick: notices the window's thread finishing.
pub fn tick() void {
    if (g_state == .open and g_thread_done.load(.acquire)) onClosed();
}

/// Doesn't wait for the window's thread, since the process is exiting.
pub fn shutdown() void {
    close();
}

pub fn close() void {
    const window = hwnd() orelse return;
    _ = win32.PostMessageA(window, win32.WM_CLOSE, 0, 0);
}

/// Thread-safe; dropped while the window isn't ready.
pub fn runScript(script: []const u8) void {
    g_webview_mutex.lockUncancelable(g_io);
    defer g_webview_mutex.unlock(g_io);
    const w = g_webview orelse return;
    const owned = g_allocator.dupeSentinel(u8, script, 0) catch |err| {
        slog.err("Failed to copy a script for the configuration window: {}", .{err});
        return;
    };
    if (webview.webview_dispatch(w, evalOnWindowThread, @ptrCast(owned.ptr)) < 0) {
        slog.err("Failed to send a script to the configuration window", .{});
        g_allocator.free(owned);
    }
}

/// Thread-safe; replies to the JS call `id` unless its window has since closed.
pub fn reply(call_generation: u32, id: [*:0]const u8, json: [*:0]const u8) void {
    g_webview_mutex.lockUncancelable(g_io);
    defer g_webview_mutex.unlock(g_io);
    if (call_generation != g_generation) return;
    const w = g_webview orelse return;
    if (webview.webview_return(w, id, 0, json) < 0) slog.err("Failed to reply to an rpc call", .{});
}

/// Thread-safe; the window an rpc call arriving now belongs to.
pub fn generation() u32 {
    g_webview_mutex.lockUncancelable(g_io);
    defer g_webview_mutex.unlock(g_io);
    return g_generation;
}

pub fn hwnd() ?win32.HWND {
    const raw = g_hwnd.load(.acquire);
    return if (raw == 0) null else @ptrFromInt(raw);
}

pub fn editingProfile() []const u8 {
    return g_editing_profile orelse main.g_store.live.profile_name;
}

pub fn setEditingProfile(name: []const u8) !void {
    const owned = try g_allocator.dupe(u8, name);
    if (g_editing_profile) |old| g_allocator.free(old);
    g_editing_profile = owned;
}

/// Whether the window edits the profile the app is running, so its edits can preview live.
pub fn editsLiveProfile() bool {
    return std.mem.eql(u8, editingProfile(), main.g_store.live.profile_name);
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
    if (!win32.toBool(win32.GetWindowRect(window, &rect))) {
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
    main.g_global_settings.saveDialogPosition(x, y) catch |err| {
        slog.warn("Failed to save the configuration window's position: {}", .{err});
    };
}

fn openWindow() !void {
    const settings = &main.g_global_settings;
    const position = savedPosition(settings);
    setUiScale(resolveScale(settings.dialogScale, position));

    try setEditingProfile(main.g_store.live.profile_name);
    g_page = try resources.buildPage(g_allocator, resources.Lang.fromCode(settings.language), uiScale());

    g_webview_mutex.lockUncancelable(g_io);
    g_generation +%= 1;
    g_webview_mutex.unlock(g_io);

    g_thread_done.store(false, .release);
    const size = targetSize(win32.dpiForPoint(position));
    const thread = try std.Thread.spawn(.{}, windowThread, .{ position, size, settings.alwaysOnTop });
    thread.detach();
    g_state = .open;
}

/// Owns the window and its control from creation to destruction, so nothing else can use either after it's gone.
fn windowThread(position: win32.POINT, size: Size, always_on_top: bool) void {
    defer g_thread_done.store(true, .release);

    if (win32.CoInitializeEx(null, COINIT_APARTMENTTHREADED) < 0) {
        slog.err("Failed to initialize COM for the configuration window", .{});
        return;
    }
    defer win32.CoUninitialize();

    const instance = win32.GetModuleHandleA(null) orelse {
        slog.err("Failed to get the module handle for the configuration window", .{});
        return;
    };
    const window = win32.CreateWindowExA(0, WINDOW_CLASS, WINDOW_TITLE, win32.WS_OVERLAPPEDWINDOW, position.x, position.y, @intCast(size.width), @intCast(size.height), null, null, instance, null) orelse {
        slog.err("Failed to create the configuration window: error {d}", .{win32.GetLastError()});
        return;
    };
    g_hwnd.store(@intFromPtr(window), .release);
    defer g_hwnd.store(0, .release);
    defer if (win32.toBool(win32.IsWindow(window))) {
        _ = win32.DestroyWindow(window);
    };

    // Pumps this thread's messages until WebView2 is ready.
    const w = webview.webview_create(0, window) orelse {
        slog.err("Failed to create the configuration window's WebView2 control; is the WebView2 Runtime installed?", .{});
        return;
    };
    defer _ = webview.webview_destroy(w);

    g_webview_mutex.lockUncancelable(g_io);
    g_webview = w;
    g_webview_mutex.unlock(g_io);
    defer {
        g_webview_mutex.lockUncancelable(g_io);
        g_webview = null;
        g_webview_mutex.unlock(g_io);
    }

    rpc.bind(w) catch |err| {
        slog.err("Failed to connect the configuration window to the app: {}", .{err});
        return;
    };
    const hr = webview.eve_webview_serve(w, ORIGIN, serve);
    if (hr < 0) {
        slog.err("Failed to serve the configuration window's page: HRESULT 0x{x}", .{@as(u32, @bitCast(hr))});
        return;
    }
    layoutWidget(window);
    if (webview.webview_navigate(w, ORIGIN ++ PAGE_NAME) < 0) {
        slog.err("Failed to load the configuration window's page", .{});
        return;
    }

    if (always_on_top) setAlwaysOnTop(true);
    _ = win32.ShowWindow(window, win32.SW_SHOW);
    _ = win32.SetForegroundWindow(window);
    webview.eve_webview_focus(w);
    slog.info("Configuration window opened", .{});

    _ = webview.webview_run(w);
}

fn windowProc(window: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_SIZE => layoutWidget(window),
        win32.WM_ACTIVATE => if (wParam & 0xFFFF != WA_INACTIVE) {
            if (g_webview) |w| webview.eve_webview_focus(w);
        },
        win32.WM_DPICHANGED => {
            const target = targetSize(win32.GetDpiForWindow(window));
            const suggested = win32.lparamToPtr(win32.RECT, lParam);
            _ = win32.SetWindowPos(window, win32.HWND_NOTOPMOST, suggested.left, suggested.top, @intCast(target.width), @intCast(target.height), win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            var rect: win32.RECT = undefined;
            if (win32.toBool(win32.GetWindowRect(window, &rect))) {
                if (main.g_timer_hwnd) |timer| {
                    const packed_pos = (@as(u64, @as(u32, @bitCast(rect.top))) << 32) | @as(u32, @bitCast(rect.left));
                    _ = win32.PostMessageA(timer, win32.WM_DIALOG_MOVED, 0, @bitCast(@as(i64, @bitCast(packed_pos))));
                }
            }
        },
        win32.WM_CLOSE => {
            _ = win32.DestroyWindow(window);
            return 0;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcA(window, msg, wParam, lParam);
}

/// The control's host window fills the client area; webview/webview only does that for windows it creates itself.
fn layoutWidget(window: win32.HWND) void {
    const w = g_webview orelse return;
    const widget = webview.widget(w) orelse return;
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetClientRect(window, &rect))) return;
    _ = win32.SetWindowPos(widget, win32.HWND_NOTOPMOST, 0, 0, win32.rectWidth(rect), win32.rectHeight(rect), win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
}

/// On the window's thread, for every request under ORIGIN.
fn serve(path: [*:0]const u8, body: *[*]const u8, body_len: *usize, content_type: *[*:0]const u8) callconv(.c) c_int {
    const name = std.mem.span(path);
    const file: resources.File = if (name.len == 0 or std.mem.eql(u8, name, PAGE_NAME))
        .{ .content_type = "text/html; charset=utf-8", .body = g_page orelse return 0 }
    else
        resources.staticFile(name) orelse {
            slog.warn("Configuration window requested an unknown file '{s}'", .{name});
            return 0;
        };
    body.* = file.body.ptr;
    body_len.* = file.body.len;
    content_type.* = file.content_type.ptr;
    return 1;
}

fn evalOnWindowThread(w: webview.Webview, arg: ?*anyopaque) callconv(.c) void {
    const script: [*:0]u8 = @ptrCast(arg orelse return);
    defer g_allocator.free(std.mem.span(script));
    _ = webview.webview_eval(w, script);
}

fn onClosed() void {
    slog.info("Configuration window closed", .{});
    session.end();
    main.onDialogClosed();
    resetWindow();
}

fn registerWindowClass() void {
    const instance = win32.GetModuleHandleA(null) orelse {
        slog.err("Failed to get the module handle to register the configuration window", .{});
        return;
    };
    const wc = win32.WNDCLASSEXA{
        .cbSize = @sizeOf(win32.WNDCLASSEXA),
        .style = 0,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = win32.LoadIconA(instance, @ptrFromInt(APP_ICON_ID)),
        .hCursor = win32.LoadCursorA(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS,
        .hIconSm = null,
    };
    if (win32.RegisterClassExA(&wc) == 0) {
        slog.err("Failed to register the configuration window's class: error {d}", .{win32.GetLastError()});
    }
}

/// Appends to any arguments already in the environment, so a recording script can pass --remote-debugging-port.
fn disableProxyDetection() void {
    var existing_buf: [1024]u8 = undefined;
    // Returns 0 when unset, or the required size when it doesn't fit.
    const existing_len = win32.GetEnvironmentVariableA(BROWSER_ARGS_VAR, &existing_buf, existing_buf.len);
    if (existing_len >= existing_buf.len) {
        slog.warn("Failed to read '{s}', its arguments are too long and will be replaced", .{BROWSER_ARGS_VAR});
    }
    const existing = if (existing_len < existing_buf.len) existing_buf[0..existing_len] else "";

    var args_buf: [existing_buf.len + 32]u8 = undefined;
    const separator = if (existing.len > 0) " " else "";
    const args = std.mem.printSentinel(&args_buf, "{s}{s}--no-proxy-server", .{ existing, separator }, 0) catch unreachable;
    // Windows proxy auto-detection (WPAD) otherwise stalls every page load ~2.7s on some networks.
    if (!win32.toBool(win32.SetEnvironmentVariableA(BROWSER_ARGS_VAR, args))) {
        slog.warn("Failed to disable proxy detection for the configuration window, it may open slowly", .{});
    }
}

/// Main thread, once the window's thread has finished.
fn resetWindow() void {
    if (g_page) |page| g_allocator.free(page);
    g_page = null;
    if (g_editing_profile) |name| g_allocator.free(name);
    g_editing_profile = null;
    g_state = .closed;
}

fn focus() void {
    const window = hwnd() orelse return;
    if (win32.toBool(win32.IsIconic(window))) _ = win32.ShowWindow(window, win32.SW_RESTORE);
    _ = win32.SetForegroundWindow(window);
}

fn uiScale() f32 {
    return @bitCast(g_ui_scale_bits.load(.acquire));
}

fn setUiScale(scale: f32) void {
    g_ui_scale_bits.store(@bitCast(scale), .release);
}

/// Falls back to DEFAULT_POSITION when the saved spot is on no monitor, e.g. a hand-edited value or an unplugged screen.
fn savedPosition(settings: *const GlobalConfig) win32.POINT {
    const x = settings.dialogX orelse return DEFAULT_POSITION;
    const y = settings.dialogY orelse return DEFAULT_POSITION;
    const position: win32.POINT = .{ .x = x, .y = y };
    if (win32.isOnMonitor(position)) return position;
    slog.warn("Saved configuration window position ({d}, {d}) is off-screen, using the default", .{ x, y });
    return DEFAULT_POSITION;
}

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
