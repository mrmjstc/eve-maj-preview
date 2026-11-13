//! The simulated EVE clients: their processes and windows, the log files they write, and the steps queued for them; main thread only.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const win32_sim = @import("win32_sim.zig");
const universe = @import("../map/universe.zig");
const client_window = @import("client_window.zig");
const lines = @import("lines.zig");
const journal_mod = @import("journal.zig");
const schedule_mod = @import("schedule.zig");
const log = @import("../log.zig");

const Journal = journal_mod.Journal;
const Schedule = schedule_mod.Schedule;
const Step = schedule_mod.Step;
const Task = schedule_mod.Task;
const Via = schedule_mod.Via;
const Alert = lines.Alert;
const Activity = lines.Activity;
const Stamp = lines.Stamp;
const slog = log.Scoped("sim");

/// Where a character with no saved system starts.
const DEFAULT_SYSTEM = "Jita";
/// Every client joins these at login, besides Local; edited on the Setup tab.
const DEFAULT_CHANNELS = "east.imperium, Intel Test, Fleet, Corp";
/// How long closing clients get to exit before they're ended.
const CLOSE_WAIT_MS = 1000;
const BURST_SECONDS = 60;
const BOUNTY_INTERVAL_MS = 3000;
const COMBAT_INTERVAL_MS = 2000;
const ROUTE_JUMPS = 3;
const ROUTE_INTERVAL_MS = 10000;
/// Past any system's name, which is all a state file holds.
const MAX_STATE_BYTES = 256;

pub const State = enum {
    logged_in,
    logged_out,
    /// Closed, killed or crashed; the row stays so it can be started again.
    exited,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .logged_in => "logged in",
            .logged_out => "logged out",
            .exited => "not running",
        };
    }
};

/// Repeated activity a client can be set running.
pub const Burst = enum {
    bounty,
    /// Three minutes of a real gamelog, on its own timing.
    mining,
    combat_in,
    combat_out,
    miss,
    /// Incoming, outgoing and misses, picked at random.
    mixed_combat,

    pub fn label(self: Burst) []const u8 {
        return switch (self) {
            .bounty => "Bounties",
            .mining => "Mining",
            .combat_in => "Incoming fire",
            .combat_out => "Outgoing fire",
            .miss => "Misses",
            .mixed_combat => "Mixed fight",
        };
    }

    fn task(self: Burst) Task {
        return switch (self) {
            .bounty => .bounty,
            .mining => .mining,
            .combat_in, .combat_out, .miss, .mixed_combat => .combat,
        };
    }

    fn intervalMs(self: Burst) u64 {
        return switch (self) {
            .bounty => BOUNTY_INTERVAL_MS,
            .combat_in, .combat_out, .miss, .mixed_combat, .mining => COMBAT_INTERVAL_MS,
        };
    }

    /// The step each tick runs; not for mining, which replays its own lines.
    fn action(self: Burst) schedule_mod.Action {
        return switch (self) {
            .mining => unreachable,
            .bounty => .{ .activity = .bounty },
            .combat_in => .{ .activity = .combat_in },
            .combat_out => .{ .activity = .combat_out },
            .miss => .{ .activity = .miss },
            .mixed_combat => .mixed_combat,
        };
    }
};

pub const Channel = struct {
    /// Owned.
    name: []const u8,
    /// Owned.
    path: []const u8,
};

pub const Client = struct {
    /// Owned.
    name: []const u8,
    character_id: u64,
    state: State = .exited,
    /// Owned; null once the process has exited.
    process: ?win32.HANDLE = null,
    process_id: win32.DWORD = 0,
    /// Found once the process has created it.
    hwnd: ?win32.HWND = null,
    /// A requested close or kill, so its exit isn't reported as a crash.
    is_exit_expected: bool = false,
    /// Owned.
    system: []const u8,
    /// Owned; the Local chatlog of the current session.
    chatlog_path: []const u8 = "",
    /// Owned.
    gamelog_path: []const u8 = "",
    /// Every other channel's log of the current session.
    channels: std.ArrayList(Channel) = .empty,
    /// Picked in the client list, for the actions that work on several.
    is_picked: bool = false,

    fn channelPath(self: *const Client, channel: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, channel, lines.LOCAL_CHANNEL)) return self.chatlog_path;
        for (self.channels.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, channel)) return entry.path;
        }
        return null;
    }
};

pub const Fleet = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Owned; the scratch root, also this process's working directory.
    work_dir: []const u8,
    /// Owned; this exe copied as exefile.exe, which scout requires of a client.
    client_executable: [:0]const u8,
    /// Owned.
    state_dir: []const u8,
    /// Edited on the Setup tab; read whenever a log is created.
    chatlog_dir: std.ArrayList(u8) = .empty,
    /// Edited on the Setup tab; read whenever a log is created.
    gamelog_dir: std.ArrayList(u8) = .empty,
    /// Comma-separated; read whenever a session starts.
    channel_list: std.ArrayList(u8) = .empty,
    clients: std.ArrayList(Client) = .empty,
    journal: Journal,
    schedule: Schedule,
    random_source: std.Random.DefaultPrng,

    /// Both paths are copied.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, work_dir_path: []const u8, documents_dir: []const u8) !Fleet {
        const work_dir = try allocator.dupe(u8, work_dir_path);
        errdefer allocator.free(work_dir);
        const executable_dir = try std.Io.Dir.path.join(allocator, &.{ work_dir, "exe" });
        defer allocator.free(executable_dir);
        const state_dir = try std.Io.Dir.path.join(allocator, &.{ work_dir, "state" });
        errdefer allocator.free(state_dir);
        const client_executable = try allocator.printSentinel("{s}\\exefile.exe", .{executable_dir}, 0);
        errdefer allocator.free(client_executable);
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, executable_dir);
        try cwd.createDirPath(io, state_dir);

        var fleet: Fleet = .{
            .allocator = allocator,
            .io = io,
            .work_dir = work_dir,
            .client_executable = client_executable,
            .state_dir = state_dir,
            .journal = .init(allocator),
            .schedule = .init(allocator),
            .random_source = .init(@bitCast(std.Io.Clock.real.now(io).toSeconds())),
        };
        errdefer fleet.freeSetup();
        try fleet.chatlog_dir.print(allocator, "{s}\\EVE\\logs\\Chatlogs", .{documents_dir});
        try fleet.gamelog_dir.print(allocator, "{s}\\EVE\\logs\\Gamelogs", .{documents_dir});
        try fleet.channel_list.appendSlice(allocator, DEFAULT_CHANNELS);
        fleet.refreshClientExe();
        return fleet;
    }

    /// Closes every client first, ending those that don't exit in time.
    pub fn deinit(self: *Fleet) void {
        self.closeAll();
        for (self.clients.items) |*client| self.freeClient(client);
        self.clients.deinit(self.allocator);
        self.schedule.deinit();
        self.journal.deinit();
        self.freeSetup();
        self.allocator.free(self.client_executable);
        self.allocator.free(self.state_dir);
        self.allocator.free(self.work_dir);
    }

    pub fn indexOf(self: *const Fleet, name: []const u8) ?usize {
        for (self.clients.items, 0..) |client, index| {
            if (std.mem.eql(u8, client.name, name)) return index;
        }
        return null;
    }

    /// A new client, or a stopped one started again.
    pub fn start(self: *Fleet, name: []const u8) void {
        const trimmed = std.mem.trim(u8, name, " ");
        if (trimmed.len == 0 or trimmed.len > lines.MAX_CHARACTER_NAME_LENGTH or std.mem.findScalar(u8, trimmed, '"') != null) {
            self.note(.warning, "'{s}' isn't a character name EVE allows", .{trimmed});
            return;
        }
        const index = self.indexOf(trimmed) orelse blk: {
            self.addClient(trimmed) catch |err| {
                slog.err("Failed to add client '{s}': {}", .{ trimmed, err });
                self.note(.failure, "Failed to add {s}: {t}", .{ trimmed, err });
                return;
            };
            break :blk self.clients.items.len - 1;
        };
        const client = &self.clients.items[index];
        if (client.state != .exited) {
            self.note(.warning, "{s} is already running", .{client.name});
            return;
        }
        self.launch(client) catch |err| {
            slog.err("Failed to start client '{s}': {}", .{ client.name, err });
            self.note(.failure, "Failed to start {s}: {t}", .{ client.name, err });
            return;
        };
        self.beginSession(client);
        client.state = .logged_in;
        self.note(.success, "Started {s} (PID {d}, character ID {d}) in {s}", .{ client.name, client.process_id, client.character_id, client.system });
    }

    /// Asks the client to close, as quitting the game would.
    pub fn stop(self: *Fleet, index: usize) void {
        const client = &self.clients.items[index];
        const hwnd = client.hwnd orelse return self.kill(index);
        _ = self.schedule.cancel(client.name, null);
        client.is_exit_expected = true;
        if (!win32.toBool(win32.PostMessageA(hwnd, win32.WM_CLOSE, 0, 0))) {
            slog.warn("Failed to close client '{s}', ending it instead: error {d}", .{ client.name, win32.GetLastError() });
            return self.kill(index);
        }
        self.note(.info, "Closing {s}", .{client.name});
    }

    /// Ends the process at once, as a crash would.
    pub fn kill(self: *Fleet, index: usize) void {
        const client = &self.clients.items[index];
        const process = client.process orelse return;
        _ = self.schedule.cancel(client.name, null);
        client.is_exit_expected = true;
        if (!win32.toBool(win32_sim.TerminateProcess(process, 1))) {
            slog.warn("Failed to end client '{s}': error {d}", .{ client.name, win32.GetLastError() });
            self.note(.failure, "Failed to end {s}", .{client.name});
            return;
        }
        self.note(.info, "Killed {s}, as a crash would", .{client.name});
    }

    /// Only once it has exited.
    pub fn remove(self: *Fleet, index: usize) void {
        const client = &self.clients.items[index];
        if (client.state != .exited) return;
        self.freeClient(client);
        _ = self.clients.orderedRemove(index);
    }

    /// Logging in starts fresh session logs, as EVE does.
    pub fn setLoggedIn(self: *Fleet, index: usize, is_logged_in: bool) void {
        const client = &self.clients.items[index];
        const hwnd = client.hwnd orelse {
            self.note(.warning, "{s} has no window yet", .{client.name});
            return;
        };
        const message: win32.UINT = if (is_logged_in) client_window.WM_SIM_LOGIN else client_window.WM_SIM_LOGOUT;
        if (!win32.toBool(win32.PostMessageA(hwnd, message, 0, 0))) {
            slog.warn("Failed to log client '{s}' in or out: error {d}", .{ client.name, win32.GetLastError() });
            self.note(.failure, "Failed to reach {s}'s window", .{client.name});
            return;
        }
        if (!is_logged_in) {
            client.state = .logged_out;
            self.note(.info, "{s} logged out (title \"EVE\")", .{client.name});
            return;
        }
        client.state = .logged_in;
        self.beginSession(client);
        self.note(.info, "{s} logged in, with new session logs", .{client.name});
    }

    /// An `age_seconds` move is stamped that far back, as a late read would be, so the character stays put.
    pub fn move(self: *Fleet, index: usize, system: []const u8, via: Via, age_seconds: u32) void {
        const client = &self.clients.items[index];
        if (!self.isWritable(client)) return;
        const stamp = self.stampAgo(age_seconds);
        if (via != .local) {
            var line: std.Io.Writer.Allocating = .init(self.allocator);
            defer line.deinit();
            lines.writeJump(&line.writer, stamp, client.system, system) catch return self.outOfMemory("a jump line");
            self.appendGamelog(client, line.written());
        }
        if (via != .gamelog) self.appendLocalChange(client, stamp, system);
        const how = switch (via) {
            .both => "jumped",
            .gamelog => "jumped (gamelog only)",
            .local => "moved (Local only)",
        };
        if (age_seconds > 0) {
            self.note(.info, "{s} {s} to {s}, stamped {d}s ago", .{ client.name, how, system, age_seconds });
            return;
        }
        self.note(.info, "{s} {s}: {s} -> {s}", .{ client.name, how, client.system, system });
        self.setSystem(client, system);
    }

    /// A conduit jump also moves the character, to a random gate neighbour.
    pub fn fireAlert(self: *Fleet, index: usize, alert: Alert) void {
        const client = &self.clients.items[index];
        if (!self.isWritable(client)) return;
        var destination_buf: [lines.MAX_SYSTEM_NAME_LENGTH]u8 = undefined;
        const destination = if (alert == .conduit_jump) self.randomNeighbour(client.system, &destination_buf) else "";
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        defer text.deinit();
        alert.write(&text.writer, destination) catch return self.outOfMemory("an alert line");
        self.appendGameText(client, text.written());
        self.note(.info, "{s}: {s}", .{ client.name, text.written() });
        if (alert != .conduit_jump) return;
        self.appendLocalChange(client, self.stampAgo(0), destination);
        self.setSystem(client, destination);
    }

    fn writeActivity(self: *Fleet, index: usize, activity: Activity) void {
        const client = &self.clients.items[index];
        if (!self.isWritable(client)) return;
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        defer text.deinit();
        activity.write(&text.writer, self.random_source.random()) catch return self.outOfMemory("an activity line");
        self.appendGameText(client, text.written());
    }

    /// Every listener's log gets its own copy, up to a second apart like real clients', so the app must count them as one message.
    pub fn sendChat(self: *Fleet, channel: []const u8, speaker: []const u8, text: []const u8) void {
        var listener_count: u64 = 0;
        const now = self.nowSeconds();
        for (self.clients.items) |*client| {
            if (client.state != .logged_in) continue;
            const path = client.channelPath(channel) orelse continue;
            var line: std.Io.Writer.Allocating = .init(self.allocator);
            defer line.deinit();
            lines.writeChatLine(&line.writer, Stamp.fromUnix(now + listener_count % 2), speaker, text) catch return self.outOfMemory("a chat line");
            self.appendChatlog(path, line.written());
            listener_count += 1;
        }
        if (listener_count == 0) {
            self.note(.warning, "No logged-in client is in '{s}'", .{channel});
            return;
        }
        self.note(.info, "[{s}, {d} listening] {s} > {s}", .{ channel, listener_count, speaker, text });
    }

    /// Opens the channel's log mid-session, as joining it in game does.
    pub fn join(self: *Fleet, index: usize, channel: []const u8) void {
        const client = &self.clients.items[index];
        const trimmed = std.mem.trim(u8, channel, " ");
        if (trimmed.len == 0 or client.channelPath(trimmed) != null) return;
        if (!self.isWritable(client)) return;
        self.openChannel(client, trimmed, Stamp.fromUnix(self.nowSeconds())) catch |err| {
            slog.err("Failed to join '{s}' for '{s}': {}", .{ trimmed, client.name, err });
            self.note(.failure, "Failed to join {s} for {s}: {t}", .{ trimmed, client.name, err });
            return;
        };
        self.note(.info, "{s} joined {s}", .{ client.name, trimmed });
    }

    /// Bounty and combat run a minute; mining replays three minutes of a real gamelog.
    pub fn startBurst(self: *Fleet, index: usize, burst: Burst) void {
        const client = &self.clients.items[index];
        if (!self.isWritable(client)) return;
        const task = burst.task();
        if (self.schedule.isRunning(client.name, task)) {
            self.note(.warning, "{s} is already running {s}", .{ client.name, task.label() });
            return;
        }
        self.scheduleBurst(client.name, burst) catch |err| {
            slog.err("Failed to schedule {s} for '{s}': {}", .{ task.label(), client.name, err });
            _ = self.schedule.cancel(client.name, task);
            self.note(.failure, "Failed to start {s} for {s}", .{ task.label(), client.name });
            return;
        };
        self.note(.success, "{s} started: {s}", .{ client.name, burst.label() });
    }

    /// ROUTE_JUMPS random gates from where the client is, ROUTE_INTERVAL_MS apart.
    pub fn startRandomRoute(self: *Fleet, index: usize) void {
        const client = &self.clients.items[index];
        if (!self.isWritable(client)) return;
        if (self.schedule.isRunning(client.name, .route)) {
            self.note(.warning, "{s} is already on a route", .{client.name});
            return;
        }
        var route_buf: [ROUTE_JUMPS][lines.MAX_SYSTEM_NAME_LENGTH]u8 = undefined;
        var from = client.system;
        const now = win32.Ticks.now().ms;
        for (&route_buf, 0..) |*buf, step_index| {
            const system = self.randomNeighbour(from, buf);
            from = system;
            self.schedule.add(now + @as(u64, step_index) * ROUTE_INTERVAL_MS, client.name, .route, .{ .move = .{ .system = system } }) catch |err| {
                slog.err("Failed to schedule a route for '{s}': {}", .{ client.name, err });
                _ = self.schedule.cancel(client.name, .route);
                self.note(.failure, "Failed to start a route for {s}", .{client.name});
                return;
            };
        }
        self.note(.success, "{s} set off on a {d}-jump route, {d}s apart", .{ client.name, ROUTE_JUMPS, ROUTE_INTERVAL_MS / std.time.ms_per_s });
    }

    /// Through one random gate.
    pub fn jumpRandomly(self: *Fleet, index: usize) void {
        var destination_buf: [lines.MAX_SYSTEM_NAME_LENGTH]u8 = undefined;
        const destination = self.randomNeighbour(self.clients.items[index].system, &destination_buf);
        self.move(index, destination, .both, 0);
    }

    /// Stops the client's bursts, routes and alert storms.
    pub fn stopWork(self: *Fleet, index: usize) void {
        const client = &self.clients.items[index];
        const dropped_count = self.schedule.cancel(client.name, null);
        if (dropped_count > 0) self.note(.info, "Stopped {s}'s running work", .{client.name});
    }

    /// Runs what's due; returns whether anything did, so the view redraws.
    pub fn tick(self: *Fleet) bool {
        var is_changed = self.poll();
        const now = win32.Ticks.now().ms;
        while (self.schedule.takeDue(now)) |step| {
            defer self.schedule.free(step);
            self.runStep(step);
            is_changed = true;
        }
        return is_changed;
    }

    /// The client's window, once created, and whether its process is still alive; returns whether anything changed.
    fn poll(self: *Fleet) bool {
        var is_changed = false;
        for (self.clients.items) |*client| {
            const process = client.process orelse continue;
            if (win32.WaitForSingleObject(process, 0) == win32.WAIT_OBJECT_0) {
                _ = win32.CloseHandle(process);
                client.process = null;
                client.hwnd = null;
                client.state = .exited;
                _ = self.schedule.cancel(client.name, null);
                if (client.is_exit_expected) self.note(.info, "{s} exited", .{client.name}) else self.note(.failure, "{s}'s client exited unexpectedly", .{client.name});
                is_changed = true;
                continue;
            }
            if (client.hwnd == null) {
                client.hwnd = findWindow(client.process_id);
                if (client.hwnd != null) is_changed = true;
            }
        }
        return is_changed;
    }

    /// Adds to the activity feed, stamped with local time.
    pub fn note(self: *Fleet, kind: journal_mod.Kind, comptime text_format: []const u8, args: anytype) void {
        var time: win32.SYSTEMTIME = undefined;
        win32.GetLocalTime(&time);
        var clock: journal_mod.Clock = undefined;
        // `% 100` keeps each part to two digits, so the clock always fits.
        _ = std.fmt.bufPrint(&clock, "{d:0>2}:{d:0>2}:{d:0>2}", .{ time.wHour % 100, time.wMinute % 100, time.wSecond % 100 }) catch unreachable;
        self.journal.add(kind, clock, text_format, args);
    }

    /// The channels every session joins, from the Setup tab's list; borrows from it.
    pub fn channelNames(self: *const Fleet) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.channel_list.items, ',');
    }

    fn runStep(self: *Fleet, step: Step) void {
        switch (step.action) {
            .chat => |chat| self.sendChat(chat.channel, chat.speaker, chat.text),
            .expect => |text| self.note(.expect, "Expect: {s}", .{text}),
            .move => |planned| self.move(self.stepClient(step) orelse return, planned.system, planned.via, planned.age_seconds),
            .alert => |alert| self.fireAlert(self.stepClient(step) orelse return, alert),
            .activity => |activity| self.writeActivity(self.stepClient(step) orelse return, activity),
            .mixed_combat => {
                const index = self.stepClient(step) orelse return;
                const choices = [_]Activity{ .combat_in, .combat_out, .miss };
                self.writeActivity(index, choices[self.random_source.random().uintLessThan(usize, choices.len)]);
            },
            .mining => |replay_index| {
                const index = self.stepClient(step) orelse return;
                self.appendGameText(&self.clients.items[index], lines.MINING_REPLAY[replay_index].text);
            },
        }
    }

    fn stepClient(self: *Fleet, step: Step) ?usize {
        return self.indexOf(step.client) orelse {
            self.note(.warning, "Skipped a step for {s}, who is no longer listed", .{step.client});
            return null;
        };
    }

    /// Asks every running client to close, waits up to CLOSE_WAIT_MS, then ends any still running.
    fn closeAll(self: *Fleet) void {
        _ = self.schedule.cancel(null, null);
        for (self.clients.items) |*client| {
            const hwnd = client.hwnd orelse continue;
            client.is_exit_expected = true;
            _ = win32.PostMessageA(hwnd, win32.WM_CLOSE, 0, 0);
        }
        const deadline = win32.Ticks.now().ms + CLOSE_WAIT_MS;
        for (self.clients.items) |*client| {
            const process = client.process orelse continue;
            const remaining = deadline -| win32.Ticks.now().ms;
            if (win32.WaitForSingleObject(process, @intCast(remaining)) != win32.WAIT_OBJECT_0) {
                if (!win32.toBool(win32_sim.TerminateProcess(process, 0))) slog.warn("Failed to end client '{s}' on exit: error {d}", .{ client.name, win32.GetLastError() });
            }
            _ = win32.CloseHandle(process);
            client.process = null;
        }
    }

    fn scheduleBurst(self: *Fleet, name: []const u8, burst: Burst) !void {
        const now = win32.Ticks.now().ms;
        switch (burst) {
            .mining => for (lines.MINING_REPLAY, 0..) |replayed, replay_index| {
                try self.schedule.add(now + @as(u64, replayed.offset_seconds) * std.time.ms_per_s, name, .mining, .{ .mining = replay_index });
            },
            .bounty, .combat_in, .combat_out, .miss, .mixed_combat => {
                var due = now;
                while (due < now + BURST_SECONDS * std.time.ms_per_s) : (due += burst.intervalMs()) {
                    try self.schedule.add(due, name, burst.task(), burst.action());
                }
            },
        }
    }

    fn addClient(self: *Fleet, name: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const system = try self.savedSystem(name);
        errdefer self.allocator.free(system);
        try self.clients.append(self.allocator, .{ .name = owned_name, .character_id = lines.characterId(name), .system = system });
    }

    fn launch(self: *Fleet, client: *Client) !void {
        const command_line = try self.allocator.printSentinel("\"{s}\" --client \"{s}\"", .{ self.client_executable, client.name }, 0);
        defer self.allocator.free(command_line);
        const work_dir = try self.allocator.dupeSentinel(u8, self.work_dir, 0);
        defer self.allocator.free(work_dir);
        const startup: win32_sim.STARTUPINFOA = .{};
        var info: win32_sim.PROCESS_INFORMATION = undefined;
        if (!win32.toBool(win32_sim.CreateProcessA(self.client_executable, command_line, null, null, win32.FALSE, 0, null, work_dir, &startup, &info))) {
            slog.err("Failed to create the process for '{s}' from '{s}': error {d}", .{ client.name, self.client_executable, win32.GetLastError() });
            return error.CreateProcessFailed;
        }
        _ = win32.CloseHandle(info.hThread);
        client.process = info.hProcess;
        client.process_id = info.dwProcessId;
        client.hwnd = null;
        client.is_exit_expected = false;
    }

    /// Fresh Local, gamelog and channel logs dated now, as a real login makes.
    fn beginSession(self: *Fleet, client: *Client) void {
        self.freeSessionLogs(client);
        const started = Stamp.fromUnix(self.nowSeconds());
        self.openSessionLogs(client, started) catch |err| {
            slog.err("Failed to create the session logs for '{s}': {}", .{ client.name, err });
            self.note(.failure, "Failed to create {s}'s logs: {t}", .{ client.name, err });
        };
    }

    fn openSessionLogs(self: *const Fleet, client: *Client, started: Stamp) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.chatlog_dir.items);
        try cwd.createDirPath(self.io, self.gamelog_dir.items);

        var chatlog_name: std.Io.Writer.Allocating = .init(self.allocator);
        defer chatlog_name.deinit();
        try lines.writeChatlogName(&chatlog_name.writer, lines.LOCAL_CHANNEL, started, client.character_id);
        var header: std.Io.Writer.Allocating = .init(self.allocator);
        defer header.deinit();
        try lines.writeChatlogHeader(&header.writer, lines.LOCAL_CHANNEL, client.name, started, client.system);
        client.chatlog_path = try std.Io.Dir.path.join(self.allocator, &.{ self.chatlog_dir.items, chatlog_name.written() });
        try self.writeChatlogFile(client.chatlog_path, header.written());

        var gamelog_name: std.Io.Writer.Allocating = .init(self.allocator);
        defer gamelog_name.deinit();
        try lines.writeGamelogName(&gamelog_name.writer, started, client.character_id);
        header.clearRetainingCapacity();
        try lines.writeGamelogHeader(&header.writer, client.name, started);
        client.gamelog_path = try std.Io.Dir.path.join(self.allocator, &.{ self.gamelog_dir.items, gamelog_name.written() });
        try self.writeNewFile(client.gamelog_path, "\u{FEFF}", header.written());

        var names = self.channelNames();
        while (names.next()) |raw| {
            const channel = std.mem.trim(u8, raw, " ");
            if (channel.len == 0 or client.channelPath(channel) != null) continue;
            try self.openChannel(client, channel, started);
        }
    }

    fn openChannel(self: *const Fleet, client: *Client, channel: []const u8, started: Stamp) !void {
        var file_name: std.Io.Writer.Allocating = .init(self.allocator);
        defer file_name.deinit();
        try lines.writeChatlogName(&file_name.writer, channel, started, client.character_id);
        var header: std.Io.Writer.Allocating = .init(self.allocator);
        defer header.deinit();
        try lines.writeChatlogHeader(&header.writer, channel, client.name, started, client.system);
        const path = try std.Io.Dir.path.join(self.allocator, &.{ self.chatlog_dir.items, file_name.written() });
        errdefer self.allocator.free(path);
        const name = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(name);
        try self.writeChatlogFile(path, header.written());
        try client.channels.append(self.allocator, .{ .name = name, .path = path });
    }

    /// UTF-16LE with a BOM, as EVE writes chatlogs.
    fn writeChatlogFile(self: *const Fleet, path: []const u8, text: []const u8) !void {
        const units = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, text);
        defer self.allocator.free(units);
        try self.writeNewFile(path, "\xFF\xFE", std.mem.sliceAsBytes(units));
    }

    fn writeNewFile(self: *const Fleet, path: []const u8, preamble: []const u8, bytes: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        try file.writePositionalAll(self.io, preamble, 0);
        try file.writePositionalAll(self.io, bytes, preamble.len);
    }

    fn appendChatlog(self: *Fleet, path: []const u8, text: []const u8) void {
        const units = std.unicode.utf8ToUtf16LeAlloc(self.allocator, text) catch |err| {
            slog.err("Failed to encode a chat line for '{s}': {}", .{ path, err });
            return;
        };
        defer self.allocator.free(units);
        self.append(path, std.mem.sliceAsBytes(units));
    }

    fn appendLocalChange(self: *Fleet, client: *Client, stamp: Stamp, system: []const u8) void {
        var line: std.Io.Writer.Allocating = .init(self.allocator);
        defer line.deinit();
        lines.writeLocalChange(&line.writer, stamp, system) catch return self.outOfMemory("a Local change");
        self.appendChatlog(client.chatlog_path, line.written());
    }

    /// `text` is what follows the timestamp.
    fn appendGameText(self: *Fleet, client: *Client, text: []const u8) void {
        var line: std.Io.Writer.Allocating = .init(self.allocator);
        defer line.deinit();
        lines.writeGameLine(&line.writer, self.stampAgo(0), text) catch return self.outOfMemory("a gamelog line");
        self.appendGamelog(client, line.written());
    }

    fn appendGamelog(self: *Fleet, client: *Client, line: []const u8) void {
        self.append(client.gamelog_path, line);
    }

    fn append(self: *Fleet, path: []const u8, bytes: []const u8) void {
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .read = true, .truncate = false }) catch |err| {
            slog.err("Failed to open log '{s}': {}", .{ path, err });
            self.note(.failure, "Failed to open {s}: {t}", .{ path, err });
            return;
        };
        defer file.close(self.io);
        const end = file.length(self.io) catch |err| {
            slog.err("Failed to measure log '{s}': {}", .{ path, err });
            return;
        };
        file.writePositionalAll(self.io, bytes, end) catch |err| {
            slog.err("Failed to write to log '{s}': {}", .{ path, err });
            self.note(.failure, "Failed to write to {s}: {t}", .{ path, err });
        };
    }

    /// Logs only exist while the client runs a session.
    fn isWritable(self: *Fleet, client: *const Client) bool {
        if (client.state == .exited) {
            self.note(.warning, "{s} isn't running", .{client.name});
            return false;
        }
        if (client.gamelog_path.len == 0) {
            self.note(.warning, "{s} has no session logs", .{client.name});
            return false;
        }
        return true;
    }

    fn setSystem(self: *Fleet, client: *Client, system: []const u8) void {
        const owned = self.allocator.dupe(u8, system) catch return self.outOfMemory("a system name");
        self.allocator.free(client.system);
        client.system = owned;
        self.saveSystem(client);
    }

    /// Kept across runs, so a restarted character is where it was left.
    fn saveSystem(self: *Fleet, client: *const Client) void {
        const path = self.statePath(client.name) catch return self.outOfMemory("a state path");
        defer self.allocator.free(path);
        self.writeNewFile(path, "", client.system) catch |err| {
            slog.warn("Failed to save the system of '{s}', it starts in {s} next time: {}", .{ client.name, DEFAULT_SYSTEM, err });
        };
    }

    /// Caller frees.
    fn savedSystem(self: *const Fleet, name: []const u8) ![]const u8 {
        const path = try self.statePath(name);
        defer self.allocator.free(path);
        const saved = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(MAX_STATE_BYTES)) catch |err| switch (err) {
            error.FileNotFound => return self.allocator.dupe(u8, DEFAULT_SYSTEM),
            else => {
                slog.warn("Failed to read the saved system of '{s}', starting in {s}: {}", .{ name, DEFAULT_SYSTEM, err });
                return self.allocator.dupe(u8, DEFAULT_SYSTEM);
            },
        };
        defer self.allocator.free(saved);
        const system = std.mem.trim(u8, saved, " \r\n");
        return self.allocator.dupe(u8, if (system.len > 0) system else DEFAULT_SYSTEM);
    }

    /// Caller frees.
    fn statePath(self: *const Fleet, name: []const u8) ![]const u8 {
        var file_name: std.Io.Writer.Allocating = .init(self.allocator);
        defer file_name.deinit();
        try lines.writeSafeName(&file_name.writer, name);
        try file_name.writer.writeAll(".txt");
        return std.Io.Dir.path.join(self.allocator, &.{ self.state_dir, file_name.written() });
    }

    /// A gate neighbour of `from`, written into `buf`; from Jita when `from` isn't on the gate map.
    fn randomNeighbour(self: *Fleet, from: []const u8, buf: *[lines.MAX_SYSTEM_NAME_LENGTH]u8) []const u8 {
        const origin = universe.findSystem(from) orelse universe.findSystem(DEFAULT_SYSTEM) orelse return DEFAULT_SYSTEM;
        var neighbour_count: usize = 0;
        var counted = universe.neighbours(origin);
        while (counted.next()) |_| neighbour_count += 1;
        if (neighbour_count == 0) return DEFAULT_SYSTEM;
        var chosen = self.random_source.random().uintLessThan(usize, neighbour_count);
        var links = universe.neighbours(origin);
        const system = while (links.next()) |neighbour| {
            if (chosen == 0) break neighbour;
            chosen -= 1;
        } else origin;
        const name = universe.systemName(system);
        const length = @min(name.len, buf.len);
        @memcpy(buf[0..length], name[0..length]);
        return buf[0..length];
    }

    fn nowSeconds(self: *const Fleet) u64 {
        return @intCast(@max(0, std.Io.Clock.real.now(self.io).toSeconds()));
    }

    fn stampAgo(self: *const Fleet, age_seconds: u32) Stamp {
        return Stamp.fromUnix(self.nowSeconds() -| age_seconds);
    }

    /// Re-copied each start, so clients run this build; a copy still running from a crashed simulator keeps the old one.
    fn refreshClientExe(self: *Fleet) void {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const own_path = win32.selfExecutablePath(&path_buf) catch |err| {
            slog.err("Failed to find the simulator's own executable: {}", .{err});
            return;
        };
        const terminated = self.allocator.dupeSentinel(u8, own_path, 0) catch return self.outOfMemory("the executable path");
        defer self.allocator.free(terminated);
        if (!win32.toBool(win32_sim.CopyFileA(terminated, self.client_executable, win32.FALSE))) {
            slog.warn("Failed to copy the simulator to '{s}', clients run the previous copy: error {d}", .{ self.client_executable, win32.GetLastError() });
            self.note(.warning, "Couldn't refresh exefile.exe (a client from an earlier run may still be open)", .{});
        }
    }

    fn outOfMemory(self: *Fleet, what: []const u8) void {
        slog.err("Failed to build {s}: out of memory", .{what});
        self.note(.failure, "Ran out of memory building {s}", .{what});
    }

    fn freeSessionLogs(self: *const Fleet, client: *Client) void {
        if (client.chatlog_path.len > 0) self.allocator.free(client.chatlog_path);
        if (client.gamelog_path.len > 0) self.allocator.free(client.gamelog_path);
        client.chatlog_path = "";
        client.gamelog_path = "";
        for (client.channels.items) |channel| {
            self.allocator.free(channel.name);
            self.allocator.free(channel.path);
        }
        client.channels.clearRetainingCapacity();
    }

    fn freeClient(self: *Fleet, client: *Client) void {
        if (client.process) |process| _ = win32.CloseHandle(process);
        _ = self.schedule.cancel(client.name, null);
        self.freeSessionLogs(client);
        client.channels.deinit(self.allocator);
        self.allocator.free(client.system);
        self.allocator.free(client.name);
    }

    fn freeSetup(self: *Fleet) void {
        self.chatlog_dir.deinit(self.allocator);
        self.gamelog_dir.deinit(self.allocator);
        self.channel_list.deinit(self.allocator);
    }
};

const WindowSearch = struct { process_id: win32.DWORD, found: ?win32.HWND = null };

fn findWindow(process_id: win32.DWORD) ?win32.HWND {
    var search: WindowSearch = .{ .process_id = process_id };
    _ = win32.EnumWindows(findWindowCallback, @bitCast(@intFromPtr(&search)));
    return search.found;
}

fn findWindowCallback(hwnd: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const search = win32.lparamToPtr(WindowSearch, lParam);
    var process_id: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &process_id);
    if (process_id != search.process_id) return win32.TRUE;
    var class_buf: [64]u8 = undefined;
    const class_name = win32.getClassNameBuf(hwnd, &class_buf) orelse return win32.TRUE;
    if (!std.mem.eql(u8, class_name, client_window.CLASS_NAME)) return win32.TRUE;
    search.found = hwnd;
    return win32.FALSE;
}
