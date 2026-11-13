//! The Intel Panel's own window, for when it's detached from the Map Panel, which otherwise draws the same reports in a card.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const history = @import("../notifications/history.zig");
const universe = @import("../map/universe.zig");
const glyphs = @import("glyphs.zig");
const history_look = @import("history_look.zig");
const history_rows = @import("history_rows.zig");
const intel_look = @import("intel_look.zig");
const list_look = @import("list_look.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_header = @import("panel_header.zig");
const panel_look = @import("panel_look.zig");
const header_panel = @import("header_panel.zig");
const panel_host = @import("panel_host.zig");
const panel_lifecycle = @import("panel_lifecycle.zig");
const panel_menu = @import("panel_menu.zig");
const panel_menu_look = @import("panel_menu_look.zig");
const palette = @import("palette.zig");
const segmented = @import("segmented.zig");
const box = @import("../util/box.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const log = @import("../log.zig");

const Box = box.Box;
const PanelWindow = panel_window.PanelWindow;
const slog = log.Scoped("intel_panel");

const INTEL_PANEL_WINDOW_CLASS = "EVE_INTEL_PANEL_CLASS";
const HEADER_ACTIONS = [_]panel_header.Action{ .mute, .pin, .menu };
const ROW_ACTIONS = [_]RowAction{ .show_on_map, .copy_name };

const Class = header_panel.HeaderPanel(IntelPanelWindow, INTEL_PANEL_WINDOW_CLASS);

/// What the Intel Panel's window borrows from App.
pub const Links = struct {
    host: panel_host.Host,
    /// The reports it lists; outlives the panel.
    intel_history: *const history.NotificationHistory,
};

/// Owns whether the Intel Panel shows: inside the map it shows with the map, and alone it has this window and its own settings.
pub const IntelPanel = struct {
    window: ?IntelPanelWindow = null,
    visibility: panel_look.Visibility = .{},
    /// Last sync's intelPanel.attached, to catch the panel leaving the map.
    was_attached: bool = false,
    /// Null until start.
    links: ?Links = null,

    /// Creates the window if the context's profile shows it alone; in place, as the window is linked to where it's stored.
    pub fn start(self: *IntelPanel, context: panel_host.Context, links: Links) void {
        self.links = links;
        self.was_attached = context.store.live.intelPanel.attached;
        panel_lifecycle.sync(self, context);
    }

    pub fn deinit(self: *IntelPanel) void {
        self.destroyWindow();
    }

    /// `is_map_shown` decides it while the panel is inside the map.
    pub fn isVisible(self: *const IntelPanel, config: *const config_mod.Config, presence: panel_look.Presence, is_map_shown: bool) bool {
        const intel_settings = &config.intelPanel;
        if (!intel_settings.show) return false;
        if (intel_settings.attached) return is_map_shown;
        return self.window != null and self.visibility.allowsFor(intel_settings, presence.any_character_logged_in, win32.Ticks.now().ms);
    }

    /// Keyed on isVisible(), not the window: a visible panel turns off, and a hidden one is forced on.
    pub fn toggle(self: *IntelPanel, context: panel_host.Context, presence: panel_look.Presence, is_map_shown: bool) void {
        panel_lifecycle.toggle(self, context, self.isVisible(&context.store.live, presence, is_map_shown));
    }

    /// Matches the window to the settings, for a change made in the config dialog or by a new profile.
    pub fn sync(self: *IntelPanel, context: panel_host.Context) void {
        const intel_settings = &context.store.live.intelPanel;
        const has_left_map = self.was_attached and !intel_settings.attached;
        self.was_attached = intel_settings.attached;
        panel_lifecycle.sync(self, context);
        // Its auto-hide never applied inside the map, so detaching mustn't make it vanish.
        if (has_left_map and self.window != null) self.visibility.force();
        if (self.window) |*window| window.panel.followPosition(intel_settings.x, intel_settings.y);
    }

    /// Per tick: renders the window from `notifications`, or hides it.
    pub fn update(self: *IntelPanel, notifications: *const history.NotificationHistory, config: *const config_mod.Config, presence: panel_look.Presence) void {
        self.visibility.note(presence, win32.Ticks.now().ms);
        const window = if (self.window) |*w| w else return;
        if (!self.isVisible(config, presence, false)) {
            window.hide();
            return;
        }
        window.render(notifications) catch |err| {
            slog.err("Failed to render Intel Panel window: {}", .{err});
        };
    }

    /// For panel_lifecycle: only while it's out of the map.
    pub fn wantsWindow(_: *const IntelPanel, config: *const config_mod.Config) bool {
        return config.intelPanel.show and !config.intelPanel.attached;
    }

    /// For panel_lifecycle.
    pub fn setShown(_: *const IntelPanel, store: *config_mod.ProfileStore, is_shown: bool) void {
        store.update(.{ .intelPanel = .{ .show = is_shown } });
    }

    /// For panel_lifecycle.
    pub fn createWindow(self: *IntelPanel, context: panel_host.Context) void {
        const links = self.links orelse {
            slog.err("Failed to create Intel Panel window: the panel wasn't started", .{});
            return;
        };
        panel_lifecycle.install(IntelPanelWindow, &self.window, IntelPanelWindow.init(context, links), null, "Intel Panel");
    }

    /// For panel_lifecycle.
    pub fn destroyWindow(self: *IntelPanel) void {
        if (self.window) |*window| window.deinit();
        self.window = null;
    }
};

pub const IntelPanelWindow = struct {
    panel: PanelWindow,
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the window.
    config: *const config_mod.Config,
    host: panel_host.Host,
    instance: win32.HINSTANCE,
    /// Borrowed; outlives the window.
    intel_history: *const history.NotificationHistory,
    rows: [history.CAPACITY]history_rows.Row = undefined,
    row_count: usize = 0,
    /// Each row's system, for clicks after the history has moved on.
    row_systems: [history.CAPACITY]?universe.SystemIndex = undefined,
    /// Each drawn row's top and bottom from the last render, for clicks.
    row_spans: [history.CAPACITY][2]i32 = undefined,
    /// How many rows fitted at the last render.
    drawn_count: usize = 0,
    /// From the last render, for clicks; null while the bar isn't drawn.
    range_layout: ?intel_look.RangeLayout = null,
    hovered_row: ?usize = null,
    hovered_action: ?RowAction = null,
    hovered_range: ?types.IntelRange = null,
    /// The row whose action buttons were drawn last render, and where they went.
    action_row: ?usize = null,
    action_boxes: [ROW_ACTIONS.len]Box = undefined,
    /// The configured font in bold, for each row's system.
    bold_font: gdi_overlay.CachedFont = .{},
    header_fonts: panel_chrome.HeaderFonts = .{},
    header_input: header_panel.HeaderInput = .{},
    menu: panel_menu.PanelMenu = .{},

    pub fn init(context: panel_host.Context, links: Links) !IntelPanelWindow {
        const intel_settings = &context.store.live.intelPanel;
        try Class.register(context.instance);
        const panel = try PanelWindow.init(context.allocator, context.instance, INTEL_PANEL_WINDOW_CLASS, "EVE Intel", panel_lifecycle.windowRect(intel_settings), intel_settings.alwaysOnTop);
        return .{ .panel = panel, .store = context.store, .config = &context.store.live, .host = links.host, .instance = context.instance, .intel_history = links.intel_history };
    }

    pub fn deinit(self: *IntelPanelWindow) void {
        self.menu.deinit(self.panel.allocator);
        self.header_fonts.deinit(self.panel.allocator);
        self.bold_font.deinit(self.panel.allocator);
        self.panel.deinit();
    }

    pub fn hide(self: *IntelPanelWindow) void {
        self.menu.close();
        self.panel.hide();
    }

    pub fn headerLayout(self: *const IntelPanelWindow) panel_header.Layout {
        return .init(@max(1, self.config.intelPanel.width), &HEADER_ACTIONS);
    }

    pub fn toggleCollapsed(self: *IntelPanelWindow) void {
        self.store.update(.{ .intelPanel = .{ .collapsed = !self.config.intelPanel.collapsed } });
        self.redraw();
    }

    pub fn runHeaderAction(self: *IntelPanelWindow, action: panel_header.Action) void {
        const intel_settings = &self.config.intelPanel;
        switch (action) {
            .pin => self.store.update(.{ .intelPanel = .{ .alwaysOnTop = !intel_settings.alwaysOnTop } }),
            .mute => self.store.update(.{ .intelPanel = .{ .muteSounds = !intel_settings.muteSounds } }),
            .menu => self.menu.toggle(self.panel.allocator, self.instance, panel_menu.ownerFor(IntelPanelWindow, self), self.menuButton() orelse return),
            .clear => {},
        }
        self.redraw();
        self.menu.refresh();
    }

    /// The ⋯ button in screen pixels.
    fn menuButton(self: *const IntelPanelWindow) ?box.Box {
        const button = self.headerLayout().boxOf(.{ .button = .menu }) orelse return null;
        return panel_menu.screenBox(&self.panel, button);
    }

    pub fn menuContents(self: *const IntelPanelWindow) panel_menu_look.Contents {
        const intel_settings = &self.config.intelPanel;
        return .{
            .is_on_top = intel_settings.alwaysOnTop,
            .is_locked = intel_settings.lockPosition,
            .opacity = intel_settings.opacity,
            .settings_label = "Intel Panel Settings\u{2026}",
            .can_hide = true,
            .accent = self.config.accentColor,
        };
    }

    pub fn runMenuAction(self: *IntelPanelWindow, action: panel_menu_look.Action) void {
        const intel_settings = &self.config.intelPanel;
        switch (action) {
            .toggle => |toggle| switch (toggle) {
                .keep_on_top => self.store.update(.{ .intelPanel = .{ .alwaysOnTop = !intel_settings.alwaysOnTop } }),
                .lock_position => self.store.update(.{ .intelPanel = .{ .lockPosition = !intel_settings.lockPosition } }),
                .group_by_system => {},
            },
            .order => {},
            .opacity => |opacity| if (opacity.is_final) self.store.update(.{ .intelPanel = .{ .opacity = opacity.value } }) else self.store.preview(.{ .intelPanel = .{ .opacity = opacity.value } }),
            .command => |command| switch (command) {
                .settings => self.host.run(.{ .open_settings = .intel_panel }),
                .hide => {
                    self.store.update(.{ .intelPanel = .{ .show = false } });
                    self.hide();
                    return;
                },
            },
        }
        self.redraw();
    }

    pub fn isPositionLocked(self: *const IntelPanelWindow) bool {
        return self.config.intelPanel.lockPosition;
    }

    /// Now, for input that changed what the panel shows, rather than on the next tick.
    pub fn redraw(self: *IntelPanelWindow) void {
        self.render(self.intel_history) catch |err| {
            slog.err("Failed to redraw Intel Panel window: {}", .{err});
        };
    }

    fn header(self: *const IntelPanelWindow) panel_chrome.Header {
        const intel_settings = &self.config.intelPanel;
        return .{ .layout = self.headerLayout(), .title = intel_look.HEADER_TEXT, .is_collapsed = intel_settings.collapsed, .hovered = self.header_input.hovered, .lit = .init(.{ .pin = intel_settings.alwaysOnTop, .mute = intel_settings.muteSounds }), .accent = self.config.accentColor };
    }

    pub fn saveWindowPosition(self: *const IntelPanelWindow) void {
        const intel_settings = &self.config.intelPanel;
        if (!intel_settings.rememberPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .intelPanel = .{ .x = top_left.x, .y = top_left.y } });
    }

    /// A range segment filters the rows; a hovered row's button runs its action, and the rest of a row shows its system on the map.
    pub fn onLeftClick(self: *IntelPanelWindow, x: i32, y: i32) void {
        if (self.config.intelPanel.collapsed) return;
        if (self.range_layout) |layout| {
            if (layout.rangeAt(x, y)) |range| {
                self.store.update(.{ .intelPanel = .{ .range = range } });
                self.redraw();
                return;
            }
        }
        const row_index = self.rowAt(y) orelse return;
        const system = self.row_systems[row_index] orelse return;
        const action = self.actionAt(row_index, x, y) orelse .show_on_map;
        switch (action) {
            .show_on_map => self.host.run(.{ .show_system = system }),
            .copy_name => if (!win32.setClipboardText(universe.systemName(system))) slog.warn("Failed to copy '{s}' to the clipboard", .{universe.systemName(system)}),
        }
    }

    /// Null for a message left to Windows.
    pub fn handleMessage(self: *IntelPanelWindow, hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) ?win32.LRESULT {
        _ = hwnd;
        _ = wParam;
        switch (msg) {
            win32.WM_MOUSEMOVE => {
                const x = win32.lparamX(lParam);
                const y = win32.lparamY(lParam);
                const row_index = self.rowAt(y);
                const action = if (row_index) |index| self.actionAt(index, x, y) else null;
                const range = if (self.range_layout) |layout| layout.rangeAt(x, y) else null;
                if (row_index == self.hovered_row and action == self.hovered_action and range == self.hovered_range) return null;
                self.hovered_row = row_index;
                self.hovered_action = action;
                self.hovered_range = range;
                self.redraw();
            },
            win32.WM_MOUSELEAVE => {
                self.hovered_row = null;
                self.hovered_action = null;
                self.hovered_range = null;
                self.redraw();
            },
            else => {},
        }
        return null;
    }

    /// From the last render.
    fn rowAt(self: *const IntelPanelWindow, y: i32) ?usize {
        for (self.row_spans[0..self.drawn_count], 0..) |span, index| {
            if (y >= span[0] and y < span[1]) return index;
        }
        return null;
    }

    /// Only the row whose buttons were drawn has any.
    fn actionAt(self: *const IntelPanelWindow, row_index: usize, x: i32, y: i32) ?RowAction {
        if (self.action_row != row_index) return null;
        for (self.action_boxes, ROW_ACTIONS) |action_box, action| {
            if (action_box.containsPoint(x, y)) return action;
        }
        return null;
    }

    fn computeRenderSignature(self: *const IntelPanelWindow, notifications: *const history.NotificationHistory, entries: []const history.Entry, total_count: usize, panel_header_state: *const panel_chrome.Header) u64 {
        const intel_settings = &self.config.intelPanel;
        const history_settings = &self.config.historyPanel;
        var hasher = std.hash.Wyhash.init(0);
        panel_chrome.hashHeader(&hasher, panel_header_state);
        hasher.update(std.mem.asBytes(&intel_settings.width));
        hasher.update(std.mem.asBytes(&intel_settings.height));
        hasher.update(std.mem.asBytes(&intel_settings.opacity));
        hasher.update(std.mem.asBytes(&intel_settings.range));
        hasher.update(std.mem.asBytes(&total_count));
        const hovered_row = self.hovered_row orelse std.math.maxInt(usize);
        hasher.update(std.mem.asBytes(&hovered_row));
        const hovered_action: u8 = if (self.hovered_action) |action| @as(u8, @backingInt(action)) + 1 else 0;
        hasher.update(std.mem.asBytes(&hovered_action));
        const hovered_range: u8 = if (self.hovered_range) |range| @as(u8, @backingInt(range)) + 1 else 0;
        hasher.update(std.mem.asBytes(&hovered_range));
        panel_chrome.hashFonts(&hasher, history_settings);
        history_rows.hashIntel(&hasher, notifications, entries, history_settings, intel_settings, &self.config.thumbnail.notifications);
        return hasher.final();
    }

    /// Called every tick; redraws only when the render signature changed.
    pub fn render(self: *IntelPanelWindow, notifications: *const history.NotificationHistory) !void {
        const intel_settings = &self.config.intelPanel;
        const history_settings = &self.config.historyPanel;
        self.panel.followTopmost(intel_settings.alwaysOnTop);
        try panel_chrome.ensureFonts(&self.panel, history_settings);
        try self.bold_font.ensure(self.panel.allocator, "Intel Panel system", history_settings.fontName, history_settings.fontSize, history_settings.fontWeight.bolded());
        try self.header_fonts.ensure(self.panel.allocator);

        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        const all_entries = notifications.snapshot(&entry_buf);
        var shown_buf: [history.CAPACITY]history.Entry = undefined;
        var shown_count: usize = 0;
        for (all_entries) |entry| {
            const jumps = if (entry.intel) |facts| facts.jumps else null;
            if (!intel_look.isWithin(intel_settings.range, jumps)) continue;
            shown_buf[shown_count] = entry;
            shown_count += 1;
        }
        const entries = shown_buf[0..shown_count];
        self.row_count = history_rows.build(&self.rows, entries, history.CAPACITY, history_rows.buildOptions(history_settings, null));
        for (self.rows[0..self.row_count], self.row_systems[0..self.row_count]) |row, *system| system.* = entries[row.first_index].system;

        const panel_header_state = self.header();
        const signature = self.computeRenderSignature(notifications, entries, all_entries.len, &panel_header_state);
        if (self.panel.isUnchanged(signature)) return;

        const is_collapsed = intel_settings.collapsed;
        const panel_width: i32 = @max(1, intel_settings.width);
        const panel_height = panel_header.panelHeight(is_collapsed, intel_settings.height);
        const bitmap = try self.panel.beginFrame(panel_width, panel_height);
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        panel_chrome.fillBody(canvas);
        panel_chrome.fillHeader(canvas, &panel_header_state);

        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        const summary_left = panel_chrome.drawHeaderText(dc, &self.header_fonts, &panel_header_state);
        self.range_layout = null;
        self.drawn_count = 0;
        self.action_row = null;
        if (is_collapsed) {
            self.drawSummary(canvas, dc, entries, summary_left, panel_header_state.layout.content_right);
        } else {
            self.range_layout = self.drawRangeBar(canvas, dc, panel_width, entries.len, all_entries.len);
            const rows_top = if (self.range_layout) |layout| layout.bottom else panel_header.HEIGHT;
            self.drawRows(canvas, dc, entries, all_entries.len, rows_top, panel_width, panel_height);
        }

        panel_chrome.finish(canvas);
        self.panel.present(intel_settings.opacity, signature);
    }

    /// The newest report in range, after the title of a collapsed panel: its distance, its system in its colour, then the rest.
    fn drawSummary(self: *const IntelPanelWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, entries: []const history.Entry, left: i32, right: i32) void {
        if (self.row_count == 0) return;
        const entry = &entries[self.rows[0].first_index];
        const parts = self.partsOf(entry);
        const jumps = if (entry.intel) |facts| facts.jumps else null;
        const swatch = intel_look.pillSwatch(jumps);
        var pill_buf: [intel_look.TEXT_MAX]u8 = undefined;
        var time_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        const runs = [_]panel_chrome.Run{
            .{ .text = intel_look.pillText(&pill_buf, jumps), .color = swatch.text, .fill = swatch.fill },
            .{ .text = parts.system, .color = parts.system_color },
            .{ .text = if (parts.is_clear) intel_look.CLEAR_TEXT else parts.message, .color = palette.TEXT_SECONDARY },
            .{ .text = panel_look.relativeTime(&time_buf, win32.Ticks.now().elapsedSince(entry.timestamp)), .color = palette.MUTED },
        };
        panel_chrome.drawSummary(canvas, dc, &self.header_fonts, left, right, &runs);
    }

    /// "Within", the range as the panels' segmented control, and how many reports it leaves; returns where they sit, or null without the fonts.
    fn drawRangeBar(self: *const IntelPanelWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, panel_width: i32, shown_count: usize, total_count: usize) ?intel_look.RangeLayout {
        const small_font = self.header_fonts.small.handle orelse return null;
        const label_font = self.panel.font.handle orelse return null;
        // The header's title font is segmented.PICKED_FACE at its size.
        const picked_font = self.header_fonts.title.handle orelse label_font;
        const picked = self.config.intelPanel.range;

        _ = win32.SelectObject(dc, small_font);
        const small_height = panel_chrome.lineHeight(dc);
        const label_width = panel_chrome.textWidth(dc, intel_look.RANGE_LABEL);
        var count_buf: [intel_look.TEXT_MAX]u8 = undefined;
        const count_text = intel_look.filterText(&count_buf, shown_count, total_count);
        const count_width = panel_chrome.textWidth(dc, count_text);
        // Sized for the picked label, so the segments don't move as the pick does.
        _ = win32.SelectObject(dc, picked_font);
        var widths: [intel_look.RANGE_COUNT]i32 = undefined;
        for (intel_look.RANGE_ORDER, &widths) |range, *width| width.* = panel_chrome.textWidth(dc, intel_look.rangeLabel(range));
        const layout = intel_look.layOutRange(widths, intel_look.PADDING_X + label_width + intel_look.LABEL_GAP, panel_header.HEIGHT);

        const bar = layout.bar;
        segmented.drawBar(canvas, bar);
        const accent = self.config.accentColor;
        for (intel_look.RANGE_ORDER, layout.segments) |range, segment| {
            if (segmented.buttonFill(self.rangeState(range), accent)) |fill| segmented.fillButton(canvas, segment, fill);
        }
        const small_y = bar.top + @divTrunc(bar.bottom - bar.top - small_height, 2);
        _ = win32.SelectObject(dc, small_font);
        panel_chrome.drawLine(dc, intel_look.RANGE_LABEL, intel_look.PADDING_X, small_y, palette.MUTED);
        const count_left = panel_width - intel_look.PADDING_X - count_width;
        if (count_left > bar.right + intel_look.LABEL_GAP) panel_chrome.drawLine(dc, count_text, count_left, small_y, palette.MUTED);
        for (intel_look.RANGE_ORDER, layout.segments) |range, segment| {
            const is_picked = range == picked;
            _ = win32.SelectObject(dc, if (is_picked) picked_font else label_font);
            const label = intel_look.rangeLabel(range);
            const label_x = segment.left + @divTrunc(segment.right - segment.left - panel_chrome.textWidth(dc, label), 2);
            panel_chrome.drawLine(dc, label, label_x, segment.top + @divTrunc(segment.bottom - segment.top - panel_chrome.lineHeight(dc), 2), segmented.labelColor(self.rangeState(range), accent));
        }
        pixel_buffer.fillRect(canvas, 0, @intCast(layout.bottom - 1), canvas.width, 1, list_look.DIVIDER);
        return layout;
    }

    fn rangeState(self: *const IntelPanelWindow, range: types.IntelRange) segmented.State {
        if (range == self.config.intelPanel.range) return .picked;
        return if (self.hovered_range == range) .hovered else .idle;
    }

    /// From `top` down, as many as fit; records where each landed.
    fn drawRows(self: *IntelPanelWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, entries: []const history.Entry, total_count: usize, top: i32, panel_width: i32, panel_height: i32) void {
        const message_font = self.panel.font.handle orelse return;
        const small_font = self.panel.small_font.handle orelse return;
        const fonts: RowFonts = .{ .system = self.bold_font.handle orelse message_font, .message = message_font, .small = small_font };
        _ = win32.SelectObject(dc, message_font);
        const name_height = panel_chrome.lineHeight(dc);
        const row_height = intel_look.rowHeight(self.config.historyPanel.fontSize);
        const bottom = panel_height - list_look.BOTTOM_PADDING;
        var y = top + intel_look.ROWS_PADDING_TOP;
        if (self.row_count == 0) {
            var empty_buf: [intel_look.TEXT_MAX]u8 = undefined;
            const empty = if (total_count == 0) history_rows.INTEL_EMPTY_TEXT else intel_look.emptyText(&empty_buf, self.config.intelPanel.range);
            const empty_left = @max(intel_look.PADDING_X, @divTrunc(panel_width - panel_chrome.wideTextWidth(dc, empty), 2));
            _ = panel_chrome.drawFitted(dc, empty, empty_left, y + row_height, list_look.MUTED, panel_width - empty_left - intel_look.PADDING_X);
            return;
        }

        const now = win32.Ticks.now();
        for (self.rows[0..self.row_count], 0..) |row, index| {
            if (y + row_height > bottom) return;
            self.drawRow(canvas, dc, fonts, name_height, entries, row, index, .{ .left = 0, .top = y, .right = panel_width, .bottom = y + row_height }, now);
            self.row_spans[index] = .{ y, y + row_height };
            self.drawn_count = index + 1;
            y += row_height;
        }
    }

    /// Its distance pill, system, clear tag and message, any merged count, the hovered row's buttons, then its age.
    fn drawRow(self: *IntelPanelWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, fonts: RowFonts, name_height: i32, entries: []const history.Entry, row: history_rows.Row, index: usize, row_box: Box, now: win32.Ticks) void {
        const entry = &entries[row.first_index];
        const is_hovered = self.hovered_row == index;
        if (is_hovered) pixel_buffer.fillRect(canvas, @intCast(row_box.left), @intCast(row_box.top), @intCast(row_box.right - row_box.left), @intCast(row_box.bottom - row_box.top), list_look.ROW_HOVER);
        const is_old = now.elapsedSince(entry.timestamp) > intel_look.OLD_AFTER_MS;
        const center_y = row_box.top + @divTrunc(row_box.bottom - row_box.top, 2);

        _ = win32.SelectObject(dc, fonts.small);
        const small_height = panel_chrome.lineHeight(dc);
        const small_y = center_y - @divTrunc(small_height, 2);
        const jumps = if (entry.intel) |facts| facts.jumps else null;
        var pill_buf: [intel_look.TEXT_MAX]u8 = undefined;
        const pill_text = intel_look.pillText(&pill_buf, jumps);
        const pill_text_width = panel_chrome.textWidth(dc, pill_text);
        const pill_width = @max(intel_look.PILL_MIN_WIDTH, pill_text_width + 2 * intel_look.PILL_PADDING_X);
        const pill_left = row_box.left + intel_look.PADDING_X;
        const swatch = intel_look.pillSwatch(jumps);
        pixel_buffer.fillRoundedRect(canvas, @intCast(pill_left), @intCast(center_y - @divTrunc(intel_look.PILL_HEIGHT, 2)), @intCast(pill_width), @intCast(intel_look.PILL_HEIGHT), intel_look.PILL_RADIUS, intel_look.faded(swatch.fill, is_old));
        panel_chrome.drawLine(dc, pill_text, pill_left + @divTrunc(pill_width - pill_text_width, 2), small_y, intel_look.faded(swatch.text, is_old));

        var content_right = row_box.right - intel_look.PADDING_X;
        if (self.config.historyPanel.showTimestamp) {
            var time_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
            const time_text = panel_look.relativeTime(&time_buf, now.elapsedSince(entry.timestamp));
            content_right -= panel_chrome.textWidth(dc, time_text);
            panel_chrome.drawLine(dc, time_text, content_right, small_y, intel_look.faded(palette.MUTED, is_old));
            content_right -= intel_look.ROW_GAP;
        }
        if (is_hovered) content_right = self.drawActions(canvas, index, content_right, center_y);
        if (row.count > 1) {
            var merged_buf: [history_look.COUNT_TEXT_MAX]u8 = undefined;
            const merged = history_look.mergedText(&merged_buf, row.count);
            content_right -= panel_chrome.wideTextWidth(dc, merged);
            panel_chrome.drawWideLine(dc, merged, content_right, small_y, intel_look.faded(palette.MUTED, is_old));
            content_right -= history_look.TEXT_GAP;
        }

        const parts = self.partsOf(entry);
        const name_y = center_y - @divTrunc(name_height, 2);
        var x = pill_left + pill_width + intel_look.ROW_GAP;
        _ = win32.SelectObject(dc, fonts.system);
        x += panel_chrome.drawFitted(dc, parts.system, x, name_y, intel_look.faded(parts.system_color, is_old), content_right - x) + history_look.TEXT_GAP;
        if (parts.is_clear and x < content_right) {
            _ = win32.SelectObject(dc, fonts.small);
            const clear = intel_look.clearSwatch();
            const tag_width = @min(panel_chrome.textWidth(dc, intel_look.CLEAR_TEXT) + 2 * intel_look.TAG_PADDING_X, content_right - x);
            pixel_buffer.fillRoundedRect(canvas, @intCast(x), @intCast(small_y - 1), @intCast(tag_width), @intCast(small_height + 2), intel_look.TAG_RADIUS, intel_look.faded(clear.fill, is_old));
            _ = panel_chrome.drawFitted(dc, intel_look.CLEAR_TEXT, x + intel_look.TAG_PADDING_X, small_y, intel_look.faded(clear.text, is_old), tag_width - 2 * intel_look.TAG_PADDING_X);
            x += tag_width + history_look.TEXT_GAP;
        }
        if (x >= content_right) return;
        _ = win32.SelectObject(dc, fonts.message);
        _ = panel_chrome.drawFitted(dc, parts.message, x, name_y, intel_look.faded(palette.TEXT, is_old), content_right - x);
    }

    /// Ending at `right`; returns where they start, less a gap.
    fn drawActions(self: *IntelPanelWindow, canvas: pixel_buffer.Canvas, index: usize, right: i32, center_y: i32) i32 {
        var left = right;
        var action_index = ROW_ACTIONS.len;
        while (action_index > 0) {
            action_index -= 1;
            const action = ROW_ACTIONS[action_index];
            left -= intel_look.ACTION_SIZE;
            const action_box: Box = .{ .left = left, .top = center_y - @divTrunc(intel_look.ACTION_SIZE, 2), .right = left + intel_look.ACTION_SIZE, .bottom = center_y - @divTrunc(intel_look.ACTION_SIZE, 2) + intel_look.ACTION_SIZE };
            self.action_boxes[action_index] = action_box;
            const is_lit = self.hovered_action == action;
            if (is_lit) pixel_buffer.fillRoundedRect(canvas, @intCast(action_box.left), @intCast(action_box.top), @intCast(intel_look.ACTION_SIZE), @intCast(intel_look.ACTION_SIZE), intel_look.ACTION_RADIUS, palette.SURFACE);
            const inset = @divTrunc(intel_look.ACTION_SIZE - glyphs.SIZE, 2);
            glyphs.draw(canvas, actionGlyph(action), action_box.left + inset, action_box.top + inset, if (is_lit) palette.TEXT else palette.MUTED);
            left -= intel_look.ACTION_GAP;
        }
        self.action_row = index;
        return left + intel_look.ACTION_GAP - intel_look.ROW_GAP;
    }

    /// The system, in its colour while the panel colours them, and the rest of the message after its distance.
    fn partsOf(self: *const IntelPanelWindow, entry: *const history.Entry) RowParts {
        const message = entry.text();
        const is_clear = if (entry.intel) |facts| facts.is_clear else false;
        if (entry.lead) |lead| {
            const system_color = if (self.config.intelPanel.colorSystemNames) lead.color else palette.TEXT;
            return .{ .system = message[0..lead.length], .system_color = system_color, .message = history_look.splitAfterSystem(message[lead.length..]).message, .is_clear = is_clear };
        }
        const system = if (entry.system) |index| universe.systemName(index) else "";
        return .{ .system = system, .system_color = palette.TEXT, .message = message, .is_clear = is_clear };
    }
};

/// What a hovered row's buttons do, left to right before its age.
const RowAction = enum { show_on_map, copy_name };

/// A row's text split for drawing.
const RowParts = struct {
    /// Borrows from the entry's text, or is the map's own name for its system.
    system: []const u8,
    system_color: u32,
    /// Borrows from the entry's text.
    message: []const u8,
    is_clear: bool,
};

const RowFonts = struct {
    /// Bold.
    system: win32.HFONT,
    message: win32.HFONT,
    small: win32.HFONT,
};

fn actionGlyph(action: RowAction) glyphs.Glyph {
    return switch (action) {
        .show_on_map => .map,
        .copy_name => .copy,
    };
}
