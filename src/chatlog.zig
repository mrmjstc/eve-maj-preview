const std = @import("std");
const win32 = @import("platform/win32.zig");
const log = @import("log.zig");
const notification_mod = @import("notifications/notification.zig");
const gamelog_events = @import("notifications/gamelog_events.zig");
const activity_mod = @import("activity/tracker.zig");
const scout_mod = @import("clients/scout.zig");
const painter_mod = @import("painter.zig");
const config_mod = @import("config.zig");
const CharacterIds = @import("chatlog/character_ids.zig").CharacterIds;
const lines_mod = @import("chatlog/lines.zig");
const tail = @import("chatlog/tail.zig");
const discovery = @import("chatlog/discovery.zig");
const slog = log.scoped("chatlog");

/// From the worker; the hwnd is resolved on the main thread, the only one that may touch Scout and Painter.
pub const SystemUpdateEvent = struct {
    character_name: []const u8,
    system_name: []const u8,
    // 0 skips the staleness check; live-tail lines arrive in order.
    event_ts: u64,
    // Stargate and conduit jumps only, for Travel Mode.
    is_jump: bool = false,

    pub fn deinit(self: *SystemUpdateEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
        allocator.free(self.system_name);
    }
};

/// From the worker; the text is rendered on the main thread, where per-type config lives.
pub const NotificationEvent = struct {
    character_name: []const u8,
    /// source/target are owned copies.
    notification: notification_mod.Notification,

    pub fn deinit(self: *NotificationEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
        if (self.notification.source) |s| allocator.free(s);
        if (self.notification.target) |t| allocator.free(t);
    }
};

/// Main thread to worker; names are owned by the command.
pub const ChatlogCommand = union(enum) {
    add_character: struct {
        name: []const u8,
    },
    remove_character: []const u8,
    resolve_character_id: struct {
        name: []const u8,
    },
    shutdown: void,

    pub fn deinit(self: *ChatlogCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .add_character => |data| allocator.free(data.name),
            .remove_character => |name| allocator.free(name),
            .resolve_character_id => |data| allocator.free(data.name),
            .shutdown => {},
        }
    }
};

pub fn EventQueue(comptime T: type) type {
    return struct {
        mutex: std.Io.Mutex,
        events: std.ArrayList(T),
        allocator: std.mem.Allocator,
        io: std.Io,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return .{
                .mutex = .init,
                .events = std.ArrayList(T).empty,
                .allocator = allocator,
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            self.events.deinit(self.allocator);
        }

        pub fn push(self: *Self, event: T) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try self.events.append(self.allocator, event);
        }

        pub fn drain(self: *Self, out_list: *std.ArrayList(T)) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try out_list.appendSlice(self.allocator, self.events.items);
            self.events.clearRetainingCapacity();
        }
    };
}

/// Shorter lines can't hold a timestamp and a message.
const MIN_LINE_LENGTH = 25;

/// win32.Ticks unwrapped to i64, for activity trackers' plain integer arithmetic.
fn trackerNowMs() i64 {
    return @intCast(win32.Ticks.now().ms);
}

const LogFile = tail.LogFile;

pub const ChatlogMonitor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_files: std.ArrayList(LogFile),
    monitored_paths: std.StringHashMap(void),
    finder: discovery.LogFinder,
    /// Read for ore prices, which only change while the worker is stopped.
    global_settings: ?*config_mod.GlobalConfig = null,
    character_ids: ?*CharacterIds = null,
    combat_tracker: ?*activity_mod.CombatTracker = null,
    mining_tracker: ?*activity_mod.MiningTracker = null,
    bounty_tracker: ?*activity_mod.BountyTracker = null,
    damage_alert_excluded_weapons: []const u8 = "",
    idle_poll_threshold: u32 = 20,
    max_poll_multiplier: u8 = 8,
    poll_interval_ms: u32 = 50,
    last_sync_poll_ms: win32.Ticks = .{},
    pending_scan_index: usize = 0,
    /// The folder changes a rescan still in progress is for.
    pending_changes: discovery.Changes = .{},
    pending_scan_names: std.ArrayList([]u8) = .empty,
    worker_thread: ?std.Thread = null,
    command_queue: EventQueue(ChatlogCommand),
    result_queue: EventQueue(SystemUpdateEvent),
    notification_queue: EventQueue(NotificationEvent),
    should_exit: std.atomic.Value(bool),
    threading_enabled: bool = false,
    pending_characters: std.StringHashMap(void),
    pending_characters_mutex: std.Io.Mutex,
    /// Worker only: every added character, including ones with no logs yet, so folder changes keep looking for them.
    wanted_characters: std.StringHashMap(void),
    /// Reused each tick; main thread only, borrowed slices.
    tick_names: std.ArrayList([]const u8),
    tick_logged_out_names: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: *const config_mod.ChatlogConfig, global_settings_ref: ?*config_mod.GlobalConfig, character_ids: ?*CharacterIds) !*ChatlogMonitor {
        const monitor = try allocator.create(ChatlogMonitor);
        errdefer allocator.destroy(monitor);
        monitor.finder = try discovery.LogFinder.init(allocator, io, cfg.chatlogDir, cfg.gamelogDir, character_ids);
        errdefer monitor.finder.deinit();

        monitor.allocator = allocator;
        monitor.io = io;
        monitor.log_files = .empty;
        monitor.monitored_paths = std.StringHashMap(void).init(allocator);
        monitor.global_settings = global_settings_ref;
        monitor.character_ids = character_ids;
        monitor.combat_tracker = null;
        monitor.mining_tracker = null;
        monitor.bounty_tracker = null;
        monitor.damage_alert_excluded_weapons = "";
        monitor.applySettings(cfg);
        monitor.last_sync_poll_ms = .{};
        monitor.pending_scan_index = 0;
        monitor.pending_changes = .{};
        monitor.pending_scan_names = .empty;

        monitor.worker_thread = null;
        monitor.command_queue = EventQueue(ChatlogCommand).init(allocator, io);
        monitor.result_queue = EventQueue(SystemUpdateEvent).init(allocator, io);
        monitor.notification_queue = EventQueue(NotificationEvent).init(allocator, io);
        monitor.should_exit = std.atomic.Value(bool).init(false);
        monitor.threading_enabled = false;
        monitor.pending_characters = std.StringHashMap(void).init(allocator);
        monitor.pending_characters_mutex = .init;
        monitor.wanted_characters = std.StringHashMap(void).init(allocator);
        monitor.tick_names = .empty;
        monitor.tick_logged_out_names = .empty;

        return monitor;
    }

    /// Whether this monitor already watches what `cfg` asks for, so a reload can keep it and its scan state.
    pub fn runsWith(self: *const ChatlogMonitor, cfg: *const config_mod.ChatlogConfig) bool {
        return cfg.enabled and
            cfg.useThreading == self.threading_enabled and
            std.mem.eql(u8, cfg.chatlogDir, self.finder.chatlog_dir) and
            std.mem.eql(u8, cfg.gamelogDir, self.finder.gamelog_dir);
    }

    /// The polling settings a profile reload can change without rebuilding the monitor.
    pub fn applySettings(self: *ChatlogMonitor, cfg: *const config_mod.ChatlogConfig) void {
        self.idle_poll_threshold = cfg.idlePollThreshold;
        self.max_poll_multiplier = cfg.maxPollMultiplier;
        self.poll_interval_ms = cfg.pollIntervalMs;
    }

    pub fn stopWorkerThread(self: *ChatlogMonitor) void {
        if (!self.threading_enabled) return;

        self.should_exit.store(true, .release);
        if (self.worker_thread) |thread| {
            thread.join();
        }
        self.worker_thread = null;
        self.threading_enabled = false;
    }

    pub fn startWorkerThread(self: *ChatlogMonitor) !void {
        if (self.threading_enabled) {
            return error.AlreadyRunning;
        }

        slog.info("Starting chatlog worker thread...", .{});
        self.should_exit.store(false, .release);
        self.worker_thread = try std.Thread.spawn(.{}, workerThreadMain, .{self});
        self.threading_enabled = true;
        slog.info("Chatlog worker thread started", .{});
    }

    fn workerThreadMain(monitor: *ChatlogMonitor) void {
        slog.info("Worker thread started (TID: {})", .{std.Thread.getCurrentId()});

        var loop_count: u64 = 0;
        while (!monitor.should_exit.load(.acquire)) {
            loop_count += 1;

            monitor.processCommands() catch |err| {
                slog.err("Worker thread command processing error: {}", .{err});
            };

            monitor.pollLogFiles() catch |err| {
                slog.err("Worker thread poll error: {}", .{err});
            };

            // A longer budget than the main thread's, since nothing waits on the worker.
            const time_budget_ns = 100 * std.time.ns_per_ms;
            var characters = monitor.getCurrentCharacterList() catch |err| {
                slog.err("Worker thread failed to get character list: {}", .{err});
                win32.Sleep(100);
                continue;
            };
            defer characters.deinit(monitor.allocator);

            _ = monitor.checkNewLogFiles(characters.items, time_budget_ns) catch |err| {
                slog.err("Worker thread scan error: {}", .{err});
            };

            win32.Sleep(monitor.poll_interval_ms);
        }

        slog.info("Worker thread exiting (processed {} loops)", .{loop_count});
    }

    fn processCommands(self: *ChatlogMonitor) !void {
        var commands = std.ArrayList(ChatlogCommand).empty;
        defer commands.deinit(self.allocator);
        try self.command_queue.drain(&commands);

        for (commands.items) |*mutable_cmd| {
            defer mutable_cmd.deinit(self.allocator);

            switch (mutable_cmd.*) {
                .add_character => |data| {
                    slog.debug("Worker: Add character {s}", .{data.name});
                    self.wantCharacter(data.name);

                    if (self.finder.find(data.name, true)) |chatlog_path| {
                        defer self.allocator.free(chatlog_path);
                        self.addLogFile(chatlog_path, data.name, true) catch |err| {
                            slog.err("Worker: Failed to add chatlog for {s}: {}", .{ data.name, err });
                        };
                    }

                    if (self.finder.find(data.name, false)) |gamelog_path| {
                        defer self.allocator.free(gamelog_path);
                        self.addLogFile(gamelog_path, data.name, false) catch |err| {
                            slog.err("Worker: Failed to add gamelog for {s}: {}", .{ data.name, err });
                        };
                    }
                },
                .remove_character => |char_name| {
                    slog.debug("Worker: Remove character {s}", .{char_name});
                    if (self.wanted_characters.fetchRemove(char_name)) |entry| self.allocator.free(entry.key);
                    self.removeCharacter(char_name);
                },
                .resolve_character_id => |data| {
                    const already_cached = if (self.character_ids) |ids| ids.contains(data.name) catch |err| blk: {
                        slog.err("Worker: failed to check character ID cache for {s}: {}", .{ data.name, err });
                        break :blk false;
                    } else false;
                    if (already_cached) continue;

                    slog.debug("Worker: Resolving character ID for {s}", .{data.name});
                    if (self.finder.find(data.name, true)) |path| {
                        self.allocator.free(path);
                    } else if (self.finder.find(data.name, false)) |path| {
                        self.allocator.free(path);
                    }
                },
                .shutdown => {
                    slog.info("Worker: Shutdown command received", .{});
                    self.should_exit.store(true, .release);
                },
            }
        }

        if (commands.items.len > 0) {
            slog.debug("Worker: Processed {} commands", .{commands.items.len});
        }
    }

    fn wantCharacter(self: *ChatlogMonitor, name: []const u8) void {
        if (self.wanted_characters.contains(name)) return;
        const owned = self.allocator.dupe(u8, name) catch |err| {
            slog.err("Worker: failed to remember {s} to watch for its logs: {}", .{ name, err });
            return;
        };
        self.wanted_characters.put(owned, {}) catch |err| {
            slog.err("Worker: failed to remember {s} to watch for its logs: {}", .{ name, err });
            self.allocator.free(owned);
        };
    }

    /// The characters a directory change is checked against, borrowed from wanted_characters; worker thread only.
    fn getCurrentCharacterList(self: *ChatlogMonitor) !std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).empty;
        errdefer list.deinit(self.allocator);
        var names = self.wanted_characters.keyIterator();
        while (names.next()) |name| try list.append(self.allocator, name.*);
        return list;
    }

    pub fn deinit(self: *ChatlogMonitor) void {
        self.stopWorkerThread();

        {
            var commands = std.ArrayList(ChatlogCommand).empty;
            defer commands.deinit(self.allocator);
            self.command_queue.drain(&commands) catch {};
            for (commands.items) |*cmd| cmd.deinit(self.allocator);
        }
        {
            var events = std.ArrayList(SystemUpdateEvent).empty;
            defer events.deinit(self.allocator);
            self.result_queue.drain(&events) catch {};
            for (events.items) |*event| event.deinit(self.allocator);
        }
        {
            var events = std.ArrayList(NotificationEvent).empty;
            defer events.deinit(self.allocator);
            self.notification_queue.drain(&events) catch {};
            for (events.items) |*event| event.deinit(self.allocator);
        }
        self.command_queue.deinit();
        self.result_queue.deinit();
        self.notification_queue.deinit();

        var pending_iter = self.pending_characters.keyIterator();
        while (pending_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.pending_characters.deinit();

        var wanted_iter = self.wanted_characters.keyIterator();
        while (wanted_iter.next()) |key| self.allocator.free(key.*);
        self.wanted_characters.deinit();

        self.clearPendingScanNames();
        self.pending_scan_names.deinit(self.allocator);

        self.finder.deinit();

        for (self.log_files.items) |*state| {
            state.deinit(self.allocator, self.io);
        }
        self.log_files.deinit(self.allocator);

        var key_iter = self.monitored_paths.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.monitored_paths.deinit();

        self.tick_names.deinit(self.allocator);
        self.tick_logged_out_names.deinit(self.allocator);

        if (self.damage_alert_excluded_weapons.len > 0) self.allocator.free(self.damage_alert_excluded_weapons);
    }

    /// Owned, since the worker thread reads it while a dialog preview may replace the config's copy; call only while the worker is stopped.
    pub fn setDamageAlertExcludedWeapons(self: *ChatlogMonitor, weapons: []const u8) void {
        const owned: []const u8 = if (weapons.len == 0) "" else self.allocator.dupe(u8, weapons) catch |err| {
            slog.err("Failed to copy damage alert weapon filter, keeping the previous one: {}", .{err});
            return;
        };
        if (self.damage_alert_excluded_weapons.len > 0) self.allocator.free(self.damage_alert_excluded_weapons);
        self.damage_alert_excluded_weapons = owned;
    }

    pub fn addCharacter(self: *ChatlogMonitor, character_name: []const u8) !void {
        if (self.threading_enabled) {
            try self.pending_characters_mutex.lock(self.io);
            defer self.pending_characters_mutex.unlock(self.io);

            if (self.pending_characters.contains(character_name)) return;

            const cmd = ChatlogCommand{
                .add_character = .{
                    .name = try self.allocator.dupe(u8, character_name),
                },
            };
            try self.command_queue.push(cmd);

            const key = try self.allocator.dupe(u8, character_name);
            try self.pending_characters.put(key, {});

            slog.debug("Queued character for worker: {s}", .{character_name});
            return;
        }

        if (self.finder.find(character_name, true)) |chatlog_path| {
            try self.addLogFile(chatlog_path, character_name, true);
            self.allocator.free(chatlog_path);
        }

        if (self.finder.find(character_name, false)) |gamelog_path| {
            try self.addLogFile(gamelog_path, character_name, false);
            self.allocator.free(gamelog_path);
        }
    }

    /// Backfills a character's ID from existing log files without monitoring them (unlike addCharacter); worker-thread only.
    pub fn resolveCharacterId(self: *ChatlogMonitor, character_name: []const u8) !void {
        if (!self.threading_enabled) {
            slog.debug("Skipping ID backfill for {s}: threading disabled", .{character_name});
            return;
        }

        const cmd = ChatlogCommand{
            .resolve_character_id = .{
                .name = try self.allocator.dupe(u8, character_name),
            },
        };
        try self.command_queue.push(cmd);
    }

    pub fn removeCharacter(self: *ChatlogMonitor, character_name: []const u8) void {
        var i: usize = 0;
        while (i < self.log_files.items.len) {
            const state = &self.log_files.items[i];
            if (std.mem.eql(u8, state.character_name, character_name)) {
                slog.info("Stopped monitoring {s} for {s}: {s}", .{
                    if (state.is_chatlog) "chatlog" else "gamelog",
                    character_name,
                    state.path,
                });

                _ = self.monitored_paths.remove(state.path);

                var removed = self.log_files.orderedRemove(i);
                removed.deinit(self.allocator, self.io);

                if (self.combat_tracker) |tracker| {
                    tracker.removeCharacter(character_name);
                }

                if (self.mining_tracker) |tracker| {
                    tracker.removeCharacter(character_name);
                }

                if (self.bounty_tracker) |tracker| {
                    tracker.removeCharacter(character_name);
                }

            } else {
                i += 1;
            }
        }
    }

    fn addLogFile(self: *ChatlogMonitor, file_path: []const u8, character_name: []const u8, is_chatlog: bool) !void {
        if (self.monitored_paths.contains(file_path)) return;

        // A newer file for the same character and kind replaces the old one: EVE started a new session.
        var i: usize = 0;
        while (i < self.log_files.items.len) {
            const state = &self.log_files.items[i];
            if (state.is_chatlog == is_chatlog and std.mem.eql(u8, state.character_name, character_name)) {
                slog.info("Log rotated for {s} ({s}): {s} -> {s}", .{ character_name, if (is_chatlog) "chatlog" else "gamelog", state.path, file_path });
                _ = self.monitored_paths.remove(state.path);
                var removed = self.log_files.orderedRemove(i);
                removed.deinit(self.allocator, self.io);
            } else {
                i += 1;
            }
        }

        {
            var entry = try LogFile.init(self.allocator, file_path, character_name, is_chatlog);
            errdefer entry.deinit(self.allocator, self.io);
            try self.log_files.append(self.allocator, entry);
        }
        const new_entry = &self.log_files.items[self.log_files.items.len - 1];

        {
            // The map owns its own copy of the key.
            const key = try self.allocator.dupe(u8, new_entry.path);
            errdefer self.allocator.free(key);
            try self.monitored_paths.put(key, {});
        }

        const found = new_entry.start(self.allocator, self.io) catch |err| {
            slog.warn("Failed to open {s} for initial read: {}", .{ file_path, err });
            return err;
        };
        if (found) |match| {
            slog.debug("Initial system for {s}: {s} (event_ts={})", .{ character_name, match.system, match.event_ts });
            // Not a jump: it's where the character already was.
            self.queueSystemUpdate(character_name, match.system, match.event_ts, false);
        }

        slog.info("Monitoring {s} for {s}: {s}", .{ if (is_chatlog) "chatlog" else "gamelog", character_name, file_path });
    }

    pub fn pollLogFiles(self: *ChatlogMonitor) !void {
        const backoff: tail.Backoff = .{ .idle_threshold = self.idle_poll_threshold, .max_multiplier = self.max_poll_multiplier };
        for (self.log_files.items) |*state| {
            state.poll(self.allocator, self.io, backoff, LineHandler{ .monitor = self, .state = state }) catch |err| {
                slog.err("Error reading {s}: {}", .{ state.path, err });
            };
        }
    }

    fn clearPendingScanNames(self: *ChatlogMonitor) void {
        for (self.pending_scan_names.items) |name| self.allocator.free(name);
        self.pending_scan_names.clearRetainingCapacity();
    }

    /// Rescans `character_names` for new logs once EVE creates files in their folders, within `max_time_ns` per call; returns whether work remains.
    pub fn checkNewLogFiles(self: *ChatlogMonitor, character_names: []const []const u8, max_time_ns: u64) !bool {
        const start_time = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();

        if (!self.pending_changes.any()) {
            const changes = self.finder.changes();
            if (!changes.any()) return false;
            self.pending_changes = changes;
            self.pending_scan_index = 0;

            // Copied, since the names may be freed or moved while the scan spans several calls.
            self.clearPendingScanNames();
            for (character_names) |name| {
                const copy = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(copy);
                try self.pending_scan_names.append(self.allocator, copy);
            }
            slog.debug("New log file scan started (chatlog={}, gamelog={})", .{ changes.chatlog, changes.gamelog });
        }

        const scan_names = self.pending_scan_names.items;
        while (self.pending_scan_index < scan_names.len) : (self.pending_scan_index += 1) {
            const elapsed = std.Io.Timestamp.now(self.io, .awake).toNanoseconds() - start_time;
            if (elapsed > max_time_ns) {
                slog.debug("Log file scan paused at character {}/{}, continuing next time", .{ self.pending_scan_index, scan_names.len });
                return true;
            }

            const char_name = scan_names[self.pending_scan_index];
            if (scout_mod.isGenericCharacterName(char_name)) continue;

            // addLogFile skips a file it already monitors.
            if (self.pending_changes.chatlog) {
                if (self.finder.find(char_name, true)) |chatlog_path| {
                    defer self.allocator.free(chatlog_path);
                    try self.addLogFile(chatlog_path, char_name, true);
                }
            }
            if (self.pending_changes.gamelog) {
                if (self.finder.find(char_name, false)) |gamelog_path| {
                    defer self.allocator.free(gamelog_path);
                    try self.addLogFile(gamelog_path, char_name, false);
                }
            }
        }

        self.finder.rearm(self.pending_changes);
        self.pending_changes = .{};
        self.clearPendingScanNames();
        self.pending_scan_index = 0;
        slog.debug("Log file scan completed", .{});
        return false;
    }

    pub fn update(self: *ChatlogMonitor, scout_result: *const scout_mod.UpdateResult) !void {
        self.tick_names.clearRetainingCapacity();
        self.tick_logged_out_names.clearRetainingCapacity();

        for (scout_result.windows) |eve_window| {
            self.tick_names.append(self.allocator, eve_window.character_name) catch |err| {
                slog.warn("Failed to track {s} for chatlog update: {}", .{ eve_window.character_name, err });
                continue;
            };
        }

        for (scout_result.name_changes.items) |change| {
            if (scout_mod.isGenericCharacterName(change.new_name) and !scout_mod.isGenericCharacterName(change.old_name)) {
                self.tick_logged_out_names.append(self.allocator, change.old_name) catch |err| {
                    slog.warn("Failed to track logged-out name {s} for chatlog update: {}", .{ change.old_name, err });
                    continue;
                };
            }
        }

        try self.applyTick(self.tick_names.items, scout_result.closed_windows.items, self.tick_logged_out_names.items);
    }

    fn applyTick(self: *ChatlogMonitor, character_names: []const []const u8, closed_windows: []const scout_mod.ClosedWindow, logged_out_names: []const []const u8) !void {
        if (!self.threading_enabled) {
            // pollLogFiles()'s per-file backoff assumes fixed-interval calls, which this UI-tick-driven path doesn't guarantee.
            const now = win32.Ticks.now();
            if (now.elapsedSince(self.last_sync_poll_ms) >= self.poll_interval_ms) {
                self.last_sync_poll_ms = now;
                try self.pollLogFiles();
            }

            for (closed_windows) |cw| {
                self.removeCharacter(cw.character_name);
            }

            for (logged_out_names) |name| {
                self.removeCharacter(name);
            }

            // Short enough not to hold up a UI tick; the rest continues next tick.
            const time_budget_ns = 2 * std.time.ns_per_ms;
            _ = try self.checkNewLogFiles(character_names, time_budget_ns);
        } else {
            try self.pending_characters_mutex.lock(self.io);
            defer self.pending_characters_mutex.unlock(self.io);

            for (closed_windows) |cw| {
                if (self.pending_characters.fetchRemove(cw.character_name)) |entry| {
                    self.allocator.free(entry.key);

                    const cmd = ChatlogCommand{
                        .remove_character = try self.allocator.dupe(u8, cw.character_name),
                    };
                    try self.command_queue.push(cmd);
                }
            }

            for (logged_out_names) |name| {
                if (self.pending_characters.fetchRemove(name)) |entry| {
                    self.allocator.free(entry.key);

                    const cmd = ChatlogCommand{
                        .remove_character = try self.allocator.dupe(u8, name),
                    };
                    try self.command_queue.push(cmd);
                }
            }

            for (character_names) |char_name| {
                if (scout_mod.isGenericCharacterName(char_name)) continue;

                if (self.pending_characters.contains(char_name)) continue;

                const cmd = ChatlogCommand{
                    .add_character = .{
                        .name = try self.allocator.dupe(u8, char_name),
                    },
                };
                try self.command_queue.push(cmd);

                const key = try self.allocator.dupe(u8, char_name);
                try self.pending_characters.put(key, {});
            }
        }

        try self.drainResultQueue();
        try self.drainNotificationQueue();
    }

    /// Safe from either thread; Painter and Scout are only touched when the main thread drains it.
    fn queueSystemUpdate(self: *ChatlogMonitor, character_name: []const u8, system_name: []const u8, event_ts: u64, is_jump: bool) void {
        const character_name_copy = self.allocator.dupe(u8, character_name) catch |err| {
            slog.err("Failed to allocate character name for system update: {}", .{err});
            return;
        };
        const system_name_copy = self.allocator.dupe(u8, system_name) catch |err| {
            slog.err("Failed to allocate system name for system update: {}", .{err});
            self.allocator.free(character_name_copy);
            return;
        };

        const event = SystemUpdateEvent{
            .character_name = character_name_copy,
            .system_name = system_name_copy,
            .event_ts = event_ts,
            .is_jump = is_jump,
        };
        self.result_queue.push(event) catch |err| {
            var mutable_event = event;
            mutable_event.deinit(self.allocator);
            slog.err("Failed to push system update event: {}", .{err});
        };
    }

    /// Safe from either thread; enabled/type/throttle gating happens in Painter.notify when the main thread drains it.
    fn queueNotification(self: *ChatlogMonitor, character_name: []const u8, n: notification_mod.Notification) void {
        var event = NotificationEvent{
            .character_name = "",
            .notification = .{ .ntype = n.ntype, .state = n.state },
        };
        self.copyNotificationEvent(&event, character_name, n) catch |err| {
            event.deinit(self.allocator);
            slog.err("Failed to allocate {s} notification for {s}: {}", .{ @tagName(n.ntype), character_name, err });
            return;
        };
        self.notification_queue.push(event) catch |err| {
            event.deinit(self.allocator);
            slog.err("Failed to push notification event: {}", .{err});
        };
    }

    /// Fills `event` field by field so a partial failure leaves it safe to deinit.
    fn copyNotificationEvent(self: *ChatlogMonitor, event: *NotificationEvent, character_name: []const u8, n: notification_mod.Notification) !void {
        event.character_name = try self.allocator.dupe(u8, character_name);
        if (n.source) |s| event.notification.source = try self.allocator.dupe(u8, s);
        if (n.target) |t| event.notification.target = try self.allocator.dupe(u8, t);
    }

    /// Main thread only: Scout and Painter aren't safe to touch from the worker.
    fn drainResultQueue(self: *ChatlogMonitor) !void {
        var events = std.ArrayList(SystemUpdateEvent).empty;
        defer events.deinit(self.allocator);

        try self.result_queue.drain(&events);

        for (events.items) |*event| {
            defer event.deinit(self.allocator);

            const scout_ptr = scout_mod.g_scout_ptr orelse continue;
            const hwnd = scout_ptr.getHwndByName(event.character_name) orelse {
                slog.warn("No HWND for {s}, skipping system update", .{event.character_name});
                continue;
            };

            if (painter_mod.g_painter_ptr) |painter_ptr| {
                painter_ptr.updateSystemNameByHwnd(hwnd, event.system_name, event.event_ts, event.is_jump) catch |err| {
                    slog.err("Failed to update system name for {s}: {}", .{ event.character_name, err });
                    scout_ptr.clearHwndForCharacter(event.character_name);
                };
            } else {
                slog.warn("No painter available to apply system update: {s} -> {s}", .{ event.character_name, event.system_name });
            }
        }
    }

    /// Main thread only, like drainResultQueue.
    fn drainNotificationQueue(self: *ChatlogMonitor) !void {
        var events = std.ArrayList(NotificationEvent).empty;
        defer events.deinit(self.allocator);

        try self.notification_queue.drain(&events);

        for (events.items) |*event| {
            defer event.deinit(self.allocator);

            const scout_ptr = scout_mod.g_scout_ptr orelse continue;
            const hwnd = scout_ptr.getHwndByName(event.character_name) orelse continue;

            if (painter_mod.g_painter_ptr) |painter_ptr| {
                painter_ptr.notify(hwnd, event.notification);
            }
        }
    }

    /// Where a file's complete lines go.
    const LineHandler = struct {
        monitor: *ChatlogMonitor,
        state: *LogFile,

        pub fn onLine(self: LineHandler, line: []const u8) void {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len > 0) self.monitor.parseLine(self.state, trimmed);
        }

        pub fn onLongLine(self: LineHandler, len: usize) void {
            self.monitor.warnLongLine(self.state, len);
        }
    };

    /// Only the first few and then every 100th, since a malformed log can produce thousands.
    fn warnLongLine(self: *ChatlogMonitor, state: *LogFile, len: usize) void {
        _ = self;
        state.long_line_warnings += 1;
        if (state.long_line_warnings <= 3 or state.long_line_warnings % 100 == 0) {
            slog.warn("Dropping line ({} bytes, over the {}-byte cap) for {s} (warning #{})", .{ len, lines_mod.MAX_LINE_LENGTH, state.character_name, state.long_line_warnings });
        }
    }

    fn parseLine(self: *ChatlogMonitor, state: *LogFile, clean_line: []const u8) void {
        if (clean_line.len < MIN_LINE_LENGTH) return;
        if (clean_line.len > lines_mod.MAX_LINE_LENGTH) {
            self.warnLongLine(state, clean_line.len);
            return;
        }

        if (state.is_chatlog) {
            if (lines_mod.parseChatLine(clean_line)) |system| self.handleSystemChange(state, system, .chatlog);
            return;
        }

        const parsed = lines_mod.parseGameLine(clean_line);
        if (parsed.system) |change| self.handleSystemChange(state, change.system, change.source);
        if (parsed.activity) |activity| switch (activity) {
            .event => self.handleGamelogEvent(state, clean_line),
            .mining => self.handleMiningEvent(state, clean_line),
            .bounty => self.handleBountyEvent(state, clean_line),
        };
    }

    /// Ignores a repeat of the last system; `system` is borrowed and copied into the queued events.
    fn handleSystemChange(self: *ChatlogMonitor, state: *LogFile, system: []const u8, source: lines_mod.SystemSource) void {
        const system_hash = std.hash.Wyhash.hash(0, system);
        const is_different = (state.last_system_hash != system_hash);

        if (is_different) {
            state.last_system_hash = system_hash;

            // Only jumps notify: undock and Local detection report the same arrival and would fire it twice.
            if (source == .jump) {
                self.queueNotification(state.character_name, .{ .ntype = .SystemChange, .target = system });
            }

            // Undock/chatlog-detect are same-system confirmations, not travel.
            const is_jump = source == .jump or source == .conduit;

            // 0: live lines arrive in order, so need no staleness check.
            self.queueSystemUpdate(state.character_name, system, 0, is_jump);

            slog.info("System change ({s}): {s} -> {s}", .{ @tagName(source), state.character_name, system });
        }
    }

    /// Feeds the DPS tracker and queues any notification the line warrants.
    fn handleGamelogEvent(self: *ChatlogMonitor, state: *LogFile, event_text: []const u8) void {
        // Stripped once for both uses; this is the highest-volume line type.
        var stripped_buf: [512]u8 = undefined;
        const stripped_text = activity_mod.stripHtml(event_text, &stripped_buf);

        if (self.combat_tracker) |tracker| {
            if (activity_mod.parseCombatLine(stripped_text)) |parsed| {
                // Filtered weapons still count toward DPS but mustn't retrigger Taking Damage.
                const counts_for_alert = !activity_mod.isWeaponExcluded(parsed.weapon, self.damage_alert_excluded_weapons);
                tracker.addEntry(state.character_name, parsed.amount, parsed.is_incoming, trackerNowMs(), counts_for_alert) catch |err| {
                    slog.warn("Failed to record combat entry for {s}: {}", .{ state.character_name, err });
                };
            }
        }

        const n = gamelog_events.classify(stripped_text) orelse return;
        self.queueNotification(state.character_name, n);

        slog.debug("Gamelog event: {s} -> {s}", .{ state.character_name, event_text });
    }

    /// A missing price counts as 0 ISK; only a missing volume drops the yield, since m3 can't be computed without it.
    fn handleMiningEvent(self: *ChatlogMonitor, state: *LogFile, event_text: []const u8) void {
        const tracker = self.mining_tracker orelse return;
        const parsed = activity_mod.parseMiningLine(event_text) orelse return;
        const gs = self.global_settings orelse return;
        const volume_per_unit = gs.oreVolume(parsed.name()) orelse {
            slog.warn("Unknown ore/ice/gas type in mining line, dropping yield: '{s}'", .{parsed.name()});
            return;
        };
        const price_per_unit = gs.orePrice(parsed.name()) orelse 0;
        const amount_f: f32 = @floatFromInt(parsed.amount);
        const m3 = amount_f * @as(f32, @floatCast(volume_per_unit));
        const isk = amount_f * @as(f32, @floatCast(price_per_unit));
        tracker.addEntry(state.character_name, m3, isk, trackerNowMs()) catch |err| {
            slog.warn("Failed to record mining entry for {s}: {}", .{ state.character_name, err });
        };
    }

    fn handleBountyEvent(self: *ChatlogMonitor, state: *LogFile, event_text: []const u8) void {
        const tracker = self.bounty_tracker orelse return;
        const isk = activity_mod.parseBountyLine(event_text) orelse return;
        tracker.addEntry(state.character_name, isk, trackerNowMs()) catch |err| {
            slog.warn("Failed to record bounty entry for {s}: {}", .{ state.character_name, err });
        };
    }
};
