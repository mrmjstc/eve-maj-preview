//! Follows each logged-in character's chatlog and gamelog on a worker thread, and hands what they say to the main thread.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const tracker = @import("activity/tracker.zig");
const scout = @import("clients/scout.zig");
const config = @import("config.zig");
const character_ids_mod = @import("chatlog/character_ids.zig");
const lines = @import("chatlog/lines.zig");
const tail = @import("chatlog/tail.zig");
const discovery = @import("chatlog/discovery.zig");
const queue = @import("chatlog/queue.zig");
const interpret = @import("chatlog/interpret.zig");
const log = @import("log.zig");

const CharacterIds = character_ids_mod.CharacterIds;
const LogFile = tail.LogFile;
const slog = log.Scoped("chatlog");

/// Per worker loop, so a rescan of many characters doesn't keep commands waiting.
const RESCAN_BUDGET_NS = 100 * std.time.ns_per_ms;

/// What the worker found since the last drain, for the main thread to route to the clients; free with deinit and the monitor's allocator.
pub const Findings = struct {
    system_updates: std.ArrayList(queue.SystemUpdate) = .empty,
    notifications: std.ArrayList(queue.NotificationEvent) = .empty,
    session_starts: std.ArrayList(queue.SessionStart) = .empty,
    intel_sightings: std.ArrayList(queue.IntelSighting) = .empty,

    pub fn deinit(self: *Findings, allocator: std.mem.Allocator) void {
        freeAll(queue.SystemUpdate, allocator, &self.system_updates);
        freeAll(queue.NotificationEvent, allocator, &self.notifications);
        freeAll(queue.SessionStart, allocator, &self.session_starts);
        freeAll(queue.IntelSighting, allocator, &self.intel_sightings);
    }
};

pub const ChatlogMonitor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Worker only, but for its folder paths, which never change after init.
    finder: discovery.LogFinder,
    /// Borrowed, outliving the monitor; shared by both threads, as it locks its own map.
    character_ids: ?*CharacterIds,
    /// Worker only, but for its set functions, which run only while the worker is stopped.
    interpreter: interpret.Interpreter,
    /// Set with the interpreter's alert rules; the worker clears it once it has followed the channels they name.
    has_stale_channels: bool = false,
    /// Read by the worker; set by applySettings only while it's stopped.
    idle_poll_threshold: u32 = 20,
    /// Read by the worker; set by applySettings only while it's stopped.
    max_poll_multiplier: u8 = 8,
    /// Read by the worker; set by applySettings only while it's stopped.
    poll_interval_ms: u32 = 50,

    /// Main thread only.
    worker_thread: ?std.Thread = null,
    /// Set by the main thread to stop the worker, which reads it each loop.
    should_exit: std.atomic.Value(bool) = .init(false),
    /// Signalled by the main thread to wake the worker from its poll wait.
    stop_event: win32.HANDLE,
    /// Main thread to worker; each queue locks itself.
    commands: queue.Queue(queue.Command),
    /// Worker to main thread.
    system_updates: queue.Queue(queue.SystemUpdate),
    /// Worker to main thread.
    notifications: queue.Queue(queue.NotificationEvent),
    /// Worker to main thread.
    session_starts: queue.Queue(queue.SessionStart),
    /// Worker to main thread.
    intel_sightings: queue.Queue(queue.IntelSighting),

    /// Main thread only: characters added and not yet removed, so each is sent to the worker once.
    requested: std.StringHashMap(void),

    /// Worker only.
    log_files: std.ArrayList(LogFile) = .empty,
    /// Worker only.
    monitored_paths: std.StringHashMap(void),
    /// Worker only: every added character, including ones with no logs yet, so folder changes keep looking for them.
    wanted: std.StringHashMap(void),
    /// Worker only: which folders changed, for a rescan in progress.
    rescan_changes: discovery.Changes = .{},
    /// Worker only: the characters a rescan in progress still has to check.
    rescan_names: std.ArrayList([]u8) = .empty,
    /// Worker only.
    rescan_index: usize = 0,

    const LineHandler = struct {
        monitor: *ChatlogMonitor,
        file: *LogFile,

        pub fn onLine(self: LineHandler, line: []const u8) void {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len > 0) self.monitor.interpreter.interpret(self.file, trimmed);
        }

        pub fn onLongLine(self: LineHandler, line_length: usize) void {
            interpret.Interpreter.warnLongLine(self.file, line_length);
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, chatlog_config: *const config.ChatlogConfig, global_settings: ?*config.GlobalConfig, character_ids: ?*CharacterIds) !*ChatlogMonitor {
        const monitor = try allocator.create(ChatlogMonitor);
        errdefer allocator.destroy(monitor);
        const stop_event = win32.CreateEventA(null, win32.TRUE, win32.FALSE, null) orelse return error.CreateEventFailed;
        errdefer _ = win32.CloseHandle(stop_event);
        monitor.* = .{
            .allocator = allocator,
            .io = io,
            .stop_event = stop_event,
            .finder = try discovery.LogFinder.init(allocator, io, chatlog_config.chatlogDir, chatlog_config.gamelogDir, character_ids),
            .character_ids = character_ids,
            .interpreter = .{
                .allocator = allocator,
                .outbox = .{ .system_updates = &monitor.system_updates, .notifications = &monitor.notifications, .intel_sightings = &monitor.intel_sightings },
                .own_characters = &monitor.wanted,
                .global_settings = global_settings,
            },
            .commands = .init(allocator, io),
            .system_updates = .init(allocator, io),
            .notifications = .init(allocator, io),
            .session_starts = .init(allocator, io),
            .intel_sightings = .init(allocator, io),
            .requested = .init(allocator),
            .monitored_paths = .init(allocator),
            .wanted = .init(allocator),
        };
        monitor.applySettings(chatlog_config);
        return monitor;
    }

    pub fn deinit(self: *ChatlogMonitor) void {
        self.stopWorkerThread();
        _ = win32.CloseHandle(self.stop_event);
        self.commands.deinit();
        self.system_updates.deinit();
        self.notifications.deinit();
        self.session_starts.deinit();
        self.intel_sightings.deinit();
        freeKeys(self.allocator, &self.requested);
        freeKeys(self.allocator, &self.wanted);
        freeKeys(self.allocator, &self.monitored_paths);
        self.clearRescanNames();
        self.rescan_names.deinit(self.allocator);
        self.finder.deinit();
        for (self.log_files.items) |*file| file.deinit(self.allocator, self.io);
        self.log_files.deinit(self.allocator);
        self.interpreter.deinit();
    }

    fn freeKeys(allocator: std.mem.Allocator, map: *std.StringHashMap(void)) void {
        var keys = map.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        map.deinit();
    }

    /// Whether this monitor already watches what `chatlog_config` asks for, so a reload can keep it and its scan state.
    pub fn runsWith(self: *const ChatlogMonitor, chatlog_config: *const config.ChatlogConfig) bool {
        return chatlog_config.enabled and
            std.mem.eql(u8, chatlog_config.chatlogDir, self.finder.chatlog_dir) and
            std.mem.eql(u8, chatlog_config.gamelogDir, self.finder.gamelog_dir);
    }

    /// The polling settings a profile reload can change without rebuilding the monitor; only while the worker is stopped.
    pub fn applySettings(self: *ChatlogMonitor, chatlog_config: *const config.ChatlogConfig) void {
        if (!self.isWorkerStopped("polling settings")) return;
        self.idle_poll_threshold = chatlog_config.idlePollThreshold;
        self.max_poll_multiplier = chatlog_config.maxPollMultiplier;
        self.poll_interval_ms = chatlog_config.pollIntervalMs;
    }

    /// The profile's chat-alert rules and Taking Damage weapon filter; only while the worker is stopped.
    pub fn applyProfile(self: *ChatlogMonitor, settings: *const config.Config) void {
        if (!self.isWorkerStopped("chat alerts and weapon filter")) return;
        self.interpreter.setDamageAlertExcludedWeapons(settings.combat.damage_alert_excluded_weapons);
        if (self.interpreter.setChatAlerts(settings.chatAlerts.items, settings.characters.items)) self.has_stale_channels = true;
    }

    /// Borrows the trackers; only while the worker is stopped.
    pub fn setTrackers(self: *ChatlogMonitor, combat: ?*tracker.CombatTracker, mining: ?*tracker.MiningTracker, bounty: ?*tracker.BountyTracker) void {
        if (!self.isWorkerStopped("trackers")) return;
        self.interpreter.setTrackers(combat, mining, bounty);
    }

    /// Logs rather than asserts when it's running, so a misordered call costs a setting instead of the app.
    pub fn isWorkerStopped(self: *const ChatlogMonitor, setting: []const u8) bool {
        if (self.worker_thread == null) return true;
        slog.err("Failed to change chatlog {s}: the worker thread is running", .{setting});
        return false;
    }

    /// Pauses the worker; what it follows, and any rescan in progress, carry on when it's started again.
    pub fn stopWorkerThread(self: *ChatlogMonitor) void {
        const thread = self.worker_thread orelse return;
        self.should_exit.store(true, .release);
        _ = win32.SetEvent(self.stop_event);
        thread.join();
        self.worker_thread = null;
    }

    pub fn startWorkerThread(self: *ChatlogMonitor) !void {
        if (self.worker_thread != null) return error.AlreadyRunning;
        self.should_exit.store(false, .release);
        _ = win32.ResetEvent(self.stop_event);
        self.worker_thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    /// Main thread only.
    pub fn addCharacter(self: *ChatlogMonitor, character_name: []const u8) !void {
        if (scout.isGenericCharacterName(character_name) or self.requested.contains(character_name)) return;
        const key = try self.allocator.dupe(u8, character_name);
        errdefer self.allocator.free(key);
        try self.commands.push(.{ .add_character = try self.allocator.dupe(u8, character_name) });
        try self.requested.put(key, {});
        slog.debug("Queued character for worker: {s}", .{character_name});
    }

    fn removeCharacter(self: *ChatlogMonitor, character_name: []const u8) !void {
        if (!self.requested.contains(character_name)) return;
        // Queued first, so a failed push leaves the character still requested, matching what the worker follows.
        try self.commands.push(.{ .remove_character = try self.allocator.dupe(u8, character_name) });
        const entry = self.requested.fetchRemove(character_name) orelse return;
        self.allocator.free(entry.key);
    }

    /// Backfills a character's ID from its existing logs without following them, unlike addCharacter.
    pub fn resolveCharacterId(self: *ChatlogMonitor, character_name: []const u8) !void {
        try self.commands.push(.{ .resolve_character_id = try self.allocator.dupe(u8, character_name) });
    }

    pub fn update(self: *ChatlogMonitor, scout_result: *const scout.UpdateResult) !void {
        for (scout_result.closed_windows.items) |closed| try self.removeCharacter(closed.character_name);
        for (scout_result.name_changes.items) |change| {
            if (scout.isGenericCharacterName(change.new_name) and !scout.isGenericCharacterName(change.old_name)) {
                try self.removeCharacter(change.old_name);
            }
        }
        for (scout_result.windows) |window| {
            if (window.is_eve_client) try self.addCharacter(window.character_name);
        }
    }

    /// Takes what the worker has found since the last call; a queue that fails to drain keeps its events for the next one.
    pub fn drain(self: *ChatlogMonitor) Findings {
        var findings: Findings = .{};
        drainLogged(queue.SystemUpdate, &self.system_updates, &findings.system_updates, "system updates");
        drainLogged(queue.NotificationEvent, &self.notifications, &findings.notifications, "notifications");
        drainLogged(queue.SessionStart, &self.session_starts, &findings.session_starts, "session starts");
        drainLogged(queue.IntelSighting, &self.intel_sightings, &findings.intel_sightings, "intel sightings");
        return findings;
    }

    fn workerMain(self: *ChatlogMonitor) void {
        slog.info("Chatlog worker thread started (TID: {})", .{std.Thread.getCurrentId()});
        var loop_count: u64 = 0;
        while (!self.should_exit.load(.acquire)) : (loop_count += 1) {
            self.processCommands() catch |err| slog.err("Failed to process worker commands: {}", .{err});
            self.pollLogFiles();
            self.rescanForNewLogs() catch |err| slog.err("Failed to rescan for new logs: {}", .{err});
            _ = win32.WaitForSingleObject(self.stop_event, self.poll_interval_ms);
        }
        slog.info("Chatlog worker thread exiting (processed {} loops)", .{loop_count});
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
        self.followChannels(character_name);
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
        self.addLogFile(path, character_name, if (is_chatlog) lines.LOCAL_CHANNEL else "", is_chatlog) catch |err| {
            slog.err("Failed to follow {s} '{s}' for '{s}': {}", .{ if (is_chatlog) "chatlog" else "gamelog", path, character_name, err });
        };
    }

    /// Needs the character's Local log, which dates its session.
    fn followChannels(self: *ChatlogMonitor, character_name: []const u8) void {
        const rules = self.interpreter.alertRules() orelse return;
        if (rules.rules.len == 0) return;
        const session_start = self.sessionStart(character_name) orelse return;

        var logs = self.finder.findChannels(character_name, session_start);
        defer {
            for (logs.items) |*channel_log| channel_log.deinit(self.allocator);
            logs.deinit(self.allocator);
        }
        for (logs.items) |channel_log| {
            if (!rules.followsChannel(channel_log.channel)) continue;
            self.addLogFile(channel_log.path, character_name, channel_log.channel, true) catch |err| {
                slog.err("Failed to follow channel '{s}' for '{s}': {}", .{ channel_log.channel, character_name, err });
            };
        }
    }

    /// UTC Unix seconds; EVE opens a character's channel logs as it opens Local.
    fn sessionStart(self: *const ChatlogMonitor, character_name: []const u8) ?i64 {
        for (self.log_files.items) |*file| {
            if (!file.is_chatlog or file.isChannelLog() or !std.mem.eql(u8, file.character_name, character_name)) continue;
            return lines.logTimestampToUnixSeconds(lines.logFileTimestamp(std.Io.Dir.path.basename(file.path), true));
        }
        return null;
    }

    /// After the rules change, as nothing else lets go of a channel that's still written to.
    fn dropUnfollowedChannels(self: *ChatlogMonitor) void {
        var i: usize = 0;
        while (i < self.log_files.items.len) {
            const file = &self.log_files.items[i];
            const is_followed = if (self.interpreter.alertRules()) |rules| rules.followsChannel(file.channel_name) else false;
            if (!file.isChannelLog() or is_followed) {
                i += 1;
                continue;
            }
            slog.info("Stopped monitoring channel '{s}' for {s}", .{ file.channel_name, file.character_name });
            self.dropLogFile(i);
        }
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

        self.interpreter.forget(character_name);
    }

    fn resolveId(self: *const ChatlogMonitor, character_name: []const u8) void {
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

    fn addLogFile(self: *ChatlogMonitor, path: []const u8, character_name: []const u8, channel_name: []const u8, is_chatlog: bool) !void {
        if (self.monitored_paths.contains(path)) return;

        // A newer file for the same character and channel replaces the old one: EVE started a new session.
        var i: usize = 0;
        while (i < self.log_files.items.len) {
            const file = &self.log_files.items[i];
            if (file.is_chatlog != is_chatlog or !std.mem.eql(u8, file.character_name, character_name) or !std.mem.eql(u8, file.channel_name, channel_name)) {
                i += 1;
                continue;
            }
            slog.info("Log rotated for {s} ({s}): {s} -> {s}", .{ character_name, if (is_chatlog) "chatlog" else "gamelog", file.path, path });
            self.dropLogFile(i);
        }

        {
            var file = try LogFile.init(self.allocator, path, character_name, channel_name, is_chatlog);
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

        const initial_system = new_file.start(self.allocator, self.io) catch |err| blk: {
            slog.warn("Failed to read the current system from '{s}' for '{s}', following it from its end: {}", .{ path, character_name, err });
            break :blk null;
        };
        if (initial_system) |match| {
            slog.debug("Initial system for {s}: {s} (event_timestamp={})", .{ character_name, match.system, match.event_timestamp });
            // Not a jump: it's where the character already was.
            self.interpreter.queueSystemUpdate(character_name, match.system, match.event_timestamp, false);
        }
        if (!is_chatlog) self.queueSessionStart(character_name, std.Io.Dir.path.basename(path));

        slog.info("Monitoring {s} for {s}: {s}", .{ if (is_chatlog) "chatlog" else "gamelog", character_name, path });
    }

    fn pollLogFiles(self: *ChatlogMonitor) void {
        const backoff: tail.Backoff = .{ .idle_threshold = self.idle_poll_threshold, .max_multiplier = self.max_poll_multiplier };
        for (self.log_files.items) |*file| file.poll(self.allocator, self.io, backoff, LineHandler{ .monitor = self, .file = file });
    }

    fn clearRescanNames(self: *ChatlogMonitor) void {
        for (self.rescan_names.items) |name| self.allocator.free(name);
        self.rescan_names.clearRetainingCapacity();
    }

    /// Once EVE creates files in a log folder, checks every wanted character for a newer log there; spread over several loops past RESCAN_BUDGET_NS.
    fn rescanForNewLogs(self: *ChatlogMonitor) !void {
        const start_time_ns = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();

        if (!self.rescan_changes.hasAny()) {
            var changes = self.finder.changes();
            if (self.has_stale_channels) {
                self.has_stale_channels = false;
                self.dropUnfollowedChannels();
                // The logs of a newly named channel already exist, so the folder won't signal them.
                changes.chatlog_changed = true;
            }
            if (!changes.hasAny()) return;
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
            slog.debug("New log file scan started (chatlog={}, gamelog={})", .{ changes.chatlog_changed, changes.gamelog_changed });
        }

        const names = self.rescan_names.items;
        while (self.rescan_index < names.len) : (self.rescan_index += 1) {
            if (std.Io.Timestamp.now(self.io, .awake).toNanoseconds() - start_time_ns > RESCAN_BUDGET_NS) {
                slog.debug("Log file scan paused at character {}/{}, continuing next loop", .{ self.rescan_index, names.len });
                return;
            }
            const name = names[self.rescan_index];
            if (!self.wanted.contains(name)) continue;
            // addLogFile skips a file already followed.
            if (self.rescan_changes.chatlog_changed) {
                self.followNewestLog(name, true);
                self.followChannels(name);
            }
            if (self.rescan_changes.gamelog_changed) self.followNewestLog(name, false);
        }

        self.finder.rearm(self.rescan_changes);
        self.rescan_changes = .{};
        self.rescan_index = 0;
        self.clearRescanNames();
        slog.debug("Log file scan completed", .{});
    }

    /// EVE starts a new gamelog at each login, named for when it did.
    fn queueSessionStart(self: *ChatlogMonitor, character_name: []const u8, file_name: []const u8) void {
        const started_at = lines.logTimestampToUnixSeconds(lines.logFileTimestamp(file_name, false)) orelse return;
        const owned_name = self.allocator.dupe(u8, character_name) catch |err| {
            slog.err("Failed to copy session start for '{s}': {}", .{ character_name, err });
            return;
        };
        self.session_starts.push(.{ .character_name = owned_name, .started_at = started_at }) catch |err| {
            slog.err("Failed to queue session start for '{s}': {}", .{ character_name, err });
        };
    }
};

fn drainLogged(comptime T: type, from: *queue.Queue(T), to: *std.ArrayList(T), kind: []const u8) void {
    from.drain(to) catch |err| {
        slog.err("Failed to collect the chatlog worker's {s}, keeping them for the next tick: {}", .{ kind, err });
    };
}

fn freeAll(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(T)) void {
    for (list.items) |*item| item.deinit(allocator);
    list.deinit(allocator);
}
