//! Follows each logged-in character's chatlog and gamelog on a worker thread, and hands what they say to the main thread.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const notification_mod = @import("notifications/notification.zig");
const gamelog_events = @import("notifications/gamelog_events.zig");
const activity_mod = @import("activity/tracker.zig");
const scout = @import("clients/scout.zig");
const painter = @import("painter.zig");
const config = @import("config.zig");
const CharacterIds = @import("chatlog/character_ids.zig").CharacterIds;
const lines = @import("chatlog/lines.zig");
const tail = @import("chatlog/tail.zig");
const discovery = @import("chatlog/discovery.zig");
const queue = @import("chatlog/queue.zig");
const log = @import("log.zig");

const LogFile = tail.LogFile;
const slog = log.scoped("chatlog");

/// Shorter lines can't hold a timestamp and a message.
const MIN_LINE_LENGTH = 25;
/// Per worker loop, so a rescan of many characters doesn't keep commands waiting.
const RESCAN_BUDGET_NS = 100 * std.time.ns_per_ms;

pub const ChatlogMonitor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    finder: discovery.LogFinder,
    /// Read for ore prices, which only change while the worker is stopped.
    global_settings: ?*config.GlobalConfig,
    character_ids: ?*CharacterIds,
    // Set only while the worker is stopped (see activity/runtime.zig).
    combat_tracker: ?*activity_mod.CombatTracker = null,
    mining_tracker: ?*activity_mod.MiningTracker = null,
    bounty_tracker: ?*activity_mod.BountyTracker = null,
    damage_alert_excluded_weapons: []const u8 = "",
    idle_poll_threshold: u32 = 20,
    max_poll_multiplier: u8 = 8,
    poll_interval_ms: u32 = 50,

    worker_thread: ?std.Thread = null,
    should_exit: std.atomic.Value(bool) = .init(false),
    commands: queue.Queue(queue.Command),
    system_updates: queue.Queue(queue.SystemUpdate),
    notifications: queue.Queue(queue.NotificationEvent),

    /// Main thread only: characters added and not yet removed, so each is sent to the worker once.
    requested: std.StringHashMap(void),

    // Worker only; the main thread touches these only while the worker is stopped.
    log_files: std.ArrayList(LogFile) = .empty,
    monitored_paths: std.StringHashMap(void),
    /// Every added character, including ones with no logs yet, so folder changes keep looking for them.
    wanted: std.StringHashMap(void),
    /// A rescan in progress: which folders changed, and the characters still to check.
    rescan_changes: discovery.Changes = .{},
    rescan_names: std.ArrayList([]u8) = .empty,
    rescan_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: *const config.ChatlogConfig, global_settings: ?*config.GlobalConfig, character_ids: ?*CharacterIds) !*ChatlogMonitor {
        const monitor = try allocator.create(ChatlogMonitor);
        errdefer allocator.destroy(monitor);
        monitor.* = .{
            .allocator = allocator,
            .io = io,
            .finder = try discovery.LogFinder.init(allocator, io, cfg.chatlogDir, cfg.gamelogDir, character_ids),
            .global_settings = global_settings,
            .character_ids = character_ids,
            .commands = .init(allocator, io),
            .system_updates = .init(allocator, io),
            .notifications = .init(allocator, io),
            .requested = .init(allocator),
            .monitored_paths = .init(allocator),
            .wanted = .init(allocator),
        };
        monitor.applySettings(cfg);
        return monitor;
    }

    pub fn deinit(self: *ChatlogMonitor) void {
        self.stopWorkerThread();
        self.commands.deinit();
        self.system_updates.deinit();
        self.notifications.deinit();
        freeKeys(self.allocator, &self.requested);
        freeKeys(self.allocator, &self.wanted);
        freeKeys(self.allocator, &self.monitored_paths);
        self.clearRescanNames();
        self.rescan_names.deinit(self.allocator);
        self.finder.deinit();
        for (self.log_files.items) |*file| file.deinit(self.allocator, self.io);
        self.log_files.deinit(self.allocator);
        if (self.damage_alert_excluded_weapons.len > 0) self.allocator.free(self.damage_alert_excluded_weapons);
    }

    fn freeKeys(allocator: std.mem.Allocator, map: *std.StringHashMap(void)) void {
        var keys = map.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        map.deinit();
    }

    /// Whether this monitor already watches what `cfg` asks for, so a reload can keep it and its scan state.
    pub fn runsWith(self: *const ChatlogMonitor, cfg: *const config.ChatlogConfig) bool {
        return cfg.enabled and
            std.mem.eql(u8, cfg.chatlogDir, self.finder.chatlog_dir) and
            std.mem.eql(u8, cfg.gamelogDir, self.finder.gamelog_dir);
    }

    /// The polling settings a profile reload can change without rebuilding the monitor; only while the worker is stopped.
    pub fn applySettings(self: *ChatlogMonitor, cfg: *const config.ChatlogConfig) void {
        self.idle_poll_threshold = cfg.idlePollThreshold;
        self.max_poll_multiplier = cfg.maxPollMultiplier;
        self.poll_interval_ms = cfg.pollIntervalMs;
    }

    /// Owned, since the worker reads it while a dialog preview may replace the config's copy; only while the worker is stopped.
    pub fn setDamageAlertExcludedWeapons(self: *ChatlogMonitor, weapons: []const u8) void {
        const owned: []const u8 = if (weapons.len == 0) "" else self.allocator.dupe(u8, weapons) catch |err| {
            slog.err("Failed to copy damage alert weapon filter, keeping the previous one: {}", .{err});
            return;
        };
        if (self.damage_alert_excluded_weapons.len > 0) self.allocator.free(self.damage_alert_excluded_weapons);
        self.damage_alert_excluded_weapons = owned;
    }

    /// Pauses the worker; what it follows, and any rescan in progress, carry on when it's started again.
    pub fn stopWorkerThread(self: *ChatlogMonitor) void {
        const thread = self.worker_thread orelse return;
        self.should_exit.store(true, .release);
        thread.join();
        self.worker_thread = null;
    }

    pub fn startWorkerThread(self: *ChatlogMonitor) !void {
        if (self.worker_thread != null) return error.AlreadyRunning;
        self.should_exit.store(false, .release);
        self.worker_thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    /// Main thread only, like the rest of what the tick calls; asks the worker to follow the character's logs.
    pub fn addCharacter(self: *ChatlogMonitor, character_name: []const u8) !void {
        if (scout.isGenericCharacterName(character_name) or self.requested.contains(character_name)) return;
        const key = try self.allocator.dupe(u8, character_name);
        errdefer self.allocator.free(key);
        try self.commands.push(.{ .add_character = try self.allocator.dupe(u8, character_name) });
        try self.requested.put(key, {});
        slog.debug("Queued character for worker: {s}", .{character_name});
    }

    fn removeCharacter(self: *ChatlogMonitor, character_name: []const u8) !void {
        const entry = self.requested.fetchRemove(character_name) orelse return;
        self.allocator.free(entry.key);
        try self.commands.push(.{ .remove_character = try self.allocator.dupe(u8, character_name) });
    }

    /// Backfills a character's ID from its existing logs without following them, unlike addCharacter.
    pub fn resolveCharacterId(self: *ChatlogMonitor, character_name: []const u8) !void {
        try self.commands.push(.{ .resolve_character_id = try self.allocator.dupe(u8, character_name) });
    }

    /// Sends the tick's logouts, closed windows and logins to the worker, then delivers what it found.
    pub fn update(self: *ChatlogMonitor, scout_result: *const scout.UpdateResult) !void {
        for (scout_result.closed_windows.items) |closed| try self.removeCharacter(closed.character_name);
        for (scout_result.name_changes.items) |change| {
            if (scout.isGenericCharacterName(change.new_name) and !scout.isGenericCharacterName(change.old_name)) {
                try self.removeCharacter(change.old_name);
            }
        }
        for (scout_result.windows) |window| try self.addCharacter(window.character_name);

        try self.deliverSystemUpdates();
        try self.deliverNotifications();
    }

    /// Only the main thread may touch Scout and Painter.
    fn deliverSystemUpdates(self: *ChatlogMonitor) !void {
        var updates: std.ArrayList(queue.SystemUpdate) = .empty;
        defer updates.deinit(self.allocator);
        try self.system_updates.drain(&updates);

        for (updates.items) |*system_update| {
            defer system_update.deinit(self.allocator);
            const scout_ptr = scout.g_scout_ptr orelse continue;
            const hwnd = scout_ptr.getHwndByName(system_update.character_name) orelse {
                slog.warn("No HWND for '{s}', skipping system update", .{system_update.character_name});
                continue;
            };
            const painter_ptr = painter.g_painter_ptr orelse {
                slog.warn("No painter to apply system update for '{s}' to '{s}'", .{ system_update.character_name, system_update.system_name });
                continue;
            };
            painter_ptr.updateSystemNameByHwnd(hwnd, system_update.system_name, system_update.event_ts, system_update.is_jump) catch |err| {
                slog.err("Failed to update system name for '{s}': {}", .{ system_update.character_name, err });
                scout_ptr.clearHwndForCharacter(system_update.character_name);
            };
        }
    }

    fn deliverNotifications(self: *ChatlogMonitor) !void {
        var events: std.ArrayList(queue.NotificationEvent) = .empty;
        defer events.deinit(self.allocator);
        try self.notifications.drain(&events);

        for (events.items) |*event| {
            defer event.deinit(self.allocator);
            const scout_ptr = scout.g_scout_ptr orelse continue;
            const hwnd = scout_ptr.getHwndByName(event.character_name) orelse continue;
            const painter_ptr = painter.g_painter_ptr orelse continue;
            painter_ptr.notify(hwnd, event.notification);
        }
    }

    /// Everything below runs on the worker, apart from teardown once it's stopped.
    fn workerMain(self: *ChatlogMonitor) void {
        slog.info("Chatlog worker thread started (TID: {})", .{std.Thread.getCurrentId()});
        var loops: u64 = 0;
        while (!self.should_exit.load(.acquire)) : (loops += 1) {
            self.processCommands() catch |err| slog.err("Failed to process worker commands: {}", .{err});
            self.pollLogFiles();
            self.rescanForNewLogs() catch |err| slog.err("Failed to rescan for new logs: {}", .{err});
            win32.Sleep(self.poll_interval_ms);
        }
        slog.info("Chatlog worker thread exiting (processed {} loops)", .{loops});
    }

    fn processCommands(self: *ChatlogMonitor) !void {
        var commands: std.ArrayList(queue.Command) = .empty;
        defer commands.deinit(self.allocator);
        try self.commands.drain(&commands);

        for (commands.items) |*command| {
            defer command.deinit(self.allocator);
            switch (command.*) {
                .add_character => |name| self.follow(name),
                .remove_character => |name| self.unfollow(name),
                .resolve_character_id => |name| self.resolveId(name),
            }
        }
    }

    fn follow(self: *ChatlogMonitor, character_name: []const u8) void {
        slog.debug("Worker: Add character {s}", .{character_name});
        self.want(character_name);
        self.followNewestLog(character_name, true);
        self.followNewestLog(character_name, false);
    }

    fn want(self: *ChatlogMonitor, character_name: []const u8) void {
        if (self.wanted.contains(character_name)) return;
        const owned = self.allocator.dupe(u8, character_name) catch |err| {
            slog.err("Failed to remember '{s}' to watch for its logs: {}", .{ character_name, err });
            return;
        };
        self.wanted.put(owned, {}) catch |err| {
            slog.err("Failed to remember '{s}' to watch for its logs: {}", .{ character_name, err });
            self.allocator.free(owned);
        };
    }

    fn followNewestLog(self: *ChatlogMonitor, character_name: []const u8, is_chatlog: bool) void {
        const path = self.finder.find(character_name, is_chatlog) orelse return;
        defer self.allocator.free(path);
        self.addLogFile(path, character_name, is_chatlog) catch |err| {
            slog.err("Failed to follow {s} for '{s}': {}", .{ if (is_chatlog) "chatlog" else "gamelog", character_name, err });
        };
    }

    fn unfollow(self: *ChatlogMonitor, character_name: []const u8) void {
        slog.debug("Worker: Remove character {s}", .{character_name});
        if (self.wanted.fetchRemove(character_name)) |entry| self.allocator.free(entry.key);

        var i: usize = 0;
        while (i < self.log_files.items.len) {
            const file = &self.log_files.items[i];
            if (!std.mem.eql(u8, file.character_name, character_name)) {
                i += 1;
                continue;
            }
            slog.info("Stopped monitoring {s} for {s}: {s}", .{ if (file.is_chatlog) "chatlog" else "gamelog", character_name, file.path });
            self.dropLogFile(i);
        }

        if (self.combat_tracker) |tracker| tracker.removeCharacter(character_name);
        if (self.mining_tracker) |tracker| tracker.removeCharacter(character_name);
        if (self.bounty_tracker) |tracker| tracker.removeCharacter(character_name);
    }

    fn resolveId(self: *ChatlogMonitor, character_name: []const u8) void {
        const ids = self.character_ids orelse return;
        const cached = ids.contains(character_name) catch |err| blk: {
            slog.err("Failed to check character ID cache for '{s}': {}", .{ character_name, err });
            break :blk false;
        };
        if (cached) return;

        slog.debug("Worker: Resolving character ID for {s}", .{character_name});
        // Finding a log by its header caches the ID; the path itself isn't needed.
        const path = self.finder.find(character_name, true) orelse self.finder.find(character_name, false) orelse return;
        self.allocator.free(path);
    }

    fn dropLogFile(self: *ChatlogMonitor, index: usize) void {
        var removed = self.log_files.orderedRemove(index);
        if (self.monitored_paths.fetchRemove(removed.path)) |entry| self.allocator.free(entry.key);
        removed.deinit(self.allocator, self.io);
    }

    fn addLogFile(self: *ChatlogMonitor, path: []const u8, character_name: []const u8, is_chatlog: bool) !void {
        if (self.monitored_paths.contains(path)) return;

        // A newer file for the same character and kind replaces the old one: EVE started a new session.
        var i: usize = 0;
        while (i < self.log_files.items.len) {
            const file = &self.log_files.items[i];
            if (file.is_chatlog != is_chatlog or !std.mem.eql(u8, file.character_name, character_name)) {
                i += 1;
                continue;
            }
            slog.info("Log rotated for {s} ({s}): {s} -> {s}", .{ character_name, if (is_chatlog) "chatlog" else "gamelog", file.path, path });
            self.dropLogFile(i);
        }

        {
            var file = try LogFile.init(self.allocator, path, character_name, is_chatlog);
            errdefer file.deinit(self.allocator, self.io);
            try self.log_files.append(self.allocator, file);
        }
        const new_file = &self.log_files.items[self.log_files.items.len - 1];
        {
            // The map owns its own copy of the key.
            const key = try self.allocator.dupe(u8, new_file.path);
            errdefer self.allocator.free(key);
            try self.monitored_paths.put(key, {});
        }

        const found = new_file.start(self.allocator, self.io) catch |err| {
            slog.warn("Failed to open '{s}' for initial read: {}", .{ path, err });
            return err;
        };
        if (found) |match| {
            slog.debug("Initial system for {s}: {s} (event_ts={})", .{ character_name, match.system, match.event_ts });
            // Not a jump: it's where the character already was.
            self.queueSystemUpdate(character_name, match.system, match.event_ts, false);
        }

        slog.info("Monitoring {s} for {s}: {s}", .{ if (is_chatlog) "chatlog" else "gamelog", character_name, path });
    }

    fn pollLogFiles(self: *ChatlogMonitor) void {
        const backoff: tail.Backoff = .{ .idle_threshold = self.idle_poll_threshold, .max_multiplier = self.max_poll_multiplier };
        for (self.log_files.items) |*file| {
            file.poll(self.allocator, self.io, backoff, LineHandler{ .monitor = self, .file = file }) catch |err| {
                slog.err("Failed to read '{s}': {}", .{ file.path, err });
            };
        }
    }

    fn clearRescanNames(self: *ChatlogMonitor) void {
        for (self.rescan_names.items) |name| self.allocator.free(name);
        self.rescan_names.clearRetainingCapacity();
    }

    /// Once EVE creates files in a log folder, checks every wanted character for a newer log there, so new sessions
    /// and logs created after login are followed; spread over several loops if it runs past RESCAN_BUDGET_NS.
    fn rescanForNewLogs(self: *ChatlogMonitor) !void {
        const start_time = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();

        if (!self.rescan_changes.any()) {
            const changes = self.finder.changes();
            if (!changes.any()) return;
            self.rescan_changes = changes;
            self.rescan_index = 0;

            // Copied, since remove commands can change `wanted` while the rescan spans several loops.
            self.clearRescanNames();
            var names = self.wanted.keyIterator();
            while (names.next()) |name| {
                const copy = try self.allocator.dupe(u8, name.*);
                errdefer self.allocator.free(copy);
                try self.rescan_names.append(self.allocator, copy);
            }
            slog.debug("New log file scan started (chatlog={}, gamelog={})", .{ changes.chatlog, changes.gamelog });
        }

        const names = self.rescan_names.items;
        while (self.rescan_index < names.len) : (self.rescan_index += 1) {
            if (std.Io.Timestamp.now(self.io, .awake).toNanoseconds() - start_time > RESCAN_BUDGET_NS) {
                slog.debug("Log file scan paused at character {}/{}, continuing next loop", .{ self.rescan_index, names.len });
                return;
            }
            // addLogFile skips a file already followed.
            if (self.rescan_changes.chatlog) self.followNewestLog(names[self.rescan_index], true);
            if (self.rescan_changes.gamelog) self.followNewestLog(names[self.rescan_index], false);
        }

        self.finder.rearm(self.rescan_changes);
        self.rescan_changes = .{};
        self.rescan_index = 0;
        self.clearRescanNames();
        slog.debug("Log file scan completed", .{});
    }

    fn queueSystemUpdate(self: *ChatlogMonitor, character_name: []const u8, system_name: []const u8, event_ts: u64, is_jump: bool) void {
        const system_update = self.copySystemUpdate(character_name, system_name, event_ts, is_jump) catch |err| {
            slog.err("Failed to copy system update for '{s}': {}", .{ character_name, err });
            return;
        };
        self.system_updates.push(system_update) catch |err| {
            slog.err("Failed to queue system update for '{s}': {}", .{ character_name, err });
        };
    }

    fn copySystemUpdate(self: *ChatlogMonitor, character_name: []const u8, system_name: []const u8, event_ts: u64, is_jump: bool) !queue.SystemUpdate {
        const owned_name = try self.allocator.dupe(u8, character_name);
        errdefer self.allocator.free(owned_name);
        return .{ .character_name = owned_name, .system_name = try self.allocator.dupe(u8, system_name), .event_ts = event_ts, .is_jump = is_jump };
    }

    /// Gated by the type's settings in Painter.notify, once the main thread delivers it.
    fn queueNotification(self: *ChatlogMonitor, character_name: []const u8, notification: notification_mod.Notification) void {
        var event: queue.NotificationEvent = .{ .character_name = "", .notification = .{ .ntype = notification.ntype, .state = notification.state } };
        self.copyNotificationEvent(&event, character_name, notification) catch |err| {
            event.deinit(self.allocator);
            slog.err("Failed to copy {s} notification for '{s}': {}", .{ @tagName(notification.ntype), character_name, err });
            return;
        };
        self.notifications.push(event) catch |err| {
            slog.err("Failed to queue {s} notification for '{s}': {}", .{ @tagName(notification.ntype), character_name, err });
        };
    }

    /// Fills `event` field by field so a partial failure leaves it safe to deinit.
    fn copyNotificationEvent(self: *ChatlogMonitor, event: *queue.NotificationEvent, character_name: []const u8, notification: notification_mod.Notification) !void {
        event.character_name = try self.allocator.dupe(u8, character_name);
        if (notification.source) |source| event.notification.source = try self.allocator.dupe(u8, source);
        if (notification.target) |target| event.notification.target = try self.allocator.dupe(u8, target);
    }

    const LineHandler = struct {
        monitor: *ChatlogMonitor,
        file: *LogFile,

        pub fn onLine(self: LineHandler, line: []const u8) void {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len > 0) self.monitor.parseLine(self.file, trimmed);
        }

        pub fn onLongLine(self: LineHandler, len: usize) void {
            warnLongLine(self.file, len);
        }
    };

    /// Only the first few and then every 100th, since a malformed log can produce thousands.
    fn warnLongLine(file: *LogFile, len: usize) void {
        file.long_line_warnings += 1;
        if (file.long_line_warnings <= 3 or file.long_line_warnings % 100 == 0) {
            slog.warn("Dropping line ({} bytes, over the {}-byte cap) for '{s}' (warning #{})", .{ len, lines.MAX_LINE_LENGTH, file.character_name, file.long_line_warnings });
        }
    }

    fn parseLine(self: *ChatlogMonitor, file: *LogFile, line: []const u8) void {
        if (line.len < MIN_LINE_LENGTH) return;
        if (line.len > lines.MAX_LINE_LENGTH) {
            warnLongLine(file, line.len);
            return;
        }

        if (file.is_chatlog) {
            if (lines.parseChatLine(line)) |system| self.handleSystemChange(file, system, .chatlog);
            return;
        }

        const parsed = lines.parseGameLine(line);
        if (parsed.system) |change| self.handleSystemChange(file, change.system, change.source);
        if (parsed.activity) |activity| switch (activity) {
            .event => self.handleGamelogEvent(file, line),
            .mining => self.handleMiningEvent(file, line),
            .bounty => self.handleBountyEvent(file, line),
        };
    }

    /// Ignores a repeat of the last system; `system` is borrowed and copied into the queued events.
    fn handleSystemChange(self: *ChatlogMonitor, file: *LogFile, system: []const u8, source: lines.SystemSource) void {
        const system_hash = std.hash.Wyhash.hash(0, system);
        if (file.last_system_hash == system_hash) return;
        file.last_system_hash = system_hash;

        // Only jumps notify: undock and Local detection report the same arrival and would fire it twice.
        if (source == .jump) self.queueNotification(file.character_name, .{ .ntype = .SystemChange, .target = system });
        // 0: live lines arrive in order, so need no staleness check. Undocks and Local changes aren't travel.
        self.queueSystemUpdate(file.character_name, system, 0, source == .jump or source == .conduit);
        slog.info("System change ({s}): {s} -> {s}", .{ @tagName(source), file.character_name, system });
    }

    /// Feeds the DPS tracker and queues any notification the line warrants.
    fn handleGamelogEvent(self: *ChatlogMonitor, file: *LogFile, event_text: []const u8) void {
        // Stripped once for both uses; this is the highest-volume line type.
        var stripped_buf: [512]u8 = undefined;
        const stripped_text = activity_mod.stripHtml(event_text, &stripped_buf);

        if (self.combat_tracker) |tracker| {
            if (activity_mod.parseCombatLine(stripped_text)) |parsed| {
                // Filtered weapons still count toward DPS but mustn't retrigger Taking Damage.
                const counts_for_alert = !activity_mod.isWeaponExcluded(parsed.weapon, self.damage_alert_excluded_weapons);
                tracker.addEntry(file.character_name, parsed.amount, parsed.is_incoming, trackerNowMs(), counts_for_alert) catch |err| {
                    slog.warn("Failed to record combat entry for '{s}': {}", .{ file.character_name, err });
                };
            }
        }

        const notification = gamelog_events.classify(stripped_text) orelse return;
        self.queueNotification(file.character_name, notification);
        slog.debug("Gamelog event: {s} -> {s}", .{ file.character_name, event_text });
    }

    /// A missing price counts as 0 ISK; only a missing volume drops the yield, since m3 can't be computed without it.
    fn handleMiningEvent(self: *ChatlogMonitor, file: *LogFile, event_text: []const u8) void {
        const tracker = self.mining_tracker orelse return;
        const parsed = activity_mod.parseMiningLine(event_text) orelse return;
        const global_settings = self.global_settings orelse return;
        const volume_per_unit = global_settings.oreVolume(parsed.name()) orelse {
            slog.warn("Unknown ore, ice or gas '{s}' in mining line, dropping yield", .{parsed.name()});
            return;
        };
        const price_per_unit = global_settings.orePrice(parsed.name()) orelse 0;
        const amount_f: f32 = @floatFromInt(parsed.amount);
        const m3 = amount_f * @as(f32, @floatCast(volume_per_unit));
        const isk = amount_f * @as(f32, @floatCast(price_per_unit));
        tracker.addEntry(file.character_name, m3, isk, trackerNowMs()) catch |err| {
            slog.warn("Failed to record mining entry for '{s}': {}", .{ file.character_name, err });
        };
    }

    fn handleBountyEvent(self: *ChatlogMonitor, file: *LogFile, event_text: []const u8) void {
        const tracker = self.bounty_tracker orelse return;
        const isk = activity_mod.parseBountyLine(event_text) orelse return;
        tracker.addEntry(file.character_name, isk, trackerNowMs()) catch |err| {
            slog.warn("Failed to record bounty entry for '{s}': {}", .{ file.character_name, err });
        };
    }
};

/// win32.Ticks unwrapped to i64, for activity trackers' plain integer arithmetic.
fn trackerNowMs() i64 {
    return @intCast(win32.Ticks.now().ms);
}
