const std = @import("std");
const win32 = @import("win32.zig");
const log = @import("log.zig");
const types = @import("types.zig");
const activity_mod = @import("activity_tracker.zig");
const scout_mod = @import("scout.zig");
const painter_mod = @import("painter.zig");
const config_mod = @import("config.zig");
const slog = log.scoped("chatlog");

/// Event sent from worker thread to main thread: apply a system-name update.
/// hwnd is resolved by the receiver (main thread) via Scout, not by the sender -
/// only the main thread may touch Scout/Painter, since both are mutated every
/// tick by the main thread and aren't synchronized for cross-thread access.
pub const SystemUpdateEvent = struct {
    character_name: []const u8,
    system_name: []const u8,
    // 0 = no staleness check (live-tail lines are already strictly ordered)
    event_ts: u64,
    // True only for stargate/conduit jumps; feeds Travel Mode's last-jump tracking.
    is_jump: bool = false,

    pub fn deinit(self: *SystemUpdateEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
        allocator.free(self.system_name);
    }
};

/// Event sent from worker thread to main thread: show a notification.
pub const NotificationEvent = struct {
    character_name: []const u8,
    text: []const u8,
    ntype: types.NotificationType,

    pub fn deinit(self: *NotificationEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
        allocator.free(self.text);
    }
};

/// Commands sent from main thread to worker thread
pub const ChatlogCommand = union(enum) {
    add_character: struct {
        // Owned by command, must be freed by receiver
        name: []const u8,
    },
    // Owned by command, must be freed by receiver
    remove_character: []const u8,
    // Owned by command, must be freed by receiver
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

/// Thread-safe event queue for cross-thread communication
pub fn EventQueue(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex,
        events: std.ArrayList(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .mutex = .{},
                .events = std.ArrayList(T).empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.events.deinit(self.allocator);
        }

        pub fn push(self: *Self, event: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.events.append(self.allocator, event);
        }

        pub fn drain(self: *Self, out_list: *std.ArrayList(T)) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try out_list.appendSlice(self.allocator, self.events.items);
            self.events.clearRetainingCapacity();
        }

        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.events.items.len;
        }
    };
}

/// Caps memory use on malformed logs; 4KB covers combat logs with color tags (up to 2-3KB).
const MAX_LINE_LENGTH = 4000;

/// Minimum line length to consider (timestamp + space = ~20 chars)
const MIN_LINE_LENGTH = 25;

/// Optimized chunk size for backward scanning (8KB)
const SCAN_CHUNK_SIZE = 8192;

/// Upper bound on how far findSystemBackward scans back from EOF. This runs
/// synchronously on the main thread by default, so it's bounded, not unbounded.
const MAX_BACKWARD_SCAN_BYTES: u64 = 8 * 1024 * 1024;

/// Maximum size for partial line buffer (combat logs with color tags can be long)
const MAX_PARTIAL_LINE_SIZE = 1024;

pub const LogFileState = struct {
    file_path: []const u8,
    character_name: []const u8,
    position: u64 = 0,
    last_size: u64 = 0,
    last_modified: i64 = 0,
    partial_line_buffer: [MAX_PARTIAL_LINE_SIZE]u8 = undefined,
    partial_line_len: usize = 0,
    // true for chatlog (UTF-16 LE), false for gamelog (UTF-8)
    is_chatlog: bool,
    had_activity: bool = false,
    // Permanently disabled after an unrecoverable error
    disabled: bool = false,
    has_bom: bool = false,
    last_system_hash: u64 = 0,
    idle_checks: u32 = 0,
    cycle_counter: u32 = 0,
    // 1x, 2x, 4x, 8x backoff multiplier
    poll_interval_multiplier: u8 = 1,
    // Pooled buffers, reused across polls to avoid per-line heap allocations
    utf8_buffer: std.ArrayList(u8),
    line_buffer: std.ArrayList(u8),
    u16_buffer: std.ArrayList(u16),
    system_name_buffer: std.ArrayList(u8),
    excessive_data_warnings: u32 = 0,

    pub fn deinit(self: *LogFileState, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.character_name);
        self.utf8_buffer.deinit(allocator);
        self.line_buffer.deinit(allocator);
        self.u16_buffer.deinit(allocator);
        self.system_name_buffer.deinit(allocator);
    }
};

pub const ChatlogMonitor = struct {
    allocator: std.mem.Allocator,
    log_files: std.ArrayList(LogFileState),
    monitored_paths: std.StringHashMap(void),
    chatlog_dir: []const u8,
    gamelog_dir: []const u8,
    chatlog_watcher: win32.HANDLE,
    gamelog_watcher: win32.HANDLE,
    enabled: bool = true,
    painter: ?*painter_mod.Painter = null,
    scout: ?*scout_mod.Scout = null,
    global_settings: ?*config_mod.GlobalSettings = null,
    combat_tracker: ?*activity_mod.CombatTracker = null,
    mining_tracker: ?*activity_mod.MiningTracker = null,
    bounty_tracker: ?*activity_mod.BountyTracker = null,
    // Borrowed from Config, not Painter - set only while the worker is stopped, like combat_tracker.
    damage_alert_excluded_weapons: []const u8 = "",
    idle_poll_threshold: u32 = 20,
    max_poll_multiplier: u8 = 8,
    poll_interval_ms: u32 = 50,
    last_sync_poll_ms: i64 = 0,
    pending_scan_index: usize = 0,
    pending_chatlog_signaled: bool = false,
    pending_gamelog_signaled: bool = false,
    // Owned snapshot of character names for the in-progress scan; immune to Scout.windows reordering mid-scan.
    pending_scan_names: std.ArrayList([]u8) = .empty,
    worker_thread: ?std.Thread = null,
    command_queue: EventQueue(ChatlogCommand),
    result_queue: EventQueue(SystemUpdateEvent),
    notification_queue: EventQueue(NotificationEvent),
    should_exit: std.atomic.Value(bool),
    threading_enabled: bool = false,
    pending_characters: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, chatlog_dir: []const u8, gamelog_dir: []const u8, painter_ref: ?*painter_mod.Painter, scout_ref: ?*scout_mod.Scout, global_settings_ref: ?*config_mod.GlobalSettings, idle_poll_threshold: u32, max_poll_multiplier: u8, poll_interval_ms: u32) !*ChatlogMonitor {
        if (!std.unicode.utf8ValidateSlice(chatlog_dir)) {
            slog.err("Chatlog directory path contains invalid UTF-8", .{});
            return error.InvalidUtf8;
        }
        if (!std.unicode.utf8ValidateSlice(gamelog_dir)) {
            slog.err("Gamelog directory path contains invalid UTF-8", .{});
            return error.InvalidUtf8;
        }

        const monitor = try allocator.create(ChatlogMonitor);
        errdefer allocator.destroy(monitor);

        monitor.allocator = allocator;
        monitor.log_files = .empty;
        monitor.monitored_paths = std.StringHashMap(void).init(allocator);
        monitor.chatlog_dir = try allocator.dupe(u8, chatlog_dir);
        errdefer allocator.free(monitor.chatlog_dir);
        monitor.gamelog_dir = try allocator.dupe(u8, gamelog_dir);
        errdefer allocator.free(monitor.gamelog_dir);
        monitor.enabled = true;
        monitor.painter = painter_ref;
        monitor.scout = scout_ref;
        monitor.global_settings = global_settings_ref;
        monitor.combat_tracker = null;
        monitor.mining_tracker = null;
        monitor.bounty_tracker = null;
        monitor.idle_poll_threshold = idle_poll_threshold;
        monitor.max_poll_multiplier = max_poll_multiplier;
        monitor.last_sync_poll_ms = 0;
        monitor.pending_scan_index = 0;
        monitor.pending_chatlog_signaled = false;
        monitor.pending_gamelog_signaled = false;
        monitor.pending_scan_names = .empty;

        monitor.worker_thread = null;
        monitor.command_queue = EventQueue(ChatlogCommand).init(allocator);
        monitor.result_queue = EventQueue(SystemUpdateEvent).init(allocator);
        monitor.notification_queue = EventQueue(NotificationEvent).init(allocator);
        monitor.should_exit = std.atomic.Value(bool).init(false);
        monitor.threading_enabled = false;
        monitor.pending_characters = std.StringHashMap(void).init(allocator);
        monitor.poll_interval_ms = poll_interval_ms;

        monitor.chatlog_watcher = monitor.setupDirectoryWatcher(chatlog_dir);
        errdefer if (monitor.chatlog_watcher != win32.INVALID_HANDLE_VALUE) {
            _ = win32.FindCloseChangeNotification(monitor.chatlog_watcher);
        };
        monitor.gamelog_watcher = monitor.setupDirectoryWatcher(gamelog_dir);

        if (monitor.chatlog_watcher != win32.INVALID_HANDLE_VALUE or monitor.gamelog_watcher != win32.INVALID_HANDLE_VALUE) {
            slog.debug("File system watchers initialized for log directories (chatlog={}, gamelog={})", .{
                monitor.chatlog_watcher != win32.INVALID_HANDLE_VALUE,
                monitor.gamelog_watcher != win32.INVALID_HANDLE_VALUE,
            });
        }

        return monitor;
    }

    /// Stops the worker thread only - log_files/monitored_paths are left intact.
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

    /// Worker thread main loop - runs I/O operations asynchronously
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

            // Check for new files (blocking I/O) - use longer time budget since we're not blocking UI
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

            if (loop_count % 1000 == 0) {
                const cmd_queue_len = monitor.command_queue.len();
                const result_queue_len = monitor.result_queue.len();
                slog.debug("Worker thread stats: loop={}, cmd_queue={}, result_queue={}, log_files={}", .{
                    loop_count,
                    cmd_queue_len,
                    result_queue_len,
                    monitor.log_files.items.len,
                });
            }

            // Sleep briefly to avoid busy-wait
            win32.Sleep(monitor.poll_interval_ms);
        }

        slog.info("Worker thread exiting (processed {} loops)", .{loop_count});
    }

    /// Process commands from main thread (add/remove characters, shutdown)
    fn processCommands(self: *ChatlogMonitor) !void {
        var commands = std.ArrayList(ChatlogCommand).empty;
        defer commands.deinit(self.allocator);
        try self.command_queue.drain(&commands);

        for (commands.items) |*mutable_cmd| {
            defer mutable_cmd.deinit(self.allocator);

            switch (mutable_cmd.*) {
                .add_character => |data| {
                    slog.debug("Worker: Add character {s}", .{data.name});

                    if (self.findChatlogForCharacter(data.name)) |chatlog_path| {
                        defer self.allocator.free(chatlog_path);
                        self.addLogFile(chatlog_path, data.name, true) catch |err| {
                            slog.err("Worker: Failed to add chatlog for {s}: {}", .{ data.name, err });
                        };
                    }

                    if (self.findGamelogForCharacter(data.name)) |gamelog_path| {
                        defer self.allocator.free(gamelog_path);
                        self.addLogFile(gamelog_path, data.name, false) catch |err| {
                            slog.err("Worker: Failed to add gamelog for {s}: {}", .{ data.name, err });
                        };
                    }
                },
                .remove_character => |char_name| {
                    slog.debug("Worker: Remove character {s}", .{char_name});
                    self.removeCharacter(char_name);
                },
                .resolve_character_id => |data| {
                    const needs_lookup = if (self.global_settings) |gs| !gs.characterIdMap.contains(data.name) else false;
                    if (!needs_lookup) continue;

                    slog.debug("Worker: Resolving character ID for {s}", .{data.name});
                    if (self.findChatlogForCharacter(data.name)) |path| {
                        self.allocator.free(path);
                    } else if (self.findGamelogForCharacter(data.name)) |path| {
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

    /// Get current list of monitored character names (for worker thread).
    /// Borrowed from log_files, not duped - safe since only the worker thread mutates it.
    fn getCurrentCharacterList(self: *ChatlogMonitor) !std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).empty;
        errdefer list.deinit(self.allocator);

        for (self.log_files.items) |*state| {
            try list.append(self.allocator, state.character_name);
        }

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

        self.clearPendingScanNames();
        self.pending_scan_names.deinit(self.allocator);

        if (self.chatlog_watcher != win32.INVALID_HANDLE_VALUE) {
            _ = win32.FindCloseChangeNotification(self.chatlog_watcher);
        }
        if (self.gamelog_watcher != win32.INVALID_HANDLE_VALUE) {
            _ = win32.FindCloseChangeNotification(self.gamelog_watcher);
        }

        for (self.log_files.items) |*state| {
            state.deinit(self.allocator);
        }
        self.log_files.deinit(self.allocator);

        // Free HashMap keys (values are void)
        var key_iter = self.monitored_paths.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.monitored_paths.deinit();

        self.allocator.free(self.chatlog_dir);
        self.allocator.free(self.gamelog_dir);
    }

    /// Add a character to monitor (finds and tracks their chat and game logs).
    /// Queues a command for the worker thread if threading is enabled, otherwise does the I/O synchronously.
    pub fn addCharacter(self: *ChatlogMonitor, character_name: []const u8) !void {
        if (self.threading_enabled) {
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

        // Sync mode: I/O on main thread, added only on an exact character name match.
        if (self.findChatlogForCharacter(character_name)) |chatlog_path| {
            try self.addLogFile(chatlog_path, character_name, true);
            self.allocator.free(chatlog_path);
        }

        if (self.findGamelogForCharacter(character_name)) |gamelog_path| {
            try self.addLogFile(gamelog_path, character_name, false);
            self.allocator.free(gamelog_path);
        }
    }

    /// Backfills a character's ID from existing log files without monitoring them (unlike addCharacter); worker-thread only.
    pub fn resolveCharacterId(self: *ChatlogMonitor, character_name: []const u8) !void {
        if (!self.threading_enabled) return;

        const cmd = ChatlogCommand{
            .resolve_character_id = .{
                .name = try self.allocator.dupe(u8, character_name),
            },
        };
        try self.command_queue.push(cmd);
    }

    /// Remove all log files for a character (called when character logs out)
    pub fn removeCharacter(self: *ChatlogMonitor, character_name: []const u8) void {
        var i: usize = 0;
        while (i < self.log_files.items.len) {
            const state = &self.log_files.items[i];
            if (std.mem.eql(u8, state.character_name, character_name)) {
                // Log before cleanup (while file_path is still valid)
                slog.info("Stopped monitoring {s} for {s}: {s}", .{
                    if (state.is_chatlog) "chatlog" else "gamelog",
                    character_name,
                    state.file_path,
                });

                _ = self.monitored_paths.remove(state.file_path);

                var removed = self.log_files.orderedRemove(i);
                removed.deinit(self.allocator);

                if (self.combat_tracker) |tracker| {
                    tracker.removeCharacter(character_name);
                }

                if (self.mining_tracker) |tracker| {
                    tracker.removeCharacter(character_name);
                }

                if (self.bounty_tracker) |tracker| {
                    tracker.removeCharacter(character_name);
                }

                // Don't increment i, check same index again
            } else {
                i += 1;
            }
        }
    }

    fn addLogFile(self: *ChatlogMonitor, file_path: []const u8, character_name: []const u8, is_chatlog: bool) !void {
        if (self.monitored_paths.contains(file_path)) {
            return;
        }

        {
            const duped_path = try self.allocator.dupe(u8, file_path);
            errdefer self.allocator.free(duped_path);
            const character_name_copy = try self.allocator.dupe(u8, character_name);
            errdefer self.allocator.free(character_name_copy);

            const state: LogFileState = .{
                .file_path = duped_path,
                .character_name = character_name_copy,
                .is_chatlog = is_chatlog,
                .utf8_buffer = .empty,
                .line_buffer = .empty,
                .u16_buffer = .empty,
                .system_name_buffer = .empty,
            };

            try self.log_files.append(self.allocator, state);
        }

        const new_entry = &self.log_files.items[self.log_files.items.len - 1];

        {
            // Must dupe again since HashMap owns the key
            const hashmap_key = try self.allocator.dupe(u8, new_entry.file_path);
            errdefer self.allocator.free(hashmap_key);
            try self.monitored_paths.put(hashmap_key, {});
        }

        try self.readInitialState(new_entry);

        slog.info("Monitoring {s} for {s}: {s}", .{
            if (is_chatlog) "chatlog" else "gamelog",
            character_name,
            file_path,
        });
    }

    pub fn pollLogFiles(self: *ChatlogMonitor) !void {
        for (self.log_files.items) |*state| {
            if (state.disabled) continue;

            // Exponential backoff: only poll every Nth cycle based on multiplier
            state.cycle_counter += 1;
            if (state.cycle_counter < state.poll_interval_multiplier) {
                continue;
            }
            state.cycle_counter = 0;

            const file = std.fs.cwd().openFile(state.file_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    // Temporary failure - reset state but keep trying
                    state.position = 0;
                    state.last_size = 0;
                    state.partial_line_len = 0;
                    continue;
                },
                error.InvalidWtf8 => {
                    // Permanent failure - disable this state forever
                    slog.warn("Disabling log file {s} due to InvalidWtf8", .{state.character_name});
                    state.disabled = true;
                    continue;
                },
                else => {
                    // Other errors - skip this iteration but keep trying
                    slog.warn("Failed to open {s}: {}", .{ state.file_path, err });
                    continue;
                },
            };
            defer file.close();

            self.readNewLines(state, file) catch |err| {
                slog.err("Error reading {s}: {}", .{ state.file_path, err });
                continue;
            };
        }
    }

    fn setupDirectoryWatcher(self: *ChatlogMonitor, dir_path: []const u8) win32.HANDLE {
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, dir_path) catch |err| {
            slog.warn("Failed to convert path to UTF-16 for {s}: {} - chatlog monitoring will be disabled for this directory", .{ dir_path, err });
            return win32.INVALID_HANDLE_VALUE;
        };
        defer self.allocator.free(path_w);

        // Watch for new files only (FILE_NOTIFY_CHANGE_FILE_NAME)
        const handle = win32.FindFirstChangeNotificationW(
            path_w.ptr,
            // Don't watch subdirectories
            win32.FALSE,
            win32.FILE_NOTIFY_CHANGE_FILE_NAME,
        );

        if (handle == win32.INVALID_HANDLE_VALUE) {
            slog.warn("Failed to setup directory watcher for {s} - chatlog monitoring will be disabled for this directory", .{dir_path});
            return win32.INVALID_HANDLE_VALUE;
        }

        return handle;
    }

    /// Free and clear the owned scan-name snapshot (call on scan completion or teardown).
    fn clearPendingScanNames(self: *ChatlogMonitor) void {
        for (self.pending_scan_names.items) |name| self.allocator.free(name);
        self.pending_scan_names.clearRetainingCapacity();
    }

    /// Check for new log files using file system watchers with time budget (non-blocking)
    /// This handles both new character logins AND log rotation for existing characters
    /// Returns true if more work is pending (exceeded time budget), false if complete
    pub fn checkNewLogFiles(self: *ChatlogMonitor, character_names: []const []const u8, max_time_ns: u64) !bool {
        const start_time = std.time.nanoTimestamp();

        // Check if we're continuing previous work or starting new scan
        if (!self.pending_chatlog_signaled and !self.pending_gamelog_signaled) {
            const chatlog_signaled = if (self.chatlog_watcher != win32.INVALID_HANDLE_VALUE)
                win32.WaitForSingleObject(self.chatlog_watcher, 0) == win32.WAIT_OBJECT_0
            else
                false;
            const gamelog_signaled = if (self.gamelog_watcher != win32.INVALID_HANDLE_VALUE)
                win32.WaitForSingleObject(self.gamelog_watcher, 0) == win32.WAIT_OBJECT_0
            else
                false;

            if (!chatlog_signaled and !gamelog_signaled) {
                // No new files, no work to do
                return false;
            }

            self.pending_chatlog_signaled = chatlog_signaled;
            self.pending_gamelog_signaled = gamelog_signaled;
            self.pending_scan_index = 0;

            // Snapshot into owned memory: character_names aliases Scout.windows, which orderedRemove() can reshuffle mid-scan.
            self.clearPendingScanNames();
            for (character_names) |name| {
                const copy = try self.allocator.dupe(u8, name);
                try self.pending_scan_names.append(self.allocator, copy);
            }

            slog.debug("New log file scan started (chatlog={}, gamelog={})", .{ chatlog_signaled, gamelog_signaled });
        }

        const scan_names = self.pending_scan_names.items;

        // Process characters incrementally with time budget
        while (self.pending_scan_index < scan_names.len) : (self.pending_scan_index += 1) {
            const elapsed = std.time.nanoTimestamp() - start_time;
            if (elapsed > max_time_ns) {
                slog.debug("Time budget exceeded at character {}/{} ({}ns > {}ns), deferring remaining work", .{
                    self.pending_scan_index,
                    scan_names.len,
                    elapsed,
                    max_time_ns,
                });
                return true;
            }

            const char_name = scan_names[self.pending_scan_index];

            // Skip generic "EVE" name (logged out or loading windows)
            if (scout_mod.isGenericCharacterName(char_name)) continue;

            if (self.pending_chatlog_signaled) {
                if (self.findChatlogForCharacter(char_name)) |chatlog_path| {
                    defer self.allocator.free(chatlog_path);
                    // addLogFile automatically skips if already monitoring this path
                    try self.addLogFile(chatlog_path, char_name, true);
                }
            }

            if (self.pending_gamelog_signaled) {
                if (self.findGamelogForCharacter(char_name)) |gamelog_path| {
                    defer self.allocator.free(gamelog_path);
                    // addLogFile automatically skips if already monitoring this path
                    try self.addLogFile(gamelog_path, char_name, false);
                }
            }
        }

        // All characters processed - reset watchers and clear pending state
        if (self.pending_chatlog_signaled) {
            if (self.chatlog_watcher != win32.INVALID_HANDLE_VALUE) {
                _ = win32.FindNextChangeNotification(self.chatlog_watcher);
            }
            self.pending_chatlog_signaled = false;
        }
        if (self.pending_gamelog_signaled) {
            if (self.gamelog_watcher != win32.INVALID_HANDLE_VALUE) {
                _ = win32.FindNextChangeNotification(self.gamelog_watcher);
            }
            self.pending_gamelog_signaled = false;
        }
        self.clearPendingScanNames();
        self.pending_scan_index = 0;

        slog.debug("Log file scan completed", .{});
        return false;
    }

    /// Main update cycle - performs all Chatlog operations for a single tick
    pub fn update(self: *ChatlogMonitor, character_names: []const []const u8, closed_windows: []const scout_mod.ClosedWindow, logged_out_names: []const []const u8) !void {
        // In Phase 1 (synchronous mode), handle I/O directly on main thread
        if (!self.threading_enabled) {
            // pollLogFiles()'s per-file backoff assumes fixed-interval calls, which this UI-tick-driven path doesn't guarantee.
            const now_ms = std.time.milliTimestamp();
            const interval_ms: i64 = @intCast(self.poll_interval_ms);
            if (now_ms - self.last_sync_poll_ms >= interval_ms) {
                self.last_sync_poll_ms = now_ms;
                try self.pollLogFiles();
            }

            for (closed_windows) |cw| {
                self.removeCharacter(cw.character_name);
            }

            for (logged_out_names) |name| {
                self.removeCharacter(name);
            }

            // 2ms time budget (safe for 60fps); continues next frame if work remains
            const time_budget_ns = 2 * std.time.ns_per_ms;
            _ = try self.checkNewLogFiles(character_names, time_budget_ns);
        } else {
            // Phase 2: Send commands to worker thread
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
                // Skip generic "EVE" name (logged out or loading windows)
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

    /// Push a system-name update to the main thread. Safe to call from either thread -
    /// resolution against Painter/Scout happens on drain, on the main thread only.
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

    /// Push a notification to the main thread. Safe to call from either thread - the
    /// enabled/type/throttle checks in Painter.showNotification also run here, on drain.
    fn queueNotification(self: *ChatlogMonitor, character_name: []const u8, text: []const u8, ntype: types.NotificationType) void {
        const character_name_copy = self.allocator.dupe(u8, character_name) catch |err| {
            slog.err("Failed to allocate character name for notification: {}", .{err});
            return;
        };
        const text_copy = self.allocator.dupe(u8, text) catch |err| {
            slog.err("Failed to allocate text for notification: {}", .{err});
            self.allocator.free(character_name_copy);
            return;
        };

        const event = NotificationEvent{
            .character_name = character_name_copy,
            .text = text_copy,
            .ntype = ntype,
        };
        self.notification_queue.push(event) catch |err| {
            var mutable_event = event;
            mutable_event.deinit(self.allocator);
            slog.err("Failed to push notification event: {}", .{err});
        };
    }

    /// Drain queued system-name updates and apply them to Painter. Main thread only -
    /// resolves hwnd via Scout here, since Scout is otherwise touched only by the main thread's tick.
    fn drainResultQueue(self: *ChatlogMonitor) !void {
        var events = std.ArrayList(SystemUpdateEvent).empty;
        defer events.deinit(self.allocator);

        try self.result_queue.drain(&events);

        for (events.items) |*event| {
            defer event.deinit(self.allocator);

            const scout_ptr = self.scout orelse continue;
            const hwnd = scout_ptr.getHwndByName(event.character_name) orelse {
                slog.warn("No HWND for {s}, skipping system update", .{event.character_name});
                continue;
            };

            if (self.painter) |painter_ptr| {
                painter_ptr.updateSystemNameByHwnd(hwnd, event.system_name, event.event_ts, event.is_jump) catch |err| {
                    slog.err("Failed to update system name for {s}: {}", .{ event.character_name, err });
                    scout_ptr.clearHwndForCharacter(event.character_name);
                };
            } else {
                slog.warn("No painter available to apply system update: {s} -> {s}", .{ event.character_name, event.system_name });
            }
        }
    }

    /// Drain queued notifications and apply them to Painter. Main thread only, same
    /// reasoning as drainResultQueue.
    fn drainNotificationQueue(self: *ChatlogMonitor) !void {
        var events = std.ArrayList(NotificationEvent).empty;
        defer events.deinit(self.allocator);

        try self.notification_queue.drain(&events);

        for (events.items) |*event| {
            defer event.deinit(self.allocator);

            const scout_ptr = self.scout orelse continue;
            const hwnd = scout_ptr.getHwndByName(event.character_name) orelse continue;

            if (self.painter) |painter_ptr| {
                painter_ptr.showNotification(hwnd, event.text, event.ntype) catch |err| {
                    slog.err("Failed to show notification for {s}: {}", .{ event.character_name, err });
                };
            }
        }
    }

    /// Read initial state from log file with optimized backward scanning
    fn readInitialState(self: *ChatlogMonitor, state: *LogFileState) !void {
        const file = std.fs.cwd().openFile(state.file_path, .{}) catch |err| {
            slog.warn("Failed to open {s} for initial read: {}", .{ state.file_path, err });
            return err;
        };
        defer file.close();

        const file_stat = try file.stat();
        state.last_size = file_stat.size;
        state.last_modified = @intCast(file_stat.mtime);

        // Check for UTF-8 BOM at file start (only for gamelogs, chatlogs are UTF-16)
        if (!state.is_chatlog and file_stat.size >= 3) {
            try file.seekTo(0);
            var bom_buf: [3]u8 = undefined;
            const bom_read = try file.readAll(&bom_buf);
            if (bom_read == 3 and bom_buf[0] == 0xEF and bom_buf[1] == 0xBB and bom_buf[2] == 0xBF) {
                state.has_bom = true;
            }
        }

        const match = try self.findSystemBackward(state, file, file_stat.size);

        if (match) |m| {
            slog.debug("Initial system for {s}: {s} (event_ts={})", .{ state.character_name, m.system, m.event_ts });

            // is_jump=false: this seeds initial state, it isn't a live jump.
            self.queueSystemUpdate(state.character_name, m.system, m.event_ts, false);

            // No need to free - m.system is a borrowed slice from system_name_buffer
        }
        // Not found: nothing to seed from yet. Skip to EOF either way.

        state.position = file_stat.size;
    }

    /// Scan backwards through the log file for the most recent system (chatlog and gamelog).
    /// Returns as soon as a match is found, so this stays cheap despite the generous bound.
    fn findSystemBackward(self: *ChatlogMonitor, state: *LogFileState, file: std.fs.File, file_size: u64) !?SystemMatch {
        if (file_size == 0) return null;

        var buffer: [SCAN_CHUNK_SIZE]u8 = undefined;
        var scan_pos: u64 = file_size;
        // Chatlog: smaller overlap; Gamelog: larger, for complete messages
        const overlap: u64 = if (state.is_chatlog) 128 else 256;
        const scan_floor: u64 = if (file_size > MAX_BACKWARD_SCAN_BYTES) file_size - MAX_BACKWARD_SCAN_BYTES else 0;

        while (scan_pos > scan_floor) {
            const chunk_size = @min(SCAN_CHUNK_SIZE, scan_pos);
            const start_pos = scan_pos - chunk_size;

            try file.seekTo(start_pos);
            const bytes_read = try file.readAll(buffer[0..chunk_size]);
            if (bytes_read == 0) break;

            const chunk = buffer[0..bytes_read];

            if (state.is_chatlog) {
                // In UTF-16 LE, "Channel" appears as: C\0h\0a\0n\0n\0e\0l\0
                if (containsUtf16Pattern(chunk, "Channel")) {
                    if (try self.decodeUtf16Le(state, chunk)) |text| {
                        if (try self.extractSystemFromChatlog(state, text)) |match| {
                            return match;
                        }
                    }
                }
            } else {
                // Gamelog: quick keyword check before parsing
                if (std.mem.indexOf(u8, chunk, "Jumping from") != null or
                    std.mem.indexOf(u8, chunk, "Undocking from") != null)
                {
                    if (try self.extractSystemFromGamelog(state, chunk)) |match| {
                        return match;
                    }
                }
            }

            // Move back with overlap to catch patterns split across chunk boundaries
            scan_pos = if (start_pos > overlap) start_pos + overlap else 0;
        }

        return null;
    }

    fn containsUtf16Pattern(data: []const u8, pattern: []const u8) bool {
        if (data.len < pattern.len * 2) return false;

        // Search for pattern in UTF-16 LE (each char = 2 bytes, low byte first)
        var i: usize = 0;
        while (i + (pattern.len * 2) <= data.len) : (i += 2) {
            var match = true;
            for (pattern, 0..) |c, j| {
                const idx = i + (j * 2);
                if (idx + 1 >= data.len or data[idx] != c or data[idx + 1] != 0) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    fn readNewLines(self: *ChatlogMonitor, state: *LogFileState, file: std.fs.File) !void {
        const file_stat = try file.stat();
        const current_size = file_stat.size;
        const current_modified: i64 = @intCast(file_stat.mtime);

        if (current_size == state.last_size and current_modified == state.last_modified) {
            state.had_activity = false;
            state.idle_checks += 1;

            if (state.idle_checks >= self.idle_poll_threshold and state.poll_interval_multiplier < self.max_poll_multiplier) {
                const old_multiplier = state.poll_interval_multiplier;
                state.poll_interval_multiplier *= 2;
                state.idle_checks = 0;
                const log_type = if (state.is_chatlog) "chatlog" else "gamelog";
                slog.debug("Poll backoff {s} ({s}): {}x -> {}x", .{ state.character_name, log_type, old_multiplier, state.poll_interval_multiplier });
            }
            return;
        }

        state.idle_checks = 0;
        state.poll_interval_multiplier = 1;

        // File truncated (log rotation)
        if (current_size < state.last_size) {
            state.position = 0;
            state.partial_line_len = 0;
        }

        try file.seekTo(state.position);

        var buffer: [4096]u8 = undefined;
        const bytes_read = try file.readAll(&buffer);

        if (bytes_read == 0) {
            state.last_size = current_size;
            state.last_modified = current_modified;
            state.had_activity = false;
            return;
        }

        state.position += bytes_read;

        // Only update last_size/last_modified once caught up, so unread data triggers another poll
        if (state.position >= current_size) {
            state.last_size = current_size;
            state.last_modified = current_modified;
        }

        if (state.is_chatlog) {
            // UTF-16 LE chatlog (uses pooled buffer, no defer needed)
            if (try self.decodeUtf16Le(state, buffer[0..bytes_read])) |text| {
                try self.processTextLines(state, text);
            }
        } else {
            try self.processTextLines(state, buffer[0..bytes_read]);
        }

        state.had_activity = true;
    }

    /// Decode UTF-16 LE to UTF-8 using pooled buffers (zero heap allocations)
    fn decodeUtf16Le(self: *ChatlogMonitor, state: *LogFileState, data: []const u8) !?[]u8 {
        // Odd length: caught file mid-write, bytes unrecoverable.
        if (data.len % 2 != 0) {
            slog.warn("Dropping {} odd-length byte(s) mid-write for {s}", .{ data.len, state.character_name });
            return null;
        }
        if (data.len < 2) return null;

        const u16_count = data.len / 2;

        state.u16_buffer.clearRetainingCapacity();
        try state.u16_buffer.resize(self.allocator, u16_count);

        var i: usize = 0;
        while (i < u16_count) : (i += 1) {
            const byte_idx = i * 2;
            // Little endian: low byte first, high byte second
            state.u16_buffer.items[i] = @as(u16, data[byte_idx]) | (@as(u16, data[byte_idx + 1]) << 8);
        }

        // UTF-16 can be up to 3 bytes per code unit in UTF-8 (worst case for non-BMP characters)
        const utf8_len = u16_count * 3;

        state.utf8_buffer.clearRetainingCapacity();
        try state.utf8_buffer.resize(self.allocator, utf8_len);

        const bytes_written = std.unicode.utf16LeToUtf8(state.utf8_buffer.items, state.u16_buffer.items) catch {
            return null;
        };

        try state.utf8_buffer.resize(self.allocator, bytes_written);

        return state.utf8_buffer.items;
    }

    /// Process text lines (either from chatlog or gamelog)
    /// Optimized to minimize copying when handling partial lines
    fn processTextLines(self: *ChatlogMonitor, state: *LogFileState, text: []const u8) !void {
        const had_partial = state.partial_line_len > 0;

        if (had_partial) {
            // First read after partial was saved - need to restore it
            state.line_buffer.clearRetainingCapacity();
            try state.line_buffer.appendSlice(self.allocator, state.partial_line_buffer[0..state.partial_line_len]);
            state.partial_line_len = 0;
        } else if (state.line_buffer.items.len > 0) {
            // Already has partial data from previous call - keep it (no clear/copy needed)
        } else {
            state.line_buffer.clearRetainingCapacity();
        }

        // Protection against unbounded growth from malformed logs without newlines
        if (state.line_buffer.items.len + text.len > MAX_LINE_LENGTH * 2) {
            state.excessive_data_warnings += 1;

            // Rate limit warnings: log only first 3 occurrences, then every 100th
            if (state.excessive_data_warnings <= 3 or state.excessive_data_warnings % 100 == 0) {
                const preview_len = @min(text.len, 40);
                slog.warn("Discarding accumulated line data ({} bytes buffered + {} bytes new = {} total) for {s} - no newline found (warning #{}, preview: {s})", .{
                    state.line_buffer.items.len,
                    text.len,
                    state.line_buffer.items.len + text.len,
                    state.character_name,
                    state.excessive_data_warnings,
                    text[0..preview_len],
                });
            }

            state.line_buffer.clearRetainingCapacity();
            state.partial_line_len = 0;
            // Don't append the text that caused the overflow - skip this chunk entirely
            return;
        }

        try state.line_buffer.appendSlice(self.allocator, text);

        var line_iter = std.mem.splitScalar(u8, state.line_buffer.items, '\n');
        var line_count: usize = 0;

        while (line_iter.next()) |line| {
            line_count += 1;

            const is_last = line_iter.peek() == null;
            if (is_last and !std.mem.endsWith(u8, text, "\n")) {
                // Incomplete line - keep it in line_buffer for next read
                const line_start = @intFromPtr(line.ptr) - @intFromPtr(state.line_buffer.items.ptr);

                if (line.len > MAX_PARTIAL_LINE_SIZE) {
                    // Line too long - save truncated version to fixed buffer
                    @memcpy(state.partial_line_buffer[0..MAX_PARTIAL_LINE_SIZE], line[0..MAX_PARTIAL_LINE_SIZE]);
                    state.partial_line_len = MAX_PARTIAL_LINE_SIZE;
                    slog.warn("Partial line truncated from {} to {} bytes", .{ line.len, MAX_PARTIAL_LINE_SIZE });
                    state.line_buffer.clearRetainingCapacity();
                } else if (line_start > 0) {
                    // Move incomplete line to start of buffer (sliding window)
                    std.mem.copyForwards(u8, state.line_buffer.items[0..line.len], line);
                    try state.line_buffer.resize(self.allocator, line.len);
                } else {
                    // Already at start - just resize to keep only incomplete line
                    try state.line_buffer.resize(self.allocator, line.len);
                }
                break;
            }

            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len > 0) {
                try self.parseLine(state, trimmed);
            }
        }

        if (line_count > 0 and std.mem.endsWith(u8, text, "\n")) {
            state.line_buffer.clearRetainingCapacity();
        }
    }

    /// Parse a single log line (optimized with single-pass scanning)
    fn parseLine(self: *ChatlogMonitor, state: *LogFileState, line: []const u8) !void {
        var clean_line = line;
        if (state.has_bom and line.len >= 3 and line[0] == 0xEF and line[1] == 0xBB and line[2] == 0xBF) {
            clean_line = line[3..];
            // BOM only appears once at file start
            state.has_bom = false;
        }

        if (clean_line.len < MIN_LINE_LENGTH or clean_line.len > MAX_LINE_LENGTH) {
            return;
        }

        // Fast pre-filter: Check for relevant keywords before expensive parsing
        if (state.is_chatlog) {
            // Chatlog: Look for "EVE System" (indicates "Channel changed to Local:")
            if (std.mem.indexOf(u8, clean_line, "EVE System")) |_| {
                if (try self.parseSystemChangeFromChat(state, clean_line)) |system| {
                    self.handleSystemChange(state, system, "chatlog");
                }
            }
            // Early exit for chatlog - only one pattern to match
            return;
        }

        // Gamelog lines are "[ timestamp ] (type) message"; dispatch on the first character after the timestamp to avoid multiple full scans.
        // Skip timestamp: "[ YYYY.MM.DD HH:MM:SS ] " (~28 chars)
        var search_start: usize = 0;
        if (std.mem.indexOf(u8, clean_line, "] ")) |close_bracket| {
            search_start = close_bracket + 2;
        }

        if (search_start >= clean_line.len) return;
        const message_part = clean_line[search_start..];

        const first_char = message_part[0];

        switch (first_char) {
            'J' => {
                if (std.mem.startsWith(u8, message_part, "Jumping from")) {
                    if (try self.parseJumpFromGamelog(state, clean_line)) |system| {
                        self.handleSystemChange(state, system, "jump");
                    }
                }
            },
            'U' => {
                if (std.mem.startsWith(u8, message_part, "Undocking from")) {
                    if (try self.parseUndockFromGamelog(state, clean_line)) |system| {
                        self.handleSystemChange(state, system, "undock");
                    }
                }
            },
            '(' => {
                // Event type markers - check second character for quick dispatch
                if (message_part.len < 2) return;

                switch (message_part[1]) {
                    'n' => {
                        // "(notify)" - fleet commands, compression, decloak, etc.
                        if (std.mem.startsWith(u8, message_part, "(notify)")) {
                            // Conduit Field jump: treat as a system change in addition to showing a notification
                            if (std.mem.indexOf(u8, message_part, "Conduit Field") != null and
                                std.mem.indexOf(u8, message_part, "jumps you to") != null)
                            {
                                if (try self.parseConduitJumpFromGamelog(state, clean_line)) |system| {
                                    self.handleSystemChange(state, system, "conduit");
                                }
                            }
                            self.handleCombatEvent(state, clean_line);
                        }
                    },
                    'q' => {
                        // "(question)" - fleet invites, confirmations
                        if (std.mem.startsWith(u8, message_part, "(question)")) {
                            self.handleCombatEvent(state, clean_line);
                        }
                    },
                    'c' => {
                        // "(combat)" - damage, scrambles (usually filtered)
                        if (std.mem.startsWith(u8, message_part, "(combat)")) {
                            self.handleCombatEvent(state, clean_line);
                        }
                    },
                    'm' => {
                        // "(mining)" - mining yields
                        if (std.mem.startsWith(u8, message_part, "(mining)")) {
                            self.handleMiningEvent(state, clean_line);
                        }
                    },
                    'b' => {
                        // "(bounty)" - bounty payouts
                        if (std.mem.startsWith(u8, message_part, "(bounty)")) {
                            self.handleBountyEvent(state, clean_line);
                        }
                    },
                    'N' => {
                        // "(None)" - system jumps, conversation invites
                        if (std.mem.startsWith(u8, message_part, "(None)")) {
                            self.handleCombatEvent(state, clean_line);
                        }
                    },
                    'h' => {
                        // "(hint)" - skip these entirely
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    /// Handle system change with deduplication and event emission
    /// Takes borrowed slice from system_name_buffer - will be copied into event
    fn handleSystemChange(self: *ChatlogMonitor, state: *LogFileState, system: []const u8, event_type: []const u8) void {
        const system_hash = std.hash.Wyhash.hash(0, system);
        const is_different = (state.last_system_hash != system_hash);

        if (is_different) {
            state.last_system_hash = system_hash;

            // Only jumps pop a .SystemChange notification: undock and the chatlog's Local detection race the same event and would double-fire it.
            if (std.mem.eql(u8, event_type, "jump")) {
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "Jumped to {s}", .{system}) catch system;
                self.queueNotification(state.character_name, text, .SystemChange);
            }

            // Undock/chatlog-detect are same-system confirmations, not travel.
            const is_jump = std.mem.eql(u8, event_type, "jump") or std.mem.eql(u8, event_type, "conduit");

            // event_ts=0: live tailing has no timestamp but doesn't need one - lines are strictly ordered
            self.queueSystemUpdate(state.character_name, system, 0, is_jump);

            slog.info("System change ({s}): {s} -> {s}", .{ event_type, state.character_name, system });
        }
    }

    /// Handle combat event and update painter notification
    fn handleCombatEvent(self: *ChatlogMonitor, state: *LogFileState, event_text: []const u8) void {
        // Stripped once and shared below - re-stripping per call would double the cost on this, the highest-volume line type.
        var stripped_buf: [512]u8 = undefined;
        const stripped_text = activity_mod.stripHtml(event_text, &stripped_buf);

        // Combat DPS tracking (independent of notification settings)
        if (self.combat_tracker) |tracker| {
            if (activity_mod.parseCombatLine(stripped_text)) |parsed| {
                // Weapon-filtered incoming hits still count toward DPS stats but shouldn't retrigger the Taking Damage alert (see CombatWindow.addEntry).
                const counts_for_alert = !activity_mod.isWeaponExcluded(parsed.weapon, self.damage_alert_excluded_weapons);
                tracker.addEntry(state.character_name, parsed.amount, parsed.is_incoming, std.time.milliTimestamp(), counts_for_alert) catch |err| {
                    slog.warn("Failed to record combat entry for {s}: {}", .{ state.character_name, err });
                };
            }
        }

        var notify_buf: [64]u8 = undefined;
        const notification_data = self.formatCombatNotificationWithType(stripped_text, &notify_buf) catch {
            return;
        };

        // Skip empty notification text (e.g., system jumps, hint messages)
        if (notification_data.text.len == 0) return;

        // Enabled/type/throttle gating happens in Painter.showNotification itself on drain, so it isn't duplicated here.
        self.queueNotification(state.character_name, notification_data.text, notification_data.ntype);

        slog.debug("Combat event: {s} -> {s}", .{ state.character_name, event_text });
    }

    /// Parses the log line, looks up the ore's m3/unit and ISK/unit in GlobalSettings.oreTable, and records both in the mining tracker.
    /// A missing price (unset by the user) contributes 0 ISK rather than dropping the yield - only a missing volume does that, since m3 can't be computed at all without it.
    fn handleMiningEvent(self: *ChatlogMonitor, state: *LogFileState, event_text: []const u8) void {
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
        tracker.addEntry(state.character_name, m3, isk, std.time.milliTimestamp()) catch |err| {
            slog.warn("Failed to record mining entry for {s}: {}", .{ state.character_name, err });
        };
    }

    fn handleBountyEvent(self: *ChatlogMonitor, state: *LogFileState, event_text: []const u8) void {
        const tracker = self.bounty_tracker orelse return;
        const isk = activity_mod.parseBountyLine(event_text) orelse return;
        tracker.addEntry(state.character_name, isk, std.time.milliTimestamp()) catch |err| {
            slog.warn("Failed to record bounty entry for {s}: {}", .{ state.character_name, err });
        };
    }

    /// Finds `needle` in line, then `secondary` after it, and returns the trimmed text between
    /// `secondary` and the next newline, copied into state.system_name_buffer.
    /// Returns borrowed slice from state.system_name_buffer - valid until next parse.
    fn extractSystemAfterMarkers(self: *ChatlogMonitor, state: *LogFileState, line: []const u8, needle: []const u8, secondary: []const u8) !?[]const u8 {
        const pos = std.mem.indexOf(u8, line, needle) orelse return null;
        const after_needle = line[pos + needle.len ..];
        const marker_pos = std.mem.indexOf(u8, after_needle, secondary) orelse return null;
        const dest_start = marker_pos + secondary.len;
        if (dest_start >= after_needle.len) return null;

        const remaining = after_needle[dest_start..];
        const newline_pos = std.mem.indexOfAny(u8, remaining, "\r\n") orelse remaining.len;
        const system = std.mem.trim(u8, remaining[0..newline_pos], " \t");

        state.system_name_buffer.clearRetainingCapacity();
        try state.system_name_buffer.appendSlice(self.allocator, system);
        return state.system_name_buffer.items;
    }

    /// Parse "Channel changed to Local : SystemName" from chatlog
    fn parseSystemChangeFromChat(self: *ChatlogMonitor, state: *LogFileState, line: []const u8) !?[]const u8 {
        return self.extractSystemAfterMarkers(state, line, "Channel changed to Local", ":");
    }

    /// Parse "A Conduit Field activated by X jumps you to [System]." from gamelog notify.
    /// The activating character's own line instead reads "...jumps you to [System], bringing
    /// along N passengers." so the comma must terminate the system name too.
    /// Returns borrowed slice from state.system_name_buffer - valid until next parse
    fn parseConduitJumpFromGamelog(self: *ChatlogMonitor, state: *LogFileState, line: []const u8) !?[]const u8 {
        const needle = "jumps you to ";
        if (std.mem.indexOf(u8, line, needle)) |pos| {
            const remaining = line[pos + needle.len ..];
            const end_pos = std.mem.indexOfAny(u8, remaining, "\r\n.,") orelse remaining.len;
            const system = std.mem.trim(u8, remaining[0..end_pos], " \t");

            if (system.len == 0) return null;

            state.system_name_buffer.clearRetainingCapacity();
            try state.system_name_buffer.appendSlice(self.allocator, system);
            return state.system_name_buffer.items;
        }
        return null;
    }

    /// Parse "Jumping from [SystemA] to [SystemB]" from gamelog
    fn parseJumpFromGamelog(self: *ChatlogMonitor, state: *LogFileState, line: []const u8) !?[]const u8 {
        return self.extractSystemAfterMarkers(state, line, "Jumping from", " to ");
    }

    /// Parse "Undocking from [Station] in [System]" from gamelog
    fn parseUndockFromGamelog(self: *ChatlogMonitor, state: *LogFileState, line: []const u8) !?[]const u8 {
        return self.extractSystemAfterMarkers(state, line, "Undocking from", " in ");
    }

    /// A system name paired with its event's in-game timestamp, so chatlog and gamelog
    /// scans can be compared for recency instead of trusting whichever ran last.
    const SystemMatch = struct {
        // Borrowed from state.system_name_buffer
        system: []const u8,
        // 0 if the line's timestamp couldn't be parsed
        event_ts: u64,
    };

    /// Parse the "[ YYYY.MM.DD HH:MM:SS ]" timestamp immediately preceding `needle_pos` in `text`.
    /// Bounded to ~38 chars so a chunk-boundary truncation can't pick up an earlier line's bracket.
    fn parseLineTimestamp(text: []const u8, needle_pos: usize) u64 {
        const window_start = if (needle_pos > 64) needle_pos - 64 else 0;
        const before = text[window_start..needle_pos];
        const open = window_start + (std.mem.lastIndexOfScalar(u8, before, '[') orelse return 0);
        const close = std.mem.indexOfScalarPos(u8, text, open, ']') orelse return 0;
        const inner = std.mem.trim(u8, text[open + 1 .. close], " \t");

        // Expected: "YYYY.MM.DD HH:MM:SS"
        if (inner.len < 19) return 0;
        if (inner[4] != '.' or inner[7] != '.' or inner[10] != ' ' or inner[13] != ':' or inner[16] != ':') return 0;

        const year = std.fmt.parseInt(u64, inner[0..4], 10) catch return 0;
        const month = std.fmt.parseInt(u64, inner[5..7], 10) catch return 0;
        const day = std.fmt.parseInt(u64, inner[8..10], 10) catch return 0;
        const hour = std.fmt.parseInt(u64, inner[11..13], 10) catch return 0;
        const minute = std.fmt.parseInt(u64, inner[14..16], 10) catch return 0;
        const second = std.fmt.parseInt(u64, inner[17..19], 10) catch return 0;

        return (year * 10000 + month * 100 + day) * 1000000 + (hour * 10000 + minute * 100 + second);
    }

    /// Extract system name from chatlog text (for initial state)
    fn extractSystemFromChatlog(self: *ChatlogMonitor, state: *LogFileState, text: []const u8) !?SystemMatch {
        var last_pos: ?usize = null;
        var search_pos: usize = 0;
        const needle = "Channel changed to Local";

        while (std.mem.indexOfPos(u8, text, search_pos, needle)) |pos| {
            last_pos = pos;
            search_pos = pos + 1;
        }

        if (last_pos) |pos| {
            const system = try self.parseSystemChangeFromChat(state, text[pos..]) orelse return null;
            return SystemMatch{ .system = system, .event_ts = parseLineTimestamp(text, pos) };
        }
        return null;
    }

    /// Extract system name from gamelog text (for initial state)
    fn extractSystemFromGamelog(self: *ChatlogMonitor, state: *LogFileState, text: []const u8) !?SystemMatch {
        var last_jump_pos: ?usize = null;
        var last_undock_pos: ?usize = null;
        var search_pos: usize = 0;

        while (std.mem.indexOfPos(u8, text, search_pos, "Jumping from")) |pos| {
            last_jump_pos = pos;
            search_pos = pos + 1;
        }

        search_pos = 0;
        while (std.mem.indexOfPos(u8, text, search_pos, "Undocking from")) |pos| {
            last_undock_pos = pos;
            search_pos = pos + 1;
        }

        // Use whichever is later in the file
        const use_jump = if (last_jump_pos) |jump_pos|
            if (last_undock_pos) |undock_pos| jump_pos > undock_pos else true
        else
            false;

        if (use_jump) {
            if (last_jump_pos) |pos| {
                const system = try self.parseJumpFromGamelog(state, text[pos..]) orelse return null;
                return SystemMatch{ .system = system, .event_ts = parseLineTimestamp(text, pos) };
            }
        } else {
            if (last_undock_pos) |pos| {
                const system = try self.parseUndockFromGamelog(state, text[pos..]) orelse return null;
                return SystemMatch{ .system = system, .event_ts = parseLineTimestamp(text, pos) };
            }
        }

        return null;
    }

    const NotificationResult = struct { text: []const u8, ntype: types.NotificationType };

    /// Format combat notification from HTML-stripped event text and classify type.
    /// Returns slices borrowed from `event_text` - caller must keep it valid;
    /// Painter.showNotification() copies before storing.
    fn formatCombatNotificationWithType(self: *ChatlogMonitor, event_text: []const u8, buf: *[64]u8) !NotificationResult {
        _ = self;

        // EVE gamelog format: "[ timestamp ] (type) message"
        var text_start: usize = 0;
        if (std.mem.indexOf(u8, event_text, "]")) |close_bracket| {
            text_start = close_bracket + 1;
        }

        const remaining = std.mem.trim(u8, event_text[text_start..], " \t\r\n");

        if (std.mem.startsWith(u8, remaining, "(question)")) {
            // Skip "(question) "
            return parseQuestionEvent(remaining[10..]);
        } else if (std.mem.startsWith(u8, remaining, "(notify)")) {
            // Skip "(notify) "
            return parseNotifyEvent(remaining[8..], buf);
        } else if (std.mem.startsWith(u8, remaining, "(None)")) {
            // Skip "(None) "
            return parseNoneEvent(remaining[6..]);
        } else if (std.mem.startsWith(u8, remaining, "(combat)")) {
            // Skip "(combat) "
            return parseCombatEvent(remaining[8..]);
        } else if (std.mem.startsWith(u8, remaining, "(hint)")) {
            // Skip hint spam
            return .{ .text = "", .ntype = .Generic };
        }

        // Fallback: return cleaned text
        return .{ .text = std.mem.trim(u8, remaining, " \t\r\n."), .ntype = .Generic };
    }

    /// Parse (question) type events
    fn parseQuestionEvent(message: []const u8) NotificationResult {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");

        // Fleet invite: "<a href...>NAME</a> wants you to join their fleet, do you accept?"
        if (std.mem.indexOf(u8, trimmed, "wants you to join their fleet")) |_| {
            return .{ .text = "Fleet invite", .ntype = .FleetInvite };
        }

        // Skip other question dialogs (confirmations, prompts)
        return .{ .text = "", .ntype = .Generic };
    }

    /// Parse (notify) type events
    fn parseNotifyEvent(message: []const u8, buf: *[64]u8) NotificationResult {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");

        // Follow warp: "Following [leader] in warp"
        if (std.mem.startsWith(u8, trimmed, "Following ") and std.mem.indexOf(u8, trimmed, " in warp") != null) {
            return .{ .text = "Following", .ntype = .FleetFollow };
        }

        // Regroup: "Regrouping to [leader]"
        if (std.mem.indexOf(u8, trimmed, "Regrouping to ") != null) {
            return .{ .text = "Regrouping", .ntype = .FleetRegroup };
        }

        // Fleet disbanding: "Your fleet is disbanding"
        if (std.mem.indexOf(u8, trimmed, "Your fleet is disbanding") != null) {
            return .{ .text = "Fleet disbanding", .ntype = .FleetDisband };
        }

        // Jump clone: "Starting clone jumping"
        if (std.mem.indexOf(u8, trimmed, "Starting clone jumping") != null) {
            return .{ .text = "Jump Cloning", .ntype = .JumpCloning };
        }

        // Compression: "Successfully compressed [ore] into [count] [compressed]"
        if (std.mem.indexOf(u8, trimmed, "Successfully compressed") != null) {
            return .{ .text = "Compressed", .ntype = .MiningCompression };
        }

        // Asteroid depleted: "[miner] deactivates as it finds the resource it was harvesting
        // a pale shadow of its former glory."
        if (std.mem.indexOf(u8, trimmed, "a pale shadow of its former glory") != null) {
            return .{ .text = "Asteroid Depleted", .ntype = .AsteroidDepleted };
        }

        // Cargo hold full: "Your [module] has completed operations. Ship's cargo hold is full."
        if (std.mem.indexOf(u8, trimmed, "cargo hold is full") != null) {
            return .{ .text = "Cargo full", .ntype = .CargoFull };
        }

        // Observatory decloak: "Your cloak deactivates due to a pulse from a Mobile Observatory..."
        if (std.mem.indexOf(u8, trimmed, "cloak deactivates") != null and
            std.mem.indexOf(u8, trimmed, "Mobile Observatory") != null)
        {
            return .{ .text = "Observatory Decloak", .ntype = .ObservatoryDecloak };
        }

        // Proximity decloak: "Your cloak deactivates due to proximity to [source]"
        if (std.mem.indexOf(u8, trimmed, "cloak deactivates") != null) {
            return .{ .text = "Decloaked", .ntype = .Decloak };
        }

        // Cloak failed: "Your cloaking systems are unable to activate due to your ship being within..."
        if (std.mem.indexOf(u8, trimmed, "cloaking systems are unable to activate") != null) {
            return .{ .text = "Can't cloak", .ntype = .CloakFailed };
        }

        // Crystal broke: "[module] deactivates due to the destruction of the [crystal]"
        if (std.mem.indexOf(u8, trimmed, "deactivates due to the destruction") != null) {
            return .{ .text = "Crystal broke", .ntype = .CrystalBroke };
        }

        // Bomb Launcher out of charges: "Bomb Launcher II has run out of charges"
        if (std.mem.indexOf(u8, trimmed, "Bomb Launcher") != null and std.mem.indexOf(u8, trimmed, "has run out of charges") != null) {
            return .{ .text = "Bomb Launcher Empty", .ntype = .BombLauncherEmpty };
        }

        // Checks for "Your" to avoid triggering on other players' self-destructs.
        if (std.mem.indexOf(u8, trimmed, "Your") != null and std.mem.indexOf(u8, trimmed, "will self-destruct in") != null) {
            return .{ .text = "Self-Destruct", .ntype = .SelfDestruct };
        }
        if (std.mem.indexOf(u8, trimmed, "You have aborted the self-destruct") != null) {
            return .{ .text = "Self-Destruct Aborted", .ntype = .SelfDestruct };
        }

        // Docking: "You cannot do that while docking."
        if (std.mem.indexOf(u8, trimmed, "You cannot do that while docking") != null) {
            return .{ .text = "Docking", .ntype = .Docking };
        }

        // Autopilot reached: "Autopilot disabled - Waypoint reached"
        if (std.mem.indexOf(u8, trimmed, "Autopilot disabled - Waypoint reached") != null) {
            return .{ .text = "Waypoint reached", .ntype = .AutopilotReached };
        }

        // Autopilot approaching: "Autopilot approaching target"
        if (std.mem.indexOf(u8, trimmed, "Autopilot approaching target") != null) {
            return .{ .text = "Approaching", .ntype = .AutopilotApproaching };
        }

        // Jump range: "Please get within 2500 meters of the stargate to jump."
        if (std.mem.indexOf(u8, trimmed, "get within") != null and std.mem.indexOf(u8, trimmed, "stargate to jump") != null) {
            return .{ .text = "Can't Jump: Range", .ntype = .JumpRange };
        }

        // Warp disruption bubble: "You are within a warp disruption zone. Get 20000.0 meters
        // from Warp Disrupt Probe to warp."
        if (std.mem.indexOf(u8, trimmed, "within a warp disruption zone") != null) {
            return .{ .text = "Warp Disrupted", .ntype = .WarpBubble };
        }

        // Aggression timer blocking jump: "The stargate denies you permission to jump for
        // the moment due to your recent acts of aggression."
        if (std.mem.indexOf(u8, trimmed, "recent acts of aggression") != null) {
            return .{ .text = "Can't Jump: Aggression", .ntype = .AggressionCantJump };
        }

        // Same comma-termination quirk as parseConduitJumpFromGamelog (activating character's line ends in "...N passengers." instead of a period).
        if (std.mem.indexOf(u8, trimmed, "Conduit Field") != null and
            std.mem.indexOf(u8, trimmed, "jumps you to") != null)
        {
            if (std.mem.indexOf(u8, trimmed, "jumps you to ")) |idx| {
                const after = trimmed[idx + "jumps you to ".len ..];
                const end = std.mem.indexOfAny(u8, after, "\r\n.,") orelse after.len;
                const system = std.mem.trim(u8, after[0..end], " \t");
                if (system.len > 0) {
                    const text = std.fmt.bufPrint(buf, "Taking Conduit to {s}", .{system}) catch system;
                    return .{ .text = text, .ntype = .ConduitJump };
                }
            }
            return .{ .text = "Conduit Jump", .ntype = .ConduitJump };
        }

        // Skip other generic notify messages
        return .{ .text = "", .ntype = .Generic };
    }

    /// Parse (combat) type events for the rare cases worth a popup (e.g. being
    /// scrambled). Plain damage/miss lines are handled by the DPS tracker
    /// elsewhere and are intentionally skipped here to avoid popup spam.
    /// `message` must already have HTML stripped by the caller.
    fn parseCombatEvent(message: []const u8) NotificationResult {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");

        // Must end in "to you!" - a scramble landing on someone else instead reads "...to [target name]!".
        if (std.mem.indexOf(u8, trimmed, "Warp scramble attempt") != null and
            std.mem.endsWith(u8, trimmed, "to you!"))
        {
            return .{ .text = "Warp Scrambled", .ntype = .WarpScrambled };
        }

        // Same "to you!" requirement as the scramble check above.
        if (std.mem.indexOf(u8, trimmed, "Warp disruption attempt") != null and
            std.mem.endsWith(u8, trimmed, "to you!"))
        {
            return .{ .text = "Warp Disrupted", .ntype = .WarpDisrupted };
        }

        // Skip other combat spam (damage/misses - handled by the DPS tracker, not popups)
        return .{ .text = "", .ntype = .Generic };
    }

    /// Parse (None) type events
    fn parseNoneEvent(message: []const u8) NotificationResult {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");

        // System jump: "Jumping from [SystemA] to [SystemB]" - handled elsewhere
        if (std.mem.startsWith(u8, trimmed, "Jumping from")) {
            return .{ .text = "", .ntype = .SystemChange };
        }

        // Conversation invite: "<a href...>NAME</a> is inviting you to a conversation"
        if (std.mem.indexOf(u8, trimmed, "is inviting you to a conversation") != null) {
            return .{ .text = "Convo request", .ntype = .ConversationInvite };
        }

        return .{ .text = std.mem.trim(u8, trimmed, " \t\r\n."), .ntype = .Generic };
    }

    /// Parse timestamp from EVE log filename
    /// Chatlogs: Local_YYYYMMDD_HHMMSS_[character_id].txt -> YYYYMMDDHHMMSS
    /// Gamelogs: YYYYMMDD_HHMMSS_[charactern_id].txt -> YYYYMMDDHHMMSS
    /// Returns 0 if parsing fails
    fn parseLogTimestamp(filename: []const u8, is_chatlog: bool) u64 {
        const name_no_ext = if (std.mem.endsWith(u8, filename, ".txt"))
            filename[0 .. filename.len - 4]
        else
            filename;

        const timestamp_part = if (is_chatlog) blk: {
            if (std.mem.startsWith(u8, name_no_ext, "Local_")) {
                break :blk name_no_ext[6..];
            } else {
                // Invalid chatlog filename
                return 0;
            }
        } else name_no_ext;

        // 15 = length of "YYYYMMDD_HHMMSS"
        if (timestamp_part.len < 15) return 0;

        const date_part = timestamp_part[0..8];
        const date = std.fmt.parseInt(u64, date_part, 10) catch return 0;

        // Parse time part (HHMMSS) - skip underscore at position 8
        if (timestamp_part.len < 15 or timestamp_part[8] != '_') return 0;
        const time_part = timestamp_part[9..15];
        const time = std.fmt.parseInt(u64, time_part, 10) catch return 0;

        // Combine: YYYYMMDD * 1000000 + HHMMSS (ignores any suffix after position 15)
        return date * 1000000 + time;
    }

    /// Extract character ID from log filename
    /// Chatlogs: Local_YYYYMMDD_HHMMSS_1234567890.txt -> "1234567890"
    /// Gamelogs: YYYYMMDD_HHMMSS_1234567890.txt -> "1234567890"
    /// Returns null if extraction fails
    fn extractCharacterId(filename: []const u8) ?[]const u8 {
        const name = if (std.mem.endsWith(u8, filename, ".txt"))
            filename[0 .. filename.len - 4]
        else
            filename;

        if (std.mem.lastIndexOf(u8, name, "_")) |last_underscore| {
            const character_id = name[last_underscore + 1 ..];
            if (character_id.len >= 8 and character_id.len <= 13) {
                for (character_id) |c| {
                    if (!std.ascii.isDigit(c)) return null;
                }
                return character_id;
            }
        }
        return null;
    }

    /// Decode a WIN32_FIND_DATAW's null-terminated UTF-16 filename into `buf` (caller-owned).
    /// Returns null on decode failure.
    fn decodeFindDataName(find_data: *const win32.WIN32_FIND_DATAW, buf: []u8) ?[]const u8 {
        const raw: []const u16 = find_data.cFileName[0..];
        const len = std.mem.indexOfScalar(u16, raw, 0) orelse raw.len;
        const written = std.unicode.utf16LeToUtf8(buf, raw[0..len]) catch return null;
        return buf[0..written];
    }

    /// Open a Win32 find handle scoped to `dir_path`, filtered at the filesystem level to
    /// "Local_*.txt" for chatlogs or "*.txt" for gamelogs.
    fn openLogFindHandle(self: *ChatlogMonitor, dir_path: []const u8, is_chatlog: bool, find_data: *win32.WIN32_FIND_DATAW) ?win32.HANDLE {
        const pattern = if (is_chatlog) "Local_*.txt" else "*.txt";
        const search_path = std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, pattern }) catch return null;
        defer self.allocator.free(search_path);

        const search_path_w = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, search_path) catch return null;
        defer self.allocator.free(search_path_w);

        const handle = win32.FindFirstFileW(search_path_w.ptr, find_data);
        if (handle == win32.INVALID_HANDLE_VALUE) return null;
        return handle;
    }

    /// Fast path: single OS-filtered sweep matching a known character ID. No
    /// allocation, no sort, no depth cap - tracks only the newest match.
    fn findNewestMatchingId(self: *ChatlogMonitor, dir_path: []const u8, is_chatlog: bool, character_id: []const u8) ?[]u8 {
        var find_data: win32.WIN32_FIND_DATAW = undefined;
        const handle = self.openLogFindHandle(dir_path, is_chatlog, &find_data) orelse return null;
        defer _ = win32.FindClose(handle);

        var best_ts: u64 = 0;
        var best_buf: [win32.MAX_PATH * 3]u8 = undefined;
        var best_len: usize = 0;

        var have_entry = true;
        while (have_entry) : (have_entry = win32.FindNextFileW(handle, &find_data) != win32.FALSE) {
            if (find_data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) continue;

            var name_buf: [win32.MAX_PATH * 3]u8 = undefined;
            const name = decodeFindDataName(&find_data, &name_buf) orelse continue;

            // Defensive: Gamelogs dir shouldn't contain Local_ files, but guard anyway
            if (!is_chatlog and std.mem.startsWith(u8, name, "Local_")) continue;

            const file_id = extractCharacterId(name) orelse continue;
            if (!std.mem.eql(u8, file_id, character_id)) continue;

            const ts = parseLogTimestamp(name, is_chatlog);
            if (ts == 0 or ts <= best_ts) continue;

            best_ts = ts;
            @memcpy(best_buf[0..name.len], name);
            best_len = name.len;
        }

        if (best_len == 0) return null;
        return std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, best_buf[0..best_len] }) catch null;
    }

    /// Collect every candidate filename (OS-filtered as above). Used only when a
    /// character's ID isn't cached yet.
    fn collectLogCandidates(self: *ChatlogMonitor, dir_path: []const u8, is_chatlog: bool, out: *std.ArrayList([]const u8)) void {
        var find_data: win32.WIN32_FIND_DATAW = undefined;
        const handle = self.openLogFindHandle(dir_path, is_chatlog, &find_data) orelse return;
        defer _ = win32.FindClose(handle);

        var have_entry = true;
        while (have_entry) : (have_entry = win32.FindNextFileW(handle, &find_data) != win32.FALSE) {
            if (find_data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) continue;

            var name_buf: [win32.MAX_PATH * 3]u8 = undefined;
            const name = decodeFindDataName(&find_data, &name_buf) orelse continue;

            if (!is_chatlog and std.mem.startsWith(u8, name, "Local_")) continue;
            if (parseLogTimestamp(name, is_chatlog) == 0) continue;

            const name_copy = self.allocator.dupe(u8, name) catch continue;
            out.append(self.allocator, name_copy) catch {
                self.allocator.free(name_copy);
                continue;
            };
        }
    }

    /// Finds the newest log file belonging to `character_name`, always searching
    /// the entire directory (no depth cap).
    fn findLogFile(
        self: *ChatlogMonitor,
        dir_path: []const u8,
        is_chatlog: bool,
        char_name: []const u8,
    ) ?[]u8 {
        // Fast path: character ID already cached from a previous match.
        if (self.global_settings) |gs| {
            if (gs.characterIdMap.get(char_name)) |id| {
                if (self.findNewestMatchingId(dir_path, is_chatlog, id)) |path| {
                    return path;
                }
                // Cached ID matched nothing (stale) - fall through to the slow path
            }
        }

        // Slow path: ID unknown or stale, so check every candidate's "Listener:" header, newest first.
        var candidates: std.ArrayList([]const u8) = .empty;
        defer {
            for (candidates.items) |candidate| {
                self.allocator.free(candidate);
            }
            candidates.deinit(self.allocator);
        }

        self.collectLogCandidates(dir_path, is_chatlog, &candidates);

        std.mem.sort([]const u8, candidates.items, is_chatlog, struct {
            fn lessThan(chatlog: bool, a: []const u8, b: []const u8) bool {
                const a_ts = parseLogTimestamp(a, chatlog);
                const b_ts = parseLogTimestamp(b, chatlog);
                // Descending order (newest first)
                return a_ts > b_ts;
            }
        }.lessThan);

        for (candidates.items) |candidate| {
            const full_path = std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, candidate }) catch continue;
            defer self.allocator.free(full_path);

            const log_char_name = self.extractCharacterFromLog(full_path, is_chatlog) catch continue;
            const name = log_char_name orelse continue;
            defer self.allocator.free(name);

            if (!std.mem.eql(u8, name, char_name)) continue;

            // Found match! Cache the character ID for next time
            if (extractCharacterId(candidate)) |new_id| {
                if (self.global_settings) |gs| {
                    gs.updateCharacterId(char_name, new_id) catch |err| {
                        slog.warn("Failed to cache character ID for {s}: {}", .{ char_name, err });
                    };
                }
            }
            return std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, candidate }) catch continue;
        }

        return null;
    }

    fn findChatlogForCharacter(self: *ChatlogMonitor, character_name: []const u8) ?[]u8 {
        return self.findLogFile(self.chatlog_dir, true, character_name);
    }

    fn findGamelogForCharacter(self: *ChatlogMonitor, character_name: []const u8) ?[]u8 {
        return self.findLogFile(self.gamelog_dir, false, character_name);
    }

    /// Extract character name from log file (read "Listener: CharName" line)
    fn extractCharacterFromLog(self: *ChatlogMonitor, file_path: []const u8, is_chatlog: bool) !?[]u8 {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        // Read first 512 bytes to find Listener line
        var buffer: [512]u8 = undefined;
        const bytes_read = try file.readAll(&buffer);

        if (is_chatlog) {
            // UTF-16 LE - decode first (allocate temporary buffer since we don't have a state here)
            const u16_count = bytes_read / 2;
            if (u16_count == 0) return null;

            var u16_buffer = try self.allocator.alloc(u16, u16_count);
            defer self.allocator.free(u16_buffer);

            var i: usize = 0;
            while (i < u16_count) : (i += 1) {
                const byte_idx = i * 2;
                u16_buffer[i] = @as(u16, buffer[byte_idx]) | (@as(u16, buffer[byte_idx + 1]) << 8);
            }

            const utf8_len = u16_count * 3;
            const text = try self.allocator.alloc(u8, utf8_len);
            defer self.allocator.free(text);

            const bytes_written = try std.unicode.utf16LeToUtf8(text, u16_buffer);
            return try self.extractListenerName(text[0..bytes_written]);
        } else {
            return try self.extractListenerName(buffer[0..bytes_read]);
        }
    }

    /// Extract "Listener: CharacterName" from log header
    fn extractListenerName(self: *ChatlogMonitor, text: []const u8) !?[]u8 {
        const needle = "Listener:";
        if (std.mem.indexOf(u8, text, needle)) |pos| {
            const after_needle = text[pos + needle.len ..];
            const end = std.mem.indexOfAny(u8, after_needle, "\r\n") orelse after_needle.len;
            const name = std.mem.trim(u8, after_needle[0..end], " \t");
            if (name.len > 0) {
                return try self.allocator.dupe(u8, name);
            }
        }
        return null;
    }
};
