//! Owns the thumbnail for every tracked EVE client: keeps the set in step with Scout, shows which is focused and which are hidden, and renders them each tick.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const scout = @import("../clients/scout.zig");
const exclusions_mod = @import("../clients/exclusions.zig");
const roster_mod = @import("../clients/roster.zig");
const auto_colors_mod = @import("../clients/auto_colors.zig");
const drag_overlays_mod = @import("../drag/overlays.zig");
const spaces = @import("../layout/spaces.zig");
const monitors = @import("../layout/monitors.zig");
const state = @import("state.zig");
const window = @import("window.zig");
const arrange = @import("arrange.zig");
const renderer_mod = @import("renderer.zig");
const look = @import("look.zig");
const universe = @import("../map/universe.zig");
const intel_pins = @import("../map/intel_pins.zig");
const connections = @import("../map/connections.zig");
const log = @import("../log.zig");

const AutoColorStore = auto_colors_mod.AutoColorStore;
const Roster = roster_mod.Roster;
const slog = log.Scoped("thumbnail_set");

pub const ThumbnailWindow = window.ThumbnailWindow;

pub const ThumbnailSet = struct {
    allocator: std.mem.Allocator,
    /// Searched linearly: there are only ever a few dozen.
    thumbnails: std.ArrayList(ThumbnailWindow),
    instance: win32.HINSTANCE,
    /// Read-only: runtime changes go through `store`, reaching the running and saved copies.
    config: *const config_mod.Config,
    /// Borrowed; outlives the thumbnail set.
    store: *config_mod.ProfileStore,
    /// Borrowed from App, which keeps it across a thumbnail set rebuild.
    exclusions: *const exclusions_mod.Exclusions,
    destroy_event_hook: ?win32.HANDLE = null,
    renderer: renderer_mod.Renderer,
    drag_overlays: drag_overlays_mod.DragOverlays,
    /// The roster's active window as the thumbnails last showed it; only reconcileThumbnailStates writes it.
    drawn_active_hwnd: ?win32.HWND = null,
    /// Borrowed from App, which keeps it across a thumbnail set rebuild.
    auto_colors: *AutoColorStore,
    /// Borrowed from App, which keeps it across a thumbnail set rebuild; holds the game state the thumbnails draw.
    roster: *const Roster,
    /// A different mode needs a new ThumbnailSet (see App.onLiveProfileEdited).
    view_mode: types.ViewMode,
    /// Set-wide, so it holds with no thumbnails; each thumbnail follows it, bar those the region tool hides itself.
    visibility: state.VisibilityState = .visible,

    pub const refreshAllThumbnailConfigCaches = arrange.refreshConfigCaches;
    pub const refreshAllThumbnailVisuals = arrange.refreshVisuals;
    pub const repositionAllThumbnails = arrange.repositionAll;
    pub const resizeThumbnailIfNeeded = arrange.resizeIfNeeded;
    pub const reflowIfSpacesActive = arrange.reflowIfSpacesActive;

    /// What App lends the set; each must outlive it.
    pub const Borrowed = struct {
        store: *config_mod.ProfileStore,
        exclusions: *const exclusions_mod.Exclusions,
        auto_colors: *AutoColorStore,
        roster: *const Roster,
    };

    /// Passed in, since input handling sits above thumbnail/.
    pub const Callbacks = struct {
        window_procedures: window.WindowProcs,
        /// The EVENT_OBJECT_DESTROY hook on our own process's windows.
        destroy_hook: win32.WINEVENTPROC,
    };

    const ThumbnailStrings = struct {
        /// Owned.
        character_name: []const u8,
        /// Owned.
        system_name: []const u8,
        /// Owned.
        group_badge_label: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, borrowed: Borrowed, callbacks: Callbacks) !ThumbnailSet {
        const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;
        const config = &borrowed.store.live;

        var thumbnail_set: ThumbnailSet = .{
            .allocator = allocator,
            .thumbnails = .empty,
            .auto_colors = borrowed.auto_colors,
            .roster = borrowed.roster,
            .drag_overlays = .init(allocator),
            .renderer = .init(allocator),
            .instance = instance,
            .config = config,
            .store = borrowed.store,
            .exclusions = borrowed.exclusions,
            .view_mode = config.display.viewMode,
        };
        thumbnail_set.visibility = thumbnail_set.visibility.afterAutoHide(thumbnail_set.focusHide(thumbnail_set.isEveWindowForeground()));

        try window.registerClasses(instance, callbacks.window_procedures);

        // Own process only: removeDestroyedOverlay acts on our overlay windows alone.
        thumbnail_set.destroy_event_hook = win32.setWinEventHookForProcess(win32.EVENT_OBJECT_DESTROY, callbacks.destroy_hook, win32.GetCurrentProcessId());
        if (thumbnail_set.destroy_event_hook == null) slog.err("Failed to set up destroy event hook", .{});

        return thumbnail_set;
    }

    pub fn deinit(self: *ThumbnailSet) void {
        if (self.destroy_event_hook) |hook| _ = win32.UnhookWinEvent(hook);

        self.drag_overlays.deinit();
        self.renderer.deinit();

        for (self.thumbnails.items) |thumbnail| self.destroyThumbnail(thumbnail);
        self.thumbnails.deinit(self.allocator);
    }

    /// Hides the hover zoom once the cursor has left its thumbnail.
    pub fn checkHoverZoom(self: *ThumbnailSet) void {
        self.renderer.hover_zoom.check(self.config, self.thumbnails.items);
    }

    pub fn showHoverZoom(self: *ThumbnailSet, thumbnail: *const ThumbnailWindow) void {
        self.renderer.hover_zoom.show(self.instance, &self.renderer.font_cache, thumbnail, self.config);
    }

    pub fn hideHoverZoom(self: *ThumbnailSet) void {
        self.renderer.hover_zoom.hide();
    }

    /// Goes last in a batch that raises thumbnails, so none is ever composited above the zoom.
    pub fn deferRaiseHoverZoom(self: *const ThumbnailSet, hdwp: win32.HDWP) ?win32.HDWP {
        return self.renderer.hover_zoom.deferRaise(hdwp);
    }

    /// Once per drag of either of `dragging_hwnd`'s windows.
    pub fn showDragOverlays(self: *ThumbnailSet, dragging_hwnd: win32.HWND) void {
        const dragged_character = if (self.getThumbnailByOverlayHwnd(dragging_hwnd)) |thumbnail| thumbnail.character_name else null;
        self.drag_overlays.show(self.instance, &self.renderer.font_cache, self.config, dragging_hwnd, dragged_character);
    }

    pub fn hideDragOverlays(self: *ThumbnailSet) void {
        self.drag_overlays.hide();
    }

    /// Cached for the drag by showDragOverlays; null when the ghost outlines aren't shown.
    pub fn dragGhostGroups(self: *const ThumbnailSet) ?[]const drag_overlays_mod.GhostGroup {
        return self.drag_overlays.ghostGroups();
    }

    pub fn renderThumbnail(self: *ThumbnailSet, thumbnail: *ThumbnailWindow) !void {
        const is_excluded = self.exclusions.contains(thumbnail.character_name);
        try self.renderer.render(self.config, thumbnail, self.roster.readingsOf(thumbnail.source_hwnd), is_excluded, self.roster.active_hwnd);
    }

    /// Logs a failure, with `context` in the message, instead of propagating it.
    pub fn renderThumbnailLogged(self: *ThumbnailSet, thumbnail: *ThumbnailWindow, context: []const u8) void {
        self.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail for '{s}' ({s}): {}", .{ thumbnail.character_name, context, err });
        };
    }

    pub fn hasThumbnail(self: *const ThumbnailSet, source_hwnd: win32.HWND) bool {
        return self.indexOfSource(source_hwnd) != null;
    }

    /// Returns whether a reflow is needed to refill the spaces.
    fn cleanupClosedThumbnails(self: *ThumbnailSet, closed_windows: []const scout.ClosedWindow) bool {
        // By source_hwnd, not name: multiple windows can share a name (e.g. "EVE").
        var removed_any = false;
        for (closed_windows) |closed| {
            const index = self.indexOfSource(closed.hwnd) orelse continue;
            slog.info("Cleaning up closed thumbnail for {s}", .{self.thumbnails.items[index].character_name});
            self.removeThumbnailAt(index);
            removed_any = true;
        }
        return removed_any and spaces.anyActive(self.config);
    }

    /// Our own windows only; a source window closing is Scout's to report.
    pub fn removeDestroyedOverlay(self: *ThumbnailSet, hwnd: win32.HWND) void {
        const index = self.indexOfOverlay(hwnd) orelse return;
        slog.info("Window closed (event), removing thumbnail for {s}", .{self.thumbnails.items[index].character_name});
        self.removeThumbnailAt(index);
    }

    /// Don't keep the pointer across anything that adds or removes thumbnails.
    pub fn getThumbnailBySourceHwnd(self: *ThumbnailSet, source_hwnd: win32.HWND) ?*ThumbnailWindow {
        return &self.thumbnails.items[self.indexOfSource(source_hwnd) orelse return null];
    }

    /// Don't keep the pointer across anything that adds or removes thumbnails.
    pub fn getThumbnailByOverlayHwnd(self: *ThumbnailSet, hwnd: win32.HWND) ?*ThumbnailWindow {
        return &self.thumbnails.items[self.indexOfOverlay(hwnd) orelse return null];
    }

    /// Polled on demand, since a hotkey press carries no window of its own.
    pub fn thumbnailUnderCursor(self: *ThumbnailSet) ?*ThumbnailWindow {
        var cursor: win32.POINT = undefined;
        if (!win32.toBool(win32.GetCursorPos(&cursor))) {
            slog.warn("Failed to get the cursor position to find the thumbnail under it", .{});
            return null;
        }

        const hwnd_at_cursor = win32.WindowFromPoint(cursor) orelse return null;
        const source_hwnd = win32.GetPropA(hwnd_at_cursor, window.SOURCE_HWND_PROP) orelse return null;
        return self.getThumbnailBySourceHwnd(source_hwnd);
    }

    /// After the character's group membership changed.
    pub fn refreshGroupBadge(self: *const ThumbnailSet, thumbnail: *ThumbnailWindow) void {
        const new_label = look.groupBadgeLabel(self.allocator, self.config, thumbnail.character_name) catch |err| {
            slog.err("Failed to build group badge label for '{s}': {}", .{ thumbnail.character_name, err });
            return;
        };
        thumbnail.replaceText(self.allocator, .group_badge_label, new_label);
    }

    /// Reconciles focus, then marks thumbnails dirty whose session timer moved on.
    fn updateThumbnailStates(self: *ThumbnailSet) void {
        if (self.thumbnails.items.len == 0) return;

        self.reconcileThumbnailStates();

        const now = win32.Ticks.now();
        for (self.thumbnails.items) |*thumbnail| {
            if (thumbnail.is_dragged) continue;

            if (thumbnail.render_cache.settings) |cached| {
                if (cached.show_session_timer and cached.session_minutes != (thumbnail.sessionMinutes(now) orelse 0)) thumbnail.needs_render = true;
            }
        }
    }

    pub fn thumbnailsShown(self: *const ThumbnailSet) bool {
        return self.visibility == .visible;
    }

    /// Manual hiding persists through focus changes.
    pub fn toggleAllThumbnailsVisibility(self: *ThumbnailSet) void {
        self.visibility = if (self.thumbnailsShown()) .hidden_manual else .visible;
        slog.info("Toggling all thumbnails visibility: {}", .{self.visibility});

        for (self.thumbnails.items) |*thumbnail| {
            thumbnail.setVisibility(self.visibility);
            self.renderThumbnailLogged(thumbnail, "visibility toggle");
        }
    }

    /// The hide-debounce timer fired, so no EVE window has had focus for hideDebounceMs.
    pub fn autoHideAfterFocusLoss(self: *ThumbnailSet) void {
        slog.debug("Hide debounce timer fired", .{});

        // Checked again, since the setting or focus may have changed while the timer ran.
        const eve_has_focus = self.isEveWindowForeground();
        self.visibility = self.visibility.afterAutoHide(self.focusHide(eve_has_focus));
        for (self.thumbnails.items) |*thumbnail| {
            if (self.applyAutoVisibility(thumbnail, eve_has_focus)) self.renderThumbnailLogged(thumbnail, "auto-hide");
        }
    }

    fn focusHide(self: *const ThumbnailSet, eve_has_focus: bool) state.FocusHide {
        return .{ .is_enabled = self.config.shownAutoHide().is_enabled, .is_eve_focused = eve_has_focus };
    }

    /// Returns whether it changed.
    pub fn applyAutoVisibility(self: *const ThumbnailSet, thumbnail: *ThumbnailWindow, eve_has_focus: bool) bool {
        const target = thumbnail.visibility_state.afterAutoHide(self.focusHide(eve_has_focus));
        if (thumbnail.visibility_state == target) return false;
        thumbnail.setVisibility(target);
        return true;
    }

    /// Records the ones it hid in `hidden`, so showThumbnails restores only those.
    pub fn hideVisibleThumbnails(self: *ThumbnailSet, allocator: std.mem.Allocator, hidden: *std.ArrayList(win32.HWND)) void {
        for (self.thumbnails.items) |*thumbnail| {
            if (!thumbnail.isVisible()) continue;
            thumbnail.setVisibility(.hidden_manual);
            hidden.append(allocator, thumbnail.hwnd) catch |err| {
                slog.err("Failed to remember a hidden thumbnail to show again: {}", .{err});
            };
            self.renderThumbnailLogged(thumbnail, "hide");
        }
    }

    pub fn showThumbnails(self: *ThumbnailSet, hwnds: []const win32.HWND) void {
        for (hwnds) |hwnd| {
            const thumbnail = self.getThumbnailByOverlayHwnd(hwnd) orelse continue;
            thumbnail.setVisibility(.visible);
            self.renderThumbnailLogged(thumbnail, "show");
        }
    }

    /// Takes up the roster's active window: redraws the thumbnails it left and reached, and shows any hidden while EVE had no focus.
    pub fn reconcileThumbnailStates(self: *ThumbnailSet) void {
        const old_active = self.drawn_active_hwnd;
        const active = self.roster.active_hwnd;
        self.drawn_active_hwnd = active;
        const active_changed = old_active != active;
        const any_eve_has_focus = if (active) |hwnd| self.roster.contains(hwnd) else false;
        if (any_eve_has_focus) self.visibility = self.visibility.afterAutoHide(self.focusHide(true));

        for (self.thumbnails.items) |*thumbnail| {
            // Losing focus hides only after the debounce timer, so only regaining it applies here.
            if (any_eve_has_focus and self.applyAutoVisibility(thumbnail, true)) thumbnail.needs_render = true;

            if (active_changed and (thumbnail.source_hwnd == old_active or thumbnail.source_hwnd == active)) {
                thumbnail.needs_render = true;
            }
        }
    }

    pub fn isEveWindowForeground(self: *const ThumbnailSet) bool {
        const foreground_hwnd = win32.GetForegroundWindow() orelse return false;
        return self.roster.contains(foreground_hwnd);
    }

    /// Call every tick, since pins fade with nothing to announce it.
    pub fn updateConnections(self: *ThumbnailSet, pins: *const intel_pins.IntelPins, now_ms: u64) void {
        const thumbnail_config = &self.config.thumbnail;
        const intel: ?connections.IntelView = if (thumbnail_config.showSystemConnectionIntel) .{ .pins = pins, .shrink_ms = self.config.mapPanel.intelShrinkMs() } else null;
        for (self.thumbnails.items) |*thumbnail| {
            const start = if (thumbnail_config.showSystemConnections) universe.findSystem(thumbnail.system_name) else null;
            if (thumbnail.connections.refresh(start, thumbnail_config.systemConnectionJumps, intel, now_ms)) thumbnail.needs_render = true;
        }
    }

    /// Takes up the roster's changes first; past `max_immediate`, the rest stay dirty for the next tick.
    pub fn renderDirtyThumbnails(self: *ThumbnailSet, max_immediate: ?usize) void {
        self.followRoster();
        var rendered_count: usize = 0;
        for (self.thumbnails.items) |*thumbnail| {
            if (!thumbnail.needs_render) continue;

            if (max_immediate) |cap| {
                if (rendered_count >= cap) continue;
            }

            self.renderThumbnailLogged(thumbnail, "dirty thumbnail");
            thumbnail.needs_render = false;
            rendered_count += 1;
        }
    }

    /// After Scout backdated the client's login from its gamelog.
    pub fn setSessionStart(self: *ThumbnailSet, source_hwnd: win32.HWND, started: win32.Ticks) void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse return;
        thumbnail.session_start = started;
        thumbnail.needs_render = true;
    }

    /// Logins, logouts and renames; returns whether the layout needs a reflow.
    fn applyNameChanges(self: *ThumbnailSet, name_changes: []const scout.NameChange) bool {
        var any_login = false;
        var any_logout = false;
        for (name_changes) |change| {
            const thumbnail = self.getThumbnailBySourceHwnd(change.hwnd) orelse continue;

            const was_generic = scout.isGenericCharacterName(change.old_name);
            const is_now_generic = scout.isGenericCharacterName(change.new_name);
            // Either direction can move a thumbnail to another space, or change its rank in one.
            if (was_generic and !is_now_generic) any_login = true;
            if (is_now_generic and !was_generic) any_logout = true;

            self.rename(thumbnail, change.new_name) catch |err| {
                slog.err("Failed to rename the thumbnail for '{s}': {}", .{ change.new_name, err });
                continue;
            };
            thumbnail.session_start = change.logged_in_at;

            if (was_generic and !is_now_generic) self.onLogin(thumbnail);

            self.renderThumbnailLogged(thumbnail, "name change");
            slog.info("Updated thumbnail for {s}", .{thumbnail.character_name});
        }

        if (!spaces.anyActive(self.config)) return false;
        return any_login or any_logout;
    }

    /// The client whose thumbnail is being dragged; only one is at a time.
    pub fn draggedSourceHwnd(self: *const ThumbnailSet) ?win32.HWND {
        for (self.thumbnails.items) |*thumbnail| {
            if (thumbnail.is_dragged) return thumbnail.source_hwnd;
        }
        return null;
    }

    /// Reflows once at the end, since createThumbnail sizes each against the count so far.
    pub fn populate(self: *ThumbnailSet, eve_windows: []const scout.EveWindow) void {
        if (self.addMissingThumbnails(eve_windows) and arrange.hasCountDependentLayout(self)) self.repositionAllThumbnails();
    }

    pub fn update(self: *ThumbnailSet, eve_windows: []const scout.EveWindow, closed_windows: []const scout.ClosedWindow, name_changes: []const scout.NameChange) void {
        var needs_region_reflow = self.cleanupClosedThumbnails(closed_windows);
        self.updateThumbnailStates();
        needs_region_reflow = self.applyNameChanges(name_changes) or needs_region_reflow;

        const created_new = self.addMissingThumbnails(eve_windows);
        needs_region_reflow = (created_new and arrange.hasCountDependentLayout(self)) or needs_region_reflow;

        // One reflow for all three triggers above.
        if (needs_region_reflow) self.repositionAllThumbnails();

        self.renderDirtyThumbnails(null);
    }

    pub fn saveThumbnailPosition(self: *ThumbnailSet, hwnd: win32.HWND) void {
        const thumbnail = self.getThumbnailByOverlayHwnd(hwnd) orelse return;
        const entry = positionOf(thumbnail) orelse return;
        self.store.setCharacterPositions(&.{entry});
    }

    /// After a group drag: every thumbnail's position, in one profile write.
    pub fn saveAllThumbnailPositions(self: *ThumbnailSet) void {
        var entries: std.ArrayList(config_mod.ProfileStore.CharacterPosition) = .empty;
        defer entries.deinit(self.allocator);
        for (self.thumbnails.items) |*thumbnail| {
            const entry = positionOf(thumbnail) orelse continue;
            entries.append(self.allocator, entry) catch |err| {
                slog.err("Failed to collect thumbnail positions to save: {}", .{err});
                return;
            };
        }
        self.store.setCharacterPositions(entries.items);
    }

    fn destroyThumbnail(self: *ThumbnailSet, thumbnail: ThumbnailWindow) void {
        if (thumbnail.is_win32_enabled) window.destroy(&thumbnail);
        self.freeThumbnailData(thumbnail);
    }

    /// Frees what it owns in every mode: its strings.
    fn freeThumbnailData(self: *ThumbnailSet, thumbnail: ThumbnailWindow) void {
        self.allocator.free(thumbnail.character_name);
        self.allocator.free(thumbnail.system_name);
        self.allocator.free(thumbnail.cached_group_badge_label);
    }

    fn removeThumbnailAt(self: *ThumbnailSet, index: usize) void {
        self.destroyThumbnail(self.thumbnails.orderedRemove(index));
    }

    fn indexOfSource(self: *const ThumbnailSet, source_hwnd: win32.HWND) ?usize {
        for (self.thumbnails.items, 0..) |thumbnail, i| {
            if (thumbnail.source_hwnd == source_hwnd) return i;
        }
        return null;
    }

    /// Matches a thumbnail's own window or its text overlay, never a source EVE window.
    fn indexOfOverlay(self: *const ThumbnailSet, hwnd: win32.HWND) ?usize {
        for (self.thumbnails.items, 0..) |thumbnail, i| {
            // Outside Thumbnails mode the handles are sentinels.
            if (thumbnail.is_win32_enabled and (thumbnail.hwnd == hwnd or thumbnail.text_hwnd == hwnd)) return i;
        }
        return null;
    }

    /// Keeps the old name if copying fails.
    fn rename(self: *ThumbnailSet, thumbnail: *ThumbnailWindow, name: []const u8) !void {
        thumbnail.replaceText(self.allocator, .character_name, try self.allocator.dupe(u8, name));
        thumbnail.refreshConfigCache(self.config, self.auto_colors);
        self.refreshGroupBadge(thumbnail);
    }

    /// The client went from the login screen to a character: the thumbnail goes to its saved spot, while App moves the client's own window.
    fn onLogin(self: *ThumbnailSet, thumbnail: *ThumbnailWindow) void {
        const name = thumbnail.character_name;
        // A space ignores the saved spot; applyNameChanges' reflow places it instead.
        if (thumbnail.is_win32_enabled and spaces.spaceFor(self.config, name) == null) {
            if (self.config.getCharacterPosition(name)) |saved_position| {
                thumbnail.moveTo(saved_position.x, saved_position.y, null);
                self.resizeThumbnailIfNeeded(thumbnail, null);
                slog.info("Moved {s} thumbnail to saved position: ({}, {})", .{ name, saved_position.x, saved_position.y });
            } else {
                slog.debug("No saved thumbnail position for {s}, keeping current location", .{name});
            }
        }
    }

    /// Redraws each thumbnail whose client changed, copying its system only when it differs, since replaceText drops the measured text sizes.
    fn followRoster(self: *ThumbnailSet) void {
        for (self.thumbnails.items) |*thumbnail| {
            const client = self.roster.byHwnd(thumbnail.source_hwnd) orelse continue;
            if (client.revision == thumbnail.seen_revision) continue;
            if (!std.mem.eql(u8, thumbnail.system_name, client.system_name)) {
                const copy = self.allocator.dupe(u8, client.system_name) catch |err| {
                    slog.err("Failed to copy the system '{s}' for '{s}': {}", .{ client.system_name, thumbnail.character_name, err });
                    continue;
                };
                thumbnail.replaceText(self.allocator, .system_name, copy);
                thumbnail.cached_system_color = window.systemColor(self.config, self.auto_colors, copy);
                self.shareSystemColor(thumbnail);
            }
            thumbnail.needs_render = true;
            thumbnail.seen_revision = client.revision;
        }
    }

    /// An evicted system's colour is picked again on return, so thumbnails already there would keep the old one.
    fn shareSystemColor(self: *ThumbnailSet, source: *const ThumbnailWindow) void {
        for (self.thumbnails.items) |*other| {
            if (other.cached_system_color == source.cached_system_color) continue;
            if (!std.ascii.eqlIgnoreCase(other.system_name, source.system_name)) continue;
            other.cached_system_color = source.cached_system_color;
            other.needs_render = true;
        }
    }

    /// Logs and skips failures; returns whether any were created.
    fn addMissingThumbnails(self: *ThumbnailSet, eve_windows: []const scout.EveWindow) bool {
        var created_new = false;

        for (eve_windows) |eve_window| {
            if (self.hasThumbnail(eve_window.hwnd)) continue;

            const system_name = if (self.roster.byHwnd(eve_window.hwnd)) |client| client.system_name else "";
            self.createThumbnail(&eve_window, system_name) catch |err| {
                slog.err("Failed to create thumbnail for '{s}': {}", .{ eve_window.character_name, err });
                continue;
            };
            created_new = true;
        }

        return created_new;
    }

    fn dupeThumbnailStrings(self: *const ThumbnailSet, character_name: []const u8, system_name: []const u8) !ThumbnailStrings {
        const allocator = self.allocator;
        const character_name_copy = try allocator.dupe(u8, character_name);
        errdefer allocator.free(character_name_copy);
        const system_name_copy = try allocator.dupe(u8, system_name);
        errdefer allocator.free(system_name_copy);
        const group_badge_label_copy = try look.groupBadgeLabel(allocator, self.config, character_name);
        errdefer allocator.free(group_badge_label_copy);

        return .{
            .character_name = character_name_copy,
            .system_name = system_name_copy,
            .group_badge_label = group_badge_label_copy,
        };
    }

    /// Shared by both creation paths; the caller supplies the handles and owns the result's strings.
    fn newThumbnailRecord(self: *ThumbnailSet, eve_window: *const scout.EveWindow, initial_system_name: []const u8, handles: window.Handles, is_win32_enabled: bool) !ThumbnailWindow {
        const strings = try self.dupeThumbnailStrings(eve_window.character_name, initial_system_name);
        var thumbnail: ThumbnailWindow = .{
            .hwnd = handles.hwnd,
            .text_hwnd = handles.text_hwnd,
            .source_hwnd = eve_window.hwnd,
            .is_eve_client = eve_window.is_eve_client,
            .session_start = eve_window.logged_in_at,
            .character_name = strings.character_name,
            .system_name = strings.system_name,
            .cached_group_badge_label = strings.group_badge_label,
            .visibility_state = self.visibility.afterAutoHide(self.focusHide(self.isEveWindowForeground())),
            .is_win32_enabled = is_win32_enabled,
        };
        thumbnail.refreshConfigCache(self.config, self.auto_colors);
        return thumbnail;
    }

    /// Reconciles focus afterwards, since the new client's window may already be the foreground one.
    fn addThumbnail(self: *ThumbnailSet, thumbnail: ThumbnailWindow) !void {
        try self.thumbnails.append(self.allocator, thumbnail);
        self.reconcileThumbnailStates();
    }

    /// ClientList and Nothing modes only need a data record, not real Win32 windows.
    fn createTrackingOnlyEntry(self: *ThumbnailSet, eve_window: *const scout.EveWindow, initial_system_name: []const u8) !void {
        // Never passed to Win32, since is_win32_enabled is false.
        const sentinel: win32.HWND = @ptrFromInt(1);
        const thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, .{ .hwnd = sentinel, .text_hwnd = sentinel }, false);
        errdefer self.freeThumbnailData(thumbnail);
        try self.addThumbnail(thumbnail);

        slog.info("Created tracking entry for {s} ({s} mode)", .{ eve_window.character_name, @tagName(self.config.display.viewMode) });
    }

    fn createThumbnail(self: *ThumbnailSet, eve_window: *const scout.EveWindow, initial_system_name: []const u8) !void {
        if (!self.config.display.viewMode.showsThumbnails()) {
            return self.createTrackingOnlyEntry(eve_window, initial_system_name);
        }

        const name = eve_window.character_name;
        const monitor_placement = monitors.resolveMonitorPlacement(&self.config.display);
        const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
        const scale = win32.dpiToScale(monitors.dpiForMonitor(if (monitor_placement) |mp| mp.monitor else null));
        const place = try arrange.newPlace(self, name, monitor_bounds, scale);
        const position = place.position;
        const size = place.size;

        const handles = try window.create(self.allocator, self.instance, eve_window.hwnd, name, .{
            .position = position,
            .size = size,
            .opacity = self.config.getCharacterOpacity(name),
            .is_click_through = self.config.interaction.clickThrough,
        });
        errdefer window.destroyHandles(handles);

        var thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, handles, true);
        errdefer self.freeThumbnailData(thumbnail);
        try thumbnail.applyLivePreview();
        errdefer thumbnail.dropLivePreview();
        // Before rendering, which can fail after creating the overlay bitmap.
        errdefer thumbnail.render_cache.deinit();
        try self.renderThumbnail(&thumbnail);
        const is_shown = if (thumbnail.render_cache.settings) |settings| settings.show_thumbnail else false;
        if (is_shown) window.showText(handles, position, size);

        try self.addThumbnail(thumbnail);

        slog.info("Created thumbnail for {s}", .{name});
    }

    fn positionOf(thumbnail: *const ThumbnailWindow) ?config_mod.ProfileStore.CharacterPosition {
        if (!thumbnail.is_win32_enabled) return null;
        var rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetWindowRect(thumbnail.hwnd, &rect))) {
            slog.warn("Failed to get the position of '{s}' to save it", .{thumbnail.character_name});
            return null;
        }
        return .{ .name = thumbnail.character_name, .position = .{ .x = rect.left, .y = rect.top } };
    }
};
