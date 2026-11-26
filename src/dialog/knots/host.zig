//! The knots configuration window, run as a nested loop on the main thread.
const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const gdi_overlay = @import("../../platform/gdi_overlay.zig");
const config = @import("../../config.zig");
const types = @import("../../config/types.zig");
const monitors = @import("../../layout/monitors.zig");
const update = @import("../../update.zig");
const detached = @import("../../util/detached.zig");
const panel_host = @import("../../panels/panel_host.zig");
const keyboard_hook = @import("../../hotkeys/keyboard_hook.zig");
const region_select = @import("../tools/region_select.zig");
const dialog_host = @import("../dialog_host.zig");
const session_mod = @import("session.zig");
const window_mod = @import("window.zig");
const form = @import("form.zig");
const header = @import("header.zig");
const profiles = @import("profiles.zig");
const pickers_mod = @import("pickers.zig");
const prices_mod = @import("prices.zig");
const portraits_mod = @import("portraits.zig");
const region_mod = @import("region.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const color_convert = @import("color_convert.zig");
const hotkey = @import("hotkey.zig");
const event_alerts = @import("tabs/event_alerts.zig");
const lang = @import("../../lang/lang.zig");
const import_dialog = @import("import_dialog.zig");
const mining = @import("tabs/mining.zig");
const messages = @import("../../messages.zig");
const log = @import("../../log.zig");

const GlobalConfig = config.GlobalConfig;
const Language = types.Language;
const SettingsPage = panel_host.SettingsPage;
const Session = session_mod.Session;
const Window = window_mod.Window;
const slog = log.Scoped("dialog_knots");

const WINDOW_TITLE = "EVE-Maj Preview Configuration";
/// In logical pixels, like designWidth's; knots has no zoom yet.
const DESIGN_HEIGHT = 990;
const DEFAULT_POSITION: win32.POINT = .{ .x = 20, .y = 20 };
/// On the window itself; clears the footer's status once it has shown long enough.
const STATUS_TIMER_ID = 1;
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
    /// Picker results wait in Pickers.takeAll; no command carries a pointer, since any process can post one.
    picked,
    /// Fetch results wait in Prices.takeAll.
    prices_fetched,
    /// Load results wait in Portraits.takeAll.
    portrait_loaded,
    /// Another language was picked: the window takes its width and title.
    fit_language,
    /// The update check started as the window opened has finished; the frame it draws shows what it found.
    update_checked,
};

/// What the configuration window keeps for the app's whole run, open or not.
pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: Session,
    /// Its threads can outlive the window that started them.
    pickers: pickers_mod.Pickers,
    /// Its thread can outlive the window that started it.
    prices: prices_mod.Prices,
    /// Kept for the app's run, so a reopened window shows them at once.
    portraits: portraits_mod.Portraits,
    /// Its overlay can close after the window has.
    region: region_mod.Region,
    kept: window_mod.Kept = .{},
    /// The open window; null while it's closed.
    window: ?*Window = null,
    hwnd: ?win32.HWND = null,
    /// knots' window procedure, which the subclass forwards to.
    knots_proc: isize = 0,
    /// knots' loop swallows WM_QUIT, so an exit while the window is open is posted once it has closed.
    should_quit_after_close: bool = false,
    /// Closes without asking about unsaved changes.
    should_force_close: bool = false,
    is_present_mode_chosen: bool = false,
    /// Where placeWindowHook puts the window knots creates, while App.init runs.
    spawn_position: ?win32.POINT = null,
    requested_page: ?SettingsPage = null,
    spawn_hook: ?win32.HHOOK = null,
    /// The running window, for retitling it; null while it's closed.
    app: ?*knots.App = null,
    /// Trails a newly picked language until fit_language runs.
    window_language: Language = .en,
    /// A fit_language command is on its way, so another isn't posted each frame until it runs.
    is_fit_posted: bool = false,

    /// The page openAt asked for since the last call, for form to show.
    pub fn takeRequestedPage(self: *Host) ?SettingsPage {
        defer self.requested_page = null;
        return self.requested_page;
    }

    /// The footer's Close: asks about unsaved changes like the title bar's close button.
    pub fn requestClose(self: *const Host) void {
        const window = self.hwnd orelse return;
        if (!win32.toBool(win32.PostMessageA(window, win32.WM_CLOSE, 0, 0))) {
            slog.warn("Failed to close the knots configuration window: error {d}", .{win32.GetLastError()});
        }
    }

    pub fn postCommand(self: *const Host, command: Command) void {
        const timer_hwnd = self.session.timerWindow() orelse {
            slog.err("Failed to run a knots configuration window command: the timer window is missing", .{});
            return;
        };
        if (!win32.toBool(win32.PostMessageA(timer_hwnd, messages.WM_KNOTS_COMMAND, @backingInt(command), 0))) {
            slog.err("Failed to run a knots configuration window command: error {d}", .{win32.GetLastError()});
        }
    }

    /// Runs the profile action profiles.zig queued, between frames.
    pub fn scheduleProfileAction(self: *const Host) void {
        self.postCommand(.profile_action);
    }

    /// Before each frame: text follows the picked language at once; width and title follow between frames.
    pub fn useLanguage(self: *Host, language: Language) void {
        lang.use(language);
        if (language == self.window_language or self.is_fit_posted) return;
        self.is_fit_posted = true;
        self.postCommand(.fit_language);
    }

    /// Applied at once, though the setting itself waits for Save like any other.
    pub fn setAlwaysOnTop(self: *const Host, is_enabled: bool) void {
        const window = self.hwnd orelse return;
        const insert_after = if (is_enabled) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST;
        _ = win32.SetWindowPos(window, insert_after, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    }

    /// The picker owns its own modal loop on another thread; the result arrives as a `picked` command.
    pub fn browseFolder(self: *Host, target: pickers_mod.Target, title: []const u8) void {
        const timer_hwnd = self.session.timerWindow() orelse {
            slog.err("Failed to open the folder picker: the timer window is missing", .{});
            return;
        };
        self.pickers.browse(target, 0, title, self.hwnd, timer_hwnd, @backingInt(Command.picked));
    }

    /// A settings file for the Import dialog, read once the picker closes.
    pub fn browseImportFile(self: *Host) void {
        const timer_hwnd = self.session.timerWindow() orelse {
            slog.err("Failed to open the import file picker: the timer window is missing", .{});
            return;
        };
        self.pickers.browse(.import_file, 0, "Select Settings File", self.hwnd, timer_hwnd, @backingInt(Command.picked));
    }

    /// A notification type's or chat alert rule's custom sound, set once the picker closes; `index` is whichever `target` names.
    pub fn browseSoundFile(self: *Host, target: pickers_mod.Target, index: usize) void {
        const timer_hwnd = self.session.timerWindow() orelse {
            slog.err("Failed to open the sound file picker: the timer window is missing", .{});
            return;
        };
        self.pickers.browse(target, index, "Select Sound File", self.hwnd, timer_hwnd, @backingInt(Command.picked));
    }

    /// Starts fetching Jita ore prices; returns false if a fetch is already running or couldn't start.
    pub fn fetchPrices(self: *Host) bool {
        const timer_hwnd = self.session.timerWindow() orelse {
            slog.err("Failed to fetch ore prices: the timer window is missing", .{});
            return false;
        };
        return self.prices.fetch(self.io, timer_hwnd, @backingInt(Command.prices_fetched));
    }

    /// Lets the user draw space `space_id` on screen; see Region.start.
    pub fn startRegionSelect(self: *Host, space_id: u32, is_editing: bool) void {
        const window = self.window orelse return;
        self.region.start(&self.session, &window.status, space_id, is_editing, onRegionFinished, onRegionSelected);
    }

    /// The header's name prompt names the restored profile; `backup` is copied.
    pub fn restoreBackup(self: *const Host, backup: []const u8, display_name: []const u8) void {
        const window = self.window orelse return;
        header.openRestorePrompt(window, backup, display_name);
    }

    /// `name` as typed; the profile is created and switched to between frames, then the import applied to it.
    pub fn importIntoNewProfile(self: *const Host, name: []const u8, accent: u32) void {
        const window = self.window orelse return;
        const file_name = config.profileFileName(self.allocator, name) catch |err| {
            slog.info("Rejected imported profile name '{s}': {}", .{ name, err });
            window.status.show(.failure, "'{name}' isn't a valid profile name: use " ++ profiles.NAME_RULES, .{ .name = name });
            return;
        };
        defer self.allocator.free(file_name);
        profiles.request(window, .import_new, file_name, accent);
    }

    /// Draws a frame soon, for a change made outside one, e.g. a region selection finishing.
    pub fn redraw(self: *const Host) void {
        const window = self.hwnd orelse return;
        _ = win32.InvalidateRect(window, null, win32.FALSE);
    }

    /// Refused with error.ConflictingHotkeys, which the status line explains, while hotkeys conflict; between frames only.
    pub fn saveChanges(self: *Host) !void {
        try self.refuseConflictingHotkeys();
        try self.session.save();
    }

    /// Drops unsaved changes to both documents; between frames only.
    pub fn discardChanges(self: *Host) !void {
        try self.session.discard();
        self.setAlwaysOnTop(self.session.appContext().global_settings.alwaysOnTop);
    }

    fn open(self: *Host) void {
        if (self.window != null) {
            self.focus();
            return;
        }
        self.postCommand(.open);
    }

    fn onCommand(self: *Host, command: Command) void {
        switch (command) {
            .open => self.run(),
            .save => _ = self.save(),
            .discard => _ = self.discard(),
            .save_and_close => if (self.save()) self.closeWithoutAsking(),
            .discard_and_close => if (self.discard()) self.closeWithoutAsking(),
            .profile_action => if (self.window) |window| profiles.runPending(window),
            .picked => self.applyPicked(),
            .prices_fetched => self.applyPrices(),
            .portrait_loaded => self.applyPortraits(),
            .fit_language => self.fitLanguage(),
            .update_checked => {},
        }
        self.redraw();
    }

    /// Returns whether the exit waits for the window to close, which then posts the quit itself.
    fn closeForExit(self: *Host) bool {
        if (self.window == null) return false;
        self.should_quit_after_close = true;
        self.closeWithoutAsking();
        return true;
    }

    /// Pumps every message on the main thread until the window closes, so the tick, hooks and tray keep running.
    fn run(self: *Host) void {
        if (self.window != null) {
            self.focus();
            return;
        }
        self.session.begin() catch |err| {
            slog.err("Failed to start editing the configuration: {}", .{err});
            return;
        };
        defer self.session.end();
        if (!self.session.global().get("disableUpdateChecks")) self.startUpdateCheck();

        var reopen_count: u32 = 0;
        while (true) : (reopen_count += 1) {
            self.runWindow(reopen_count > 0) catch |err| {
                slog.err("Failed to run the knots configuration window: {}", .{err});
                if (self.shouldReopen(reopen_count)) continue;
            };
            break;
        }
        if (self.should_quit_after_close) {
            self.should_quit_after_close = false;
            win32.PostQuitMessage(0);
        }
    }

    /// After a failed window, unless the app is exiting; the session's edits outlive it, so a reopened one carries on with them.
    fn shouldReopen(self: *Host, reopen_count: u32) bool {
        if (self.should_quit_after_close) return false;
        if (reopen_count < MAX_REOPENS) {
            slog.info("Reopening the knots configuration window after its error", .{});
            return true;
        }
        const message = if (self.session.isDirty())
            "The configuration window closed after repeated errors, and its unsaved changes were lost. The log has the details."
        else
            "The configuration window closed after repeated errors. The log has the details.";
        _ = win32.MessageBoxA(null, message, "EVE-Maj Preview", win32.MB_OK | win32.MB_ICONERROR);
        return false;
    }

    /// One window over the open session, until it closes or a frame fails.
    fn runWindow(self: *Host, is_reopened: bool) !void {
        const settings = self.session.appContext().global_settings;
        const position = savedPosition(settings);
        self.window_language = settings.language;
        self.is_fit_posted = false;

        var window: Window = undefined;
        window.init(self, requestFrame);
        defer window.deinit();
        keyboard_hook.g_on_win_key = onWinKey;
        defer keyboard_hook.g_on_win_key = null;
        defer self.region.cancel();
        self.portraits.begin(self.session.timerWindow(), @backingInt(Command.portrait_loaded));
        for (self.session.profile().ptr.characters.items) |character| self.portraits.preload(character.name);
        // A language picked but not saved goes with the window.
        defer lang.use(self.session.appContext().global_settings.language);
        profiles.refresh(&window);
        if (is_reopened) window.status.show(.failure, REOPENED_NOTICE, .{});

        // knots shows its window as it's created, so it's placed then rather than moved after.
        const is_placed = self.installPlacement(position);
        var running: Running = .{
            .window = &window,
            .app = knots.App.init(self.io, self.allocator, .{
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
                self.removePlacement();
                slog.err("Failed to create the knots configuration window: {}", .{err});
                _ = win32.MessageBoxA(null, "The configuration window couldn't start. It needs a graphics driver with Vulkan 1.3 support; updating the graphics driver usually fixes this.", "EVE-Maj Preview", win32.MB_OK | win32.MB_ICONERROR);
                return;
            },
        };
        defer running.app.deinit();
        self.removePlacement();
        self.app = &running.app;

        const hwnd: win32.HWND = @ptrCast(running.app.main_viewport.window.getWindowHandle().windows.hwnd);
        self.hwnd = hwnd;
        self.window = &window;
        self.is_present_mode_chosen = false;
        defer self.onClosed();
        self.knots_proc = win32.SetWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&windowProc)));
        if (self.knots_proc == 0) slog.err("Failed to subclass the configuration window, so it won't ask about unsaved changes on close or remember its position: error {d}", .{win32.GetLastError()});
        setIcon(hwnd);
        styleTitleBar(hwnd);
        if (!is_placed) _ = win32.SetWindowPos(hwnd, win32.HWND_NOTOPMOST, position.x, position.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        if (settings.alwaysOnTop) self.setAlwaysOnTop(true);
        _ = win32.SetForegroundWindow(hwnd);

        slog.info("Knots configuration window opened", .{});
        try running.app.start(frame);
    }

    /// Makes the next top-level window this thread creates start at `position`; false if it couldn't.
    fn installPlacement(self: *Host, position: win32.POINT) bool {
        self.spawn_position = position;
        self.spawn_hook = win32.SetWindowsHookExA(win32.WH_CBT, placeWindowHook, null, win32.GetCurrentThreadId()) orelse {
            slog.warn("Failed to place the configuration window as it opens, it will move there once shown: error {d}", .{win32.GetLastError()});
            self.spawn_position = null;
            return false;
        };
        return true;
    }

    fn removePlacement(self: *Host) void {
        if (self.spawn_hook) |hook| _ = win32.UnhookWindowsHookEx(hook);
        self.spawn_hook = null;
        self.spawn_position = null;
    }

    /// Restarted by each new message, so it times the latest one.
    fn startStatusTimer(self: *const Host, show_ms: u32) void {
        const window = self.hwnd orelse return;
        if (win32.SetTimer(window, STATUS_TIMER_ID, show_ms, null) == 0) {
            slog.warn("Failed to time the status message, it stays until the next one: error {d}", .{win32.GetLastError()});
        }
    }

    /// Vsync would block the main thread up to a frame, stalling the low-level input hooks.
    fn choosePresentMode(self: *Host, view: *knots.View) void {
        self.is_present_mode_chosen = true;
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

    /// On a thread of its own, so About can show a release found since the app started.
    fn startUpdateCheck(self: *const Host) void {
        const timer_hwnd = self.session.timerWindow() orelse {
            slog.err("Failed to check for updates: the timer window is missing", .{});
            return;
        };
        detached.spawn(checkThenRedraw, .{ self.allocator, self.io, timer_hwnd }) catch |err| {
            slog.warn("Failed to start update check thread: {}", .{err});
        };
    }

    fn applyPrices(self: *Host) void {
        var next = self.prices.takeAll();
        while (next) |fetched| {
            next = fetched.next;
            defer fetched.deinit();
            // The window may have closed while the fetch ran.
            if (self.window) |window| useFetched(window, fetched);
        }
    }

    /// Stored even once the window has closed, since the cache outlives it.
    fn applyPortraits(self: *Host) void {
        var next = self.portraits.takeAll();
        while (next) |loaded| {
            next = loaded.next;
            self.portraits.store(loaded);
        }
    }

    fn applyPicked(self: *Host) void {
        var next = self.pickers.takeAll();
        while (next) |picked| {
            next = picked.next;
            defer picked.deinit();
            // The window may have closed while the picker was open.
            if (self.window) |window| usePicked(window, picked);
        }
    }

    fn save(self: *Host) bool {
        self.saveChanges() catch |err| {
            // Not a failure: the user is told to fix the hotkeys first.
            if (err != error.ConflictingHotkeys) {
                slog.err("Failed to save the configuration: {}", .{err});
                self.showStatus(.failure, "Failed to save: {err}", .{ .err = err });
            }
            return false;
        };
        self.showStatus(.success, "Changes saved", .{});
        return true;
    }

    fn refuseConflictingHotkeys(self: *Host) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const conflicts = try hotkey.findConflicts(&self.session, arena);
        if (conflicts.len == 0) return;
        var keys: std.Io.Writer.Allocating = .init(arena);
        try hotkey.writeCombos(&keys.writer, conflicts);
        slog.info("Refused to save: hotkeys '{s}' are bound more than once", .{keys.written()});
        // Only the first is spelled out, since the status line holds one sentence.
        var first: std.Io.Writer.Allocating = .init(arena);
        try hotkey.writeCombos(&first.writer, conflicts[0..1]);
        var holders: std.Io.Writer.Allocating = .init(arena);
        try hotkey.writeHolders(&self.session, arena, &holders.writer, conflicts[0]);
        if (conflicts.len == 1) {
            self.showStatus(.failure, "Not saved: {key} is used by {holders}", .{ .key = first.written(), .holders = holders.written() });
        } else {
            self.showStatus(.failure, "Not saved: {key} is used by {holders} (+{count} more)", .{
                .key = first.written(),
                .holders = holders.written(),
                .count = conflicts.len - 1,
            });
        }
        return error.ConflictingHotkeys;
    }

    fn discard(self: *Host) bool {
        self.discardChanges() catch |err| {
            slog.err("Failed to discard the configuration changes: {}", .{err});
            return false;
        };
        return true;
    }

    /// On the open window's status line; dropped while it's closed, since the next one opens with a clear line.
    fn showStatus(self: *const Host, kind: status.Kind, english: []const u8, args: anytype) void {
        const window = self.window orelse return;
        window.status.show(kind, english, args);
    }

    fn closeWithoutAsking(self: *Host) void {
        const window = self.hwnd orelse return;
        if (!win32.toBool(win32.PostMessageA(window, win32.WM_CLOSE, 0, 0))) {
            slog.warn("Failed to close the knots configuration window: error {d}", .{win32.GetLastError()});
            return;
        }
        self.should_force_close = true;
    }

    fn onClosed(self: *Host) void {
        slog.info("Knots configuration window closed", .{});
        self.hwnd = null;
        self.app = null;
        self.window = null;
        self.should_force_close = false;
    }

    /// Between frames, since resizing and retitling send knots' window messages it can't take mid-frame.
    fn fitLanguage(self: *Host) void {
        self.is_fit_posted = false;
        const window = self.hwnd orelse return;
        const language = self.session.global().get("language");
        if (language == self.window_language) return;
        resizeForLanguage(window, self.window_language, language);
        self.window_language = language;
        const app = self.app orelse return;
        app.main_viewport.window.setTitle(lang.text(WINDOW_TITLE)) catch |err| {
            slog.warn("Failed to retitle the configuration window: {}", .{err});
        };
    }

    fn focus(self: *const Host) void {
        const window = self.hwnd orelse return;
        if (win32.toBool(win32.IsIconic(window))) _ = win32.ShowWindow(window, win32.SW_RESTORE);
        _ = win32.SetForegroundWindow(window);
    }

    fn savePosition(self: *const Host, window: win32.HWND) void {
        var rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetWindowRect(window, &rect))) {
            slog.warn("Failed to read the configuration window's position: error {d}", .{win32.GetLastError()});
            return;
        }
        self.session.appContext().global_settings.saveDialogPosition(self.io, rect.left, rect.top) catch |err| {
            slog.warn("Failed to save the configuration window's position: {}", .{err});
        };
    }
};

/// knots keeps a pointer to `app`, which frame turns back into the window it draws.
const Running = struct {
    app: knots.App,
    window: *Window,
};

/// Set by init; Win32 procedures, the tray, the protocol handler and App's hooks reach the window through it.
var g_host: ?Host = null;

/// At startup; returns what App asks of the window.
pub fn init(app_context: dialog_host.Context, app_host: dialog_host.Host) dialog_host.DialogHooks {
    g_host = .{
        .allocator = app_context.allocator,
        .io = app_context.io,
        .session = .init(app_context, app_host),
        .pickers = .init(app_context.allocator),
        .prices = .init(app_context.allocator),
        .portraits = .init(app_context),
        .region = .init(app_context.allocator),
    };
    return .{ .redraw = requestFrame, .is_open = isOpen, .close_for_exit = closeForExit, .live_global = liveGlobal, .open_at = openAt };
}

/// At app exit; the Host stays in place, since a picker's or a load's thread may still reach it.
pub fn deinit() void {
    const host = hostPtr() orelse return;
    host.portraits.deinit();
}

pub fn isOpen() bool {
    const host = hostPtr() orelse return false;
    return host.window != null;
}

pub fn open() void {
    const host = hostPtr() orelse return;
    host.open();
}

/// Main thread, from the timer window's procedure.
pub fn onCommand(wParam: win32.WPARAM) void {
    const command = std.enums.fromInt(Command, wParam) orelse {
        slog.warn("Failed to run a knots configuration window command: unknown command {d}", .{wParam});
        return;
    };
    const host = hostPtr() orelse return;
    host.onCommand(command);
}

/// Null before init.
fn hostPtr() ?*Host {
    return if (g_host) |*host| host else null;
}

/// Opens the window, or brings it forward, on `page`'s tab.
fn openAt(page: SettingsPage) void {
    const host = hostPtr() orelse return;
    host.requested_page = page;
    host.open();
}

/// Returns whether the exit waits for the window to close, which then posts the quit itself.
fn closeForExit() bool {
    const host = hostPtr() orelse return false;
    return host.closeForExit();
}

/// Only reached through the hooks init returns, so g_host is set.
fn liveGlobal() *const GlobalConfig {
    const host = hostPtr() orelse unreachable;
    return host.session.liveGlobal();
}

fn requestFrame() void {
    const host = hostPtr() orelse return;
    host.redraw();
}

/// Windows hands a bare Win press to the Start Menu first, so the keyboard hook reports it.
fn onWinKey(modifiers: u32) void {
    const host = hostPtr() orelse return;
    const window = host.window orelse return;
    window.hotkey.onWinKey(modifiers);
}

/// From the region overlay once it closes.
fn onRegionFinished() void {
    const host = hostPtr() orelse return;
    host.region.finish(&host.session);
}

/// From the region overlay once it closes; the selection was cancelled if the window closed first.
fn onRegionSelected(result: region_select.Status, selected: win32.RECT) void {
    const host = hostPtr() orelse return;
    const window = host.window orelse return;
    if (host.region.select(&host.session, &window.status, result, selected)) host.redraw();
}

/// Places the first top-level window created while installed, which is knots' own, then stands aside.
fn placeWindowHook(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    const host = hostPtr() orelse return win32.CallNextHookEx(null, nCode, wParam, lParam);
    if (nCode == win32.HCBT_CREATEWND) {
        if (host.spawn_position) |position| {
            const create: *win32.CBT_CREATEWND = win32.lparamToPtr(win32.CBT_CREATEWND, lParam);
            if (create.lpcs.hwndParent == null) {
                create.lpcs.x = position.x;
                create.lpcs.y = position.y;
                host.spawn_position = null;
            }
        }
    }
    return win32.CallNextHookEx(host.spawn_hook, nCode, wParam, lParam);
}

fn frame(view: *knots.View, context: *ui.Frame) !void {
    const running: *Running = @fieldParentPtr("app", view.app);
    const window = running.window;
    const host = window.host;
    if (!host.is_present_mode_chosen) host.choosePresentMode(view);
    try form.frame(window, context);
    if (window.status.takeShownMs()) |show_ms| host.startStatusTimer(show_ms);
}

/// Subclasses knots' window to prompt on unsaved close, remember its position and clear the status line.
fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // runWindow installs it, so there's always a host; without one there's no knots procedure to forward to either.
    const host = hostPtr() orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
    if (host.window) |window| {
        // A hotkey field recording takes the keys and buttons it binds before knots sees them.
        if (window.hotkey.onWindowMessage(msg, wParam, lParam)) return 0;
        switch (msg) {
            win32.WM_CLOSE => if (!host.should_force_close and host.session.isDirty()) {
                form.confirmClose(window);
                host.redraw();
                return 0;
            },
            win32.WM_TIMER => switch (wParam) {
                STATUS_TIMER_ID => {
                    _ = win32.KillTimer(hwnd, STATUS_TIMER_ID);
                    window.status.clear();
                    host.redraw();
                    return 0;
                },
                else => {},
            },
            else => {},
        }
    }
    if (msg == win32.WM_EXITSIZEMOVE) host.savePosition(hwnd);
    return win32.CallWindowProcW(host.knots_proc, hwnd, msg, wParam, lParam);
}

/// Update check thread only.
fn checkThenRedraw(allocator: std.mem.Allocator, io: std.Io, timer_hwnd: win32.HWND) void {
    update.checkForUpdatesBackground(allocator, io);
    if (!win32.toBool(win32.PostMessageA(timer_hwnd, messages.WM_KNOTS_COMMAND, @backingInt(Command.update_checked), 0))) {
        slog.warn("Failed to show the update check's result: error {d}", .{win32.GetLastError()});
    }
}

/// Fetched prices fill in the table, kept until Save.
fn useFetched(window: *Window, fetched: *const prices_mod.Fetched) void {
    if (fetched.has_failed) {
        window.status.show(.failure, "Failed to fetch prices from ESI.", .{});
        return;
    }
    for (fetched.prices) |price| mining.setOrePrice(window, price.name, price.price);
    if (fetched.prices.len > 0) mining.stampPricesFetched(window);
    window.status.show(if (fetched.prices.len > 0) .success else .failure, "Updated {fetched} of {total} price(s)", .{ .fetched = fetched.prices.len, .total = prices_mod.NAMES.len });
}

fn usePicked(window: *Window, picked: *const pickers_mod.Picked) void {
    const chatlog = window.session.global().child("chatlog");
    switch (picked.target) {
        .chatlog_dir => chatlog.set("chatlogDir", picked.path),
        .gamelog_dir => chatlog.set("gamelogDir", picked.path),
        .import_file => import_dialog.loadFile(window, picked.path),
        .sound_file => useSound(event_alerts.typeRef(window, picked.index), picked.path),
        // The rule may have been removed while the picker was open.
        .rule_sound_file => if (picked.index < window.session.profile().ptr.chatAlerts.items.len) {
            useSound(window.session.profile().item("chatAlerts", picked.index).child("alert"), picked.path);
        },
    }
}

/// Picking a file means the sound is wanted.
fn useSound(alert: session_mod.Ref(config.NotificationTypeConfig), path: []const u8) void {
    alert.set("sound_path", path);
    alert.set("sound_enabled", true);
}

/// Wider for languages with longer labels than English's.
fn designWidth(language: Language) u32 {
    return switch (language) {
        .en => 810,
        .es, .pt => 820,
        .de, .fr, .pl, .ru => 870,
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

/// DEFAULT_POSITION when the saved spot is on no monitor, e.g. an unplugged screen.
fn savedPosition(settings: *const GlobalConfig) win32.POINT {
    const x = settings.dialogX orelse return DEFAULT_POSITION;
    const y = settings.dialogY orelse return DEFAULT_POSITION;
    const position: win32.POINT = .{ .x = x, .y = y };
    if (win32.isOnMonitor(position)) return position;
    slog.warn("Saved configuration window position ({d}, {d}) is off-screen, using the default", .{ x, y });
    return DEFAULT_POSITION;
}
