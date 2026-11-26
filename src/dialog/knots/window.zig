//! The open configuration window: what its frames keep between them, built as it opens and freed as it closes; main thread only.
const std = @import("std");
const host_mod = @import("host.zig");
const session_mod = @import("session.zig");
const widgets_mod = @import("widgets.zig");
const bind_mod = @import("bind.zig");
const search_mod = @import("search.zig");
const status_mod = @import("status.zig");
const hotkey_mod = @import("hotkey.zig");
const suggest_mod = @import("suggest.zig");
const images_mod = @import("images.zig");
const form_mod = @import("form.zig");
const header_mod = @import("header.zig");
const profiles_mod = @import("profiles.zig");
const import_dialog_mod = @import("import_dialog.zig");
const update_notice_mod = @import("update_notice.zig");
const backups_mod = @import("tabs/backups.zig");
const characters_mod = @import("tabs/characters.zig");
const chat_alerts_mod = @import("tabs/chat_alerts.zig");
const client_list_mod = @import("tabs/client_list.zig");
const client_windows_mod = @import("tabs/client_windows.zig");
const display_mod = @import("tabs/display.zig");
const event_alerts_mod = @import("tabs/event_alerts.zig");
const hotkeys_mod = @import("tabs/hotkeys.zig");
const hotkey_groups_mod = @import("tabs/hotkey_groups.zig");
const mining_mod = @import("tabs/mining.zig");
const notification_history_mod = @import("tabs/notification_history.zig");
const performance_mod = @import("tabs/performance.zig");
const placement_mod = @import("tabs/placement.zig");
const system_colors_mod = @import("tabs/system_colors.zig");
const chips_mod = @import("tabs/thumbnails/chips.zig");
const stage_mod = @import("tabs/thumbnails/stage.zig");
const window_filters_mod = @import("tabs/window_filters.zig");

const Host = host_mod.Host;

/// What the window remembers from one opening to the next, e.g. the tab it was on; Host keeps it.
pub const Kept = struct {
    form: form_mod.Kept = .{},
    characters: characters_mod.Kept = .{},
    chat_alerts: chat_alerts_mod.Kept = .{},
    display: display_mod.Kept = .{},
    event_alerts: event_alerts_mod.Kept = .{},
    hotkey_groups: hotkey_groups_mod.Kept = .{},
    placement: placement_mod.Kept = .{},
    system_colors: system_colors_mod.Kept = .{},
    chips: chips_mod.Kept = .{},
    stage: stage_mod.Kept = .{},
};

pub const Window = struct {
    allocator: std.mem.Allocator,
    /// Borrows the app's, which outlives every window.
    host: *Host,
    /// Borrows the host's.
    session: *session_mod.Session,
    /// Borrows the host's.
    kept: *Kept,
    widgets: widgets_mod.Widgets,
    bind: bind_mod.Bind,
    search: search_mod.Search,
    status: status_mod.Status = .{},
    hotkey: hotkey_mod.Recorder,
    suggest: suggest_mod.Suggest = .{},
    images: images_mod.Images,
    form: form_mod.State = .{},
    header: header_mod.State = .{},
    profiles: profiles_mod.State = .{},
    import_dialog: import_dialog_mod.State,
    update_notice: update_notice_mod.State = .{},
    backups: backups_mod.State = .{},
    client_list: client_list_mod.State = .{},
    client_windows: client_windows_mod.State = .{},
    hotkeys: hotkeys_mod.State = .{},
    hotkey_groups: hotkey_groups_mod.State = .{},
    mining: mining_mod.State = .{},
    notification_history: notification_history_mod.State = .{},
    performance: performance_mod.State = .{},
    stage: stage_mod.State = .{},
    window_filters: window_filters_mod.State = .{},

    /// Fills `self` in place, since its parts point at one another; `on_capture` is the hotkey recorder's.
    pub fn init(self: *Window, host: *Host, on_capture: *const fn () void) void {
        const allocator = host.allocator;
        self.* = .{
            .allocator = allocator,
            .host = host,
            .session = &host.session,
            .kept = &host.kept,
            .widgets = .{ .search = &self.search },
            .bind = .{ .allocator = allocator, .widgets = &self.widgets },
            .search = .init(allocator),
            .hotkey = .{ .allocator = allocator, .session = &host.session, .widgets = &self.widgets, .on_capture = on_capture },
            .images = .init(allocator),
            .import_dialog = .init(allocator),
        };
    }

    pub fn deinit(self: *Window) void {
        self.window_filters.deinit();
        self.hotkey_groups.deinit(self.allocator);
        self.hotkeys.deinit();
        self.performance.deinit();
        self.client_windows.deinit();
        self.backups.deinit();
        self.update_notice.deinit(self.allocator);
        self.import_dialog.deinit(self.allocator);
        self.profiles.deinit(self.allocator);
        self.header.deinit(self.allocator);
        self.images.deinit();
        self.hotkey.deinit();
        self.search.deinit();
        self.bind.deinit();
    }
};
