const std = @import("std");
const objc = @import("objc");
const ak = @import("appkit.zig");

const c = ak.c;

pub const text_input_methods = .{
    .{ "insertText:replacementRange:", insertText },
    .{ "doCommandBySelector:", doCommandBySelector },
    .{ "setMarkedText:selectedRange:replacementRange:", setMarkedText },
    .{ "unmarkText", unmarkText },
    .{ "hasMarkedText", hasMarkedText },
    .{ "markedRange", markedRange },
    .{ "selectedRange", selectedRange },
    .{ "validAttributesForMarkedText", validAttributes },
    .{ "attributedSubstringForProposedRange:actualRange:", attributedSubstring },
    .{ "characterIndexForPoint:", characterIndexForPoint },
    .{ "firstRectForCharacterRange:actualRange:", firstRectForCharacterRange },
};

fn insertText(self: c.id, _: c.SEL, string_id: c.id, _: ak.NSRange) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const obj = objc.Object.fromId(string_id);
    const is_attr = obj.msgSend(bool, "isKindOfClass:", .{objc.getClass("NSAttributedString").?});
    const ns_str = if (is_attr) obj.msgSend(objc.Object, "string", .{}) else obj;
    const utf8: [*:0]const u8 = ns_str.msgSend([*:0]const u8, "UTF8String", .{});
    const slice = std.mem.sliceTo(utf8, 0);
    ak.pushUtf8Chars(owner, slice, false);
}

fn doCommandBySelector(_: c.id, _: c.SEL, _: c.SEL) callconv(.c) void {}

fn setMarkedText(_: c.id, _: c.SEL, _: c.id, _: ak.NSRange, _: ak.NSRange) callconv(.c) void {}

fn unmarkText(_: c.id, _: c.SEL) callconv(.c) void {}

fn hasMarkedText(_: c.id, _: c.SEL) callconv(.c) c.BOOL {
    return ak.boolParam(false);
}

fn markedRange(_: c.id, _: c.SEL) callconv(.c) ak.NSRange {
    return .{ .location = std.math.maxInt(c_ulong), .length = 0 };
}

fn selectedRange(_: c.id, _: c.SEL) callconv(.c) ak.NSRange {
    return .{ .location = std.math.maxInt(c_ulong), .length = 0 };
}

fn validAttributes(_: c.id, _: c.SEL) callconv(.c) c.id {
    const NSArray = objc.getClass("NSArray").?;
    return NSArray.msgSend(objc.Object, "array", .{}).value;
}

fn attributedSubstring(_: c.id, _: c.SEL, _: ak.NSRange, _: ?*ak.NSRange) callconv(.c) c.id {
    return null;
}

fn characterIndexForPoint(_: c.id, _: c.SEL, _: ak.NSPoint) callconv(.c) c_ulong {
    return std.math.maxInt(c_ulong);
}

fn firstRectForCharacterRange(_: c.id, _: c.SEL, _: ak.NSRange, _: ?*ak.NSRange) callconv(.c) ak.NSRect {
    return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
}
