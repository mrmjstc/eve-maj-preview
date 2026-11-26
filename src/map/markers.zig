//! The marks the Map Panel and the thumbnails' connections overlay draw alike: system markers, rings, gates, exits and intel halos.
const std = @import("std");
const palette = @import("../palette.zig");
const layout = @import("layout.zig");
const color = @import("../util/color.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

/// A system's marker, before the marker scale; the Map Panel grows a busy one.
pub const NODE_RADIUS: f32 = 3.5;
/// Just outside a client's ring, so neither hides the other; before the marker scale.
const INTEL_HALO_RADIUS: f32 = 11;
/// Before the marker scale.
const INTEL_HALO_PEAK_RADIUS: f32 = 20;
/// Around a marked system's marker.
pub const RING_GAP: f32 = 3;
pub const RING_THICKNESS: f32 = 1.5;
const EXIT_RADIUS: f32 = 2;

// The colours below are 0xAARRGGBB, not premultiplied.
pub const EDGE_LOCAL: u32 = color.mix(palette.BORDER_STRONG, palette.BORDER, 60);
const EDGE_CROSS: u32 = 0xFF6E5A7A;
/// Pale sand, kept off the accent's amber.
pub const EXIT: u32 = 0xFFD3C49C;
pub const INTEL: u32 = 0xFFFF4B3E;
const INTEL_CLEAR: u32 = 0xFFFFD23F;
pub const FOCUS: u32 = palette.TEXT;

pub fn intelColor(is_clear: bool) u32 {
    return if (is_clear) INTEL_CLEAR else INTEL;
}

/// At its largest when new, shrinking evenly to its resting size over `shrink_ms`.
pub fn intelHaloRadius(age_ms: u64, shrink_ms: u64) f32 {
    if (age_ms >= shrink_ms) return INTEL_HALO_RADIUS;
    const share_left = @as(f32, @floatFromInt(shrink_ms - age_ms)) / @as(f32, @floatFromInt(shrink_ms));
    return INTEL_HALO_RADIUS + (INTEL_HALO_PEAK_RADIUS - INTEL_HALO_RADIUS) * share_left;
}

pub fn drawIntelHalo(canvas: pixel_buffer.Canvas, x: i32, y: i32, radius: f32, is_clear: bool, freshness_percent: u64) void {
    pixel_buffer.fillCircle(canvas, x, y, radius, intelHaloColor(is_clear, freshness_percent));
    pixel_buffer.drawRing(canvas, x, y, radius, RING_THICKNESS, intelRimColor(is_clear, freshness_percent));
}

/// A gate between regions takes an exit's colour, as it's the same gate with both ends shown.
pub fn edgeColor(kind: layout.GateKind) u32 {
    return switch (kind) {
        .within_constellation => EDGE_LOCAL,
        .within_region => EDGE_CROSS,
        .between_regions => EXIT,
    };
}

/// The stub from a system to where its gate to a region not shown points.
pub fn drawExit(canvas: pixel_buffer.Canvas, node: layout.Node, exit: layout.Exit, exit_color: u32) void {
    pixel_buffer.drawLine(canvas, node.x, node.y, exit.x, exit.y, exit_color);
    pixel_buffer.fillCircle(canvas, exit.x, exit.y, EXIT_RADIUS, exit_color);
}

/// A pin's halo fill, fainter as it ages; kept faint so lines and names read through it.
fn intelHaloColor(is_clear: bool, freshness_percent: u64) u32 {
    const alpha: u8 = @intCast(15 + freshness_percent * 30 / 100);
    return color.withAlpha(intelColor(is_clear), alpha);
}

/// The rim that makes a pin's halo stand out, fainter as it ages.
fn intelRimColor(is_clear: bool, freshness_percent: u64) u32 {
    const alpha: u8 = @intCast(60 + freshness_percent * 195 / 100);
    return color.withAlpha(intelColor(is_clear), alpha);
}

const testing = std.testing;

test "an intel halo shrinks from its peak and then rests" {
    try testing.expectEqual(INTEL_HALO_PEAK_RADIUS, intelHaloRadius(0, 60_000));
    const halfway = intelHaloRadius(30_000, 60_000);
    try testing.expectApproxEqAbs((INTEL_HALO_PEAK_RADIUS + INTEL_HALO_RADIUS) / 2, halfway, 0.01);
    try testing.expectEqual(INTEL_HALO_RADIUS, intelHaloRadius(60_000, 60_000));
    try testing.expectEqual(INTEL_HALO_RADIUS, intelHaloRadius(120_000, 60_000));
    try testing.expectEqual(INTEL_HALO_RADIUS, intelHaloRadius(0, 0));
}
