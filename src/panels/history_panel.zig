//! The History Panel: a draggable list of recent notifications, with category filter chips.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const list_look = @import("list_look.zig");
const notification = @import("../notifications/notification.zig");
const history_mod = @import("../notifications/history.zig");
const history_look = @import("history_look.zig");
const history_rows = @import("history_rows.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_header = @import("panel_header.zig");
const panel_look = @import("panel_look.zig");
const header_panel = @import("header_panel.zig");
const panel_host = @import("panel_host.zig");
const panel_lifecycle = @import("panel_lifecycle.zig");
const panel_menu = @import("panel_menu.zig");
const panel_menu_look = @import("panel_menu_look.zig");
const palette = @import("palette.zig");
const box = @import("../util/box.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const log = @import("../log.zig");

const PanelWindow = panel_window.PanelWindow;
const slog = log.Scoped("history_panel");

const HISTORY_PANEL_WINDOW_CLASS = "EVE_HISTORY_PANEL_CLASS";
const HEADER_ACTIONS = [_]panel_header.Action{ .clear, .pin, .menu };

const Class = header_panel.HeaderPanel(HistoryPanelWindow, HISTORY_PANEL_WINDOW_CLASS);

/// What the History Panel's window borrows from App.
pub const Links = struct {
    host: panel_host.Host,
    /// The history it lists and clears; outlives the panel.
    history: *history_mod.NotificationHistory,
};

/// Owns the History Panel window and when it's on-screen: historyPanel.show creates it, its auto-hide settings hide it, and the tray toggle can force it visible.
pub const HistoryPanel = struct {
    window: ?HistoryPanelWindow = null,
    visibility: panel_look.Visibility = .{},
    /// Null until start.
    links: ?Links = null,

    /// Creates the window if the context's profile shows it; in place, as the window is linked to where it's stored.
    pub fn start(self: *HistoryPanel, context: panel_host.Context, links: Links) void {
        self.links = links;
        panel_lifecycle.sync(self, context);
    }

    pub fn deinit(self: *HistoryPanel) void {
        self.destroyWindow();
    }

    /// Accounts for the panel's auto-hide settings and the tray-toggle override.
    pub fn isVisible(self: *const HistoryPanel, config: *const config_mod.Config, any_character_logged_in: bool) bool {
        // The menu's Hide turns show off before the window is torn down.
        return self.window != null and config.historyPanel.show and self.visibility.allowsFor(&config.historyPanel, any_character_logged_in, win32.Ticks.now().ms);
    }

    /// Keyed on isVisible(), not the window: a visible panel turns off, and a hidden one is forced on even with no character logged in.
    pub fn toggle(self: *HistoryPanel, context: panel_host.Context, any_character_logged_in: bool) void {
        panel_lifecycle.toggle(self, context, self.isVisible(&context.store.live, any_character_logged_in));
    }

    /// Matches the window to historyPanel.show and its configured position, for a change made in the config dialog rather than by `toggle`.
    pub fn sync(self: *HistoryPanel, context: panel_host.Context) void {
        panel_lifecycle.sync(self, context);
        const history_settings = &context.store.live.historyPanel;
        if (self.window) |*window| window.panel.followPosition(history_settings.x, history_settings.y);
    }

    /// For panel_lifecycle.
    pub fn wantsWindow(_: *const HistoryPanel, config: *const config_mod.Config) bool {
        return config.historyPanel.show;
    }

    /// For panel_lifecycle.
    pub fn setShown(_: *const HistoryPanel, store: *config_mod.ProfileStore, is_shown: bool) void {
        store.update(.{ .historyPanel = .{ .show = is_shown } });
    }

    /// Per-tick: renders the panel from `notifications`, or hides it.
    pub fn update(self: *HistoryPanel, notifications: *const history_mod.NotificationHistory, config: *const config_mod.Config, presence: panel_look.Presence) void {
        self.visibility.note(presence, win32.Ticks.now().ms);

        const window = if (self.window) |*w| w else return;
        if (self.isVisible(config, presence.any_character_logged_in)) {
            window.render(notifications) catch |err| {
                slog.err("Failed to render History Panel window: {}", .{err});
            };
        } else {
            window.hide();
        }
    }

    /// For panel_lifecycle.
    pub fn createWindow(self: *HistoryPanel, context: panel_host.Context) void {
        const links = self.links orelse {
            slog.err("Failed to create History Panel window: the panel wasn't started", .{});
            return;
        };
        panel_lifecycle.install(HistoryPanelWindow, &self.window, HistoryPanelWindow.init(context, links), null, "History Panel");
    }

    /// For panel_lifecycle.
    pub fn destroyWindow(self: *HistoryPanel) void {
        if (self.window) |*window| window.deinit();
        self.window = null;
    }
};

pub const HistoryPanelWindow = struct {
    panel: PanelWindow,
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the window.
    config: *const config_mod.Config,
    host: panel_host.Host,
    instance: win32.HINSTANCE,
    /// Borrowed; outlives the window.
    history: *history_mod.NotificationHistory,
    rows: [history_mod.CAPACITY]history_rows.Row = undefined,
    row_count: usize = 0,
    /// Each row's oldest entry's timestamp in ms, which newer repeats joining the row don't change.
    row_keys: [history_mod.CAPACITY]u64 = undefined,
    /// Each drawn row's top and bottom from the last render, for clicks.
    row_spans: [history_mod.CAPACITY][2]i32 = undefined,
    /// How many rows fitted at the last render.
    drawn_count: usize = 0,
    /// From the last render, for clicks; null while the chips aren't drawn.
    chip_layout: ?history_look.ChipLayout = null,
    /// Entries pushed after this, in ms since boot, are new; it moves on when the cursor leaves the panel.
    seen_ms: u64,
    /// The expanded merged row's key from row_keys.
    expanded_key: ?u64 = null,
    hovered_row: ?usize = null,
    /// The configured font in bold, for each row's name.
    bold_font: gdi_overlay.CachedFont = .{},
    header_fonts: panel_chrome.HeaderFonts = .{},
    header_input: header_panel.HeaderInput = .{},
    menu: panel_menu.PanelMenu = .{},

    pub fn init(context: panel_host.Context, links: Links) !HistoryPanelWindow {
        const history_settings = &context.store.live.historyPanel;
        try Class.register(context.instance);
        const panel = try PanelWindow.init(context.allocator, context.instance, HISTORY_PANEL_WINDOW_CLASS, "EVE Alert History", panel_lifecycle.windowRect(history_settings), history_settings.alwaysOnTop);
        return .{ .panel = panel, .store = context.store, .config = &context.store.live, .host = links.host, .instance = context.instance, .history = links.history, .seen_ms = win32.Ticks.now().ms };
    }

    pub fn deinit(self: *HistoryPanelWindow) void {
        self.menu.deinit(self.panel.allocator);
        self.header_fonts.deinit(self.panel.allocator);
        self.bold_font.deinit(self.panel.allocator);
        self.panel.deinit();
    }

    pub fn hide(self: *HistoryPanelWindow) void {
        self.menu.close();
        self.panel.hide();
    }

    pub fn headerLayout(self: *const HistoryPanelWindow) panel_header.Layout {
        return .init(@max(1, self.config.historyPanel.width), &HEADER_ACTIONS);
    }

    pub fn toggleCollapsed(self: *HistoryPanelWindow) void {
        self.store.update(.{ .historyPanel = .{ .collapsed = !self.config.historyPanel.collapsed } });
        self.redraw();
    }

    pub fn runHeaderAction(self: *HistoryPanelWindow, action: panel_header.Action) void {
        switch (action) {
            .pin => self.store.update(.{ .historyPanel = .{ .alwaysOnTop = !self.config.historyPanel.alwaysOnTop } }),
            .menu => self.menu.toggle(self.panel.allocator, self.instance, panel_menu.ownerFor(HistoryPanelWindow, self), self.menuButton() orelse return),
            .mute => {},
            .clear => {
                self.history.clear();
                self.markSeen();
            },
        }
        self.redraw();
        self.menu.refresh();
    }

    /// The ⋯ button in screen pixels.
    fn menuButton(self: *const HistoryPanelWindow) ?box.Box {
        const button = self.headerLayout().boxOf(.{ .button = .menu }) orelse return null;
        return panel_menu.screenBox(&self.panel, button);
    }

    pub fn menuContents(self: *const HistoryPanelWindow) panel_menu_look.Contents {
        const history_settings = &self.config.historyPanel;
        return .{
            .is_on_top = history_settings.alwaysOnTop,
            .is_locked = history_settings.lockPosition,
            .opacity = history_settings.opacity,
            .settings_label = "Alert History Settings\u{2026}",
            .can_hide = true,
            .accent = self.config.accentColor,
        };
    }

    pub fn runMenuAction(self: *HistoryPanelWindow, action: panel_menu_look.Action) void {
        const history_settings = &self.config.historyPanel;
        switch (action) {
            .toggle => |toggle| switch (toggle) {
                .keep_on_top => self.store.update(.{ .historyPanel = .{ .alwaysOnTop = !history_settings.alwaysOnTop } }),
                .lock_position => self.store.update(.{ .historyPanel = .{ .lockPosition = !history_settings.lockPosition } }),
                .group_by_system => {},
            },
            .order => {},
            .opacity => |opacity| if (opacity.is_final) self.store.update(.{ .historyPanel = .{ .opacity = opacity.value } }) else self.store.preview(.{ .historyPanel = .{ .opacity = opacity.value } }),
            .command => |command| switch (command) {
                .settings => self.host.run(.{ .open_settings = .history_panel }),
                .hide => {
                    self.store.update(.{ .historyPanel = .{ .show = false } });
                    self.hide();
                    return;
                },
            },
        }
        self.redraw();
    }

    pub fn isPositionLocked(self: *const HistoryPanelWindow) bool {
        return self.config.historyPanel.lockPosition;
    }

    /// Now, for input that changed what the panel shows, rather than on the next tick.
    pub fn redraw(self: *HistoryPanelWindow) void {
        self.render(self.history) catch |err| {
            slog.err("Failed to redraw History Panel window: {}", .{err});
        };
    }

    pub fn saveWindowPosition(self: *const HistoryPanelWindow) void {
        if (!self.config.historyPanel.rememberPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .historyPanel = .{ .x = top_left.x, .y = top_left.y } });
    }

    /// A chip filters its category; a merged row expands or folds, and any other row goes to its client.
    pub fn onLeftClick(self: *HistoryPanelWindow, x: i32, y: i32) void {
        if (self.config.historyPanel.collapsed) return;
        if (self.chip_layout) |layout| {
            if (layout.categoryAt(x, y)) |category| {
                setCategoryEnabled(self.store, category, !history_look.isCategoryEnabled(&self.config.historyPanel, category));
                return;
            }
        }
        const row_index = self.rowAt(y) orelse return;
        const history_row = self.rows[row_index];
        if (history_row.count == 1) {
            self.host.run(.{ .activate = history_row.hwnd });
            return;
        }
        const key = self.row_keys[row_index];
        self.expanded_key = if (self.expanded_key == key) null else key;
        self.redraw();
    }

    /// Null for a message left to Windows.
    pub fn handleMessage(self: *HistoryPanelWindow, hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) ?win32.LRESULT {
        _ = hwnd;
        _ = wParam;
        switch (msg) {
            win32.WM_MOUSEMOVE => {
                const row_index = self.rowAt(win32.lparamY(lParam));
                if (row_index == self.hovered_row) return null;
                self.hovered_row = row_index;
                self.redraw();
            },
            win32.WM_MOUSELEAVE => {
                self.hovered_row = null;
                self.markSeen();
                self.redraw();
            },
            else => {},
        }
        return null;
    }

    /// Every row so far stops being new.
    fn markSeen(self: *HistoryPanelWindow) void {
        self.seen_ms = win32.Ticks.now().ms;
    }

    fn isNew(self: *const HistoryPanelWindow, entries: []const history_mod.Entry, row: history_rows.Row) bool {
        return entries[row.first_index].timestamp.ms > self.seen_ms;
    }

    /// From the last render.
    fn rowAt(self: *const HistoryPanelWindow, y: i32) ?usize {
        for (self.row_spans[0..self.drawn_count], 0..) |span, index| {
            if (y >= span[0] and y < span[1]) return index;
        }
        return null;
    }

    fn header(self: *const HistoryPanelWindow) panel_chrome.Header {
        const history_settings = &self.config.historyPanel;
        return .{ .layout = self.headerLayout(), .title = history_look.HEADER_TEXT, .is_collapsed = history_settings.collapsed, .hovered = self.header_input.hovered, .lit = .init(.{ .pin = history_settings.alwaysOnTop }), .accent = self.config.accentColor };
    }

    fn computeRenderSignature(self: *const HistoryPanelWindow, entries: []const history_mod.Entry, revision: u32, panel_header_state: *const panel_chrome.Header) u64 {
        const history_settings = &self.config.historyPanel;
        var hasher = std.hash.Wyhash.init(0);
        panel_chrome.hashHeader(&hasher, panel_header_state);
        hasher.update(std.mem.asBytes(&history_settings.width));
        hasher.update(std.mem.asBytes(&history_settings.height));
        hasher.update(std.mem.asBytes(&history_settings.opacity));
        panel_chrome.hashFonts(&hasher, history_settings);
        hasher.update(std.mem.asBytes(&history_settings.maxRows));
        hasher.update(std.mem.asBytes(&history_settings.showTimestamp));
        hasher.update(std.mem.asBytes(&history_settings.showCategoryFilters));
        hasher.update(std.mem.asBytes(&history_settings.mergeEnabled));
        hasher.update(std.mem.asBytes(&history_settings.mergeWindowSec));
        for (history_look.CATEGORY_ORDER) |category| {
            const is_enabled = history_look.isCategoryEnabled(history_settings, category);
            hasher.update(std.mem.asBytes(&is_enabled));
        }
        hasher.update(std.mem.asBytes(&revision));
        hasher.update(std.mem.asBytes(&self.seen_ms));
        const expanded_key = self.expanded_key orelse 0;
        hasher.update(std.mem.asBytes(&expanded_key));
        const hovered_row = self.hovered_row orelse std.math.maxInt(usize);
        hasher.update(std.mem.asBytes(&hovered_row));
        history_rows.hashEntries(&hasher, entries, &self.config.thumbnail.notifications, history_settings.showTimestamp);
        return hasher.final();
    }

    /// Called every tick; redraws only when the render signature changed.
    pub fn render(self: *HistoryPanelWindow, notifications: *const history_mod.NotificationHistory) !void {
        const history_settings = &self.config.historyPanel;
        self.panel.followTopmost(history_settings.alwaysOnTop);
        try panel_chrome.ensureFonts(&self.panel, history_settings);
        try self.bold_font.ensure(self.panel.allocator, "History Panel name", history_settings.fontName, history_settings.fontSize, history_settings.fontWeight.bolded());
        try self.header_fonts.ensure(self.panel.allocator);

        var entry_buf: [history_mod.CAPACITY]history_mod.Entry = undefined;
        const entries = notifications.snapshot(&entry_buf);
        self.row_count = history_rows.build(&self.rows, entries, @intCast(@max(1, history_settings.maxRows)), history_rows.buildOptions(history_settings, history_settings));
        for (self.rows[0..self.row_count], self.row_keys[0..self.row_count]) |row, *key| key.* = entries[row.last_index].timestamp.ms;
        const panel_header_state = self.header();
        const signature = self.computeRenderSignature(entries, notifications.revision, &panel_header_state);
        if (self.panel.isUnchanged(signature)) return;

        const is_collapsed = history_settings.collapsed;
        const panel_width: i32 = @max(1, history_settings.width);
        const panel_height = panel_header.panelHeight(is_collapsed, history_settings.height);
        const bitmap = try self.panel.beginFrame(panel_width, panel_height);
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        panel_chrome.fillBody(canvas);
        panel_chrome.fillHeader(canvas, &panel_header_state);

        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        const summary_left = panel_chrome.drawHeaderText(dc, &self.header_fonts, &panel_header_state);
        self.chip_layout = null;
        self.drawn_count = 0;
        if (is_collapsed) {
            self.drawSummary(canvas, dc, entries, summary_left, panel_header_state.layout.content_right);
        } else {
            var rows_top: i32 = panel_header.HEIGHT;
            if (history_settings.showCategoryFilters) {
                self.chip_layout = self.drawChips(canvas, dc, entries, panel_width);
                if (self.chip_layout) |layout| rows_top = layout.bottom;
            }
            self.drawRows(canvas, dc, entries, rows_top, panel_width, panel_height);
        }

        panel_chrome.finish(canvas);
        self.panel.present(history_settings.opacity, signature);
    }

    /// The newest row, after the title of a collapsed panel.
    fn drawSummary(self: *const HistoryPanelWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, entries: []const history_mod.Entry, left: i32, right: i32) void {
        if (self.row_count == 0) return;
        const row = self.rows[0];
        const entry = &entries[row.first_index];
        var count_buf: [history_look.COUNT_TEXT_MAX]u8 = undefined;
        var time_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        const runs = [_]panel_chrome.Run{
            .{ .text = if (row.count > 1) history_look.mergedText(&count_buf, row.count) else entry.characterName(), .color = palette.TEXT_SECONDARY },
            .{ .text = entry.text(), .color = palette.TEXT_SECONDARY },
            .{ .text = panel_look.relativeTime(&time_buf, win32.Ticks.now().elapsedSince(entry.timestamp)), .color = palette.MUTED },
        };
        panel_chrome.drawSummary(canvas, dc, &self.header_fonts, left, right, &runs);
    }

    /// The category chips under the header, each counting its entries; returns where they sit, or null without the header's font.
    fn drawChips(self: *const HistoryPanelWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, entries: []const history_mod.Entry, panel_width: i32) ?history_look.ChipLayout {
        const font = self.header_fonts.small.handle orelse return null;
        _ = win32.SelectObject(dc, font);
        const text_height = panel_chrome.lineHeight(dc);
        var counts: [history_look.CATEGORY_COUNT]usize = @splat(0);
        for (entries) |*entry| {
            const index = std.mem.findScalar(notification.NotificationCategory, &history_look.CATEGORY_ORDER, notification.notificationCategory(entry.notification_type)) orelse continue;
            counts[index] += 1;
        }
        var count_buffers: [history_look.CATEGORY_COUNT][history_look.COUNT_TEXT_MAX]u8 = undefined;
        var count_texts: [history_look.CATEGORY_COUNT][]const u8 = undefined;
        var widths: [history_look.CATEGORY_COUNT]i32 = undefined;
        for (history_look.CATEGORY_ORDER, counts, &count_buffers, &count_texts, &widths) |category, count, *count_buf, *count_text, *width| {
            count_text.* = std.fmt.bufPrint(count_buf, "{d}", .{count}) catch unreachable;
            width.* = history_look.chipWidth(panel_chrome.textWidth(dc, history_look.categoryLabel(category)), panel_chrome.textWidth(dc, count_text.*));
        }

        const layout = history_look.layOutChips(widths, panel_width, panel_header.HEIGHT);
        for (history_look.CATEGORY_ORDER, layout.boxes, count_texts) |category, chip, count_text| {
            const is_on = history_look.isCategoryEnabled(&self.config.historyPanel, category);
            const fill = if (is_on) palette.PANEL else list_look.PANEL;
            const label_color = if (is_on) palette.TEXT else palette.MUTED;
            const chip_width: usize = @intCast(chip.right - chip.left);
            pixel_buffer.fillRoundedRect(canvas, @intCast(chip.left), @intCast(chip.top), chip_width, @intCast(history_look.CHIP_HEIGHT), history_look.CHIP_RADIUS, if (is_on) palette.BORDER else palette.DIVIDER);
            pixel_buffer.fillRoundedRect(canvas, @intCast(chip.left + 1), @intCast(chip.top + 1), chip_width - 2, @intCast(history_look.CHIP_HEIGHT - 2), history_look.CHIP_RADIUS - 1, fill);
            const dot_x = chip.left + history_look.CHIP_PADDING_X + history_look.CHIP_DOT_RADIUS;
            pixel_buffer.fillCircle(canvas, dot_x, chip.top + @divTrunc(history_look.CHIP_HEIGHT, 2), @floatFromInt(history_look.CHIP_DOT_RADIUS), if (is_on) history_look.categoryColor(category) else palette.BORDER);
            const text_y = chip.top + @divTrunc(history_look.CHIP_HEIGHT - text_height, 2);
            const label_x = dot_x + history_look.CHIP_DOT_RADIUS + history_look.CHIP_TEXT_GAP;
            const label = history_look.categoryLabel(category);
            panel_chrome.drawLine(dc, label, label_x, text_y, label_color);
            panel_chrome.drawLine(dc, count_text, label_x + panel_chrome.textWidth(dc, label) + history_look.CHIP_TEXT_GAP, text_y, history_look.chipCountColor(label_color, fill));
        }
        pixel_buffer.fillRect(canvas, 0, @intCast(layout.bottom - 1), canvas.width, 1, list_look.DIVIDER);
        return layout;
    }

    /// From `top` down, as many as fit, with "Earlier" between the new rows and the rest; records where each landed.
    fn drawRows(self: *HistoryPanelWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, entries: []const history_mod.Entry, top: i32, panel_width: i32, panel_height: i32) void {
        const history_settings = &self.config.historyPanel;
        const text = self.historyText(dc) orelse return;
        const line_height = history_look.metrics(history_settings).row_height;
        const bottom = panel_height - list_look.BOTTOM_PADDING;
        var y = top + history_look.ROWS_PADDING_TOP;
        if (self.row_count == 0) {
            _ = win32.SelectObject(dc, text.message_font);
            panel_chrome.drawLine(dc, if (entries.len == 0) "No alerts yet" else "All alerts filtered", history_look.PADDING_X, y + @divTrunc(line_height - text.name_height, 2), list_look.MUTED);
            return;
        }

        const now = win32.Ticks.now();
        const names_width = panel_width - 2 * history_look.PADDING_X - history_look.TILE_SIZE - history_look.TILE_GAP;
        var follows_new = false;
        for (self.rows[0..self.row_count], self.row_keys[0..self.row_count], 0..) |row, key, index| {
            const is_new = self.isNew(entries, row);
            if (follows_new and !is_new) {
                if (y + history_look.EARLIER_HEIGHT > bottom) return;
                if (self.header_fonts.small.handle) |font| history_rows.drawEarlier(canvas, dc, font, y, panel_width);
                y += history_look.EARLIER_HEIGHT;
            }
            follows_new = is_new;

            var names: history_rows.Names = undefined;
            var place: history_rows.HistoryPlace = .{ .box = undefined, .line_height = line_height, .is_new = is_new, .is_hovered = self.hovered_row == index, .shows_timestamp = history_settings.showTimestamp };
            if (row.count > 1) {
                names = history_rows.mergedNames(entries, row);
                place.names = &names;
                if (self.expanded_key == key) {
                    _ = win32.SelectObject(dc, text.small_font);
                    place.name_lines = history_rows.wrapNames(dc, names.text(), names_width);
                }
            }
            const name_line_count = if (place.name_lines) |name_lines| name_lines.count else 0;
            const height = history_rows.historyRowHeight(line_height, text.small_height, name_line_count);
            if (y + height > bottom) return;
            place.box = .{ .left = 0, .top = y, .right = panel_width, .bottom = y + height };
            history_rows.drawHistoryRow(canvas, dc, text, entries, row, &self.config.thumbnail.notifications, place, now);
            self.row_spans[index] = .{ y, y + height };
            self.drawn_count = index + 1;
            y += height;
        }
    }

    /// Null if a font couldn't be created; a missing bold font falls back to the regular one.
    fn historyText(self: *const HistoryPanelWindow, dc: win32.HDC) ?history_rows.HistoryText {
        const message_font = self.panel.font.handle orelse return null;
        const small_font = self.panel.small_font.handle orelse return null;
        const name_font = self.bold_font.handle orelse message_font;
        _ = win32.SelectObject(dc, small_font);
        const small_height = panel_chrome.lineHeight(dc);
        _ = win32.SelectObject(dc, name_font);
        return .{ .name_font = name_font, .message_font = message_font, .small_font = small_font, .name_height = panel_chrome.lineHeight(dc), .small_height = small_height };
    }
};

fn setCategoryEnabled(store: *config_mod.ProfileStore, category: notification.NotificationCategory, is_enabled: bool) void {
    switch (category) {
        .Fleet => store.update(.{ .historyPanel = .{ .showFleet = is_enabled } }),
        .Mining => store.update(.{ .historyPanel = .{ .showMining = is_enabled } }),
        .Combat => store.update(.{ .historyPanel = .{ .showCombat = is_enabled } }),
        .Navigation => store.update(.{ .historyPanel = .{ .showNavigation = is_enabled } }),
        .Chat => store.update(.{ .historyPanel = .{ .showChat = is_enabled } }),
        .General => store.update(.{ .historyPanel = .{ .showGeneral = is_enabled } }),
    }
}
