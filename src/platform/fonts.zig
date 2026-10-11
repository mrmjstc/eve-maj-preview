//! The bundled fonts and the weight/style choice every font setting uses.
const win32 = @import("win32.zig");
const log = @import("../log.zig");

const slog = log.Scoped("fonts");

/// The config dialog's face, which GDI-drawn parts of the dialog, like the region overlay, match.
pub const UI_FACE = "Geist";
/// The dialog's semibold face, e.g. on its primary buttons.
pub const UI_SEMIBOLD_FACE = "Geist SemiBold";
pub const GEIST_REGULAR_DATA = @embedFile("../assets/fonts/Geist-Regular.ttf");
pub const GEIST_SEMIBOLD_DATA = @embedFile("../assets/fonts/Geist-SemiBold.ttf");

// The SemiBold faces are separate because GDI won't embolden a variable font's weights.
const BUNDLED_FONTS = [_]BundledFont{
    .{ .name = "Cascadia Code", .data = @embedFile("../assets/fonts/CascadiaCode-Regular.ttf") },
    .{ .name = "Cascadia Code SemiBold", .data = @embedFile("../assets/fonts/CascadiaCode-SemiBold.ttf") },
    .{ .name = "Cascadia Mono", .data = @embedFile("../assets/fonts/CascadiaMono-Regular.ttf") },
    .{ .name = UI_FACE, .data = GEIST_REGULAR_DATA },
    .{ .name = UI_SEMIBOLD_FACE, .data = GEIST_SEMIBOLD_DATA },
};

const BundledFont = struct { name: []const u8, data: []const u8 };

/// Tag names are saved in profiles.
pub const FontWeight = enum {
    Regular,
    Bold,
    Italic,
    BoldItalic,

    pub fn toWin32Weight(self: FontWeight) i32 {
        return switch (self) {
            .Regular, .Italic => win32.FW_NORMAL,
            .Bold, .BoldItalic => win32.FW_BOLD,
        };
    }

    pub fn isItalic(self: FontWeight) bool {
        return self == .Italic or self == .BoldItalic;
    }
};

/// Registers the bundled fonts for this process only, since not every Windows install ships them; fonts are released when the process exits.
pub fn loadBundled() void {
    for (BUNDLED_FONTS) |font| {
        var face_count: win32.DWORD = 0;
        if (win32.AddFontMemResourceEx(font.data.ptr, @intCast(font.data.len), null, &face_count) == null) {
            slog.warn("Failed to load bundled font '{s}'", .{font.name});
        }
    }
}
