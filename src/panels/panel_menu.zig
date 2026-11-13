//! The panels' ⋯ menu window: a borderless popup under the button, shared by the Client List and the History and Intel panels; main thread only.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const palette = @import("palette.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_menu_look = @import("panel_menu_look.zig");
const popup_look = @import("popup_look.zig");
const segmented = @import("segmented.zig");
const box = @import("../util/box.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const log = @import("../log.zig");

const Box = box.Box;
const Canvas = pixel_buffer.Canvas;
const PanelWindow = panel_window.PanelWindow;
const Contents = panel_menu_look.Contents;
const Action = panel_menu_look.Action;
const Hit = panel_menu_look.Hit;
const Row = panel_menu_look.Row;
const slog = log.Scoped("panel_menu");

const MENU_WINDOW_CLASS = "EVE_PANEL_MENU_CLASS";
const POLL_TIMER_ID: usize = 1;
/// How often an open menu looks for a press outside it, which a window that never takes focus isn't told of.
const POLL_INTERVAL_MS: u32 = 50;
/// Between the button and the menu.
const BUTTON_GAP: i32 = 2;

const Class = gdi_overlay.WindowClass(MENU_WINDOW_CLASS, windowProc);

/// What the menu asks of the panel that opened it.
pub const Owner = struct {
    context: *anyopaque,
    contents: *const fn (context: *anyopaque) Contents,
    run: *const fn (context: *anyopaque, action: Action) void,
};

/// Lives inside its panel's window, which deinits it.
pub const PanelMenu = struct {
    /// Null while closed.
    window: ?PanelWindow = null,
    owner: ?Owner = null,
    /// The button that opened it, in screen pixels; a press there is the button's own.
    button: Box = undefined,
    layout: panel_menu_look.Layout = .{},
    row_buf: [panel_menu_look.MAX_ROWS]Row = undefined,
    row_count: usize = 0,
    hovered: ?Hit = null,
    /// The slider's value while it's dragged, shown but not yet saved.
    dragged_opacity: ?u8 = null,
    is_tracking_leave: bool = false,
    label_font: gdi_overlay.CachedFont = .{},
    /// The picked order's label.
    picked_font: gdi_overlay.CachedFont = .{},
    small_font: gdi_overlay.CachedFont = .{},

    fn isOpen(self: *const PanelMenu) bool {
        return self.window != null;
    }

    /// Opens it under `button`, a panel's ⋯ in screen pixels, or closes it if it's open.
    pub fn toggle(self: *PanelMenu, allocator: std.mem.Allocator, instance: win32.HINSTANCE, owner: Owner, button: Box) void {
        if (self.isOpen()) {
            self.close();
            return;
        }
        self.open(allocator, instance, owner, button) catch |err| {
            slog.err("Failed to open a panel menu: {}", .{err});
            self.close();
        };
    }

    pub fn close(self: *PanelMenu) void {
        if (self.window) |*window| {
            _ = win32.KillTimer(window.hwnd, POLL_TIMER_ID);
            // Cleared first, so the release's WM_CAPTURECHANGED doesn't save a half-dragged value.
            if (self.dragged_opacity != null) {
                self.dragged_opacity = null;
                _ = win32.ReleaseCapture();
            }
            window.deinit();
        }
        self.window = null;
        self.owner = null;
        self.hovered = null;
        self.dragged_opacity = null;
        self.is_tracking_leave = false;
    }

    /// `allocator` is the one toggle was given.
    pub fn deinit(self: *PanelMenu, allocator: std.mem.Allocator) void {
        self.close();
        self.label_font.deinit(allocator);
        self.picked_font.deinit(allocator);
        self.small_font.deinit(allocator);
    }

    /// Draws it again if it's open, e.g. after its panel's settings changed.
    pub fn refresh(self: *PanelMenu) void {
        const window = if (self.window) |*shown| shown else return;
        // Turning on Keep on Top raises the panel over its own menu.
        window.raiseTopmost();
        self.render() catch |err| {
            slog.err("Failed to draw a panel menu: {}", .{err});
        };
    }

    fn open(self: *PanelMenu, allocator: std.mem.Allocator, instance: win32.HINSTANCE, owner: Owner, button: Box) !void {
        try Class.register(instance);
        try self.label_font.ensure(allocator, "panel menu", palette.FACE, palette.FONT_SIZE, .Regular);
        try self.picked_font.ensure(allocator, "panel menu picked", segmented.PICKED_FACE, palette.FONT_SIZE, .Regular);
        try self.small_font.ensure(allocator, "panel menu small", palette.FACE, palette.SMALL_FONT_SIZE, .Regular);
        self.owner = owner;
        self.button = button;
        const left = button.right - panel_menu_look.WIDTH;
        const top = button.bottom + BUTTON_GAP;
        self.window = try PanelWindow.init(allocator, instance, MENU_WINDOW_CLASS, "EVE Panel Menu", .{ .left = left, .top = top, .right = left + panel_menu_look.WIDTH, .bottom = top + 1 }, true);
        try self.window.?.attachOwner(self);
        if (win32.SetTimer(self.window.?.hwnd, POLL_TIMER_ID, POLL_INTERVAL_MS, null) == 0) slog.warn("Failed to watch for presses outside a panel menu, so only its rows and button close it", .{});
        try self.render();
    }

    fn rows(self: *const PanelMenu) []const Row {
        return self.row_buf[0..self.row_count];
    }

    fn render(self: *PanelMenu) !void {
        const window = if (self.window) |*shown| shown else return;
        const owner = self.owner orelse return;
        var contents = owner.contents(owner.context);
        if (self.dragged_opacity) |opacity| contents.opacity = opacity;
        self.row_count = panel_menu_look.rows(&contents, &self.row_buf).len;
        const height = panel_menu_look.layOut(self.rows(), @splat(0)).height;
        const label_font = self.label_font.handle orelse return error.MissingFont;
        const small_font = self.small_font.handle orelse return error.MissingFont;
        const picked_font = self.picked_font.handle orelse return error.MissingFont;

        const bitmap = try window.beginFrame(panel_menu_look.WIDTH, height);
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        // Sized for the picked label, so the segments don't move as the pick does; the menu's fonts outlive the DC's hold on them.
        _ = win32.SelectObject(dc, picked_font);
        var segment_widths: [panel_menu_look.ORDER_COUNT]i32 = undefined;
        for (panel_menu_look.ORDER_OPTIONS, &segment_widths) |order, *width| width.* = panel_chrome.wideTextWidth(dc, panel_menu_look.orderLabel(order));
        self.layout = panel_menu_look.layOut(self.rows(), segment_widths);
        self.place(window, height);

        popup_look.drawPopupBox(canvas, .{ .left = 0, .top = 0, .right = panel_menu_look.WIDTH, .bottom = height });
        for (self.rows(), self.layout.boxes[0..self.row_count], 0..) |row, row_box, index| {
            self.drawRow(canvas, dc, &contents, row, row_box, index, .{ .label = label_font, .picked = picked_font, .small = small_font });
        }
        pixel_buffer.fixTextAlpha(canvas);
        // Drawn only when something changed, so no signature is kept.
        window.present(255, 0);
    }

    /// Under the button, or over it when there's no room below; kept on its monitor.
    fn place(self: *const PanelMenu, window: *PanelWindow, height: i32) void {
        var left = self.button.right - panel_menu_look.WIDTH;
        var top = self.button.bottom + BUTTON_GAP;
        const corner: win32.POINT = .{ .x = self.button.left, .y = self.button.bottom };
        const monitor = win32.nearestMonitor(corner) orelse return window.followPosition(left, top);
        const work = win32.monitorWorkRect(monitor) orelse return window.followPosition(left, top);
        if (top + height > work.bottom) top = self.button.top - BUTTON_GAP - height;
        left = std.math.clamp(left, work.left, @max(work.left, work.right - panel_menu_look.WIDTH));
        top = std.math.clamp(top, work.top, @max(work.top, work.bottom - height));
        window.followPosition(left, top);
    }

    fn drawRow(self: *const PanelMenu, canvas: Canvas, dc: win32.HDC, contents: *const Contents, row: Row, row_box: Box, index: usize, fonts: Fonts) void {
        const middle = row_box.top + @divTrunc(row_box.bottom - row_box.top, 2);
        const text_left = row_box.left + popup_look.MENU_TEXT_LEFT;
        const text_right = row_box.right - popup_look.MENU_RIGHT_INSET;
        const is_lit = if (self.hovered) |hit| std.meta.eql(hit, Hit{ .row = index }) else false;
        switch (row) {
            .rule => pixel_buffer.fillRect(canvas, @intCast(row_box.left + panel_menu_look.RULE_INSET), @intCast(middle), @intCast(row_box.right - row_box.left - 2 * panel_menu_look.RULE_INSET), 1, popup_look.MENU_RULE),
            .toggle => |setting| {
                if (is_lit) fillLit(canvas, row_box);
                if (contents.isOn(setting)) popup_look.drawCheck(canvas, row_box.left + popup_look.MENU_CHECK_LEFT, middle, contents.accent);
                drawLabel(dc, fonts.label, panel_menu_look.toggleLabel(setting), text_left, middle, text_right, palette.TEXT);
            },
            .command => |command| {
                if (is_lit) fillLit(canvas, row_box);
                const label = switch (command) {
                    .settings => contents.settings_label,
                    .hide => panel_menu_look.HIDE_LABEL,
                };
                drawLabel(dc, fonts.label, label, text_left, middle, text_right, palette.TEXT);
            },
            .order => {
                const bar = self.layout.order_bar;
                drawLabel(dc, fonts.label, panel_menu_look.ORDER_LABEL, text_left, middle, bar.left, palette.TEXT);
                segmented.drawBar(canvas, bar);
                const picked = contents.order orelse return;
                for (panel_menu_look.ORDER_OPTIONS, self.layout.segments) |order, segment| {
                    const is_hovered = if (self.hovered) |hit| std.meta.eql(hit, Hit{ .order = order }) else false;
                    const state: segmented.State = if (order == picked) .picked else if (is_hovered) .hovered else .idle;
                    if (segmented.buttonFill(state, contents.accent)) |fill| segmented.fillButton(canvas, segment, fill);
                    _ = win32.SelectObject(dc, if (state == .picked) fonts.picked else fonts.label);
                    const label = panel_menu_look.orderLabel(order);
                    const label_width = panel_chrome.wideTextWidth(dc, label);
                    panel_chrome.drawWideLine(dc, label, segment.left + @divTrunc(segment.right - segment.left - label_width, 2), middle - @divTrunc(panel_chrome.lineHeight(dc), 2), segmented.labelColor(state, contents.accent));
                }
            },
            .opacity => {
                const track = self.layout.track;
                drawLabel(dc, fonts.label, panel_menu_look.OPACITY_LABEL, text_left, middle, track.left, palette.TEXT);
                const track_width: usize = @intCast(track.right - track.left);
                const track_height: usize = @intCast(track.bottom - track.top);
                pixel_buffer.fillRoundedRect(canvas, @intCast(track.left), @intCast(track.top), track_width, track_height, track_height / 2, palette.BORDER);
                const knob_x = panel_menu_look.knobX(track, contents.opacity);
                if (knob_x > track.left) pixel_buffer.fillRoundedRect(canvas, @intCast(track.left), @intCast(track.top), @intCast(knob_x - track.left), track_height, track_height / 2, contents.accent);
                pixel_buffer.fillCircle(canvas, knob_x, middle, @floatFromInt(panel_menu_look.KNOB_RADIUS), contents.accent);
                var percent_buf: [panel_menu_look.PERCENT_TEXT_MAX]u8 = undefined;
                const percent = panel_menu_look.percentText(&percent_buf, contents.opacity);
                _ = win32.SelectObject(dc, fonts.small);
                panel_chrome.drawLine(dc, percent, text_right - panel_chrome.textWidth(dc, percent), middle - @divTrunc(panel_chrome.lineHeight(dc), 2), palette.MUTED);
            },
        }
    }

    fn onMouseMove(self: *PanelMenu, hwnd: win32.HWND, x: i32, y: i32) void {
        if (self.dragged_opacity != null) {
            self.dragTo(x, false);
            return;
        }
        if (!self.is_tracking_leave) self.is_tracking_leave = win32.trackMouseLeave(hwnd);
        const hit = self.layout.hitAt(self.rows(), x, y);
        if (std.meta.eql(hit, self.hovered)) return;
        self.hovered = hit;
        self.refresh();
    }

    /// Toggles and the order stay open for another change; a command closes the menu before its panel acts, as hiding the panel tears the menu down.
    fn onPress(self: *PanelMenu, hwnd: win32.HWND, x: i32, y: i32) void {
        const hit = self.layout.hitAt(self.rows(), x, y) orelse return;
        const owner = self.owner orelse return;
        switch (hit) {
            .row => |index| switch (self.rows()[index]) {
                .toggle => |setting| {
                    owner.run(owner.context, .{ .toggle = setting });
                    self.refresh();
                },
                .command => |command| {
                    self.close();
                    owner.run(owner.context, .{ .command = command });
                },
                .rule, .order, .opacity => {},
            },
            .order => |order| {
                owner.run(owner.context, .{ .order = order });
                self.refresh();
            },
            .opacity => {
                _ = win32.SetCapture(hwnd);
                self.dragged_opacity = panel_menu_look.opacityAt(self.layout.track, x);
                self.dragTo(x, false);
            },
        }
    }

    fn onRelease(self: *PanelMenu, x: i32) void {
        if (self.dragged_opacity == null) return;
        // Cleared first, so the release's WM_CAPTURECHANGED leaves the saving to dragTo.
        self.dragged_opacity = null;
        _ = win32.ReleaseCapture();
        self.dragTo(x, true);
    }

    /// Saves the dragged value, as no release will come.
    fn onCaptureLost(self: *PanelMenu) void {
        const opacity = self.dragged_opacity orelse return;
        const owner = self.owner orelse return;
        self.dragged_opacity = null;
        owner.run(owner.context, .{ .opacity = .{ .value = opacity, .is_final = true } });
        self.refresh();
    }

    /// Shows the slider at `x` and tells the panel; `is_final` saves it and ends the drag.
    fn dragTo(self: *PanelMenu, x: i32, is_final: bool) void {
        const owner = self.owner orelse return;
        const opacity = panel_menu_look.opacityAt(self.layout.track, x);
        self.dragged_opacity = if (is_final) null else opacity;
        owner.run(owner.context, .{ .opacity = .{ .value = opacity, .is_final = is_final } });
        self.refresh();
    }

    /// Closes on a press outside both the menu and its button, or on Escape.
    fn poll(self: *PanelMenu) void {
        if (self.dragged_opacity != null) return;
        if (win32.isKeyDown(win32.VK_ESCAPE)) return self.close();
        if (!win32.isKeyDown(win32.VK_LBUTTON) and !win32.isKeyDown(win32.VK_RBUTTON)) return;
        var cursor: win32.POINT = undefined;
        // Debug, as the poll runs every POLL_INTERVAL_MS; the next one tries again.
        if (!win32.toBool(win32.GetCursorPos(&cursor))) {
            slog.debug("Failed to read the cursor for a panel menu's outside press: error {d}", .{win32.GetLastError()});
            return;
        }
        if (self.button.containsPoint(cursor.x, cursor.y)) return;
        const window = self.window orelse return;
        const bounds = window.bounds() orelse {
            slog.debug("Failed to read a panel menu's bounds for its outside press", .{});
            return;
        };
        if (cursor.x >= bounds.left and cursor.x < bounds.right and cursor.y >= bounds.top and cursor.y < bounds.bottom) return;
        self.close();
    }
};

const Fonts = struct {
    label: win32.HFONT,
    picked: win32.HFONT,
    small: win32.HFONT,
};

/// `Window` has `menuContents()`, returning Contents, and `runMenuAction(action)`.
pub fn ownerFor(comptime Window: type, window: *Window) Owner {
    const Thunks = struct {
        fn contents(context: *anyopaque) Contents {
            const owner: *Window = @ptrCast(@alignCast(context));
            return owner.menuContents();
        }

        fn run(context: *anyopaque, action: Action) void {
            const owner: *Window = @ptrCast(@alignCast(context));
            owner.runMenuAction(action);
        }
    };
    return .{ .context = window, .contents = Thunks.contents, .run = Thunks.run };
}

/// `button` is in the panel's own pixels; its screen box, or null if the panel's position can't be read.
pub fn screenBox(panel: *const PanelWindow, button: Box) ?Box {
    const top_left = panel.topLeft() orelse return null;
    return .{ .left = top_left.x + button.left, .top = top_left.y + button.top, .right = top_left.x + button.right, .bottom = top_left.y + button.bottom };
}

fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    const menu = panel_window.ownerOf(PanelMenu, hwnd) orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
    switch (msg) {
        win32.WM_MOUSEMOVE => menu.onMouseMove(hwnd, win32.lparamX(lParam), win32.lparamY(lParam)),
        win32.WM_MOUSELEAVE => {
            menu.is_tracking_leave = false;
            if (menu.hovered != null) {
                menu.hovered = null;
                menu.refresh();
            }
        },
        win32.WM_LBUTTONDOWN => menu.onPress(hwnd, win32.lparamX(lParam), win32.lparamY(lParam)),
        win32.WM_LBUTTONUP => menu.onRelease(win32.lparamX(lParam)),
        win32.WM_CAPTURECHANGED => menu.onCaptureLost(),
        win32.WM_TIMER => if (wParam == POLL_TIMER_ID) menu.poll(),
        win32.WM_ERASEBKGND => return win32.TRUE,
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
    return 0;
}

fn fillLit(canvas: Canvas, row_box: Box) void {
    pixel_buffer.fillRoundedRect(canvas, @intCast(row_box.left), @intCast(row_box.top), @intCast(row_box.right - row_box.left), @intCast(row_box.bottom - row_box.top), popup_look.ROW_RADIUS, popup_look.MENU_LIT);
}

/// Centred on `middle`, cut short at `right`.
fn drawLabel(dc: win32.HDC, font: win32.HFONT, label: []const u8, left: i32, middle: i32, right: i32, argb: u32) void {
    _ = win32.SelectObject(dc, font);
    _ = panel_chrome.drawFitted(dc, label, left, middle - @divTrunc(panel_chrome.lineHeight(dc), 2), argb, right - left);
}
