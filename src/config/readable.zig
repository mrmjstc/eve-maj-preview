//! Drops the settings in a parsed settings file that don't fit their type, so each falls back to its default on its own.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("config");

/// How every settings file is read: keys this version doesn't know are ignored.
pub const PARSE_OPTIONS: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// One pass of dropUnreadable, tracking the dotted path of the setting being checked.
const Check = struct {
    arena: std.mem.Allocator,
    skipped: ?*std.ArrayList([]const u8),
    /// Segments past the buffer are cut off.
    path_buf: [256]u8 = undefined,
    path_len: usize = 0,

    /// Returns the length to restore once done with the segment.
    fn push(self: *Check, comptime fmt: []const u8, args: anytype) usize {
        const start = self.path_len;
        const separator: []const u8 = if (start == 0) "" else ".";
        var writer: std.Io.Writer = .fixed(self.path_buf[start..]);
        writer.print("{s}" ++ fmt, .{separator} ++ args) catch {};
        self.path_len = start + writer.end;
        return start;
    }

    fn drop(self: *Check, comptime outcome: []const u8) void {
        const path = self.path_buf[0..self.path_len];
        slog.warn("Failed to read setting '{s}', " ++ outcome, .{path});
        const skipped = self.skipped orelse return;
        const owned = self.arena.dupe(u8, path) catch |err| {
            slog.err("Failed to note skipped setting '{s}': {}", .{ path, err });
            return;
        };
        skipped.append(self.arena, owned) catch |err| slog.err("Failed to note skipped setting '{s}': {}", .{ path, err });
    }

    /// Walks into lists, `MapValue`/`isReadableItem` types and structs whose fields all have defaults; anything else is checked whole.
    fn fits(self: *Check, comptime W: type, value: *std.json.Value) bool {
        @setEvalBranchQuota(100_000);
        switch (@typeInfo(W)) {
            .optional => |info| return value.* == .null or self.fits(info.child, value),
            .pointer => |info| if (info.size == .slice and info.child != u8) {
                if (value.* != .array) return false;
                var i: usize = 0;
                while (i < value.array.items.len) {
                    const restore = self.push("{d}", .{i});
                    defer self.path_len = restore;
                    if (self.fits(info.child, &value.array.items[i])) {
                        i += 1;
                    } else {
                        self.drop("dropping that item");
                        _ = value.array.orderedRemove(i);
                    }
                }
            },
            .@"struct" => |info| if (@hasDecl(W, "MapValue")) {
                if (value.* != .object) return false;
                var i: usize = 0;
                while (i < value.object.count()) {
                    const restore = self.push("{s}", .{value.object.keys()[i]});
                    defer self.path_len = restore;
                    if (self.fits(W.MapValue, &value.object.values()[i])) {
                        i += 1;
                    } else {
                        self.drop("using its defaults");
                        value.object.orderedRemoveAt(i);
                    }
                }
            } else if (@hasDecl(W, "isReadableItem")) {
                if (value.* != .array) return W.isReadableItem(value.*);
                var i: usize = 0;
                while (i < value.array.items.len) {
                    const restore = self.push("{d}", .{i});
                    defer self.path_len = restore;
                    if (W.isReadableItem(value.array.items[i])) {
                        i += 1;
                    } else {
                        self.drop("dropping that item");
                        _ = value.array.orderedRemove(i);
                    }
                }
            } else if (!@hasDecl(W, "jsonParseFromValue") and comptime everyFieldHasDefault(info.field_attrs)) {
                if (value.* != .object) return false;
                inline for (info.field_names, info.field_types) |name, F| {
                    if (value.object.getPtr(name)) |field_value| {
                        const restore = self.push("{s}", .{name});
                        defer self.path_len = restore;
                        if (!self.fits(F, field_value)) {
                            self.drop("using its default");
                            _ = value.object.orderedRemove(name);
                        }
                    }
                }
            },
            else => {},
        }
        _ = std.json.parseFromValueLeaky(W, self.arena, value.*, PARSE_OPTIONS) catch return false;
        return true;
    }
};

/// Drops what in `value` doesn't fit `T` and returns whether the rest parses; `skipped` gets each dropped path, allocated from `arena`.
pub fn dropUnreadable(comptime T: type, arena: std.mem.Allocator, value: *std.json.Value, skipped: ?*std.ArrayList([]const u8)) bool {
    var check: Check = .{ .arena = arena, .skipped = skipped };
    return check.fits(T, value);
}

fn everyFieldHasDefault(field_attrs: []const std.lang.Type.Struct.FieldAttributes) bool {
    for (field_attrs) |attrs| {
        if (attrs.default_value_ptr == null) return false;
    }
    return true;
}

const testing = std.testing;

const TestSettings = struct {
    mode: enum { a, b } = .a,
    names: []const []const u8 = &.{},
    inner: struct { x: i32 = 1, y: i32 = 2 } = .{},
    named: Named = .{},
    keys: Keys = .{},
    point: ?struct { x: i32, y: i32 } = null,

    const Keys = struct {
        count: usize = 0,

        pub fn isReadableItem(item: std.json.Value) bool {
            return item == .string and item.string.len == 1;
        }

        pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Keys {
            return .{ .count = if (source == .array) source.array.items.len else 1 };
        }
    };

    const Named = struct {
        map: std.json.Value = .null,

        pub const MapValue = struct { on: bool = false };

        pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Named {
            return .{ .map = source };
        }
    };
};

test "dropUnreadable reports the path of each setting it drops, keeping the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json =
        \\{"mode": "c", "names": ["a", 5], "inner": {"x": "no", "y": 3}, "named": {"first": {"on": true}, "second": {"on": 7}}}
    ;
    var tree = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    var skipped: std.ArrayList([]const u8) = .empty;
    try testing.expect(dropUnreadable(TestSettings, arena.allocator(), &tree, &skipped));

    try testing.expectEqual(@as(usize, 4), skipped.items.len);
    try testing.expectEqualStrings("mode", skipped.items[0]);
    try testing.expectEqualStrings("names.1", skipped.items[1]);
    try testing.expectEqualStrings("inner.x", skipped.items[2]);
    try testing.expectEqualStrings("named.second.on", skipped.items[3]);
    try testing.expectEqual(@as(usize, 1), tree.object.get("names").?.array.items.len);
    try testing.expect(tree.object.get("inner").?.object.get("y") != null);
    const named = tree.object.get("named").?.object;
    try testing.expect(named.get("first").?.object.get("on") != null);
    try testing.expect(named.get("second").?.object.get("on") == null);
}

test "dropUnreadable checks items one by one, and a section without defaults whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tree = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"keys\": [\"a\", \"bad\", \"b\"], \"point\": {\"x\": \"no\", \"y\": 3}}", .{});
    var skipped: std.ArrayList([]const u8) = .empty;
    try testing.expect(dropUnreadable(TestSettings, arena.allocator(), &tree, &skipped));

    try testing.expectEqual(@as(usize, 2), skipped.items.len);
    try testing.expectEqualStrings("keys.1", skipped.items[0]);
    try testing.expectEqualStrings("point", skipped.items[1]);
    try testing.expectEqual(@as(usize, 2), tree.object.get("keys").?.array.items.len);
    try testing.expect(tree.object.get("point") == null);
}

test "dropUnreadable fails when the value isn't an object of settings at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tree = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[1, 2]", .{});
    try testing.expect(!dropUnreadable(TestSettings, arena.allocator(), &tree, null));
}
