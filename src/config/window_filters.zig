//! Which windows count as game clients.
const std = @import("std");
const wire = @import("wire.zig");

pub const WindowFilterConfig = struct {
    name: []const u8 = "",
    class_names: std.ArrayList([]const u8) = .empty,
    executable_names: std.ArrayList([]const u8) = .empty,
    enabled: bool = true,

    pub const Wire = wire.Wire(WindowFilterConfig);

    /// Loaded when a profile has no windowFilters key (see Config.wire_defaults).
    pub const DEFAULT: Wire = .{
        .name = "EVE Online",
        .class_names = &.{"trinityWindow"},
        .executable_names = &.{"exefile.exe"},
    };

    pub fn matchesClass(self: *const WindowFilterConfig, class_name: []const u8) bool {
        if (!self.enabled) return false;
        // Empty defers to the executable check; both empty means no criteria, so match nothing.
        if (self.class_names.items.len == 0) return self.executable_names.items.len != 0;
        for (self.class_names.items) |filter_class| {
            if (std.mem.eql(u8, filter_class, class_name)) {
                return true;
            }
        }
        return false;
    }

    pub fn matchesExecutable(self: *const WindowFilterConfig, exe_path: []const u8) bool {
        if (!self.enabled) return false;
        if (self.executable_names.items.len == 0) return self.class_names.items.len != 0;
        for (self.executable_names.items) |filter_exe| {
            if (exe_path.len >= filter_exe.len) {
                const path_end = exe_path[exe_path.len - filter_exe.len ..];
                if (std.ascii.eqlIgnoreCase(path_end, filter_exe)) {
                    return true;
                }
            }
        }
        return false;
    }
};
