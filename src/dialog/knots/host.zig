//! The knots configuration window, run as a nested loop on the main thread.
const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const main = @import("../../main.zig");
const config = @import("../../config.zig");
const webview_host = @import("../host.zig");
const session = @import("session.zig");
const bind = @import("bind.zig");
const form = @import("form.zig");
const images = @import("images.zig");
const header = @import("header.zig");
const profiles = @import("profiles.zig");
const pickers = @import("pickers.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const log = @import("../../log.zig");

const GlobalConfig = config.GlobalConfig;
const slog = log.scoped("dialog_knots");

const WINDOW_TITLE = "EVE-Maj Preview Configuration (knots)";
/// In logical pixels; knots has no zoom yet, so the dialog scale setting doesn't apply.
const DESIGN_WIDTH = 900;
const DESIGN_HEIGHT = 760;
const DEFAULT_POSITION: win32.POINT = .{ .x = 20, .y = 20 };
const APP_ICON_ID = 101;

/// Posted to the timer window as wParam of WM_KNOTS_COMMAND, so none runs inside a tray handler or a frame.
pub const Command = enum(usize) {
    /// Runs the window's loop, which returns once it closes.
    open,
    /// Save and Discard restart subsystems or replace documents the frame is reading.
    save,
    discard,
    save_and_close,
    discard_and_close,
    /// Whatever the header queued in profiles.zig.
    profile_action,
    /// A folder picker's result, as a *pickers.Picked in lParam.
    picked,
};

const State = enum { closed, open };

var g_allocator: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;
var g_state: State = .closed;
var g_hwnd: ?win32.HWND = null;
/// knots' window procedure, which the subclass forwards to.
var g_knots_proc: isize = 0;
/// knots' loop swallows WM_QUIT, so an exit while the window is open is posted once it has closed.
var g_quit_after_close: bool = false;
/// Closes without asking about unsaved changes.
var g_force_close: bool = false;
var g_present_mode_chosen: bool = false;

pub fn init(allocator: std.mem.Allocator, io: std.Io) void {
    g_allocator = allocator;
    g_io = io;
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
    // Both windows would edit the same live profile.
    if (webview_host.isOpen()) {
        slog.warn("Failed to open the knots configuration window: the WebView2 one is open", .{});
        return;
    }
    postCommand(.open);
}

/// Returns whether the exit waits for the window to close, which then posts the quit itself.
pub fn closeForExit() bool {
    if (g_state != .open) return false;
    g_quit_after_close = true;
    closeWithoutAsking();
    return true;
}

pub fn postCommand(command: Command) void {
    const timer = main.g_timer_hwnd orelse {
        slog.err("Failed to run a knots configuration window command: the timer window is missing", .{});
        return;
    };
    if (!win32.toBool(win32.PostMessageA(timer, win32.WM_KNOTS_COMMAND, @intFromEnum(command), 0))) {
        slog.err("Failed to run a knots configuration window command: error {d}", .{win32.GetLastError()});
    }
}

/// Main thread, from the timer window's procedure.
pub fn onCommand(wParam: win32.WPARAM, lParam: win32.LPARAM) void {
    const command = std.enums.fromInt(Command, wParam) orelse {
        slog.warn("Failed to run a knots configuration window command: unknown command {d}", .{wParam});
        return;
    };
    switch (command) {
        .open => run(),
        .save => _ = save(),
        .discard => _ = discard(),
        .save_and_close => if (save()) closeWithoutAsking(),
        .discard_and_close => if (discard()) closeWithoutAsking(),
        .profile_action => profiles.runPending(),
        .picked => applyPicked(lParam),
    }
    requestFrame();
}

/// Pumps every message on the main thread until the window closes, so the tick, hooks and tray keep running.
fn run() void {
    switch (g_state) {
        .closed => {},
        .open => {
            focus();
            return;
        },
    }
    const settings = &main.g_global_settings;
    const position = savedPosition(settings);

    session.begin(g_allocator) catch |err| {
        slog.err("Failed to start editing the configuration: {}", .{err});
        return;
    };
    defer session.end();
    bind.init(g_allocator);
    pickers.init(g_allocator);
    defer bind.reset();
    images.init(g_allocator);
    defer images.deinit();
    header.init(g_allocator);
    defer header.deinit();
    profiles.init(g_allocator, scheduleProfileAction);
    defer profiles.deinit();
    status.clear();

    var app = knots.App.init(g_io, g_allocator, .{
        .window = .{
            .width = DESIGN_WIDTH,
            .height = DESIGN_HEIGHT,
            .title = WINDOW_TITLE,
        },
        .ui = .{
            .theme = style.theme,
            .fonts = &.{
                .{ .name = style.FONT_REGULAR, .data = style.FONT_REGULAR_DATA },
                .{ .name = style.FONT_SEMIBOLD, .data = style.FONT_SEMIBOLD_DATA },
            },
        },
    }) catch |err| {
        slog.err("Failed to create the knots configuration window: {}", .{err});
        _ = win32.MessageBoxA(null, "The configuration window couldn't start. It needs a graphics driver with Vulkan 1.3 support; updating the graphics driver usually fixes this.", "EVE-Maj Preview", win32.MB_OK | win32.MB_ICONERROR);
        return;
    };
    defer app.deinit();

    const window: win32.HWND = @ptrCast(app.main_viewport.window.getWindowHandle().windows.hwnd);
    g_hwnd = window;
    g_state = .open;
    g_present_mode_chosen = false;
    defer onClosed();
    g_knots_proc = win32.SetWindowLongPtrW(window, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&windowProc)));
    setIcon(window);
    _ = win32.SetWindowPos(window, win32.HWND_NOTOPMOST, position.x, position.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    if (settings.alwaysOnTop) setAlwaysOnTop(true);
    _ = win32.SetForegroundWindow(window);

    slog.info("Knots configuration window opened", .{});
    app.start(frame) catch |err| {
        slog.err("Failed to run the knots configuration window: {}", .{err});
    };
}

fn frame(view: *knots.View, context: *ui.Frame) !void {
    if (!g_present_mode_chosen) choosePresentMode(view);
    try form.frame(view, context);
}

/// A vsync-paced present blocks the main thread for up to a frame, which would stall the low-level input hooks behind it.
fn choosePresentMode(view: *knots.View) void {
    g_present_mode_chosen = true;
    const modes = view.renderer.supported_present_modes;
    var cfg = view.renderer.config;
    cfg.present_mode = if (modes.contains(.mailbox)) .mailbox else if (modes.contains(.immediate)) .immediate else {
        slog.warn("Configuration window can only present with vsync, input hooks may lag while it redraws", .{});
        return;
    };
    view.app.reconfigureRenderer(view.id, cfg) catch |err| {
        slog.warn("Failed to switch the configuration window off vsync, input hooks may lag while it redraws: {}", .{err});
    };
}

/// Subclasses knots' window, to ask before closing with unsaved changes and to remember where the window was left.
fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE => if (!g_force_close and session.isDirty()) {
            form.confirmClose();
            requestFrame();
            return 0;
        },
        win32.WM_EXITSIZEMOVE => savePosition(hwnd),
        else => {},
    }
    return win32.CallWindowProcW(g_knots_proc, hwnd, msg, wParam, lParam);
}

/// Applied at once, though the setting itself waits for Save like any other.
pub fn setAlwaysOnTop(enabled: bool) void {
    const window = g_hwnd orelse return;
    const insert_after = if (enabled) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST;
    _ = win32.SetWindowPos(window, insert_after, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
}

fn scheduleProfileAction() void {
    postCommand(.profile_action);
}

/// The picker owns its own modal loop on another thread; the result arrives as a `picked` command.
pub fn browseFolder(target: pickers.Target, title: []const u8) void {
    const timer = main.g_timer_hwnd orelse {
        slog.err("Failed to open the folder picker: the timer window is missing", .{});
        return;
    };
    pickers.browseFolder(target, title, g_hwnd, timer, @intFromEnum(Command.picked));
}

fn applyPicked(lParam: win32.LPARAM) void {
    if (lParam == 0) return;
    const picked: *pickers.Picked = @ptrFromInt(@as(usize, @bitCast(lParam)));
    defer picked.deinit();
    // The window may have closed while the picker was open.
    if (g_state != .open) return;
    const chatlog = session.profile().child("chatlog");
    switch (picked.target) {
        .chatlog_dir => chatlog.set("chatlogDir", picked.path),
        .gamelog_dir => chatlog.set("gamelogDir", picked.path),
    }
}

fn save() bool {
    session.save() catch |err| {
        slog.err("Failed to save the configuration: {}", .{err});
        return false;
    };
    return true;
}

fn discard() bool {
    session.discard() catch |err| {
        slog.err("Failed to discard the configuration changes: {}", .{err});
        return false;
    };
    setAlwaysOnTop(main.g_global_settings.alwaysOnTop);
    return true;
}

fn closeWithoutAsking() void {
    const window = g_hwnd orelse return;
    g_force_close = true;
    _ = win32.PostMessageA(window, win32.WM_CLOSE, 0, 0);
}

fn onClosed() void {
    slog.info("Knots configuration window closed", .{});
    g_hwnd = null;
    g_state = .closed;
    g_force_close = false;
    if (g_quit_after_close) {
        g_quit_after_close = false;
        win32.PostQuitMessage(0);
    }
}

/// knots draws on WM_PAINT, so invalidating the window asks it for a frame.
fn requestFrame() void {
    const window = g_hwnd orelse return;
    _ = win32.InvalidateRect(window, null, win32.FALSE);
}

fn focus() void {
    const window = g_hwnd orelse return;
    if (win32.toBool(win32.IsIconic(window))) _ = win32.ShowWindow(window, win32.SW_RESTORE);
    _ = win32.SetForegroundWindow(window);
}

fn setIcon(window: win32.HWND) void {
    const instance = win32.GetModuleHandleA(null) orelse return;
    const icon = win32.LoadIconA(instance, @ptrFromInt(APP_ICON_ID)) orelse {
        slog.warn("Failed to load the app icon for the configuration window", .{});
        return;
    };
    _ = win32.SendMessageA(window, win32.WM_SETICON, win32.ICON_BIG, @bitCast(@intFromPtr(icon)));
    _ = win32.SendMessageA(window, win32.WM_SETICON, win32.ICON_SMALL, @bitCast(@intFromPtr(icon)));
}

fn savePosition(window: win32.HWND) void {
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetWindowRect(window, &rect))) return;
    main.g_global_settings.saveDialogPosition(rect.left, rect.top) catch |err| {
        slog.warn("Failed to save the configuration window's position: {}", .{err});
    };
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
