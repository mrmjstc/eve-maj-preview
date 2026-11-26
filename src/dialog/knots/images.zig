//! Bitmaps bundled with the configuration window, stored zlib-compressed and unpacked on first use; main thread only.
const std = @import("std");
const ui = @import("ui");
const rgba = @import("../../util/rgba.zig");
const portraits = @import("portraits.zig");
const log = @import("../../log.zig");

const Image = ui.component.Image;
const slog = log.Scoped("dialog_knots");

/// A bundled bitmap as zlib-compressed RGBA; SVGs are rendered at twice their displayed size.
const PackedImage = struct {
    name: []const u8,
    packed_rgba: []const u8,
    width: u32,
    height: u32,
    /// Baked into the pixels on unpacking, since knots doesn't round images.
    corner_radius: u32 = 0,
    /// Owned; freed in deinit.
    pixels: ?[]u8 = null,

    /// Null if it can't be unpacked, which the window survives without.
    fn image(self: *PackedImage, allocator: std.mem.Allocator, key: ui.Key, image_style: *const ui.Style) ?Image {
        const pixels = self.unpack(allocator) orelse return null;
        return .{
            .key = key,
            .source = .{
                .pixels = .{
                    .data = pixels,
                    .width = self.width,
                    .height = self.height,
                    // Plain rgba8 is read as linear, which washes out a browser-rendered image.
                    .format = .rgba8_srgb,
                    .upload_policy = .versioned,
                    .version = 1,
                },
            },
            .style = image_style,
        };
    }

    fn unpack(self: *PackedImage, allocator: std.mem.Allocator) ?[]const u8 {
        if (self.pixels) |pixels| return pixels;
        const pixels = allocator.alloc(u8, self.width * self.height * 4) catch |err| {
            slog.warn("Failed to unpack the '{s}' image: {}", .{ self.name, err });
            return null;
        };
        var input: std.Io.Reader = .fixed(self.packed_rgba);
        var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
        var output: std.Io.Writer = .fixed(pixels);
        _ = decompress.reader.streamRemaining(&output) catch |err| {
            slog.warn("Failed to unpack the '{s}' image: {}", .{ self.name, err });
            allocator.free(pixels);
            return null;
        };
        rgba.roundCorners(pixels, self.width, self.height, self.corner_radius);
        self.pixels = pixels;
        return pixels;
    }

    fn deinit(self: *PackedImage, allocator: std.mem.Allocator) void {
        if (self.pixels) |pixels| allocator.free(pixels);
        self.pixels = null;
    }
};

pub const Bundled = enum {
    wordmark,
    /// The thumbnail preview's backdrop, from assets/layout_preview.jpg.
    layout_preview,
    app_mark,
    /// Stands in for a character's portrait until it loads, from assets/default_portrait.jpg.
    default_portrait,
};

/// Each window's unpacked copies, freed as it closes.
pub const Images = struct {
    allocator: std.mem.Allocator,
    packed_images: std.EnumArray(Bundled, PackedImage) = .init(.{
        .wordmark = .{
            .name = "wordmark",
            .packed_rgba = @embedFile("../../assets/wordmark_539x192.rgba.zlib"),
            .width = 539,
            .height = 192,
        },
        .layout_preview = .{
            .name = "layout preview",
            .packed_rgba = @embedFile("../../assets/layout_preview_540x304.rgba.zlib"),
            .width = 540,
            .height = 304,
        },
        .app_mark = .{ .name = "app mark", .packed_rgba = @embedFile("../../assets/icon_36x36.rgba.zlib"), .width = 36, .height = 36 },
        .default_portrait = .{
            .name = "default portrait",
            .packed_rgba = @embedFile("../../assets/default_portrait_32x32.rgba.zlib"),
            .width = 32,
            .height = 32,
            .corner_radius = portraits.CORNER_RADIUS,
        },
    }),

    pub fn init(allocator: std.mem.Allocator) Images {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Images) void {
        for (&self.packed_images.values) |*packed_image| packed_image.deinit(self.allocator);
    }

    /// Null if it can't be unpacked, which the window survives without.
    pub fn image(self: *Images, which: Bundled, key: ui.Key, image_style: *const ui.Style) ?Image {
        return self.packed_images.getPtr(which).image(self.allocator, key, image_style);
    }

    /// In pixels.
    pub fn size(self: *const Images, which: Bundled) [2]u32 {
        const packed_image = self.packed_images.getPtrConst(which);
        return .{ packed_image.width, packed_image.height };
    }
};
