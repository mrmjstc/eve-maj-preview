const win32 = @import("win32.zig");
const log = @import("../log.zig");
const slog = log.scoped("fonts");

const BundledFont = struct { name: []const u8, data: []const u8 };

// SemiBold is a separate face because GDI won't embolden Cascadia Code's variable-font weights (see dialog/tools/region_select.zig).
const BUNDLED_FONTS = [_]BundledFont{
    .{ .name = "Cascadia Code", .data = @embedFile("../assets/fonts/CascadiaCode-Regular.ttf") },
    .{ .name = "Cascadia Code SemiBold", .data = @embedFile("../assets/fonts/CascadiaCode-SemiBold.ttf") },
    .{ .name = "Cascadia Mono", .data = @embedFile("../assets/fonts/CascadiaMono-Regular.ttf") },
};

/// Registers the bundled fonts for this process only, since not every Windows install ships Cascadia; fonts are released when the process exits.
pub fn loadBundled() void {
    for (BUNDLED_FONTS) |font| {
        var face_count: win32.DWORD = 0;
        if (win32.AddFontMemResourceEx(font.data.ptr, @intCast(font.data.len), null, &face_count) == null) {
            slog.warn("Failed to load bundled font {s}", .{font.name});
        }
    }
}

pub const FontWeight = enum {
    Regular,
    Bold,
    Italic,
    BoldItalic,

    /// Convert to Windows font weight value (for CreateFontA weight parameter)
    pub fn toWin32Weight(self: FontWeight) i32 {
        // 400/700 are the raw FW_NORMAL/FW_BOLD values
        return switch (self) {
            .Regular, .Italic => 400,
            .Bold, .BoldItalic => 700,
        };
    }

    /// Check if font should be italicized (for CreateFontA italic parameter)
    pub fn isItalic(self: FontWeight) bool {
        return self == .Italic or self == .BoldItalic;
    }
};
