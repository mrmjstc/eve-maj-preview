//! The text style rows every overlay repeats: position, offsets, colours and font; main thread only.
const ui = @import("ui");
const bind = @import("../bind.zig");

/// The names an overlay's style fields go by in its settings struct.
pub const Fields = struct {
    position: []const u8,
    offset_x: []const u8,
    offset_y: []const u8,
    /// Null where the overlay has no text colour of its own.
    color: ?[]const u8,
    font_size: []const u8,
    font_name: []const u8,
    font_weight: []const u8,
    bg_color: []const u8,

    /// The activity overlays' names: `incoming_` for Combat's incoming text, none for Mining's.
    pub fn snakeCase(comptime prefix: []const u8, comptime has_color: bool) Fields {
        return .{
            .position = prefix ++ "position",
            .offset_x = prefix ++ "offset_x",
            .offset_y = prefix ++ "offset_y",
            .color = if (has_color) prefix ++ "color" else null,
            .font_size = prefix ++ "font_size",
            .font_name = prefix ++ "font_name",
            .font_weight = prefix ++ "font_weight",
            .bg_color = prefix ++ "bg_color",
        };
    }

    /// The thumbnail's own overlays' names, e.g. `characterName` gives `characterNameFontSize`.
    pub fn camelCase(comptime prefix: []const u8) Fields {
        return .{
            .position = prefix ++ "Position",
            .offset_x = prefix ++ "OffsetX",
            .offset_y = prefix ++ "OffsetY",
            .color = prefix ++ "Color",
            .font_size = prefix ++ "FontSize",
            .font_name = prefix ++ "FontName",
            .font_weight = prefix ++ "FontWeight",
            .bg_color = prefix ++ "BgColor",
        };
    }
};

pub fn show(context: *ui.Frame, ref: anytype, comptime fields: Fields) !void {
    try bind.choice(context, ref, fields.position, "Position");
    try bind.slider(context, ref, fields.offset_x, "X Offset (px)", .{});
    try bind.slider(context, ref, fields.offset_y, "Y Offset (px)", .{});
    if (comptime fields.color) |color| try bind.color(context, ref, color, "Text Color");
    try bind.number(context, ref, fields.font_size, "Font Size (px)", .{});
    try bind.fontName(context, ref, fields.font_name, "Font Name");
    try bind.choice(context, ref, fields.font_weight, "Font Weight");
    try bind.colorAndOpacity(context, ref, fields.bg_color, "Text Background Color", "Background Opacity");
}
