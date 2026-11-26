//! What CPU priority and efficiency mode each EVE client gets under Client Speed; no I/O.
const std = @import("std");

/// How long background clients wait after a focus change to be slowed, so rapid cycling never waits on it.
pub const SETTLE_MS: u64 = 1500;

pub const Priority = enum { below_normal, normal, above_normal };

pub const Throttle = enum {
    /// Windows decides, as for any process.
    default,
    /// Efficiency mode: lower clocks, or efficiency cores where the CPU has them.
    efficient,
    /// Never efficiency mode, even while minimized or covered.
    never,
};

pub const Speed = struct {
    priority: Priority = .normal,
    throttle: Throttle = .default,
};

/// Mirrors ClientSpeedConfig.
pub const Options = struct {
    raises_focused: bool = false,
    lowers_background: bool = false,
    throttles_background: bool = false,

    pub fn isAnyOn(self: Options) bool {
        return self.raises_focused or self.lowers_background or self.throttles_background;
    }
};

pub const Role = enum {
    focused,
    background,
    /// A background client whose character is set to Keep at Full Speed.
    kept_at_full_speed,
};

pub fn wantedSpeed(options: Options, role: Role) Speed {
    return switch (role) {
        .focused => .{ .priority = if (options.raises_focused) .above_normal else .normal },
        .background => .{
            .priority = if (options.lowers_background) .below_normal else .normal,
            .throttle = if (options.throttles_background) .efficient else .default,
        },
        .kept_at_full_speed => .{ .throttle = if (options.isAnyOn()) .never else .default },
    };
}

/// What to set a client to now, or null to leave it; `applied` is null for a client never set.
pub fn nextSpeed(options: Options, applied: ?Speed, wanted: Speed, is_settling: bool) ?Speed {
    // A client never set is set once any option is on, which also undoes what a run that crashed left.
    const current = applied orelse return if (options.isAnyOn()) wanted else null;
    if (std.meta.eql(current, wanted)) return null;
    if (is_settling and isSlower(wanted, current)) return null;
    return wanted;
}

/// True when any part of `speed` is slower than the same part of `reference`.
fn isSlower(speed: Speed, reference: Speed) bool {
    return priorityRank(speed.priority) < priorityRank(reference.priority) or throttleRank(speed.throttle) < throttleRank(reference.throttle);
}

fn priorityRank(priority: Priority) u8 {
    return switch (priority) {
        .below_normal => 0,
        .normal => 1,
        .above_normal => 2,
    };
}

fn throttleRank(throttle: Throttle) u8 {
    return switch (throttle) {
        .efficient => 0,
        .default => 1,
        .never => 2,
    };
}

const testing = std.testing;

const ALL_ON: Options = .{ .raises_focused = true, .lowers_background = true, .throttles_background = true };

test "wantedSpeed raises the focused client and slows only plain background ones" {
    try testing.expectEqual(Speed{ .priority = .above_normal }, wantedSpeed(ALL_ON, .focused));
    try testing.expectEqual(Speed{ .priority = .below_normal, .throttle = .efficient }, wantedSpeed(ALL_ON, .background));
    try testing.expectEqual(Speed{ .throttle = .never }, wantedSpeed(ALL_ON, .kept_at_full_speed));
}

test "wantedSpeed is Windows' default for every role with every option off" {
    for (std.enums.values(Role)) |role| try testing.expectEqual(Speed{}, wantedSpeed(.{}, role));
}

test "nextSpeed leaves a client never set alone while every option is off" {
    try testing.expectEqual(@as(?Speed, null), nextSpeed(.{}, null, .{}, false));
}

test "nextSpeed sets a client never set once an option is on, even to the default" {
    const options: Options = .{ .raises_focused = true };
    try testing.expectEqual(@as(?Speed, .{}), nextSpeed(options, null, wantedSpeed(options, .background), false));
}

test "nextSpeed puts a client back once its options are turned off" {
    const slowed: Speed = .{ .priority = .below_normal, .throttle = .efficient };
    try testing.expectEqual(@as(?Speed, .{}), nextSpeed(.{}, slowed, wantedSpeed(.{}, .background), false));
}

test "nextSpeed holds back slowing a client while focus settles but not speeding one up" {
    const raised = wantedSpeed(ALL_ON, .focused);
    const slowed = wantedSpeed(ALL_ON, .background);
    try testing.expectEqual(@as(?Speed, null), nextSpeed(ALL_ON, raised, slowed, true));
    try testing.expectEqual(@as(?Speed, slowed), nextSpeed(ALL_ON, raised, slowed, false));
    try testing.expectEqual(@as(?Speed, raised), nextSpeed(ALL_ON, slowed, raised, true));
}

test "nextSpeed counts a change that slows any part as slowing" {
    const before: Speed = .{ .priority = .below_normal, .throttle = .never };
    const after: Speed = .{ .priority = .normal, .throttle = .efficient };
    try testing.expectEqual(@as(?Speed, null), nextSpeed(ALL_ON, before, after, true));
}

test "nextSpeed leaves a client already at the wanted speed" {
    const slowed = wantedSpeed(ALL_ON, .background);
    try testing.expectEqual(@as(?Speed, null), nextSpeed(ALL_ON, slowed, slowed, false));
}
