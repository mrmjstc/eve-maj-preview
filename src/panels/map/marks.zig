//! The logged-in clients the Map Panel marks, and who's in which system and region; no I/O.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const universe = @import("../../map/universe.zig");

const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;

/// More clients than this go unmarked.
pub const MAX_MARKS = 64;

/// A logged-in client on the map.
pub const Mark = struct {
    system: SystemIndex,
    source_hwnd: win32.HWND,
    /// Borrows from the thumbnail, so it's only good until the next tick; rebuilt each render.
    character_name: []const u8,
    color: u32,
    is_active: bool,
};

pub const Marks = struct {
    items: [MAX_MARKS]Mark = undefined,
    count: usize = 0,

    pub fn slice(self: *const Marks) []const Mark {
        return self.items[0..self.count];
    }

    pub fn clear(self: *Marks) void {
        self.count = 0;
    }

    /// False once full, dropping `mark`.
    pub fn add(self: *Marks, mark: Mark) bool {
        if (self.count == MAX_MARKS) return false;
        self.items[self.count] = mark;
        self.count += 1;
        return true;
    }

    pub fn active(self: *const Marks) ?Mark {
        for (self.slice()) |mark| {
            if (mark.is_active) return mark;
        }
        return null;
    }

    pub fn countAt(self: *const Marks, system: SystemIndex) usize {
        var count: usize = 0;
        for (self.slice()) |mark| {
            if (mark.system == system) count += 1;
        }
        return count;
    }

    pub fn countIn(self: *const Marks, region: RegionIndex) usize {
        var count: usize = 0;
        for (self.slice()) |mark| {
            if (universe.systemInfo(mark.system).region == region) count += 1;
        }
        return count;
    }

    /// Whether the mark at `index` is the one its system's tag names: the active client, else the first.
    pub fn leadsSystem(self: *const Marks, index: usize) bool {
        const mark = self.items[index];
        for (self.slice(), 0..) |other, other_index| {
            if (other.system != mark.system or other_index == index) continue;
            if (other.is_active or (other_index < index and !mark.is_active)) return false;
        }
        return true;
    }

    /// The names of those in `system`, into `buffer`.
    pub fn namesAt(self: *const Marks, system: SystemIndex, buffer: *[MAX_MARKS][]const u8) []const []const u8 {
        var name_count: usize = 0;
        for (self.slice()) |mark| {
            if (mark.system != system) continue;
            buffer[name_count] = mark.character_name;
            name_count += 1;
        }
        return buffer[0..name_count];
    }

    pub fn hash(self: *const Marks, hasher: *std.hash.Wyhash) void {
        for (self.slice()) |mark| {
            hasher.update(std.mem.asBytes(&mark.system));
            hasher.update(std.mem.asBytes(&mark.color));
            hasher.update(std.mem.asBytes(&mark.is_active));
            hasher.update(mark.character_name);
        }
    }
};

const testing = std.testing;

fn testMark(system_name: []const u8, character_name: []const u8, is_active: bool) Mark {
    return .{ .system = universe.findSystem(system_name).?, .source_hwnd = @ptrFromInt(0x1000), .character_name = character_name, .color = 0, .is_active = is_active };
}

test "a full list drops the marks past it" {
    var marks: Marks = .{};
    for (0..MAX_MARKS) |_| try testing.expect(marks.add(testMark("Jita", "Alpha", false)));
    try testing.expect(!marks.add(testMark("Jita", "Beta", false)));
    try testing.expectEqual(MAX_MARKS, marks.slice().len);
}

test "the first client in a system names its tag while none there is active" {
    var marks: Marks = .{};
    _ = marks.add(testMark("Jita", "Alpha", false));
    _ = marks.add(testMark("Jita", "Beta", false));
    _ = marks.add(testMark("Perimeter", "Gamma", false));
    try testing.expect(marks.leadsSystem(0));
    try testing.expect(!marks.leadsSystem(1));
    try testing.expect(marks.leadsSystem(2));
}

test "the active client names its system's tag ahead of one listed before it" {
    var marks: Marks = .{};
    _ = marks.add(testMark("Jita", "Alpha", false));
    _ = marks.add(testMark("Jita", "Beta", true));
    try testing.expect(!marks.leadsSystem(0));
    try testing.expect(marks.leadsSystem(1));
    try testing.expectEqualStrings("Beta", marks.active().?.character_name);
}

test "clients are counted and named by the system they're in" {
    var marks: Marks = .{};
    _ = marks.add(testMark("Jita", "Alpha", false));
    _ = marks.add(testMark("Perimeter", "Beta", false));
    _ = marks.add(testMark("Jita", "Gamma", false));
    try testing.expectEqual(@as(usize, 2), marks.countAt(universe.findSystem("Jita").?));
    try testing.expectEqual(@as(usize, 1), marks.countAt(universe.findSystem("Perimeter").?));
    var buffer: [MAX_MARKS][]const u8 = undefined;
    const names = marks.namesAt(universe.findSystem("Jita").?, &buffer);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("Alpha", names[0]);
    try testing.expectEqualStrings("Gamma", names[1]);
}

test "clients in the same region are counted together" {
    var marks: Marks = .{};
    _ = marks.add(testMark("Jita", "Alpha", false));
    _ = marks.add(testMark("Perimeter", "Beta", false));
    _ = marks.add(testMark("Amarr", "Gamma", false));
    try testing.expectEqual(@as(usize, 2), marks.countIn(universe.systemInfo(universe.findSystem("Jita").?).region));
    try testing.expectEqual(@as(usize, 1), marks.countIn(universe.systemInfo(universe.findSystem("Amarr").?).region));
}
