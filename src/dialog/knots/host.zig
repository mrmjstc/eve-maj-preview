//! The knots configuration window, run as a nested loop on the main thread.
const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const main = @import("../../main.zig");
const config = @import("../../config.zig");
const session = @import("session.zig");
const bind = @import("bind.zig");
const form = @import("form.zig");
const images = @import("images.zig");
const header = @import("header.zig");
const profiles = @import("profiles.zig");
const pickers = @import("pickers.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const region = @import("region.zig");
const hotkey = @import("hotkey.zig");
const general = @import("tabs/general.zig");
const characters = @import("tabs/characters.zig");
const hotkeys_tab = @import("tabs/hotkeys.zig");
const hotkey_groups = @import("tabs/hotkey_groups.zig");
const notifications = @import("tabs/notifications.zig");
const lang = @import("lang.zig");
const search = @import("search.zig");
const import_dialog = @import("import_dialog.zig");
const update_notice = @import("update_notice.zig");
const overlays = @import("tabs/overlays.zig");
const prices = @import("prices.zig");
const behavior = @import("tabs/behavior.zig");
const log = @import("../../log.zig");

const GlobalConfig = config.GlobalConfig;
const slog = log.scoped("dialog_knots");

const WINDOW_TITLE = "EVE-Maj Preview Configuration (knots)";
/// In logical pixels; knots has no zoom yet.
const DESIGN_WIDTH = 820;
const DESIGN_HEIGHT = 900;
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
    /// An ore price fetch's result, as a *prices.Fetched in lParam.
    prices_fetched,
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
/// Where placeWindowHook puts the window knots creates, while App.init runs.
var g_spawn_position: ?win32.POINT = null;
var g_spawn_hook: ?win32.HHOOK = null;

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
    postCommand(.open);
}

/// The footer's Close: asks about unsaved changes like the title bar's close button.
pub fn requestClose() void {
    const window = g_hwnd orelse return;
    if (!win32.toBool(win32.PostMessageA(window, win32.WM_CLOSE, 0, 0))) {
        slog.warn("Failed to close the knots configuration window: error {d}", .{win32.GetLastError()});
    }
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
    if (!win32.toBool(win32.PostMessageA(timer, win32.WM_KNOTS_COMMAND, @backingInt(command), 0))) {
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
        .prices_fetched => applyPrices(lParam),
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
    defer widgets.reset();
    hotkey.init(g_allocator, requestFrame);
    defer hotkey.reset();
    region.init(g_allocator);
    defer region.cancel();
    prices.init(g_allocator);
    lang.init(g_allocator);
    defer lang.deinit();
    search.init(g_allocator);
    defer search.reset();
    import_dialog.init(g_allocator);
    defer import_dialog.reset();
    update_notice.init(g_allocator);
    defer update_notice.reset();
    notifications.init(g_allocator);
    defer notifications.reset();
    general.init(g_allocator);
    defer general.reset();
    characters.init(g_allocator);
    defer characters.reset();
    hotkeys_tab.init(g_allocator);
    defer hotkeys_tab.reset();
    hotkey_groups.init(g_allocator);
    defer hotkey_groups.reset();
    behavior.init(g_allocator);
    defer behavior.reset();
    images.init(g_allocator);
    defer images.deinit();
    header.init(g_allocator);
    defer header.deinit();
    profiles.init(g_allocator, scheduleProfileAction);
    defer profiles.deinit();
    status.clear();

    // knots creates its window at the default spot and shows it straight away, so it's placed as it's created rather than moved after.
    const is_placed = installPlacement(position);
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
                .{ .name = style.FONT_MONO, .data = style.FONT_MONO_DATA },
            },
        },
    }) catch |err| {
        removePlacement();
        slog.err("Failed to create the knots configuration window: {}", .{err});
        _ = win32.MessageBoxA(null, "The configuration window couldn't start. It needs a graphics driver with Vulkan 1.3 support; updating the graphics driver usually fixes this.", "EVE-Maj Preview", win32.MB_OK | win32.MB_ICONERROR);
        return;
    };
    defer app.deinit();
    removePlacement();

    const window: win32.HWND = @ptrCast(app.main_viewport.window.getWindowHandle().windows.hwnd);
    g_hwnd = window;
    g_state = .open;
    g_present_mode_chosen = false;
    defer onClosed();
    g_knots_proc = win32.SetWindowLongPtrW(window, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&windowProc)));
    setIcon(window);
    styleTitleBar(window);
    if (!is_placed) _ = win32.SetWindowPos(window, win32.HWND_NOTOPMOST, position.x, position.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    if (settings.alwaysOnTop) setAlwaysOnTop(true);
    _ = win32.SetForegroundWindow(window);

    slog.info("Knots configuration window opened", .{});
    app.start(frame) catch |err| {
        slog.err("Failed to run the knots configuration window: {}", .{err});
    };
}

/// Makes the next top-level window this thread creates start at `position`; false if it couldn't.
fn installPlacement(position: win32.POINT) bool {
    g_spawn_position = position;
    g_spawn_hook = win32.SetWindowsHookExA(win32.WH_CBT, placeWindowHook, null, win32.GetCurrentThreadId()) orelse {
        slog.warn("Failed to place the configuration window as it opens, it will move there once shown: error {d}", .{win32.GetLastError()});
        g_spawn_position = null;
        return false;
    };
    return true;
}

fn removePlacement() void {
    if (g_spawn_hook) |hook| _ = win32.UnhookWindowsHookEx(hook);
    g_spawn_hook = null;
    g_spawn_position = null;
}

/// Places the first top-level window created while installed, which is knots' own, then stands aside.
fn placeWindowHook(code: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    if (code == win32.HCBT_CREATEWND) {
        if (g_spawn_position) |position| {
            const create: *win32.CBT_CREATEWND = win32.lparamToPtr(win32.CBT_CREATEWND, lParam);
            if (create.lpcs.hwndParent == null) {
                create.lpcs.x = position.x;
                create.lpcs.y = position.y;
                g_spawn_position = null;
            }
        }
    }
    return win32.CallNextHookEx(g_spawn_hook, code, wParam, lParam);
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
    // A hotkey field recording takes the keys and buttons it binds before knots sees them.
    if (hotkey.onWindowMessage(msg, wParam, lParam)) return 0;
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
    pickers.browse(target, 0, title, g_hwnd, timer, @backingInt(Command.picked));
}

/// A settings file for the Import dialog, read once the picker closes.
pub fn browseImportFile() void {
    const timer = main.g_timer_hwnd orelse {
        slog.err("Failed to open the import file picker: the timer window is missing", .{});
        return;
    };
    pickers.browse(.import_file, 0, "Select Settings File", g_hwnd, timer, @backingInt(Command.picked));
}

/// The header's name prompt names the restored profile; `backup` is copied.
pub fn restoreBackup(backup: []const u8, display_name: []const u8) void {
    header.openRestorePrompt(backup, display_name);
}

/// `name` as typed; the profile is created between frames, then the import applied to it.
pub fn importIntoNewProfile(name: []const u8, accent: u32) void {
    const file_name = config.profileFileName(g_allocator, name) catch {
        status.show(.failure, "'{s}' isn't a valid profile name: use letters, digits, spaces, '-' and '_', up to 16 characters", .{name});
        return;
    };
    defer g_allocator.free(file_name);
    profiles.request(.import_new, file_name, accent);
}

/// A notification type's custom sound, set once the picker closes.
pub fn browseSoundFile(type_index: usize) void {
    const timer = main.g_timer_hwnd orelse {
        slog.err("Failed to open the sound file picker: the timer window is missing", .{});
        return;
    };
    pickers.browse(.sound_file, type_index, "Select Sound File", g_hwnd, timer, @backingInt(Command.picked));
}

/// Starts fetching Jita ore prices; returns false if a fetch is already running or couldn't start.
pub fn fetchPrices() bool {
    const timer = main.g_timer_hwnd orelse {
        slog.err("Failed to fetch ore prices: the timer window is missing", .{});
        return false;
    };
    return prices.fetch(timer, @backingInt(Command.prices_fetched));
}

/// Fetched prices fill in the table, kept until Save.
fn applyPrices(lParam: win32.LPARAM) void {
    if (lParam == 0) return;
    const fetched: *prices.Fetched = @ptrFromInt(@as(usize, @bitCast(lParam)));
    defer fetched.deinit();
    // The window may have closed while the fetch ran.
    if (g_state != .open) return;
    if (fetched.failed) {
        status.show(.failure, "Failed to fetch prices from ESI.", .{});
        return;
    }
    for (fetched.prices) |price| overlays.setOrePrice(price.name, price.price);
    status.show(if (fetched.prices.len > 0) .success else .failure, "Updated {d} of {d} price(s)", .{ fetched.prices.len, prices.NAMES.len });
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
        .import_file => import_dialog.loadFile(picked.path),
        // Picking a file means the sound is wanted.
        .sound_file => {
            const type_config = notifications.typeRef(picked.index);
            type_config.set("sound_path", picked.path);
            type_config.set("sound_enabled", true);
        },
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

/// Draws a frame soon, for a change made outside one, e.g. a region selection finishing.
pub fn redraw() void {
    requestFrame();
}

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

/// Colours the title bar like the header under it, so the two read as one bar.
fn styleTitleBar(window: win32.HWND) void {
    setWindowAttribute(window, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, 1);
    setWindowAttribute(window, win32.DWMWA_CAPTION_COLOR, colorRef(style.CHROME));
    setWindowAttribute(window, win32.DWMWA_TEXT_COLOR, colorRef(style.MUTED));
    setWindowAttribute(window, win32.DWMWA_BORDER_COLOR, colorRef(style.BORDER));
}

/// Every attribute set here is a DWORD-sized BOOL or COLORREF.
fn setWindowAttribute(window: win32.HWND, attribute: win32.DWORD, value: win32.DWORD) void {
    const result = win32.DwmSetWindowAttribute(window, attribute, &value, @sizeOf(win32.DWORD));
    // Debug only: Windows 10 rejects the colour attributes and just keeps its own title bar.
    if (result < 0) slog.debug("Failed to set window attribute {d}: HRESULT 0x{x}", .{ attribute, @as(u32, @bitCast(result)) });
}

/// DWM's COLORREF: 0x00BBGGRR.
fn colorRef(color: ui.Color) win32.DWORD {
    const argb = widgets.argbFromColor(color);
    return ((argb & 0xff) << 16) | (argb & 0xff00) | ((argb >> 16) & 0xff);
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
