//! Minimizing and restoring EVE clients, with Windows' minimize animation off when the profile asks for No Animation.
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");

const slog = log.Scoped("animation");

/// Runs ShowWindowAsync(hwnd, show_command); with No Animation, turns the Windows setting off around the call and puts the user's value back.
pub fn showClient(config: *const config_mod.Config, hwnd: win32.HWND, show_command: c_int) void {
    switch (config.interaction.animationStyle) {
        .OriginalAnimation => _ = win32.ShowWindowAsync(hwnd, show_command),
        .NoAnimation => {
            const restore_to = turnOffAnimation();
            _ = win32.ShowWindowAsync(hwnd, show_command);
            if (restore_to) |user_setting| restoreAnimation(user_setting);
        },
    }
}

/// The user's setting to put back afterwards, or null if animation was already off or couldn't be turned off.
fn turnOffAnimation() ?i32 {
    const user_setting = getMinimizeAnimation() orelse {
        slog.warn("Failed to read the Windows minimize animation setting", .{});
        return null;
    };
    if (user_setting == 0) return null;
    if (!setMinimizeAnimation(0)) {
        slog.warn("Failed to turn off the Windows minimize animation", .{});
        return null;
    }
    return user_setting;
}

fn restoreAnimation(user_setting: i32) void {
    if (!setMinimizeAnimation(user_setting)) slog.err("Failed to restore the Windows minimize animation setting to {}", .{user_setting});
}

fn getMinimizeAnimation() ?i32 {
    var animation_info = win32.ANIMATIONINFO{ .cbSize = @sizeOf(win32.ANIMATIONINFO), .iMinAnimate = 0 };
    if (!win32.toBool(win32.SystemParametersInfoA(win32.SPI_GETANIMATION, @sizeOf(win32.ANIMATIONINFO), &animation_info, 0))) return null;
    return animation_info.iMinAnimate;
}

fn setMinimizeAnimation(value: i32) bool {
    var animation_info = win32.ANIMATIONINFO{ .cbSize = @sizeOf(win32.ANIMATIONINFO), .iMinAnimate = value };
    return win32.toBool(win32.SystemParametersInfoA(win32.SPI_SETANIMATION, @sizeOf(win32.ANIMATIONINFO), &animation_info, 0));
}
