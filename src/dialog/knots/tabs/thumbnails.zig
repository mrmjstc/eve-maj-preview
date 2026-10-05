//! The configuration window's Thumbnails tab, split by what a setting is about: how a thumbnail looks, and where thumbnails go; main thread only.
const ui = @import("ui");
const widgets = @import("../widgets.zig");
const appearance = @import("thumbnails/appearance.zig");
const layout = @import("thumbnails/layout.zig");

const Page = enum { appearance, layout };

var g_page: Page = .appearance;

pub fn show(context: *ui.Frame) !void {
    g_page = try widgets.subTabs(context, Page, g_page, .{ "Appearance", "Layout" });
    switch (g_page) {
        .appearance => try appearance.show(context),
        .layout => try layout.show(context),
    }
}
