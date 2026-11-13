//! The client list: one compact panel with a row per client, in place of or beside the thumbnail windows.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const list_look = @import("list_look.zig");
const map_look = @import("map/look.zig");
const map_text = @import("map/text.zig");
const universe = @import("../map/universe.zig");
const window = @import("../thumbnail/window.zig");
const header_panel = @import("header_panel.zig");
const palette = @import("palette.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_header = @import("panel_header.zig");
const panel_host = @import("panel_host.zig");
const panel_menu = @import("panel_menu.zig");
const panel_menu_look = @import("panel_menu_look.zig");
const template = @import("../notifications/template.zig");
const box = @import("../util/box.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const strings = @import("../util/strings.zig");
const log = @import("../log.zig");

const PanelWindow = panel_window.PanelWindow;
const ThumbnailWindow = window.ThumbnailWindow;
const slog = log.Scoped("list_view");

const TEXT_BUFFER_SIZE: usize = 256;

const LIST_WINDOW_CLASS = "EVE_LIST_CLASS";
const HEADER_ACTIONS = [_]panel_header.Action{ .pin, .menu };
/// Fits a system's name, upper-cased for its heading.
const HEADING_TEXT_MAX = 64;
/// Fits alertText's longest result.
const ALERT_TEXT_MAX = 32;

const Class = header_panel.HeaderPanel(ListWindow, LIST_WINDOW_CLASS);

/// thumbnail_input's, passed in by App, so rows click like thumbnails without panels/ importing input code.
pub const RowInput = struct {
    press: *const fn (hwnd: win32.HWND, source_hwnd: win32.HWND) void,
    release: *const fn (hwnd: win32.HWND) void,
    /// False when Windows should set the class cursor.
    apply_hover_cursor: *const fn () bool,
};

/// A line of the last render: a system's heading, or rows side by side.
const Line = struct {
    top: i32,
    bottom: i32,
    /// Into `rows`.
    first_row: usize,
    row_count: usize,
    /// Over the `row_count` rows from `first_row`, rather than those rows.
    is_heading: bool = false,
};

const RowText = struct {
    /// Bold on every row, so a name's width doesn't change as it's activated.
    name_font: win32.HFONT,
    small_font: win32.HFONT,
    /// The small font in bold, for the system or notification at a row's right.
    slot_font: win32.HFONT,
    name_height: i32,
    small_height: i32,
};

pub const ListWindow = struct {
    panel: PanelWindow,
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrows store.live.
    config: *const config_mod.Config,
    /// For drag snapping to the thumbnails.
    host: panel_host.Host,
    instance: win32.HINSTANCE,
    row_input: RowInput,
    /// Indices into the thumbnails render() was given, one per row in display order; hidden characters get none.
    rows: std.ArrayList(usize) = .empty,
    /// Each row's client, for clicks between renders.
    row_source_hwnds: std.ArrayList(win32.HWND) = .empty,
    /// From the last render, top to bottom; a line of rows is as tall as its tallest.
    lines: std.ArrayList(Line) = .empty,
    /// The client whose row is under the cursor.
    hovered_source_hwnd: ?win32.HWND = null,
    /// The configured font in bold, for the rows' names.
    bold_font: gdi_overlay.CachedFont = .{},
    /// The small font in bold, for the rows' systems and notifications.
    small_bold_font: gdi_overlay.CachedFont = .{},
    header_fonts: panel_chrome.HeaderFonts = .{},
    header_input: header_panel.HeaderInput = .{},
    menu: panel_menu.PanelMenu = .{},

    pub fn init(context: panel_host.Context, host: panel_host.Host, row_input: RowInput) !ListWindow {
        const config = &context.store.live;
        try Class.register(context.instance);
        const x = config.display.startX;
        const y = config.display.startY;
        const sizes = list_look.metrics(&config.listView);
        const panel = try PanelWindow.init(context.allocator, context.instance, LIST_WINDOW_CLASS, "EVE Client List", .{ .left = x, .top = y, .right = x + sizes.column_width, .bottom = y + sizes.header_height }, config.listView.alwaysOnTop);
        win32.setClickThroughStyle(panel.hwnd, config.interaction.clickThrough);
        return .{ .panel = panel, .store = context.store, .config = config, .host = host, .instance = context.instance, .row_input = row_input };
    }

    pub fn deinit(self: *ListWindow) void {
        self.menu.deinit(self.panel.allocator);
        self.header_fonts.deinit(self.panel.allocator);
        self.bold_font.deinit(self.panel.allocator);
        self.small_bold_font.deinit(self.panel.allocator);
        self.rows.deinit(self.panel.allocator);
        self.row_source_hwnds.deinit(self.panel.allocator);
        self.lines.deinit(self.panel.allocator);
        self.panel.deinit();
    }

    /// Matches the panel to its configured position.
    pub fn sync(self: *ListWindow) void {
        self.panel.followPosition(self.config.display.startX, self.config.display.startY);
        win32.setClickThroughStyle(self.panel.hwnd, self.config.interaction.clickThrough);
    }

    /// From the last render; null over the header or an empty cell.
    fn rowSourceAt(self: *const ListWindow, x: i32, y: i32) ?win32.HWND {
        const list_settings = &self.config.listView;
        if (list_settings.collapsed) return null;
        const line = for (self.lines.items) |candidate| {
            if (y >= candidate.top and y < candidate.bottom) break candidate;
        } else return null;
        if (line.is_heading) return null;
        const column: usize = @intCast(@max(0, @divTrunc(x, list_look.metrics(list_settings).column_width)));
        if (column >= line.row_count) return null;
        const index = line.first_row + column;
        if (index >= self.row_source_hwnds.items.len) return null;
        return self.row_source_hwnds.items[index];
    }

    fn hoverRow(self: *ListWindow, source_hwnd: ?win32.HWND) void {
        if (self.hovered_source_hwnd == source_hwnd) return;
        self.hovered_source_hwnd = source_hwnd;
        self.redraw();
    }

    /// As last drawn.
    pub fn headerLayout(self: *const ListWindow) panel_header.Layout {
        return .init(@max(1, self.panel.width), &HEADER_ACTIONS);
    }

    pub fn toggleCollapsed(self: *ListWindow) void {
        self.store.update(.{ .listView = .{ .collapsed = !self.config.listView.collapsed } });
        self.redraw();
    }

    pub fn runHeaderAction(self: *ListWindow, action: panel_header.Action) void {
        switch (action) {
            .pin => self.store.update(.{ .listView = .{ .alwaysOnTop = !self.config.listView.alwaysOnTop } }),
            .menu => self.menu.toggle(self.panel.allocator, self.instance, panel_menu.ownerFor(ListWindow, self), self.menuButton() orelse return),
            .clear, .mute => {},
        }
        self.redraw();
        self.menu.refresh();
    }

    /// The ⋯ button in screen pixels.
    fn menuButton(self: *const ListWindow) ?box.Box {
        const button = self.headerLayout().boxOf(.{ .button = .menu }) orelse return null;
        return panel_menu.screenBox(&self.panel, button);
    }

    pub fn menuContents(self: *const ListWindow) panel_menu_look.Contents {
        const list_settings = &self.config.listView;
        return .{
            .is_on_top = list_settings.alwaysOnTop,
            .groups_by_system = list_settings.groupBySystem,
            .is_locked = list_settings.lockPosition,
            .order = list_settings.order,
            .opacity = list_settings.opacity,
            .settings_label = "Client List Settings\u{2026}",
            // It's shown by the view mode, which belongs to the dialog.
            .can_hide = false,
            .accent = self.config.accentColor,
        };
    }

    pub fn runMenuAction(self: *ListWindow, action: panel_menu_look.Action) void {
        const list_settings = &self.config.listView;
        switch (action) {
            .toggle => |toggle| switch (toggle) {
                .keep_on_top => self.store.update(.{ .listView = .{ .alwaysOnTop = !list_settings.alwaysOnTop } }),
                .group_by_system => self.store.update(.{ .listView = .{ .groupBySystem = !list_settings.groupBySystem } }),
                .lock_position => self.store.update(.{ .listView = .{ .lockPosition = !list_settings.lockPosition } }),
            },
            .order => |order| self.store.update(.{ .listView = .{ .order = order } }),
            .opacity => |opacity| if (opacity.is_final) self.store.update(.{ .listView = .{ .opacity = opacity.value } }) else self.store.preview(.{ .listView = .{ .opacity = opacity.value } }),
            .command => |command| switch (command) {
                .settings => self.host.run(.{ .open_settings = .client_list }),
                .hide => {},
            },
        }
        self.redraw();
    }

    pub fn isPositionLocked(self: *const ListWindow) bool {
        return self.config.listView.lockPosition;
    }

    /// Now, for input that changed what the panel shows, rather than on the next tick.
    pub fn redraw(self: *ListWindow) void {
        const thumbnail_set = self.host.thumbnail_set() orelse return;
        self.render(thumbnail_set.thumbnails.items, thumbnail_set.active_source_hwnd) catch |err| {
            slog.err("Failed to redraw list window: {}", .{err});
        };
    }

    fn header(self: *const ListWindow, panel_width: i32, count_text: []const u8) panel_chrome.Header {
        const list_settings = &self.config.listView;
        return .{ .layout = .init(panel_width, &HEADER_ACTIONS), .title = list_look.HEADER_TEXT, .count = count_text, .is_collapsed = list_settings.collapsed, .hovered = self.header_input.hovered, .lit = .init(.{ .pin = list_settings.alwaysOnTop }), .accent = self.config.accentColor };
    }

    pub fn saveWindowPosition(self: *const ListWindow) void {
        if (!self.config.listView.rememberPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .display = .{ .startX = top_left.x, .startY = top_left.y } });
    }

    /// Null for a message left to Windows.
    pub fn handleMessage(self: *ListWindow, hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) ?win32.LRESULT {
        _ = wParam;
        switch (msg) {
            win32.WM_MOUSEMOVE => {
                self.hoverRow(self.rowSourceAt(win32.lparamX(lParam), win32.lparamY(lParam)));
                return 0;
            },
            win32.WM_MOUSELEAVE => {
                self.hoverRow(null);
                return 0;
            },
            win32.WM_LBUTTONDOWN => {
                const source_hwnd = self.rowSourceAt(win32.lparamX(lParam), win32.lparamY(lParam)) orelse return 0;
                self.row_input.press(hwnd, source_hwnd);
                return 0;
            },
            win32.WM_LBUTTONUP => {
                self.row_input.release(hwnd);
                return 0;
            },
            win32.WM_SETCURSOR => {
                // Rows only: the header is the drag handle.
                const hit_test: win32.LRESULT = @as(u16, @truncate(@as(usize, @bitCast(lParam))));
                if (hit_test == win32.HTCLIENT and self.row_input.apply_hover_cursor()) return 1;
                return null;
            },
            else => return null,
        }
    }

    /// The shown active colour, or the character's own (or unique) active border colour.
    fn resolveActiveBadgeColor(self: *const ListWindow, thumbnail: *const ThumbnailWindow) u32 {
        if (thumbnail.cached_border_colors) |colors| {
            if (colors.activeBorderColor) |color| return color;
        }
        return self.config.shownColors().active_color;
    }

    /// Puts `rows` in the configured order and records each row's client.
    fn sortRows(self: *ListWindow, thumbnails: []const ThumbnailWindow) !void {
        const AlphabeticalContext = struct {
            thumbnails: []const ThumbnailWindow,

            fn lessThan(context: @This(), first_index: usize, second_index: usize) bool {
                const first = &context.thumbnails[first_index];
                const second = &context.thumbnails[second_index];
                switch (strings.naturalOrder(first.cached_display_name, second.cached_display_name)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
                switch (strings.naturalOrder(first.character_name, second.character_name)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => return first_index < second_index,
                }
            }
        };
        const ConfiguredContext = struct {
            thumbnails: []const ThumbnailWindow,
            order_map: *const std.StringHashMap(usize),

            fn lessThan(context: @This(), first_index: usize, second_index: usize) bool {
                return config_mod.orderMapLessThan(context.order_map, context.thumbnails[first_index].character_name, context.thumbnails[second_index].character_name, first_index, second_index);
            }
        };

        // Rows start in tracked order.
        switch (self.config.listView.order) {
            .Tracked => {},
            .Alphabetical => std.sort.pdq(usize, self.rows.items, AlphabeticalContext{ .thumbnails = thumbnails }, AlphabeticalContext.lessThan),
            .ConfiguredCharacters => {
                // Built once per sort, not per comparison.
                var order_map = try config_mod.buildCharacterOrderMap(self.config.characters.items, self.panel.allocator);
                defer order_map.deinit();
                std.sort.pdq(usize, self.rows.items, ConfiguredContext{ .thumbnails = thumbnails, .order_map = &order_map }, ConfiguredContext.lessThan);
            },
        }

        if (self.config.listView.groupBySystem) try self.groupRows(thumbnails);
        try self.row_source_hwnds.resize(self.panel.allocator, self.rows.items.len);
        for (self.rows.items, self.row_source_hwnds.items) |thumbnail_index, *hwnd| hwnd.* = thumbnails[thumbnail_index].source_hwnd;
    }

    /// A hash of everything that affects the rendered pixels, to skip the redraw when nothing changed.
    fn computeRenderSignature(self: *const ListWindow, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND, panel_header_state: *const panel_chrome.Header) u64 {
        const list_settings = &self.config.listView;
        var hasher = std.hash.Wyhash.init(0);
        panel_chrome.hashHeader(&hasher, panel_header_state);
        hasher.update(std.mem.asBytes(&self.rows.items.len));
        hasher.update(std.mem.asBytes(&list_settings.columns));
        hasher.update(std.mem.asBytes(&list_settings.columnWidth));
        hasher.update(std.mem.asBytes(&list_settings.order));
        hasher.update(std.mem.asBytes(&list_settings.groupBySystem));
        hasher.update(std.mem.asBytes(&list_settings.opacity));
        hasher.update(list_settings.fontName);
        hasher.update(std.mem.asBytes(&list_settings.fontSize));
        hasher.update(std.mem.asBytes(&list_settings.fontWeight));
        hasher.update(std.mem.asBytes(&list_settings.showSystemName));
        hasher.update(std.mem.asBytes(&list_settings.showSystemSecurity));
        hasher.update(std.mem.asBytes(&list_settings.indicatorStyle));
        hasher.update(std.mem.asBytes(&list_settings.showNotifications));
        hasher.update(std.mem.asBytes(&list_settings.notificationColor));
        hasher.update(std.mem.asBytes(&list_settings.showIncomingDps));
        hasher.update(std.mem.asBytes(&list_settings.showIncomingPrefix));
        hasher.update(std.mem.asBytes(&list_settings.incomingDpsColor));
        hasher.update(std.mem.asBytes(&list_settings.showOutgoingDps));
        hasher.update(std.mem.asBytes(&list_settings.showOutgoingPrefix));
        hasher.update(std.mem.asBytes(&list_settings.outgoingDpsColor));
        hasher.update(std.mem.asBytes(&list_settings.showMiningRate));
        hasher.update(std.mem.asBytes(&list_settings.showMiningPrefix));
        hasher.update(std.mem.asBytes(&list_settings.miningRateColor));
        hasher.update(std.mem.asBytes(&list_settings.showBountyRate));
        hasher.update(std.mem.asBytes(&list_settings.showBountyPrefix));
        hasher.update(std.mem.asBytes(&list_settings.bountyRateColor));
        hasher.update(std.mem.asBytes(&self.config.combat.enabled));
        hasher.update(std.mem.asBytes(&self.config.mining.enabled));
        hasher.update(std.mem.asBytes(&self.config.bounty.enabled));
        hasher.update(std.mem.asBytes(&self.config.bounty.isk_rate_unit));
        const hovered_address: usize = if (self.hovered_source_hwnd) |hovered| @intFromPtr(hovered) else 0;
        hasher.update(std.mem.asBytes(&hovered_address));
        // Rows are hashed before they're sorted, so the configured order has to be hashed itself.
        if (list_settings.order == .ConfiguredCharacters) {
            for (self.config.characters.items) |character| hashString(&hasher, character.name);
        }

        for (self.rows.items) |thumbnail_index| {
            const thumbnail = &thumbnails[thumbnail_index];
            const render_state = thumbnail.effectiveRenderState(active_source_hwnd);
            hashString(&hasher, thumbnail.character_name);
            hashString(&hasher, thumbnail.cached_display_name);
            hashString(&hasher, thumbnail.system_name);
            hasher.update(std.mem.asBytes(&render_state));
            hasher.update(std.mem.asBytes(&thumbnail.is_excluded_from_cycle));
            hasher.update(std.mem.asBytes(&thumbnail.stats.incoming_dps));
            hasher.update(std.mem.asBytes(&thumbnail.stats.outgoing_dps));
            hasher.update(std.mem.asBytes(&thumbnail.stats.mining_rate));
            hasher.update(std.mem.asBytes(&thumbnail.stats.bounty_isk_rate));
            hasher.update(std.mem.asBytes(&thumbnail.stats.has_dps));
            hasher.update(std.mem.asBytes(&thumbnail.stats.has_mining));
            hasher.update(std.mem.asBytes(&thumbnail.stats.has_bounty));
            if (thumbnail.system_name.len > 0) hasher.update(std.mem.asBytes(&thumbnail.cached_system_color));
            if (thumbnail.cached_list_name_color) |name_color| hasher.update(std.mem.asBytes(&name_color));
            if (render_state == .active) {
                const badge_color = self.resolveActiveBadgeColor(thumbnail);
                hasher.update(std.mem.asBytes(&badge_color));
            }
            for (thumbnail.notifications.items()) |notification| {
                hashString(&hasher, notification.text);
                hasher.update(std.mem.asBytes(&notification.border_color_override));
                hasher.update(std.mem.asBytes(&notification.text_color_override));
                hasher.update(std.mem.asBytes(&notification.shows_text));
                if (notification.lead) |lead| hasher.update(std.mem.asBytes(&lead.color));
            }
        }

        return hasher.final();
    }

    fn statSettings(self: *const ListWindow) list_look.StatSettings {
        const config = self.config;
        return .{ .list_settings = &config.listView, .combat = &config.combat, .mining = &config.mining, .bounty = &config.bounty };
    }

    /// In writing order; empty when the list shows none.
    fn statReadings(self: *const ListWindow, thumbnail: *const ThumbnailWindow, out: *[list_look.STAT_COUNT]list_look.StatReading) []const list_look.StatReading {
        const config = self.config;
        const settings = self.statSettings();
        const stats = &thumbnail.stats;
        const bounty_period_seconds = config.bounty.isk_rate_unit.seconds();
        var reading_count: usize = 0;
        for (std.enums.values(list_look.Stat)) |stat| {
            if (!list_look.showsStat(settings, stat)) continue;
            const value: ?f32 = switch (stat) {
                .incoming_dps => if (stats.showsIncoming()) stats.incoming_dps else continue,
                .outgoing_dps => if (stats.showsOutgoing()) stats.outgoing_dps else continue,
                .mining_rate => if (stats.showsMining()) (if (stats.mining_rate) |rate| rate * 60.0 else null) else continue,
                .bounty_rate => if (stats.showsBounty()) (if (stats.bounty_isk_rate) |rate| rate * bounty_period_seconds else null) else continue,
            };
            out[reading_count] = .{ .stat = stat, .value = value, .has_prefix = list_look.hasPrefix(&config.listView, stat) };
            reading_count += 1;
        }
        return out[0..reading_count];
    }

    /// Called every tick; redraws only when the render signature changed.
    pub fn render(self: *ListWindow, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND) !void {
        const list_settings = &self.config.listView;
        self.panel.followTopmost(list_settings.alwaysOnTop);
        try self.panel.ensureFont("List View", list_settings.fontName, list_settings.fontSize, list_settings.fontWeight);
        try self.panel.ensureSmallFont("List View small", list_settings.fontName, list_look.smallFontSize(list_settings.fontSize), list_settings.fontWeight);
        try self.bold_font.ensure(self.panel.allocator, "List View names", list_settings.fontName, list_settings.fontSize, list_settings.fontWeight.bolded());
        try self.small_bold_font.ensure(self.panel.allocator, "List View systems", list_settings.fontName, list_look.smallFontSize(list_settings.fontSize), list_settings.fontWeight.bolded());

        self.rows.clearRetainingCapacity();
        var has_visible_row = false;
        for (thumbnails, 0..) |*thumbnail, i| {
            if (thumbnail.cached_is_thumbnail_hidden) continue;
            try self.rows.append(self.panel.allocator, i);
            if (thumbnail.isShown()) has_visible_row = true;
        }
        // Also hidden once the visibility toggle or auto-hide has hidden every client.
        if (!has_visible_row) {
            self.menu.close();
            self.panel.hide();
            return;
        }

        const columns = list_look.effectiveColumns(list_settings.columns, self.rows.items.len);
        const sizes = list_look.metrics(list_settings);
        const panel_width = columns * sizes.column_width;
        var count_buffer: [list_look.COUNT_TEXT_MAX]u8 = undefined;
        const panel_header_state = self.header(panel_width, list_look.countText(&count_buffer, self.rows.items.len));
        const signature = self.computeRenderSignature(thumbnails, active_source_hwnd, &panel_header_state);
        if (self.panel.isUnchanged(signature)) return;

        try self.sortRows(thumbnails);
        const lines_bottom = try self.layOutLines(thumbnails, columns, sizes);
        try self.header_fonts.ensure(self.panel.allocator);

        const is_collapsed = list_settings.collapsed;
        const panel_height = panel_header.panelHeight(is_collapsed, lines_bottom + list_look.BOTTOM_PADDING);
        const bitmap = try self.panel.beginFrame(panel_width, panel_height);
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();

        panel_chrome.fillBody(canvas);
        panel_chrome.fillHeader(canvas, &panel_header_state);

        // A font still selected into the DC can't be deleted when the settings change.
        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        const summary_left = panel_chrome.drawHeaderText(dc, &self.header_fonts, &panel_header_state);
        if (is_collapsed) {
            self.drawSummary(canvas, dc, thumbnails, active_source_hwnd, summary_left, panel_header_state.layout.content_right);
        } else {
            var row_text: ?RowText = null;
            if (self.panel.font.handle) |regular_font| {
                if (self.panel.small_font.handle) |small_font| {
                    const name_font = self.bold_font.handle orelse regular_font;
                    _ = win32.SelectObject(dc, small_font);
                    const small_height = panel_chrome.lineHeight(dc);
                    _ = win32.SelectObject(dc, name_font);
                    row_text = .{ .name_font = name_font, .small_font = small_font, .slot_font = self.small_bold_font.handle orelse small_font, .name_height = panel_chrome.lineHeight(dc), .small_height = small_height };
                }
            }
            for (self.lines.items) |line| {
                if (line.is_heading) {
                    self.drawHeading(canvas, dc, thumbnails, line, panel_width);
                    continue;
                }
                for (0..line.row_count) |column| self.drawRow(bitmap, &thumbnails[self.rows.items[line.first_row + column]], line, column, sizes.column_width, row_text, active_source_hwnd);
            }
        }

        panel_chrome.finish(canvas);
        self.panel.present(list_settings.opacity, signature);
    }

    /// The active client, and how many are alerting, after the title of a collapsed list.
    fn drawSummary(self: *const ListWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND, left: i32, right: i32) void {
        var active: ?*const ThumbnailWindow = null;
        var alert_count: usize = 0;
        for (self.rows.items) |thumbnail_index| {
            const thumbnail = &thumbnails[thumbnail_index];
            switch (thumbnail.effectiveRenderState(active_source_hwnd)) {
                .active => active = thumbnail,
                .alert => alert_count += 1,
                .inactive, .minimized, .dragging => {},
            }
        }
        var alert_buffer: [ALERT_TEXT_MAX]u8 = undefined;
        const alert_text = if (alert_count == 0) "" else alertText(&alert_buffer, alert_count);
        var text_left = left;
        if (active) |thumbnail| text_left = panel_chrome.drawSummaryDot(canvas, left, self.resolveActiveBadgeColor(thumbnail));
        const runs = [_]panel_chrome.Run{
            .{ .text = if (active) |thumbnail| thumbnail.cached_display_name else "", .color = palette.TEXT_SECONDARY },
            .{ .text = alert_text, .color = palette.ERROR, .fill = palette.ERROR_TINT },
        };
        panel_chrome.drawSummary(canvas, dc, &self.header_fonts, text_left, right, &runs);
    }

    /// Reorders `rows` so clients in one system sit together, as list_look.systemGroupOrder ranks them.
    fn groupRows(self: *ListWindow, thumbnails: []const ThumbnailWindow) !void {
        const allocator = self.panel.allocator;
        const names = try allocator.alloc([]const u8, self.rows.items.len);
        defer allocator.free(names);
        for (self.rows.items, names) |thumbnail_index, *name| name.* = thumbnails[thumbnail_index].system_name;
        const order = try list_look.systemGroupOrder(allocator, names);
        defer allocator.free(order);
        const sorted = try allocator.dupe(usize, self.rows.items);
        defer allocator.free(sorted);
        for (order, self.rows.items) |position, *row| row.* = sorted[position];
    }

    /// Fills `lines`: a heading over each system's rows while grouped, every line two lines of text tall while the list shows stats; returns the last line's bottom.
    fn layOutLines(self: *ListWindow, thumbnails: []const ThumbnailWindow, columns: i32, sizes: list_look.Metrics) !i32 {
        const allocator = self.panel.allocator;
        const column_count: usize = @intCast(columns);
        const rows = self.rows.items;
        // Room for stats whether or not there are any yet, so the list doesn't grow when combat starts.
        const shows_stats = list_look.showsAnyStat(self.statSettings());
        self.lines.clearRetainingCapacity();
        var top = sizes.header_height;
        var first: usize = 0;
        while (first < rows.len) {
            var group_end = rows.len;
            if (self.config.listView.groupBySystem) {
                const system_name = thumbnails[rows[first]].system_name;
                group_end = first + 1;
                while (group_end < rows.len and std.mem.eql(u8, thumbnails[rows[group_end]].system_name, system_name)) group_end += 1;
                try self.lines.append(allocator, .{ .top = top, .bottom = top + list_look.GROUP_HEADING_HEIGHT, .first_row = first, .row_count = group_end - first, .is_heading = true });
                top += list_look.GROUP_HEADING_HEIGHT;
            }
            var line_first = first;
            while (line_first < group_end) {
                const line_end = @min(line_first + column_count, group_end);
                const height = if (shows_stats) sizes.stats_row_height else sizes.row_height;
                try self.lines.append(allocator, .{ .top = top, .bottom = top + height, .first_row = line_first, .row_count = line_end - line_first });
                top += height;
                line_first = line_end;
            }
            first = group_end;
        }
        return top;
    }

    /// The system's name and security, a rule, and how many clients are there.
    fn drawHeading(self: *const ListWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, thumbnails: []const ThumbnailWindow, line: Line, panel_width: i32) void {
        const font = self.header_fonts.small.handle orelse return;
        _ = win32.SelectObject(dc, font);
        const text_height = panel_chrome.lineHeight(dc);
        const y = line.top + @divTrunc(line.bottom - line.top - text_height, 2);
        const right = panel_width - list_look.PADDING_X;
        const system_name = thumbnails[self.rows.items[line.first_row]].system_name;
        var heading_buffer: [HEADING_TEXT_MAX]u8 = undefined;
        const heading = if (system_name.len == 0) list_look.NO_SYSTEM_TEXT else std.ascii.upperString(&heading_buffer, system_name[0..@min(system_name.len, heading_buffer.len)]);

        var count_buffer: [list_look.COUNT_TEXT_MAX]u8 = undefined;
        const count_text = list_look.countText(&count_buffer, line.row_count);
        const count_left = right - panel_chrome.textWidth(dc, count_text);
        panel_chrome.drawLine(dc, count_text, count_left, y, list_look.MUTED);
        const text_right = count_left - list_look.GROUP_HEADING_GAP;

        var x = list_look.PADDING_X;
        x += panel_chrome.drawFitted(dc, heading, x, y, list_look.MUTED, text_right - x);
        if (self.config.listView.showSystemSecurity) security: {
            const system = universe.findSystem(system_name) orelse break :security;
            const security_tenths = universe.systemInfo(system).security_tenths;
            var security_buffer: [map_text.SECURITY_TEXT_MAX]u8 = undefined;
            x += list_look.SECURITY_GAP;
            if (x < text_right) x += panel_chrome.drawFitted(dc, map_text.securityText(&security_buffer, security_tenths), x, y, map_look.securityTextColor(security_tenths), text_right - x);
        }
        const rule_left = x + list_look.GROUP_HEADING_GAP;
        if (rule_left < text_right) pixel_buffer.fillRect(canvas, @intCast(rule_left), @intCast(line.top + @divTrunc(line.bottom - line.top, 2)), @intCast(text_right - rule_left), 1, list_look.DIVIDER);
    }

    /// `column` is within `line`.
    fn drawRow(self: *const ListWindow, bitmap: *const gdi_overlay.OverlayBitmap, thumbnail: *const ThumbnailWindow, line: Line, column: usize, column_width: i32, row_text: ?RowText, active_source_hwnd: ?win32.HWND) void {
        const list_settings = &self.config.listView;
        const canvas = bitmap.canvas();
        const row_top = line.top;
        const row_height = line.bottom - line.top;
        const column_left: i32 = @as(i32, @intCast(column)) * column_width;
        const render_state = thumbnail.effectiveRenderState(active_source_hwnd);
        const is_active = render_state == .active;
        const is_alert = render_state == .alert;
        const is_excluded = thumbnail.is_excluded_from_cycle;
        const active_color = self.resolveActiveBadgeColor(thumbnail);

        const background: u32 = if (is_alert)
            list_look.alertTint(alertColor(thumbnail))
        else if (is_active)
            list_look.activeTint(active_color)
        else if (self.hovered_source_hwnd == thumbnail.source_hwnd)
            list_look.ROW_HOVER
        else
            list_look.PANEL;
        if (background != list_look.PANEL) pixel_buffer.fillRect(canvas, @intCast(column_left), @intCast(row_top), @intCast(column_width), @intCast(row_height), background);

        const badge_color: u32 = if (is_excluded)
            list_look.BADGE_EXCLUDED
        else if (is_active)
            active_color
        else if (is_alert)
            list_look.BADGE_ALERT
        else if (render_state == .minimized)
            list_look.BADGE_MINIMIZED
        else
            list_look.BADGE_INACTIVE;
        const indicator_style = list_settings.indicatorStyle;
        const center_y = row_top + @divTrunc(row_height, 2);
        drawIndicator(canvas, indicator_style, column_left + list_look.PADDING_X + list_look.LIT_BADGE_RADIUS, center_y, badge_color, if (!is_excluded and (is_active or is_alert)) background else null);

        const text = row_text orelse return;
        const dc = bitmap.mem_dc;
        const text_left = column_left + list_look.textLeft(indicator_style);
        const right_x = column_left + column_width - list_look.PADDING_X;
        var readings_buffer: [list_look.STAT_COUNT]list_look.StatReading = undefined;
        const readings = self.statReadings(thumbnail, &readings_buffer);

        _ = win32.SelectObject(dc, text.slot_font);
        const slot_left = self.drawRightSlot(canvas, dc, thumbnail, center_y - @divTrunc(text.small_height, 2), text.small_height, text_left + list_look.MIN_NAME_WIDTH, right_x);
        const name_right = if (slot_left < right_x) slot_left - list_look.SLOT_GAP else right_x;

        const text_height = if (readings.len > 0) text.name_height + list_look.LINE_GAP + text.small_height else text.name_height;
        const name_y = row_top + @divTrunc(row_height - text_height, 2);
        _ = win32.SelectObject(dc, text.name_font);
        const name_color: u32 = if (is_excluded)
            list_look.MUTED
        else
            thumbnail.cached_list_name_color orelse if (is_active) list_look.ACTIVE_NAME else list_look.NAME;
        _ = panel_chrome.drawFitted(dc, thumbnail.cached_display_name, text_left, name_y, name_color, name_right - text_left);

        if (readings.len == 0) return;
        _ = win32.SelectObject(dc, text.small_font);
        drawStats(dc, list_settings, readings, text_left, name_y + text.name_height + list_look.LINE_GAP, name_right);
    }

    /// The newest notification as a pill, else "Excluded", else the system and any security unless grouped; returns where it starts, or `right` when empty.
    fn drawRightSlot(self: *const ListWindow, canvas: pixel_buffer.Canvas, dc: win32.HDC, thumbnail: *const ThumbnailWindow, y: i32, text_height: i32, min_left: i32, right: i32) i32 {
        const list_settings = &self.config.listView;
        var notification_buffer: [TEXT_BUFFER_SIZE]u8 = undefined;
        const newest = if (list_settings.showNotifications) thumbnail.notifications.newestWithText() else null;
        if (newest) |notification| {
            const line = template.oneLine(notification.text, &notification_buffer);
            const text_color = notification.text_color_override orelse list_settings.notificationColor;
            const lead: Lead = if (notification.lead) |lead| .{ .length = @min(lead.length, line.len), .color = lead.color } else .{ .length = 0, .color = text_color };
            return drawPill(canvas, dc, line, lead, text_color, alertColor(thumbnail), y, text_height, min_left, right);
        }
        if (thumbnail.is_excluded_from_cycle) return drawRightAligned(dc, "Excluded", y, list_look.MUTED, min_left, right);
        // Grouped rows sit under their system's heading.
        if (!list_settings.showSystemName or list_settings.groupBySystem or thumbnail.system_name.len == 0) return right;

        var system_right = right;
        if (list_settings.showSystemSecurity) security: {
            const system = universe.findSystem(thumbnail.system_name) orelse break :security;
            const security_tenths = universe.systemInfo(system).security_tenths;
            var security_buffer: [map_text.SECURITY_TEXT_MAX]u8 = undefined;
            system_right = drawRightAligned(dc, map_text.securityText(&security_buffer, security_tenths), y, map_look.securityTextColor(security_tenths), min_left, right) - list_look.SECURITY_GAP;
        }
        return drawRightAligned(dc, thumbnail.system_name, y, thumbnail.cached_system_color, min_left, system_right);
    }
};

/// A notification's first bytes, drawn in their own colour.
const Lead = struct { length: usize, color: u32 };

fn alertText(buffer: *[ALERT_TEXT_MAX]u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ count, if (count == 1) "alert" else "alerts" }) catch unreachable;
}

/// The newest notification's border colour, which tints an alerting row.
fn alertColor(thumbnail: *const ThumbnailWindow) u32 {
    const notification = thumbnail.notifications.newest() orelse return list_look.BADGE_ALERT;
    return notification.border_color_override orelse list_look.BADGE_ALERT;
}

/// `glow_background` is set for a lit dot, whose halo is blended onto it.
fn drawIndicator(canvas: pixel_buffer.Canvas, style: types.ListIndicatorStyle, center_x: i32, center_y: i32, argb: u32, glow_background: ?u32) void {
    const radius = if (glow_background != null) list_look.LIT_BADGE_RADIUS else list_look.BADGE_RADIUS;
    switch (style) {
        .Dot => {
            if (glow_background) |background| pixel_buffer.fillCircle(canvas, center_x, center_y, @floatFromInt(radius + list_look.GLOW_WIDTH), list_look.glowColor(argb, background));
            pixel_buffer.fillCircle(canvas, center_x, center_y, @floatFromInt(radius), argb);
        },
        .Square => pixel_buffer.fillRect(canvas, @intCast(center_x - radius), @intCast(center_y - radius), @intCast(radius * 2), @intCast(radius * 2), argb),
        .None => {},
    }
}

/// Ending at `right`, or cut short to start at `min_left`; returns where it starts, or `right` when there's no room.
fn drawRightAligned(dc: win32.HDC, text: []const u8, y: i32, argb: u32, min_left: i32, right: i32) i32 {
    if (right <= min_left) return right;
    const left = @max(min_left, right - panel_chrome.wideTextWidth(dc, text));
    _ = panel_chrome.drawFitted(dc, text, left, y, argb, right - left);
    return left;
}

/// Outlined and filled in shades of `alert_color`, ending at `right`; returns where it starts, or `right` when there's no room.
fn drawPill(canvas: pixel_buffer.Canvas, dc: win32.HDC, text: []const u8, lead: Lead, text_color: u32, alert_color: u32, y: i32, text_height: i32, min_left: i32, right: i32) i32 {
    const padding = list_look.PILL_PADDING_X;
    const room = right - min_left - 2 * padding;
    if (room <= 0) return right;
    const text_width = @min(panel_chrome.wideTextWidth(dc, text), room);
    const left = right - text_width - 2 * padding;
    const top = y - 1;
    const pill_width: usize = @intCast(text_width + 2 * padding);
    const pill_height: usize = @intCast(text_height + 2);
    pixel_buffer.fillRoundedRect(canvas, @intCast(left), @intCast(top), pill_width, pill_height, list_look.PILL_RADIUS, list_look.pillBorder(alert_color));
    pixel_buffer.fillRoundedRect(canvas, @intCast(left + 1), @intCast(top + 1), pill_width - 2, pill_height - 2, list_look.PILL_RADIUS - 1, list_look.pillFill(alert_color));
    const lead_width = panel_chrome.drawFitted(dc, text[0..lead.length], left + padding, y, lead.color, text_width);
    _ = panel_chrome.drawFitted(dc, text[lead.length..], left + padding + lead_width, y, text_color, text_width - lead_width);
    return left;
}

/// Each reading in its own colour, left to right; stops at the first that won't fit before `right`.
fn drawStats(dc: win32.HDC, list_settings: *const config_mod.ListViewConfig, readings: []const list_look.StatReading, left: i32, y: i32, right: i32) void {
    var x = left;
    for (readings) |reading| {
        var stat_buffer: [list_look.STAT_TEXT_MAX]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&stat_buffer);
        list_look.writeStat(&writer, reading);
        const stat_text = writer.buffered();
        const width = panel_chrome.textWidth(dc, stat_text);
        if (x + width > right) return;
        panel_chrome.drawLine(dc, stat_text, x, y, list_look.statColor(list_settings, reading.stat));
        x += width + list_look.STAT_GAP;
    }
}

/// Length-prefixed, so swapping "Bob" and "BobBob" can't leave the hashed byte stream unchanged.
fn hashString(hasher: *std.hash.Wyhash, text: []const u8) void {
    hasher.update(std.mem.asBytes(&text.len));
    hasher.update(text);
}
