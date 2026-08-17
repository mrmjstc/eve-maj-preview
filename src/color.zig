const std = @import("std");

/// Convert HSV color to RGB (0xRRGGBB format).
pub fn hsvToRgb(h: u32, s: u8, val: u8) u32 {
    const s_norm = @as(f32, @floatFromInt(s)) / 255.0;
    const v_norm = @as(f32, @floatFromInt(val)) / 255.0;

    const c = v_norm * s_norm;
    const h_prime = @as(f32, @floatFromInt(h % 360)) / 60.0;
    const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
    const m = v_norm - c;

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;

    const sector = @as(u8, @intFromFloat(h_prime));
    switch (sector) {
        0 => {
            r = c;
            g = x;
            b = 0;
        },
        1 => {
            r = x;
            g = c;
            b = 0;
        },
        2 => {
            r = 0;
            g = c;
            b = x;
        },
        3 => {
            r = 0;
            g = x;
            b = c;
        },
        4 => {
            r = x;
            g = 0;
            b = c;
        },
        else => {
            r = c;
            g = 0;
            b = x;
        },
    }

    const r_byte = @as(u32, @intFromFloat((r + m) * 255.0));
    const g_byte = @as(u32, @intFromFloat((g + m) * 255.0));
    const b_byte = @as(u32, @intFromFloat((b + m) * 255.0));

    return (r_byte << 16) | (g_byte << 8) | b_byte;
}

/// Uses golden ratio for even color distribution across the spectrum.
pub fn generateUniqueColor(seed_string: []const u8) u32 {
    if (seed_string.len == 0) return 0xFFFFFF;

    const hash = std.hash.Wyhash.hash(0, seed_string);

    const max_hash = @as(f64, @floatFromInt(std.math.maxInt(u64)));
    const normalized = @as(f64, @floatFromInt(hash)) / max_hash;

    // Golden ratio conjugate for even distribution across color wheel
    const golden_ratio: f64 = 0.618033988749895;
    const hue_fraction = @mod(normalized + golden_ratio, 1.0);
    const hue = @as(u32, @intFromFloat(hue_fraction * 360.0));

    // High saturation/value for vibrant colors, using different hash bits than hue to avoid correlation.
    const saturation: u8 = 200 + @as(u8, @intCast((hash >> 20) % 36));
    const value: u8 = 210 + @as(u8, @intCast((hash >> 40) % 26));

    return hsvToRgb(hue, saturation, value);
}

pub const RgbColor = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromU32(rgb: u32) RgbColor {
        return .{
            .r = @as(u8, @intCast((rgb >> 16) & 0xFF)),
            .g = @as(u8, @intCast((rgb >> 8) & 0xFF)),
            .b = @as(u8, @intCast(rgb & 0xFF)),
        };
    }
};

pub const HsvColor = struct {
    h: u32,
    s: u8,
    v: u8,
};

pub fn rgbToHsv(rgb: u32) HsvColor {
    const color = RgbColor.fromU32(rgb);
    const r = @as(f32, @floatFromInt(color.r)) / 255.0;
    const g = @as(f32, @floatFromInt(color.g)) / 255.0;
    const b = @as(f32, @floatFromInt(color.b)) / 255.0;

    const max_val = @max(@max(r, g), b);
    const min_val = @min(@min(r, g), b);
    const delta = max_val - min_val;

    const v = @as(u8, @intFromFloat(max_val * 255.0));

    const s = if (max_val == 0.0) 0 else @as(u8, @intFromFloat((delta / max_val) * 255.0));

    var h: f32 = 0.0;
    if (delta != 0.0) {
        if (max_val == r) {
            h = 60.0 * @mod((g - b) / delta, 6.0);
        } else if (max_val == g) {
            h = 60.0 * (((b - r) / delta) + 2.0);
        } else {
            h = 60.0 * (((r - g) / delta) + 4.0);
        }
        if (h < 0.0) h += 360.0;
    }

    return .{
        .h = @as(u32, @intFromFloat(h)),
        .s = s,
        .v = v,
    };
}

/// Returns a value from 0.0 (identical) to ~1.0 (very different).
pub fn colorDistance(color1: u32, color2: u32) f32 {
    const hsv1 = rgbToHsv(color1);
    const hsv2 = rgbToHsv(color2);

    // Hue wraps at 360, so distance is the shorter way around the circle (max 180)
    const hue_diff = @abs(@as(i32, @intCast(hsv1.h)) - @as(i32, @intCast(hsv2.h)));
    const hue_distance = @min(hue_diff, 360 - hue_diff);
    const hue_norm = @as(f32, @floatFromInt(hue_distance)) / 180.0;

    const sat_diff = @abs(@as(i32, @intCast(hsv1.s)) - @as(i32, @intCast(hsv2.s)));
    const sat_norm = @as(f32, @floatFromInt(sat_diff)) / 255.0;

    const val_diff = @abs(@as(i32, @intCast(hsv1.v)) - @as(i32, @intCast(hsv2.v)));
    const val_norm = @as(f32, @floatFromInt(val_diff)) / 255.0;

    // Hue weighted 4x more than saturation/value, the most important channel for perceptual differentiation.
    const weighted_distance = (hue_norm * 2.0 + sat_norm * 0.5 + val_norm * 0.5) / 3.0;

    return weighted_distance;
}

pub fn isTooSimilar(new_color: u32, recent_colors: []const u32, threshold: f32) bool {
    for (recent_colors) |recent_color| {
        const distance = colorDistance(new_color, recent_color);
        if (distance < threshold) {
            return true;
        }
    }
    return false;
}

/// Adjusts the hue if the generated color is too similar to recent_colors (similarity_threshold: 0.0-1.0, recommend 0.3-0.4).
pub fn generateUniqueColorWithAvoidance(seed_string: []const u8, recent_colors: []const u32, similarity_threshold: f32) u32 {
    const base_color = generateUniqueColor(seed_string);

    if (recent_colors.len == 0) {
        return base_color;
    }

    if (!isTooSimilar(base_color, recent_colors, similarity_threshold)) {
        return base_color;
    }

    const hsv = rgbToHsv(base_color);

    const hue_adjustments = [_]u32{ 60, 120, 180, 240, 300, 30, 90, 150, 210, 270, 330 };

    for (hue_adjustments) |offset| {
        const new_hue = (hsv.h + offset) % 360;
        const adjusted_color = hsvToRgb(new_hue, hsv.s, hsv.v);

        if (!isTooSimilar(adjusted_color, recent_colors, similarity_threshold)) {
            return adjusted_color;
        }
    }

    // If all adjustments still too similar (rare), return the 180° opposite
    const opposite_hue = (hsv.h + 180) % 360;
    return hsvToRgb(opposite_hue, hsv.s, hsv.v);
}

pub fn withAlpha(argb: u32, alpha: u8) u32 {
    return (@as(u32, alpha) << 24) | (argb & 0x00FF_FFFF);
}
