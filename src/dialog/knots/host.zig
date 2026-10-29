//! The knots configuration window, run as a nested loop on the main thread.
const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const gdi_overlay = @import("../../platform/gdi_overlay.zig");
const app_mod = @import("../../app.zig");
const config = @import("../../config.zig");
const types = @import("../../config/types.zig");
const monitors = @import("../../layout/monitors.zig");
const update = @import("../../update.zig");
const detached = @import("../../util/detached.zig");
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
const color_convert = @import("color_convert.zig");
const region = @import("region.zig");
const hotkey = @import("hotkey.zig");
const general = @import("tabs/general.zig");
const backups = @import("tabs/backups.zig");
const hotkeys = @import("tabs/hotkeys.zig");
const hotkey_groups = @import("tabs/hotkey_groups.zig");
const event_alerts = @import("tabs/event_alerts.zig");
const characters = @import("tabs/characters.zig");
const lang = @import("../../lang/lang.zig");
const search = @import("search.zig");
const import_dialog = @import("import_dialog.zig");
const update_notice = @import("update_notice.zig");
const mining = @import("tabs/mining.zig");
const portraits = @import("portraits.zig");
const prices = @import("prices.zig");
const behavior = @import("tabs/behavior.zig");
const client_list = @import("tabs/client_list.zig");
const barrage = @import("barrage.zig");
const log = @import("../../log.zig");

const GlobalConfig = config.GlobalConfig;
const Language = types.Language;
const slog = log.Scoped("dialog_knots");

const WINDOW_TITLE = "EVE-Maj Preview Configuration";
/// In logical pixels, like designWidth's; knots has no zoom yet.
const DESIGN_HEIGHT = 960;
const DEFAULT_POSITION: win32.POINT = .{ .x = 20, .y = 20 };
/// On the window itself; clears the footer's status once it has shown long enough.
const STATUS_TIMER_ID = 1;
/// On the window itself; draws frames while the Barrage easter egg is open.
const ANIMATION_TIMER_ID = 2;
const ANIMATION_INTERVAL_MS = 15;
/// Per open, so an error every frame can't reopen the window forever.
const MAX_REOPENS = 2;
const REOPENED_NOTICE = "Reopened after an error. Your unsaved changes are kept.";

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
    /// A picker's result, as a *pickers.Picked in lParam.
    picked,
    /// An ore price fetch's result, as a *prices.Fetched in lParam.
    prices_fetched,
    /// A character portrait's load result, as a *portraits.Loaded in lParam.
    portrait_loaded,
    /// Another language was picked: the window takes its width and title.
    fit_language,
    /// The update check started as the window opened has finished; the frame it draws shows what it found.
    update_checked,
    /// What the Barrage link's thread received, as a *link.Arrival in lParam.
    barrage_arrival,
};

const State = enum { closed, open };

var g_allocator: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;
var g_state: State = .closed;
var g_hwnd: ?win32.HWND = null;
/// knots' window procedure, which the subclass forwards to.
var g_knots_proc: isize = 0;
/// knots' loop swallows WM_QUIT, so an exit while the window is open is posted once it has closed.
var g_should_quit_after_close: bool = false;
/// Closes without asking about unsaved changes.
var g_should_force_close: bool = false;
var g_is_present_mode_chosen: bool = false;
/// Where placeWindowHook puts the window knots creates, while App.init runs.
var g_spawn_position: ?win32.POINT = null;
var g_spawn_hook: ?win32.HHOOK = null;
/// The running window, for retitling it; null while it's closed.
var g_app: ?*knots.App = null;
/// Trails a newly picked language until fit_language runs.
var g_window_language: Language = .en;
/// A fit_language command is on its way, so another isn't posted each frame until it runs.
var g_is_fit_posted: bool = false;

/// At startup; `app` outlives every window.
pub fn init(app: *app_mod.App) void {
    g_allocator = app.allocator;
    g_io = app.io;
    session.init(app);
    pickers.init(g_allocator);
    prices.init(g_allocator);
    portraits.setAllocator(g_allocator);
    barrage.init(g_allocator);
}

/// At app exit.
pub fn deinit() void {
    portraits.deinit();
}

pub fn isOpen() bool {
    return g_state == .open;
}

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
    g_should_quit_after_close = true;
    closeWithoutAsking();
    return true;
}

pub fn postCommand(command: Command) void {
    const timer_hwnd = session.runningApp().timer_hwnd orelse {
        slog.err("Failed to run a knots configuration window command: the timer window is missing", .{});
        return;
    };
    if (!win32.toBool(win32.PostMessageA(timer_hwnd, win32.WM_KNOTS_COMMAND, @backingInt(command), 0))) {
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
        .portrait_loaded => applyPortrait(lParam),
        .fit_language => fitLanguage(),
        .update_checked => {},
        .barrage_arrival => barrage.onArrival(lParam),
    }
    requestFrame();
}

/// Before each frame: text follows the picked language at once; width and title follow between frames.
pub fn useLanguage(language: Language) void {
    lang.use(language);
    if (language == g_window_language or g_is_fit_posted) return;
    g_is_fit_posted = true;
    postCommand(.fit_language);
}

/// Applied at once, though the setting itself waits for Save like any other.
pub fn setAlwaysOnTop(is_enabled: bool) void {
    const window = g_hwnd orelse return;
    const insert_after = if (is_enabled) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST;
    _ = win32.SetWindowPos(window, insert_after, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
}

/// The picker owns its own modal loop on another thread; the result arrives as a `picked` command.
pub fn browseFolder(target: pickers.Target, title: []const u8) void {
    const timer_hwnd = session.runningApp().timer_hwnd orelse {
        slog.err("Failed to open the folder picker: the timer window is missing", .{});
        return;
    };
    pickers.browse(target, 0, title, g_hwnd, timer_hwnd, @backingInt(Command.picked));
}

/// A settings file for the Import dialog, read once the picker closes.
pub fn browseImportFile() void {
    const timer_hwnd = session.runningApp().timer_hwnd orelse {
        slog.err("Failed to open the import file picker: the timer window is missing", .{});
        return;
    };
    pickers.browse(.import_file, 0, "Select Settings File", g_hwnd, timer_hwnd, @backingInt(Command.picked));
}

/// The header's name prompt names the restored profile; `backup` is copied.
pub fn restoreBackup(backup: []const u8, display_name: []const u8) void {
    header.openRestorePrompt(backup, display_name);
}

/// `name` as typed; the profile is created and switched to between frames, then the import applied to it.
pub fn importIntoNewProfile(name: []const u8, accent: u32) void {
    const file_name = config.profileFileName(g_allocator, name) catch |err| {
        slog.info("Rejected imported profile name '{s}': {}", .{ name, err });
        status.show(.failure, "'{name}' isn't a valid profile name: use " ++ profiles.NAME_RULES, .{ .name = name });
        return;
    };
    defer g_allocator.free(file_name);
    profiles.request(.import_new, file_name, accent);
}

/// A notification type's custom sound, set once the picker closes.
pub fn browseSoundFile(type_index: usize) void {
    const timer_hwnd = session.runningApp().timer_hwnd orelse {
        slog.err("Failed to open the sound file picker: the timer window is missing", .{});
        return;
    };
    pickers.browse(.sound_file, type_index, "Select Sound File", g_hwnd, timer_hwnd, @backingInt(Command.picked));
}

/// Starts fetching Jita ore prices; returns false if a fetch is already running or couldn't start.
pub fn fetchPrices() bool {
    const timer_hwnd = session.runningApp().timer_hwnd orelse {
        slog.err("Failed to fetch ore prices: the timer window is missing", .{});
        return false;
    };
    return prices.fetch(g_io, timer_hwnd, @backingInt(Command.prices_fetched));
}

/// Draws a frame soon, for a change made outside one, e.g. a region selection finishing.
pub fn redraw() void {
    requestFrame();
}

/// Draws frames steadily until stopAnimation, for the Barrage easter egg.
pub fn startAnimation() void {
    const window = g_hwnd orelse return;
    if (win32.SetTimer(window, ANIMATION_TIMER_ID, ANIMATION_INTERVAL_MS, null) == 0) {
        slog.warn("Failed to start animating the configuration window, Barrage will stutter: error {d}", .{win32.GetLastError()});
    }
}

pub fn stopAnimation() void {
    const window = g_hwnd orelse return;
    _ = win32.KillTimer(window, ANIMATION_TIMER_ID);
}

/// Refused with error.ConflictingHotkeys, which the status line explains, while hotkeys conflict; between frames only.
pub fn saveChanges() !void {
    try refuseConflictingHotkeys();
    try session.save();
}

/// Drops unsaved changes to both documents; between frames only.
pub fn discardChanges() !void {
    try session.discard();
    setAlwaysOnTop(session.runningApp().global_settings.alwaysOnTop);
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
    session.begin() catch |err| {
        slog.err("Failed to start editing the configuration: {}", .{err});
        return;
    };
    defer session.end();
    if (!session.global().get("disableUpdateChecks")) startUpdateCheck();

    var reopen_count: u32 = 0;
    while (true) : (reopen_count += 1) {
        runWindow(reopen_count > 0) catch |err| {
            slog.err("Failed to run the knots configuration window: {}", .{err});
            if (shouldReopen(reopen_count)) continue;
        };
        break;
    }
    if (g_should_quit_after_close) {
        g_should_quit_after_close = false;
        win32.PostQuitMessage(0);
    }
}

/// After a failed window, unless the app is exiting; the session's edits outlive it, so a reopened one carries on with them.
fn shouldReopen(reopen_count: u32) bool {
    if (g_should_quit_after_close) return false;
    if (reopen_count < MAX_REOPENS) {
        slog.info("Reopening the knots configuration window after its error", .{});
        return true;
    }
    const message = if (session.isDirty())
        "The configuration window closed after repeated errors, and its unsaved changes were lost. The log has the details."
    else
        "The configuration window closed after repeated errors. The log has the details.";
    _ = win32.MessageBoxA(null, message, "EVE-Maj Preview", win32.MB_OK | win32.MB_ICONERROR);
    return false;
}

/// One window over the open session, until it closes or a frame fails.
fn runWindow(is_reopened: bool) !void {
    const settings = &session.runningApp().global_settings;
    const position = savedPosition(settings);
    g_window_language = settings.language;
    g_is_fit_posted = false;

    bind.init(g_allocator);
    defer bind.reset();
    defer widgets.reset();
    hotkey.init(g_allocator, requestFrame);
    defer hotkey.reset();
    region.init(g_allocator);
    defer region.cancel();
    portraits.init(session.runningApp().timer_hwnd, @backingInt(Command.portrait_loaded));
    for (session.profile().ptr.characters.items) |character| portraits.preload(character.name);
    // A language picked but not saved goes with the window.
    defer lang.use(session.runningApp().global_settings.language);
    search.init(g_allocator);
    defer search.reset();
    import_dialog.init(g_allocator);
    defer import_dialog.reset();
    update_notice.init(g_allocator);
    defer update_notice.reset();
    general.init(g_allocator);
    defer general.reset();
    backups.init(g_allocator);
    defer backups.reset();
    hotkeys.init(g_allocator);
    defer hotkeys.reset();
    hotkey_groups.init(g_allocator);
    defer hotkey_groups.reset();
    behavior.init(g_allocator);
    defer behavior.reset();
    defer client_list.reset();
    defer barrage.reset();
    images.init(g_allocator);
    defer images.deinit();
    header.init(g_allocator);
    defer header.deinit();
    profiles.init(g_allocator, scheduleProfileAction);
    defer profiles.deinit();
    status.clear();
    if (is_reopened) status.show(.failure, REOPENED_NOTICE, .{});

    // knots shows its window as it's created, so it's placed then rather than moved after.
    const is_placed = installPlacement(position);
    var app = knots.App.init(g_io, g_allocator, .{
        .window = .{
            .width = designWidth(settings.language),
            .height = DESIGN_HEIGHT,
            .title = lang.text(WINDOW_TITLE),
        },
        .ui = .{
            .theme = style.theme,
            .fonts = &.{
                .{ .name = style.FONT_REGULAR, .data = style.FONT_REGULAR_DATA },
                .{ .name = style.FONT_SEMIBOLD, .data = style.FONT_SEMIBOLD_DATA },
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
    g_app = &app;

    const window: win32.HWND = @ptrCast(app.main_viewport.window.getWindowHandle().windows.hwnd);
    g_hwnd = window;
    g_state = .open;
    g_is_present_mode_chosen = false;
    defer onClosed();
    g_knots_proc = win32.SetWindowLongPtrW(window, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&windowProc)));
    if (g_knots_proc == 0) slog.err("Failed to subclass the configuration window, so it won't ask about unsaved changes on close or remember its position: error {d}", .{win32.GetLastError()});
    setIcon(window);
    styleTitleBar(window);
    if (!is_placed) _ = win32.SetWindowPos(window, win32.HWND_NOTOPMOST, position.x, position.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    if (settings.alwaysOnTop) setAlwaysOnTop(true);
    _ = win32.SetForegroundWindow(window);

    slog.info("Knots configuration window opened", .{});
    try app.start(frame);
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
fn placeWindowHook(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    if (nCode == win32.HCBT_CREATEWND) {
        if (g_spawn_position) |position| {
            const create: *win32.CBT_CREATEWND = win32.lparamToPtr(win32.CBT_CREATEWND, lParam);
            if (create.lpcs.hwndParent == null) {
                create.lpcs.x = position.x;
                create.lpcs.y = position.y;
                g_spawn_position = null;
            }
        }
    }
    return win32.CallNextHookEx(g_spawn_hook, nCode, wParam, lParam);
}

fn frame(view: *knots.View, context: *ui.Frame) !void {
    if (!g_is_present_mode_chosen) choosePresentMode(view);
    try form.frame(view, context);
    if (status.takeShownMs()) |show_ms| startStatusTimer(show_ms);
}

/// Restarted by each new message, so it times the latest one.
fn startStatusTimer(show_ms: u32) void {
    const window = g_hwnd orelse return;
    if (win32.SetTimer(window, STATUS_TIMER_ID, show_ms, null) == 0) {
        slog.warn("Failed to time the status message, it stays until the next one: error {d}", .{win32.GetLastError()});
    }
}

/// Vsync would block the main thread up to a frame, stalling the low-level input hooks.
fn choosePresentMode(view: *knots.View) void {
    g_is_present_mode_chosen = true;
    const modes = view.renderer.supported_present_modes;
    var renderer_config = view.renderer.config;
    renderer_config.present_mode = if (modes.contains(.mailbox)) .mailbox else if (modes.contains(.immediate)) .immediate else {
        slog.warn("Configuration window can only present with vsync, input hooks may lag while it redraws", .{});
        return;
    };
    view.app.reconfigureRenderer(view.id, renderer_config) catch |err| {
        slog.warn("Failed to switch the configuration window off vsync, input hooks may lag while it redraws: {}", .{err});
    };
}

/// Subclasses knots' window to prompt on unsaved close, remember its position and clear the status line.
fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // A hotkey field recording takes the keys and buttons it binds before knots sees them.
    if (hotkey.onWindowMessage(msg, wParam, lParam)) return 0;
    switch (msg) {
        win32.WM_CLOSE => if (!g_should_force_close and session.isDirty()) {
            form.confirmClose();
            requestFrame();
            return 0;
        },
        win32.WM_TIMER => switch (wParam) {
            STATUS_TIMER_ID => {
                _ = win32.KillTimer(hwnd, STATUS_TIMER_ID);
                status.clear();
                requestFrame();
                return 0;
            },
            ANIMATION_TIMER_ID => {
                requestFrame();
                return 0;
            },
            else => {},
        },
        win32.WM_EXITSIZEMOVE => savePosition(hwnd),
        else => {},
    }
    return win32.CallWindowProcW(g_knots_proc, hwnd, msg, wParam, lParam);
}

/// On a thread of its own, so About can show a release found since the app started.
fn startUpdateCheck() void {
    const timer_hwnd = session.runningApp().timer_hwnd orelse {
        slog.err("Failed to check for updates: the timer window is missing", .{});
        return;
    };
    detached.spawn(checkThenRedraw, .{ g_allocator, g_io, timer_hwnd }) catch |err| {
        slog.warn("Failed to start update check thread: {}", .{err});
    };
}

/// Update check thread only.
fn checkThenRedraw(allocator: std.mem.Allocator, io: std.Io, timer_hwnd: win32.HWND) void {
    update.checkForUpdatesBackground(allocator, io);
    if (!win32.toBool(win32.PostMessageA(timer_hwnd, win32.WM_KNOTS_COMMAND, @backingInt(Command.update_checked), 0))) {
        slog.warn("Failed to show the update check's result: error {d}", .{win32.GetLastError()});
    }
}

fn scheduleProfileAction() void {
    postCommand(.profile_action);
}

/// Fetched prices fill in the table, kept until Save.
fn applyPrices(lParam: win32.LPARAM) void {
    if (lParam == 0) return;
    const fetched = win32.lparamToPtr(prices.Fetched, lParam);
    defer fetched.deinit();
    // The window may have closed while the fetch ran.
    if (g_state != .open) return;
    if (fetched.has_failed) {
        status.show(.failure, "Failed to fetch prices from ESI.", .{});
        return;
    }
    for (fetched.prices) |price| mining.setOrePrice(price.name, price.price);
    if (fetched.prices.len > 0) mining.stampPricesFetched();
    status.show(if (fetched.prices.len > 0) .success else .failure, "Updated {fetched} of {total} price(s)", .{ .fetched = fetched.prices.len, .total = prices.NAMES.len });
}

fn applyPortrait(lParam: win32.LPARAM) void {
    if (lParam == 0) return;
    // Stored even once the window has closed, since the cache outlives it.
    portraits.store(win32.lparamToPtr(portraits.Loaded, lParam));
}

fn applyPicked(lParam: win32.LPARAM) void {
    if (lParam == 0) return;
    const picked = win32.lparamToPtr(pickers.Picked, lParam);
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
            const type_config = event_alerts.typeRef(picked.index);
            type_config.set("sound_path", picked.path);
            type_config.set("sound_enabled", true);
        },
    }
}

fn save() bool {
    saveChanges() catch |err| {
        // Not a failure: the user is told to fix the hotkeys first.
        if (err != error.ConflictingHotkeys) {
            slog.err("Failed to save the configuration: {}", .{err});
            status.show(.failure, "Failed to save: {err}", .{ .err = err });
        }
        return false;
    };
    status.show(.success, "Changes saved", .{});
    return true;
}

fn refuseConflictingHotkeys() !void {
    var arena_state: std.heap.ArenaAllocator = .init(g_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const conflicts = try hotkey.findConflicts(arena);
    if (conflicts.len == 0) return;
    var keys: std.Io.Writer.Allocating = .init(arena);
    try hotkey.writeCombos(&keys.writer, conflicts);
    slog.info("Refused to save: hotkeys '{s}' are bound more than once", .{keys.written()});
    // Only the first is spelled out, since the status line holds one sentence.
    var first: std.Io.Writer.Allocating = .init(arena);
    try hotkey.writeCombos(&first.writer, conflicts[0..1]);
    var holders: std.Io.Writer.Allocating = .init(arena);
    try hotkey.writeHolders(arena, &holders.writer, conflicts[0]);
    if (conflicts.len == 1) {
        status.show(.failure, "Not saved: {key} is used by {holders}", .{ .key = first.written(), .holders = holders.written() });
    } else {
        status.show(.failure, "Not saved: {key} is used by {holders} (+{count} more)", .{ .key = first.written(), .holders = holders.written(), .count = conflicts.len - 1 });
    }
    return error.ConflictingHotkeys;
}

fn discard() bool {
    discardChanges() catch |err| {
        slog.err("Failed to discard the configuration changes: {}", .{err});
        return false;
    };
    return true;
}

fn closeWithoutAsking() void {
    const window = g_hwnd orelse return;
    if (!win32.toBool(win32.PostMessageA(window, win32.WM_CLOSE, 0, 0))) {
        slog.warn("Failed to close the knots configuration window: error {d}", .{win32.GetLastError()});
        return;
    }
    g_should_force_close = true;
}

fn onClosed() void {
    slog.info("Knots configuration window closed", .{});
    g_hwnd = null;
    g_app = null;
    g_state = .closed;
    g_should_force_close = false;
}

/// Wider for languages with longer labels than English's.
fn designWidth(language: Language) u32 {
    return switch (language) {
        .en => 810,
        .es, .pt => 820,
        .de, .fr, .pl, .ru => 870,
    };
}

/// Between frames, since resizing and retitling send knots' window messages it can't take mid-frame.
fn fitLanguage() void {
    g_is_fit_posted = false;
    const window = g_hwnd orelse return;
    const language = session.global().get("language");
    if (language == g_window_language) return;
    resizeForLanguage(window, g_window_language, language);
    g_window_language = language;
    const app = g_app orelse return;
    app.main_viewport.window.setTitle(lang.text(WINDOW_TITLE)) catch |err| {
        slog.warn("Failed to retitle the configuration window: {}", .{err});
    };
}

/// Keeps the window's left edge unless the new width would push it off its monitor.
fn resizeForLanguage(window: win32.HWND, from: Language, to: Language) void {
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetWindowRect(window, &rect))) {
        slog.warn("Failed to read the configuration window's size: error {d}", .{win32.GetLastError()});
        return;
    }
    const dpi = win32.GetDpiForWindow(window);
    const scale = win32.dpiToScale(if (dpi == 0) win32.USER_DEFAULT_SCREEN_DPI else dpi);
    const change = @as(i32, @intCast(designWidth(to))) - @as(i32, @intCast(designWidth(from)));
    const width = win32.rectWidth(rect) + win32.scalePixels(change, scale);
    const bounds = monitors.nearestMonitorBounds(window).bounds;
    const x = @max(bounds.left, @min(rect.left, bounds.right - width));
    _ = win32.SetWindowPos(window, win32.HWND_NOTOPMOST, x, rect.top, width, win32.rectHeight(rect), win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
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
    const instance = win32.GetModuleHandleA(null) orelse {
        slog.warn("Failed to load the app icon for the configuration window: error {d}", .{win32.GetLastError()});
        return;
    };
    const icon = win32.LoadIconA(instance, @ptrFromInt(win32.APP_ICON_ID)) orelse {
        slog.warn("Failed to load the app icon for the configuration window", .{});
        return;
    };
    _ = win32.SendMessageA(window, win32.WM_SETICON, win32.ICON_BIG, @bitCast(@intFromPtr(icon)));
    _ = win32.SendMessageA(window, win32.WM_SETICON, win32.ICON_SMALL, @bitCast(@intFromPtr(icon)));
}

/// Colours the title bar like the header under it, so the two read as one bar.
fn styleTitleBar(window: win32.HWND) void {
    setWindowAttribute(window, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, 1);
    setWindowAttribute(window, win32.DWMWA_CAPTION_COLOR, toDwmColor(style.CHROME));
    setWindowAttribute(window, win32.DWMWA_TEXT_COLOR, toDwmColor(style.MUTED));
    setWindowAttribute(window, win32.DWMWA_BORDER_COLOR, toDwmColor(style.BORDER));
}

/// Every attribute set here is a DWORD-sized BOOL or COLORREF.
fn setWindowAttribute(window: win32.HWND, attribute: win32.DWORD, value: win32.DWORD) void {
    const result = win32.DwmSetWindowAttribute(window, attribute, &value, @sizeOf(win32.DWORD));
    // Debug only: Windows 10 rejects the colour attributes and just keeps its own title bar.
    if (result < 0) slog.debug("Failed to set window attribute {d}: HRESULT 0x{x}", .{ attribute, @as(u32, @bitCast(result)) });
}

/// DWM takes a COLORREF, 0x00BBGGRR.
fn toDwmColor(color: ui.Color) win32.DWORD {
    return gdi_overlay.toColorRef(color_convert.toArgb(color));
}

fn savePosition(window: win32.HWND) void {
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetWindowRect(window, &rect))) {
        slog.warn("Failed to read the configuration window's position: error {d}", .{win32.GetLastError()});
        return;
    }
    session.runningApp().global_settings.saveDialogPosition(g_io, rect.left, rect.top) catch |err| {
        slog.warn("Failed to save the configuration window's position: {}", .{err});
    };
}

/// DEFAULT_POSITION when the saved spot is on no monitor, e.g. an unplugged screen.
fn savedPosition(settings: *const GlobalConfig) win32.POINT {
    const x = settings.dialogX orelse return DEFAULT_POSITION;
    const y = settings.dialogY orelse return DEFAULT_POSITION;
    const position: win32.POINT = .{ .x = x, .y = y };
    if (win32.isOnMonitor(position)) return position;
    slog.warn("Saved configuration window position ({d}, {d}) is off-screen, using the default", .{ x, y });
    return DEFAULT_POSITION;
}
