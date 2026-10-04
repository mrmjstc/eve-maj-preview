//! Root of `zig build test`: the modules with unit tests, which can run without the app or Windows UI.
test {
    _ = @import("activity/tracker.zig");
    _ = @import("chatlog/lines.zig");
    _ = @import("chatlog/utf16.zig");
    _ = @import("config/import/values.zig");
    _ = @import("config/key_list.zig");
    _ = @import("config/profiles.zig");
    _ = @import("config/ranges.zig");
    _ = @import("config/system_colors.zig");
    _ = @import("config/wire.zig");
    _ = @import("hotkeys/bindings.zig");
    _ = @import("hotkeys/exclusions.zig");
    _ = @import("layout/placement.zig");
    _ = @import("notifications/gamelog_events.zig");
    _ = @import("notifications/notification.zig");
    _ = @import("notifications/template.zig");
    _ = @import("platform/virtual_keys.zig");
    _ = @import("protocol.zig");
    _ = @import("util/color.zig");
    _ = @import("util/format.zig");
    _ = @import("util/strings.zig");
}
