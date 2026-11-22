//! What the followed logs' lines mean: system changes, chat alerts, intel, game events and the activity trackers' entries.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const notification_mod = @import("../notifications/notification.zig");
const gamelog_events = @import("../notifications/gamelog_events.zig");
const tracker_mod = @import("../activity/tracker.zig");
const activity_lines = @import("../activity/lines.zig");
const ores = @import("../activity/ores.zig");
const config = @import("../config.zig");
const universe = @import("../map/universe.zig");
const lines = @import("lines.zig");
const alert_rules_mod = @import("alert_rules.zig");
const routing = @import("routing.zig");
const tail = @import("tail.zig");
const queue = @import("queue.zig");
const log = @import("../log.zig");

const LogFile = tail.LogFile;
const RuleSet = alert_rules_mod.RuleSet;
const slog = log.Scoped("chatlog");

/// Shorter lines can't hold a timestamp and a message.
const MIN_LINE_LENGTH = 25;

/// Where findings go for the main thread; each queue locks itself.
pub const Outbox = struct {
    system_updates: *queue.Queue(queue.SystemUpdate),
    notifications: *queue.Queue(queue.NotificationEvent),
    intel_sightings: *queue.Queue(queue.IntelSighting),
};

/// The chatlog worker's; its set functions run only while that worker is stopped.
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    /// Borrows the monitor's queues.
    outbox: Outbox,
    /// Borrows the monitor's set of followed characters, so their own chat never alerts; worker only.
    own_characters: *const std.StringHashMap(void),
    /// Read by the worker for ore prices, which only change while it's stopped.
    global_settings: ?*const config.GlobalConfig,
    /// Read by the worker; set by setTrackers only while it's stopped.
    combat_tracker: ?*tracker_mod.CombatTracker = null,
    /// Read by the worker; set by setTrackers only while it's stopped.
    mining_tracker: ?*tracker_mod.MiningTracker = null,
    /// Read by the worker; set by setTrackers only while it's stopped.
    bounty_tracker: ?*tracker_mod.BountyTracker = null,
    /// Owned and freed in deinit; read by the worker, and set only while it's stopped.
    damage_alert_excluded_weapons: []const u8 = "",
    /// Owned and freed in deinit; read by the worker, and set only while it's stopped.
    alert_rules: ?RuleSet = null,
    /// Worker only.
    client_systems: routing.ClientSystems = .{},
    /// Worker only: chat alerts raised lately, so other clients' copies and cooldowns stay quiet.
    recent_hits: alert_rules_mod.RecentHits = .{},
    /// Worker only: intel lines seen lately, so other clients' copies aren't listed again.
    recent_sightings: alert_rules_mod.RecentHits = .{},
    /// Worker only.
    next_alert_group: u64 = 0,

    pub fn deinit(self: *Interpreter) void {
        if (self.damage_alert_excluded_weapons.len > 0) self.allocator.free(self.damage_alert_excluded_weapons);
        if (self.alert_rules) |*rules| rules.deinit();
        self.client_systems.deinit(self.allocator);
    }

    /// Owned, since the worker reads it while a dialog preview may replace the config's copy.
    pub fn setDamageAlertExcludedWeapons(self: *Interpreter, weapons: []const u8) void {
        const owned: []const u8 = if (weapons.len == 0) "" else self.allocator.dupe(u8, weapons) catch |err| {
            slog.err("Failed to copy damage alert weapon filter, keeping the previous one: {}", .{err});
            return;
        };
        if (self.damage_alert_excluded_weapons.len > 0) self.allocator.free(self.damage_alert_excluded_weapons);
        self.damage_alert_excluded_weapons = owned;
    }

    /// Copied, since the worker reads them while a dialog preview may replace the config's; false, keeping the previous ones, on failure.
    pub fn setChatAlerts(self: *Interpreter, chat_alerts: []const config.ChatAlertConfig, characters: []const config.CharacterConfig) bool {
        var muted: std.ArrayList([]const u8) = .empty;
        defer muted.deinit(self.allocator);
        for (characters) |character| {
            if (!character.mutesChatAlerts()) continue;
            muted.append(self.allocator, character.name) catch |err| {
                slog.err("Failed to copy chat alert rules, keeping the previous ones: {}", .{err});
                return false;
            };
        }
        const rules = RuleSet.init(self.allocator, chat_alerts, muted.items) catch |err| {
            slog.err("Failed to copy chat alert rules, keeping the previous ones: {}", .{err});
            return false;
        };
        if (self.alert_rules) |*previous| previous.deinit();
        self.alert_rules = rules;
        return true;
    }

    /// Borrows the trackers.
    pub fn setTrackers(self: *Interpreter, combat: ?*tracker_mod.CombatTracker, mining: ?*tracker_mod.MiningTracker, bounty: ?*tracker_mod.BountyTracker) void {
        self.combat_tracker = combat;
        self.mining_tracker = mining;
        self.bounty_tracker = bounty;
    }

    /// Null while there are none.
    pub fn alertRules(self: *const Interpreter) ?*const RuleSet {
        return if (self.alert_rules) |*alert_rules| alert_rules else null;
    }

    /// Drops what's known about a character whose logs are no longer followed.
    pub fn forget(self: *Interpreter, character_name: []const u8) void {
        self.client_systems.forget(self.allocator, character_name);
        if (self.combat_tracker) |tracker| tracker.removeCharacter(character_name);
        if (self.mining_tracker) |tracker| tracker.removeCharacter(character_name);
        if (self.bounty_tracker) |tracker| tracker.removeCharacter(character_name);
    }

    /// Only the first few and then every 100th, since a malformed log can produce thousands.
    pub fn warnLongLine(file: *LogFile, line_length: usize) void {
        file.long_line_warning_count += 1;
        if (file.long_line_warning_count <= 3 or file.long_line_warning_count % 100 == 0) {
            slog.warn("Dropping line ({} bytes, over the {}-byte cap) for '{s}' (warning #{})", .{ line_length, lines.MAX_LINE_LENGTH, file.character_name, file.long_line_warning_count });
        }
    }

    pub fn interpret(self: *Interpreter, file: *LogFile, line: []const u8) void {
        if (line.len < MIN_LINE_LENGTH) return;
        if (line.len > lines.MAX_LINE_LENGTH) {
            warnLongLine(file, line.len);
            return;
        }

        if (file.is_chatlog) {
            if (!file.isChannelLog()) {
                if (lines.parseChatLine(line)) |system| self.handleSystemChange(file, system, .chatlog, lines.leadingTimestamp(line));
            }
            self.handleChatMessage(file, line);
            return;
        }

        const parsed = lines.parseGameLine(line);
        if (parsed.system) |change| self.handleSystemChange(file, change.system, change.source, lines.leadingTimestamp(line));
        if (parsed.activity) |activity| switch (activity) {
            .event => self.handleGamelogEvent(file, line),
            .mining => self.handleMiningEvent(file, line),
            .bounty => self.handleBountyEvent(file, line),
        };
    }

    /// Also where chat alerts look for the character; `is_jump` is false for where it already was.
    pub fn queueSystemUpdate(self: *Interpreter, character_name: []const u8, system_name: []const u8, event_timestamp: u64, is_jump: bool) void {
        self.client_systems.record(self.allocator, character_name, system_name, event_timestamp) catch |err| {
            slog.warn("Failed to remember where '{s}' is for chat alerts: {}", .{ character_name, err });
        };
        const system_update = self.copySystemUpdate(character_name, system_name, event_timestamp, is_jump) catch |err| {
            slog.err("Failed to copy system update for '{s}': {}", .{ character_name, err });
            return;
        };
        self.outbox.system_updates.push(system_update) catch |err| {
            slog.err("Failed to queue system update for '{s}': {}", .{ character_name, err });
        };
    }

    fn copySystemUpdate(self: *const Interpreter, character_name: []const u8, system_name: []const u8, event_timestamp: u64, is_jump: bool) !queue.SystemUpdate {
        const owned_name = try self.allocator.dupe(u8, character_name);
        errdefer self.allocator.free(owned_name);
        return .{
            .character_name = owned_name,
            .system_name = try self.allocator.dupe(u8, system_name),
            .event_timestamp = event_timestamp,
            .is_jump = is_jump,
        };
    }

    /// Gated by the type's settings in Notifier.notify, once the main thread delivers it.
    fn queueNotification(self: *Interpreter, character_name: []const u8, notification: notification_mod.Notification) void {
        var event: queue.NotificationEvent = .{
            .character_name = "",
            .notification = .{
                .notification_type = notification.notification_type,
                .state = notification.state,
                .chat_rule_index = notification.chat_rule_index,
                .alert_group = notification.alert_group,
            },
        };
        self.copyNotificationEvent(&event, character_name, notification) catch |err| {
            event.deinit(self.allocator);
            slog.err("Failed to copy {s} notification for '{s}': {}", .{ @tagName(notification.notification_type), character_name, err });
            return;
        };
        self.outbox.notifications.push(event) catch |err| {
            slog.err("Failed to queue {s} notification for '{s}': {}", .{ @tagName(notification.notification_type), character_name, err });
        };
    }

    /// Fills `event` field by field so a partial failure leaves it safe to deinit.
    fn copyNotificationEvent(self: *const Interpreter, event: *queue.NotificationEvent, character_name: []const u8, notification: notification_mod.Notification) !void {
        event.character_name = try self.allocator.dupe(u8, character_name);
        if (notification.source) |source| event.notification.source = try self.allocator.dupe(u8, source);
        if (notification.target) |target| event.notification.target = try self.allocator.dupe(u8, target);
        if (notification.channel) |channel| event.notification.channel = try self.allocator.dupe(u8, channel);
        if (notification.message) |message| event.notification.message = try self.allocator.dupe(u8, message);
        if (notification.jumps) |jumps| event.notification.jumps = try self.allocator.dupe(u8, jumps);
    }

    fn handleChatMessage(self: *Interpreter, file: *const LogFile, line: []const u8) void {
        const alert_rules = if (self.alert_rules) |*alert_rules| alert_rules else return;
        if (!alert_rules.followsChannel(file.channel_name)) return;
        var message = lines.parseChatMessage(line) orelse return;
        var body_buf: [lines.MAX_LINE_LENGTH]u8 = undefined;
        message.body = lines.collapseSpaces(message.body, &body_buf);
        self.queueIntelSightings(alert_rules, file.channel_name, message);

        var client_buf: [alert_rules_mod.MAX_CLIENTS]alert_rules_mod.Client = undefined;
        const clients = self.client_systems.alertable(alert_rules, &client_buf);
        var recipient_buf: [alert_rules_mod.MAX_CLIENTS][]const u8 = undefined;
        const heard: routing.Heard = .{
            .channel = file.channel_name,
            .listener = file.character_name,
            .message = message,
            .is_own_character = self.own_characters.contains(message.speaker),
        };
        const alert = routing.route(alert_rules, &self.recent_hits, heard, clients, win32.Ticks.now().ms, &recipient_buf) orelse return;
        const hit = alert.hit;

        var jumps_buf: [3]u8 = undefined;
        // A u8 is at most three digits.
        const jumps: ?[]const u8 = if (hit.jumps) |count| std.mem.print(&jumps_buf, "{d}", .{count}) catch unreachable else null;
        const notification: notification_mod.Notification = .{
            .notification_type = hit.notification_type,
            .source = message.speaker,
            .target = hit.term,
            .channel = file.channel_name,
            .message = message.body,
            .jumps = jumps,
            .chat_rule_index = hit.rule_index,
            .alert_group = self.next_alert_group,
        };
        self.next_alert_group += 1;
        slog.debug("Chat alert ({s}) in '{s}': {s}", .{ @tagName(hit.notification_type), file.channel_name, hit.term });
        for (alert.recipients) |character_name| self.queueNotification(character_name, notification);
    }

    /// One per system named, however far off: the map and Intel Panel show intel a client's alert range doesn't reach.
    fn queueIntelSightings(self: *Interpreter, alert_rules: *const RuleSet, channel: []const u8, message: lines.ChatMessage) void {
        var mention_buf: [alert_rules_mod.MAX_MENTIONS]universe.SystemIndex = undefined;
        const report = alert_rules.intelReport(channel, message, &mention_buf);
        if (report.systems.len == 0) return;
        if (self.recent_sightings.isRepeat(alert_rules_mod.messageKey(message), win32.Ticks.now().ms, alert_rules_mod.DUPLICATE_WINDOW_MS)) return;
        for (report.systems, 0..) |system, index| {
            const owned = self.allocator.dupe(u8, message.body) catch |err| {
                slog.warn("Failed to copy intel for the map: {}", .{err});
                return;
            };
            self.outbox.intel_sightings.push(.{
                .system = system,
                .message = owned,
                .is_clear = report.is_clear and index == 0,
                .is_pinned = index < report.pin_count,
                .is_message_first = index == 0,
            }) catch |err| {
                slog.warn("Failed to queue intel for the map: {}", .{err});
            };
        }
    }

    /// `system` is borrowed and copied into the queued events.
    fn handleSystemChange(self: *Interpreter, file: *LogFile, system: []const u8, source: lines.SystemSource, event_timestamp: u64) void {
        const report = routing.systemReport(&file.last_system_hash, system, source) orelse return;
        if (report.notifies) self.queueNotification(file.character_name, .{ .notification_type = .SystemChange, .target = system });
        // Timestamped, since a quiet chatlog can be read after a newer gamelog jump.
        self.queueSystemUpdate(file.character_name, system, event_timestamp, report.is_jump);
        slog.info("System change ({s}): {s} -> {s}", .{ @tagName(source), file.character_name, system });
    }

    fn handleGamelogEvent(self: *Interpreter, file: *LogFile, event_text: []const u8) void {
        // Stripped once for both uses; this is the highest-volume line type.
        var stripped_buf: [activity_lines.MAX_STRIPPED_LENGTH]u8 = undefined;
        const stripped_text = activity_lines.stripHtml(event_text, &stripped_buf);

        if (self.combat_tracker) |tracker| {
            if (activity_lines.parseCombatLine(stripped_text)) |parsed| {
                // Filtered weapons still count toward DPS but mustn't retrigger Taking Damage.
                const counts_for_alert = !activity_lines.isWeaponExcluded(parsed.weapon, self.damage_alert_excluded_weapons);
                const hit: tracker_mod.CombatWindow.Hit = .{
                    .amount = parsed.amount,
                    .timestamp = win32.Ticks.now(),
                    .is_incoming = parsed.is_incoming,
                    .counts_for_alert = counts_for_alert,
                };
                tracker.addEntry(file.character_name, .{hit}) catch |err| {
                    slog.warn("Failed to record combat entry for '{s}': {}", .{ file.character_name, err });
                };
            }
        }

        const notification = gamelog_events.classify(stripped_text) orelse return;
        self.queueNotification(file.character_name, notification);
        slog.debug("Gamelog event: {s} -> {s}", .{ file.character_name, event_text });
    }

    /// A missing price counts as 0 ISK; only a missing volume drops the yield, since m3 can't be computed without it.
    fn handleMiningEvent(self: *const Interpreter, file: *LogFile, event_text: []const u8) void {
        const tracker = self.mining_tracker orelse return;
        const parsed = activity_lines.parseMiningLine(event_text) orelse return;
        const global_settings = self.global_settings orelse return;
        const volume_per_unit = ores.volume(parsed.name()) orelse {
            slog.warn("Failed to record mining yield: unknown ore, ice or gas '{s}'", .{parsed.name()});
            return;
        };
        const price_per_unit = ores.price(global_settings.oreTable.items, parsed.name()) orelse 0;
        const amount: f32 = @floatFromInt(parsed.amount);
        const m3 = amount * @as(f32, @floatCast(volume_per_unit));
        const isk = amount * @as(f32, @floatCast(price_per_unit));
        tracker.addEntry(file.character_name, .{ m3, isk, win32.Ticks.now() }) catch |err| {
            slog.warn("Failed to record mining entry for '{s}': {}", .{ file.character_name, err });
        };
    }

    fn handleBountyEvent(self: *const Interpreter, file: *LogFile, event_text: []const u8) void {
        const tracker = self.bounty_tracker orelse return;
        const isk = activity_lines.parseBountyLine(event_text) orelse return;
        tracker.addEntry(file.character_name, .{ isk, win32.Ticks.now() }) catch |err| {
            slog.warn("Failed to record bounty entry for '{s}': {}", .{ file.character_name, err });
        };
    }
};
