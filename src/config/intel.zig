//! How chat intel marks systems, for every view that shows it: the Map Panel's pins and the thumbnails' connection maps.
const std = @import("std");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

pub const IntelConfig = struct {
    /// How long an intel pin shows, its halo shrinking all the while.
    shrinkSec: i32 = 300,
    /// Turns a pin yellow when intel calls its system clear; off, those messages leave pins alone.
    showClear: bool = true,

    pub const ranges = .{
        .shrinkSec = .{ 1, 900 },
    };

    pub fn validate(self: *IntelConfig) void {
        ranges_mod.clamp(IntelConfig, self);
    }

    pub fn shrinkMs(self: *const IntelConfig) u64 {
        return @as(u64, @intCast(@max(0, self.shrinkSec))) * std.time.ms_per_s;
    }

    pub const Wire = wire.Wire(IntelConfig);
};
