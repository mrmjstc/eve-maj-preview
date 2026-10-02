//! Minimizing and restoring EVE clients, with Windows' minimize animation off when the profile asks for No Animation.
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");

/// Runs ShowWindowAsync(hwnd, cmd); with No Animation, turns the Windows setting off around the call and puts the user's value back.
pub fn showClient(config: *const config_mod.Config, hwnd: win32.HWND, cmd: c_int) void {
    switch (config.interaction.animationStyle) {
        .OriginalAnimation => _ = win32.ShowWindowAsync(hwnd, cmd),
        .NoAnimation => {
            const user_setting = getMinimizeAnimation() orelse 0;
            if (user_setting != 0) setMinimizeAnimation(0);
            _ = win32.ShowWindowAsync(hwnd, cmd);
            if (user_setting != 0) setMinimizeAnimation(user_setting);
        },
    }
}

fn getMinimizeAnimation() ?i32 {
    var anim_info = win32.ANIMATIONINFO{ .cbSize = @sizeOf(win32.ANIMATIONINFO), .iMinAnimate = 0 };
    if (!win32.toBool(win32.SystemParametersInfoA(win32.SPI_GETANIMATION, @sizeOf(win32.ANIMATIONINFO), &anim_info, 0))) return null;
    return anim_info.iMinAnimate;
}

fn setMinimizeAnimation(value: i32) void {
    var anim_info = win32.ANIMATIONINFO{ .cbSize = @sizeOf(win32.ANIMATIONINFO), .iMinAnimate = value };
    _ = win32.SystemParametersInfoA(win32.SPI_SETANIMATION, @sizeOf(win32.ANIMATIONINFO), &anim_info, 0);
}
