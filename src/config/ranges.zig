//! Numeric bounds, declared once per settings type in `ranges`, enforced by `clamp` and sent to the dialog by config/schema.zig.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("config");

/// 20% of 255 up to fully opaque; below that, thumbnails and overlays effectively vanish.
pub const OPACITY = .{ 51, 255 };
pub const FONT_SIZE = .{ 6, 72 };
pub const PERCENT = .{ 0, 100 };
pub const WINDOW_SECONDS = .{ 1, 3600 };
/// How far any text (labels, overlays, notifications) can be nudged from its anchor, in pixels.
pub const TEXT_OFFSET = .{ -500, 500 };
/// Where a saved position may lie: a 4K monitor either side of, and above or below, a 4K primary.
pub const SCREEN_X = .{ -3840, 7680 };
pub const SCREEN_Y = .{ -2160, 4320 };
/// The largest a single window (thumbnail, panel) may be: one 4K monitor.
pub const MAX_WINDOW_WIDTH = 3840;
pub const MAX_WINDOW_HEIGHT = 2160;

/// Also validates every nested setting that has a validate() of its own.
pub fn clamp(comptime R: type, value: *R) void {
    if (@hasDecl(R, "ranges")) {
        inline for (@typeInfo(@TypeOf(R.ranges)).@"struct".fields) |f| {
            const field = &@field(value, f.name);
            if (@typeInfo(@TypeOf(field.*)) == .optional) {
                if (field.*) |*set| clampField(R, f.name, set);
            } else {
                clampField(R, f.name, field);
            }
        }
    }
    inline for (@typeInfo(R).@"struct".fields) |f| {
        if (comptime hasValidate(f.type)) {
            @field(value, f.name).validate();
        } else if (comptime @typeInfo(f.type) == .optional) {
            if (comptime hasValidate(@typeInfo(f.type).optional.child)) {
                if (@field(value, f.name)) |*nested| nested.validate();
            }
        }
    }
}

/// `value` brought within field `name`'s limits, for code that takes a setting in before storing it.
pub fn clampValue(comptime R: type, comptime name: []const u8, value: @FieldType(R, name)) @FieldType(R, name) {
    var result = value;
    clampField(R, name, &result);
    return result;
}

fn hasValidate(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "validate");
}

/// The default replacing a 0 isn't clamped, since it may lie outside the bounds (dialogScale's 0 means "auto").
fn clampField(comptime R: type, comptime name: []const u8, field: anytype) void {
    if (comptime isZeroMeansDefault(R, name)) {
        if (field.* == 0) {
            field.* = defaultOf(R, name);
            return;
        }
    }
    const T = @TypeOf(field.*);
    const bounds = @field(R.ranges, name);
    const clamped = std.math.clamp(field.*, @as(T, bounds[0]), @as(T, bounds[1]));
    if (clamped == field.*) return;
    slog.warn("{s}.{s} {d} out of range, clamping to {d}", .{ comptime shortTypeName(R), name, field.*, clamped });
    field.* = clamped;
}

fn isZeroMeansDefault(comptime R: type, comptime name: []const u8) bool {
    if (!@hasDecl(R, "zero_means_default")) return false;
    inline for (R.zero_means_default) |zero_name| {
        if (std.mem.eql(u8, zero_name, name)) return true;
    }
    return false;
}

fn defaultOf(comptime R: type, comptime name: []const u8) @FieldType(R, name) {
    return std.meta.fieldInfo(R, @field(std.meta.FieldEnum(R), name)).defaultValue() orelse
        @compileError(@typeName(R) ++ "." ++ name ++ " is in zero_means_default but has no default");
}

fn shortTypeName(comptime R: type) []const u8 {
    const full = @typeName(R);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}


const testing = std.testing;

const TestSettings = struct {
    opacity: u8 = 200,
    window_seconds: u32 = 60,
    offset: ?i32 = null,

    pub const ranges = .{
        .opacity = OPACITY,
        .window_seconds = WINDOW_SECONDS,
        .offset = TEXT_OFFSET,
    };
    pub const zero_means_default = .{"window_seconds"};

    pub fn validate(self: *TestSettings) void {
        clamp(TestSettings, self);
    }
};

const TestParent = struct {
    settings: TestSettings = .{},
    extra: ?TestSettings = null,
};

test "clamp pulls each field into its range" {
    var low: TestSettings = .{ .opacity = 10, .window_seconds = 5_000, .offset = -900 };
    clamp(TestSettings, &low);
    try testing.expectEqual(@as(u8, 51), low.opacity);
    try testing.expectEqual(@as(u32, 3600), low.window_seconds);
    try testing.expectEqual(@as(?i32, -500), low.offset);

    var fine: TestSettings = .{ .opacity = 128, .window_seconds = 30, .offset = 12 };
    clamp(TestSettings, &fine);
    try testing.expectEqual(@as(u8, 128), fine.opacity);
    try testing.expectEqual(@as(u32, 30), fine.window_seconds);
    try testing.expectEqual(@as(?i32, 12), fine.offset);
}

test "clamp swaps a zero-means-default 0 for the default, and clamps other zeros" {
    var settings: TestSettings = .{ .opacity = 0, .window_seconds = 0 };
    clamp(TestSettings, &settings);
    try testing.expectEqual(@as(u32, 60), settings.window_seconds);
    try testing.expectEqual(@as(u8, 51), settings.opacity);
}

test "clamp leaves an unset optional unset" {
    var settings: TestSettings = .{};
    clamp(TestSettings, &settings);
    try testing.expectEqual(@as(?i32, null), settings.offset);
}

test "clamp validates nested settings, including a set optional" {
    var parent: TestParent = .{ .settings = .{ .opacity = 1 }, .extra = .{ .opacity = 2 } };
    clamp(TestParent, &parent);
    try testing.expectEqual(@as(u8, 51), parent.settings.opacity);
    try testing.expectEqual(@as(u8, 51), parent.extra.?.opacity);
}

test "clampValue brings a single value within its field's range" {
    try testing.expectEqual(@as(u8, 51), clampValue(TestSettings, "opacity", 5));
    try testing.expectEqual(@as(u32, 60), clampValue(TestSettings, "window_seconds", 0));
    try testing.expectEqual(@as(u32, 3600), clampValue(TestSettings, "window_seconds", 9_000));
}
