//! Positions saved by a DPI-unaware process (old profiles, EVE-O, EVE-X and EVE-APM imports), scaled for the monitor they're on.
const win32 = @import("../platform/win32.zig");
const characters = @import("characters.zig");

const Position = characters.Position;

pub fn scalePosition(position: Position) Position {
    const scale = win32.dpiToScale(win32.dpiForPoint(.{ .x = position.x, .y = position.y }));
    return .{ .x = win32.scalePixels(position.x, scale), .y = win32.scalePixels(position.y, scale) };
}
