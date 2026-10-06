const std = @import("std");
const Element = @import("Element.zig");

elements: std.ArrayList(Element) = .empty,

const ElementPool = @This();

pub fn deinit(self: *ElementPool, allocator: std.mem.Allocator) void {
    self.elements.deinit(allocator);
}

pub fn reset(self: *ElementPool) void {
    self.elements.clearRetainingCapacity();
}

pub fn append(self: *ElementPool, allocator: std.mem.Allocator, id: Element.Id, el: Element) !Element.Slot {
    const slot: Element.Slot = @intCast(self.elements.items.len);
    var element = el;
    element.id = id;
    try self.elements.append(allocator, element);
    return slot;
}

pub fn get(self: *ElementPool, slot: Element.Slot) *Element {
    return &self.elements.items[slot];
}
