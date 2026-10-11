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

    pub fn matchesExecutable(self: *const WindowFilterConfig, executable_path: []const u8) bool {
        if (!self.enabled) return false;
        if (self.executable_names.items.len == 0) return self.class_names.items.len != 0;
        for (self.executable_names.items) |filter_executable| {
            if (std.ascii.endsWithIgnoreCase(executable_path, filter_executable)) return true;
        }
        return false;
    }
};

const testing = std.testing;

test "an executable filter matches the end of the path, ignoring case" {
    var filter: WindowFilterConfig = .{};
    defer filter.executable_names.deinit(testing.allocator);
    try filter.executable_names.append(testing.allocator, "exefile.exe");
    try testing.expect(filter.matchesExecutable("C:\\EVE\\bin64\\ExeFile.exe"));
    try testing.expect(!filter.matchesExecutable("C:\\EVE\\launcher.exe"));
    try testing.expect(!filter.matchesExecutable("file.exe"));
}

test "an empty class list defers to the executable check, and no criteria at all match nothing" {
    var filter: WindowFilterConfig = .{};
    defer filter.executable_names.deinit(testing.allocator);
    try testing.expect(!filter.matchesClass("trinityWindow"));
    try testing.expect(!filter.matchesExecutable("exefile.exe"));
    try filter.executable_names.append(testing.allocator, "exefile.exe");
    try testing.expect(filter.matchesClass("anyWindow"));
}

test "a disabled filter matches nothing" {
    var filter: WindowFilterConfig = .{ .enabled = false };
    defer filter.executable_names.deinit(testing.allocator);
    try filter.executable_names.append(testing.allocator, "exefile.exe");
    try testing.expect(!filter.matchesExecutable("exefile.exe"));
    try testing.expect(!filter.matchesClass("trinityWindow"));
}
