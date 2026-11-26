//! A font as GDI realized it, as plain data the render recorders keep; no I/O.
const std = @import("std");

/// Which may be a substitute for the font asked for.
pub const SelectedFont = struct {
    face_buffer: [FACE_SIZE]u8 = undefined,
    face_length: u8 = 0,
    /// A Win32 FW_ value.
    weight: i32 = 0,
    is_italic: bool = false,
    /// Leaving out internal leading, as a font setting's size means.
    height_px: i32 = 0,

    /// Win32's LF_FACESIZE, NUL included; a longer `face` is cut short.
    pub const FACE_SIZE = 32;

    pub fn setFace(self: *SelectedFont, face_name: []const u8) void {
        const length = @min(face_name.len, FACE_SIZE);
        @memcpy(self.face_buffer[0..length], face_name[0..length]);
        self.face_length = @intCast(length);
    }

    pub fn face(self: *const SelectedFont) []const u8 {
        return self.face_buffer[0..self.face_length];
    }
};

test "a face longer than the buffer is cut short" {
    var font: SelectedFont = .{};
    const long: [SelectedFont.FACE_SIZE + 5]u8 = @splat('x');
    font.setFace(&long);
    try std.testing.expectEqual(SelectedFont.FACE_SIZE, font.face().len);
    font.setFace("Courier New");
    try std.testing.expectEqualStrings("Courier New", font.face());
}
