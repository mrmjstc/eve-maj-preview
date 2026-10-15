//! Runs a forwarded protocol command in the running instance, through the same code as its hotkey or tray item.
const win32 = @import("../platform/win32.zig");
const app_mod = @import("../app.zig");
const activation = @import("../control/activation.zig");
const knots_host = @import("../dialog/knots/host.zig");
const ipc = @import("ipc.zig");
const url = @import("url.zig");
const log = @import("../log.zig");

const App = app_mod.App;
const slog = log.Scoped("protocol");

/// For the main window's WM_COPYDATA.
pub fn handleCopyData(app: *App, copy_data: *const win32.COPYDATASTRUCT) void {
    const text = ipc.receivedUrl(copy_data) orelse {
        slog.warn("Failed to read a forwarded command: unknown message kind {}", .{copy_data.dwData});
        return;
    };
    slog.info("Protocol command received: '{s}'", .{text});
    // parse logs its own failures.
    const command = url.parse(app.allocator, text) catch return;
    defer command.deinit(app.allocator);
    run(app, command);
}

fn run(app: *App, command: url.Command) void {
    switch (command) {
        .switch_character => |character_name| {
            const hwnd = app.scout.getHwndByName(character_name) orelse {
                slog.warn("Failed to switch to character '{s}': not running", .{character_name});
                return;
            };
            activation.activate(app, hwnd);
        },
        .profile => |profile_name| app.switchProfile(profile_name),
        .hotkey => |action| {
            const manager = app.hotkey_manager orelse {
                slog.warn("Failed to run '{s}': the hotkey manager isn't ready", .{@tagName(action)});
                return;
            };
            manager.runGlobalAction(action);
        },
        .group => |group| {
            const manager = app.hotkey_manager orelse {
                slog.warn("Failed to run group '{s}' on '{s}': the hotkey manager isn't ready", .{ @tagName(group.action), group.name });
                return;
            };
            manager.runGroupAction(group.action, group.name);
        },
        .open_config => knots_host.open(),
    }
}
