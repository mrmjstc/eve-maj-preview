//! Characters excluded from cycling, kept by name until the app exits.
const std = @import("std");
const strings = @import("../util/strings.zig");

/// Not saved, and independent of the hotkey manager and profile, so a Save or profile switch keeps them.
pub const Exclusions = struct {
    allocator: std.mem.Allocator,
    /// In the order they were excluded, which Next/Previous Excluded follows; owned.
    names: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Exclusions {
        return .{ .allocator = allocator };
    }

    pub fn setGlobalInstance(self: *Exclusions) void {
        g_exclusions_ptr = self;
    }

    pub fn deinit(self: *Exclusions) void {
        if (g_exclusions_ptr == self) g_exclusions_ptr = null;
        for (self.names.items) |name| self.allocator.free(name);
        self.names.deinit(self.allocator);
    }

    pub fn contains(self: *const Exclusions, character_name: []const u8) bool {
        return strings.indexOfString(self.names.items, character_name) != null;
    }

    /// Returns whether the character is now excluded.
    pub fn toggle(self: *Exclusions, character_name: []const u8) !bool {
        if (strings.indexOfString(self.names.items, character_name)) |index| {
            self.allocator.free(self.names.orderedRemove(index));
            return false;
        }
        const owned = try self.allocator.dupe(u8, character_name);
        errdefer self.allocator.free(owned);
        try self.names.append(self.allocator, owned);
        return true;
    }
};

/// Set by main.zig for code that can't be handed it directly (Painter, travel).
pub var g_exclusions_ptr: ?*Exclusions = null;

/// False before main.zig sets the instance.
pub fn isExcluded(character_name: []const u8) bool {
    const exclusions = g_exclusions_ptr orelse return false;
    return exclusions.contains(character_name);
}

const testing = std.testing;

test "toggle excludes a character, then includes them again" {
    var exclusions = Exclusions.init(testing.allocator);
    defer exclusions.deinit();

    try testing.expect(try exclusions.toggle("Pilot A"));
    try testing.expect(exclusions.contains("Pilot A"));
    try testing.expect(!try exclusions.toggle("Pilot A"));
    try testing.expect(!exclusions.contains("Pilot A"));
}

test "names keep the order characters were excluded in" {
    var exclusions = Exclusions.init(testing.allocator);
    defer exclusions.deinit();

    _ = try exclusions.toggle("Pilot B");
    _ = try exclusions.toggle("Pilot A");
    _ = try exclusions.toggle("Pilot C");
    _ = try exclusions.toggle("Pilot A");

    try testing.expectEqual(2, exclusions.names.items.len);
    try testing.expectEqualStrings("Pilot B", exclusions.names.items[0]);
    try testing.expectEqualStrings("Pilot C", exclusions.names.items[1]);
}
