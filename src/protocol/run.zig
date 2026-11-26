//! Runs a forwarded protocol command in the running instance, through the same code as its hotkey or tray item.
const win32 = @import("../platform/win32.zig");
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
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
    if (command.closeAction()) |action| {
        if (!isAllowed(&app.global_settings.protocolLinks, action)) {
            slog.warn("Failed to run protocol command '{s}': links aren't allowed to {s}, which General > Protocol Links can change", .{ text, @tagName(action) });
            return;
        }
    }
    run(app, command);
}

fn isAllowed(links: *const config.ProtocolLinksConfig, action: url.CloseAction) bool {
    return switch (action) {
        .close_all => links.allowCloseAll,
        .close_active => links.allowCloseActive,
        .close_group => links.allowCloseGroup,
        .exit_app => links.allowExitApp,
    };
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
        .hotkey => |action| app.runHotkeyOutcome(app.commands().runGlobal(action, app.rebuilt.thumbnail_set)),
        .group => |group| app.runHotkeyOutcome(app.commands().runGroup(group.action, group.name, app.rebuilt.thumbnail_set)),
        .open_config => knots_host.open(),
    }
}
