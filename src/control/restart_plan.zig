//! The order a reload tears down and rebuilds what's set up from the profile, decided from facts about the running app; no I/O.
const std = @import("std");

/// Every step at most once.
const MAX_STEPS = std.enums.values(Step).len;
/// Brought back up by Plan.recovery; safe at any point, since a paused monitor's trackers and settings change only while it's stopped.
const RESTORES = [_]Restore{
    .{ .down = .pause_monitor, .up = .start_monitor },
    .{ .down = .destroy_hotkey_manager, .up = .create_hotkey_manager },
};

/// A step that takes a subsystem down, and the later one that brings it back.
const Restore = struct { down: Step, up: Step };

/// What App.restartSubsystems runs, in plan order.
pub const Step = enum {
    /// Stops the chatlog worker but keeps the monitor and its scan state, so it must be started again.
    pause_monitor,
    destroy_monitor,
    /// The chatlog worker reads the global settings, its own and the ore prices, so they're replaced only while it's stopped.
    adopt_global_draft,
    destroy_hotkey_manager,
    /// Keeps each client's system name for build_thumbnail_set to seed the new set with.
    teardown_thumbnail_set,
    install_profile,
    record_last_used_profile,
    rescan_windows,
    build_thumbnail_set,
    /// Adds thumbnails for windows the new filters admit, keeping the set.
    populate_thumbnail_set,
    /// Drops the kept set's system names, rates and log alerts once monitoring is off, since nothing would update them.
    clear_log_readings,
    apply_monitor_settings,
    create_monitor,
    /// Wires the trackers into the monitor, which must not be running.
    setup_trackers,
    /// Skipped when there's no monitor, as after a failed create_monitor.
    start_monitor,
    add_monitor_characters,
    create_hotkey_manager,
    set_tick_interval,
};

pub const Facts = struct {
    /// A profile switch hands over a new profile; a Save restarts on the running one.
    is_profile_replaced: bool,
    has_thumbnail_set: bool,
    has_monitor: bool,
    /// The running monitor follows the log folders the next settings do, so it can be paused and kept rather than rebuilt.
    is_monitor_on_next_folders: bool,
    is_chatlog_enabled_next: bool,
    has_global_draft: bool,
};

pub const Plan = struct {
    buffer: [MAX_STEPS]Step = undefined,
    step_count: usize = 0,

    pub fn init(facts: Facts) Plan {
        var plan: Plan = .{};
        const keeps_monitor = facts.has_monitor and facts.is_monitor_on_next_folders;
        const creates_monitor = !keeps_monitor and facts.is_chatlog_enabled_next;
        // A Save keeps the thumbnail set: the dialog already previewed what was saved, so a rebuild would only flash every window.
        const rebuilds_thumbnail_set = facts.is_profile_replaced or !facts.has_thumbnail_set;

        if (keeps_monitor) plan.add(.pause_monitor) else if (facts.has_monitor) plan.add(.destroy_monitor);
        if (facts.has_global_draft) plan.add(.adopt_global_draft);
        plan.add(.destroy_hotkey_manager);
        if (rebuilds_thumbnail_set) plan.add(.teardown_thumbnail_set);
        if (facts.is_profile_replaced) plan.add(.install_profile);
        plan.add(.record_last_used_profile);
        // Windows the new filters drop are reported closed, and leave the thumbnail set and chatlog on the next tick.
        plan.add(.rescan_windows);
        plan.add(if (rebuilds_thumbnail_set) .build_thumbnail_set else .populate_thumbnail_set);
        if (!rebuilds_thumbnail_set and !facts.is_chatlog_enabled_next) plan.add(.clear_log_readings);
        if (keeps_monitor) plan.add(.apply_monitor_settings);
        if (creates_monitor) plan.add(.create_monitor);
        plan.add(.setup_trackers);
        if (keeps_monitor or creates_monitor) plan.add(.start_monitor);
        // A kept monitor still follows its characters' logs.
        if (creates_monitor) plan.add(.add_monitor_characters);
        plan.add(.create_hotkey_manager);
        plan.add(.set_tick_interval);
        return plan;
    }

    pub fn steps(self: *const Plan) []const Step {
        return self.buffer[0..self.step_count];
    }

    /// What to run when the step at `failed_index` fails: whatever an earlier step took down and a later one was to bring back, in plan order.
    pub fn recovery(self: *const Plan, failed_index: usize) Plan {
        var out: Plan = .{};
        for (self.steps()[failed_index + 1 ..]) |step| {
            for (RESTORES) |restore| {
                if (restore.up != step) continue;
                const down_index = self.indexOf(restore.down) orelse continue;
                if (down_index < failed_index) out.add(step);
            }
        }
        return out;
    }

    fn indexOf(self: *const Plan, step: Step) ?usize {
        return std.mem.indexOfScalar(Step, self.steps(), step);
    }

    fn add(self: *Plan, step: Step) void {
        self.buffer[self.step_count] = step;
        self.step_count += 1;
    }
};

const testing = std.testing;

/// A Save that keeps the log folders: the commonest reload.
const SAVE: Facts = .{
    .is_profile_replaced = false,
    .has_thumbnail_set = true,
    .has_monitor = true,
    .is_monitor_on_next_folders = true,
    .is_chatlog_enabled_next = true,
    .has_global_draft = true,
};

fn has(plan: *const Plan, step: Step) bool {
    return plan.indexOf(step) != null;
}

fn expectBefore(plan: *const Plan, first: Step, second: Step) !void {
    const first_index = plan.indexOf(first) orelse return error.TestExpectedStep;
    const second_index = plan.indexOf(second) orelse return error.TestExpectedStep;
    try testing.expect(first_index < second_index);
}

test "a Save on the same log folders pauses the monitor and keeps the thumbnail set" {
    const plan: Plan = .init(SAVE);
    try expectBefore(&plan, .pause_monitor, .start_monitor);
    try testing.expect(has(&plan, .populate_thumbnail_set));
    try testing.expect(!has(&plan, .teardown_thumbnail_set));
    try testing.expect(!has(&plan, .build_thumbnail_set));
    try testing.expect(!has(&plan, .install_profile));
    try testing.expect(!has(&plan, .create_monitor));
    try testing.expect(!has(&plan, .add_monitor_characters));
}

test "a profile switch rebuilds the thumbnail set after installing the new profile" {
    var facts = SAVE;
    facts.is_profile_replaced = true;
    const plan: Plan = .init(facts);
    try expectBefore(&plan, .teardown_thumbnail_set, .install_profile);
    try expectBefore(&plan, .install_profile, .rescan_windows);
    try expectBefore(&plan, .rescan_windows, .build_thumbnail_set);
    try testing.expect(!has(&plan, .populate_thumbnail_set));
}

test "a monitor on other log folders is replaced, and only the new one is given the characters" {
    var facts = SAVE;
    facts.is_monitor_on_next_folders = false;
    const plan: Plan = .init(facts);
    try expectBefore(&plan, .destroy_monitor, .create_monitor);
    try expectBefore(&plan, .start_monitor, .add_monitor_characters);
    try testing.expect(!has(&plan, .pause_monitor));
    try testing.expect(!has(&plan, .apply_monitor_settings));
}

test "with chatlog monitoring off, no monitor is created or started" {
    var facts = SAVE;
    facts.is_monitor_on_next_folders = false;
    facts.is_chatlog_enabled_next = false;
    const plan: Plan = .init(facts);
    try testing.expect(has(&plan, .destroy_monitor));
    try testing.expect(!has(&plan, .create_monitor));
    try testing.expect(!has(&plan, .start_monitor));
    try testing.expect(has(&plan, .setup_trackers));
}

test "a Save that turns chatlog monitoring off clears what the logs last showed" {
    var facts = SAVE;
    facts.is_monitor_on_next_folders = false;
    facts.is_chatlog_enabled_next = false;
    const plan: Plan = .init(facts);
    try expectBefore(&plan, .populate_thumbnail_set, .clear_log_readings);
}

test "a rebuilt thumbnail set or monitoring left on clears nothing" {
    var switch_facts = SAVE;
    switch_facts.is_profile_replaced = true;
    switch_facts.is_chatlog_enabled_next = false;
    const switch_plan: Plan = .init(switch_facts);
    try testing.expect(!has(&switch_plan, .clear_log_readings));
    const save_plan: Plan = .init(SAVE);
    try testing.expect(!has(&save_plan, .clear_log_readings));
}

test "every plan stops the worker before what it reads changes, and starts it only once wired" {
    var bits: u7 = 0;
    while (bits < 1 << 6) : (bits += 1) {
        const plan: Plan = .init(.{
            .is_profile_replaced = bits & 1 != 0,
            .has_thumbnail_set = bits & 2 != 0,
            .has_monitor = bits & 4 != 0,
            .is_monitor_on_next_folders = bits & 8 != 0,
            .is_chatlog_enabled_next = bits & 16 != 0,
            .has_global_draft = bits & 32 != 0,
        });
        for (std.enums.values(Step)) |step| {
            try testing.expect(std.mem.count(Step, plan.steps(), &[_]Step{step}) <= 1);
        }
        const stop: ?Step = if (has(&plan, .pause_monitor)) .pause_monitor else if (has(&plan, .destroy_monitor)) .destroy_monitor else null;
        if (stop) |stop_step| {
            if (has(&plan, .adopt_global_draft)) try expectBefore(&plan, stop_step, .adopt_global_draft);
            try expectBefore(&plan, stop_step, .setup_trackers);
        }
        if (has(&plan, .pause_monitor)) try expectBefore(&plan, .apply_monitor_settings, .start_monitor);
        if (has(&plan, .create_monitor)) try expectBefore(&plan, .create_monitor, .setup_trackers);
        if (has(&plan, .start_monitor)) try expectBefore(&plan, .setup_trackers, .start_monitor);
        try testing.expect(has(&plan, .build_thumbnail_set) != has(&plan, .populate_thumbnail_set));
        try expectBefore(&plan, .destroy_hotkey_manager, .create_hotkey_manager);
    }
}

test "a failed thumbnail set build resumes the paused monitor and recreates the hotkey manager" {
    var facts = SAVE;
    facts.is_profile_replaced = true;
    const plan: Plan = .init(facts);
    const build_index = plan.indexOf(.build_thumbnail_set) orelse return error.TestExpectedStep;
    const recovery = plan.recovery(build_index);
    try testing.expectEqualSlices(Step, &.{ .start_monitor, .create_hotkey_manager }, recovery.steps());
}

test "with no monitor paused, a failed build only recreates the hotkey manager" {
    var facts = SAVE;
    facts.is_profile_replaced = true;
    facts.is_monitor_on_next_folders = false;
    const plan: Plan = .init(facts);
    const build_index = plan.indexOf(.build_thumbnail_set) orelse return error.TestExpectedStep;
    const recovery = plan.recovery(build_index);
    try testing.expectEqualSlices(Step, &.{.create_hotkey_manager}, recovery.steps());
}

test "a failed hotkey manager isn't retried, and the monitor it follows is already running" {
    const plan: Plan = .init(SAVE);
    const hotkeys_index = plan.indexOf(.create_hotkey_manager) orelse return error.TestExpectedStep;
    try testing.expectEqual(0, plan.recovery(hotkeys_index).steps().len);
}

test "whichever step fails, nothing taken down stays down" {
    var bits: u7 = 0;
    while (bits < 1 << 6) : (bits += 1) {
        const plan: Plan = .init(.{
            .is_profile_replaced = bits & 1 != 0,
            .has_thumbnail_set = bits & 2 != 0,
            .has_monitor = bits & 4 != 0,
            .is_monitor_on_next_folders = bits & 8 != 0,
            .is_chatlog_enabled_next = bits & 16 != 0,
            .has_global_draft = bits & 32 != 0,
        });
        for (plan.steps(), 0..) |failed, failed_index| {
            const recovery = plan.recovery(failed_index);
            for (RESTORES) |restore| {
                const down_index = plan.indexOf(restore.down) orelse continue;
                const up_index = plan.indexOf(restore.up) orelse continue;
                const is_down = down_index < failed_index and failed_index < up_index;
                try testing.expectEqual(is_down, has(&recovery, restore.up));
            }
            try testing.expect(!has(&recovery, failed));
        }
    }
}
