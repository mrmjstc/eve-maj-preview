//! Bitmaps bundled with the configuration window, stored zlib-compressed and unpacked on first use; main thread only.
const std = @import("std");
const ui = @import("ui");
const log = @import("../../log.zig");

const Image = ui.component.Image;
const slog = log.scoped("dialog_knots");

/// An SVG asset rendered at twice its displayed size, as zlib-compressed RGBA.
pub const PackedImage = struct {
    name: []const u8,
    packed_rgba: []const u8,
    width: u32,
    height: u32,
    /// Owned; freed in deinit.
    pixels: ?[]u8 = null,

    /// Null if it can't be unpacked, which the window survives without.
    pub fn image(self: *PackedImage, key: ui.Key, image_style: *const ui.Style) ?Image {
        const pixels = self.unpack() orelse return null;
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

    fn unpack(self: *PackedImage) ?[]const u8 {
        if (self.pixels) |pixels| return pixels;
        const pixels = g_allocator.alloc(u8, self.width * self.height * 4) catch |err| {
            slog.warn("Failed to unpack the '{s}' image: {}", .{ self.name, err });
            return null;
        };
        var input: std.Io.Reader = .fixed(self.packed_rgba);
        var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
        var output: std.Io.Writer = .fixed(pixels);
        _ = decompress.reader.streamRemaining(&output) catch |err| {
            slog.warn("Failed to unpack the '{s}' image: {}", .{ self.name, err });
            g_allocator.free(pixels);
            return null;
        };
        self.pixels = pixels;
        return pixels;
    }

    fn deinit(self: *PackedImage) void {
        if (self.pixels) |pixels| g_allocator.free(pixels);
        self.pixels = null;
    }
};

var g_allocator: std.mem.Allocator = undefined;

pub var g_wordmark: PackedImage = .{ .name = "wordmark", .packed_rgba = @embedFile("../../assets/wordmark_539x192.rgba.zlib"), .width = 539, .height = 192 };
/// The thumbnail preview's backdrop, from assets/layout_preview.jpg.
pub var g_layout_preview: PackedImage = .{ .name = "layout preview", .packed_rgba = @embedFile("../../assets/layout_preview_540x304.rgba.zlib"), .width = 540, .height = 304 };
pub var g_app_mark: PackedImage = .{ .name = "app mark", .packed_rgba = @embedFile("../../assets/icon_36x36.rgba.zlib"), .width = 36, .height = 36 };

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn deinit() void {
    g_wordmark.deinit();
    g_app_mark.deinit();
    g_layout_preview.deinit();
}
