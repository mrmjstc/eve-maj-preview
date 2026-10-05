//! The knots configuration window's look, mirroring the WebView2 page's style.css.
const ui = @import("ui");

const Color = ui.Color;
const Style = ui.Style;

pub const BG = color("#0b0c0d");
pub const PANEL = color("#131416");
pub const SURFACE = color("#1a1b1d");
pub const SURFACE_ALT = color("#202224");
pub const BORDER = color("#35383d");
pub const BORDER_STRONG = color("#6b6e75");
pub const TEXT = color("#e8e6e1");
pub const TEXT_SECONDARY = color("#c4c0b6");
pub const MUTED = color("#8b8f96");
pub const DESTRUCTIVE = color("#d3673f");
/// Text on the accent: dark on a light accent, light on a dark one.
pub const INK_DARK = color("#1a1408");
pub const INK_LIGHT = color("#f5f0e6");
pub const SUCCESS = color("#5ec98f");
pub const ERROR = color("#e05a4e");

/// style.css's 16px rem: --fs-label, --fs-body (the default, `sm`), --fs-heading, then two larger steps.
pub const theme = ui.Theme.parse(.{
    .primary = .{ .hex = "#d9a441" },
    .secondary = .{ .hex = "#a988d1" },
    .success = .{ .hex = "#5ec98f" },
    .info = .{ .hex = "#7fb3d9" },
    .warning = .{ .hex = "#d9a441" },
    .@"error" = .{ .hex = "#e05a4e" },
    .on_primary = .{ .hex = "#1a1408" },
    .on_secondary = .{ .hex = "#1a1408" },
    .on_success = .{ .hex = "#1a1408" },
    .on_info = .{ .hex = "#1a1408" },
    .on_warning = .{ .hex = "#1a1408" },
    .on_error = .{ .hex = "#ffffff" },
    .bg = .{ .hex = "#0b0c0d" },
    .elevated = .{ .hex = "#131416" },
    .muted = .{ .hex = "#1a1b1d" },
    // The accent's hover shade; form.applyAccent sets both from the profile's accentColor.
    .accented = .{ .hex = "#e8b75f" },
    .inverted = .{ .hex = "#0b0c0d" },
    .text = .{ .hex = "#e8e6e1" },
    .highlighted = .{ .hex = "#e8e6e1" },
    .toned = .{ .hex = "#6b6e75" },
    .dimmed = .{ .hex = "#8b8f96" },
    .radius = 3,
    .font_size = .{ 11, 12, 14, 16, 20 },
    .scrollbar_thickness = SCROLLBAR_THICKNESS,
    .scrollbar_min_thumb = 24,
    .scrollbar_track_color = .{ .hex = "#131416" },
    .scrollbar_thumb_color = .{ .hex = "#35383d" },
    .scrollbar_thumb_hover_color = .{ .hex = "#6b6e75" },
    .scrollbar_corner_radius = 4,
});

pub const FONT_REGULAR = "regular";
pub const FONT_SEMIBOLD = "semibold";
pub const FONT_REGULAR_DATA = @embedFile("../../assets/fonts/CascadiaCode-Regular.ttf");
pub const FONT_SEMIBOLD_DATA = @embedFile("../../assets/fonts/CascadiaCode-SemiBold.ttf");

pub const CONTROL_HEIGHT = 28;
const SCROLLBAR_THICKNESS = 8;
/// Right padding in a scrolling pane: the scrollbar draws over the content, so this keeps a gap between it and what's inside.
const SCROLLBAR_GUTTER = SCROLLBAR_THICKNESS + 10;
pub const LABEL_WIDTH = 190;

pub const section: Style = .{
    .width = .grow(),
    .direction = .column,
    .gap = 8,
    .padding = .all(12),
    .background = .{ .color = PANEL },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .md,
};

/// A section that fills its tab, like the Characters list's.
pub const fill_section: Style = section.with(.{ .height = .grow() });

pub const sidebar: Style = .{
    .width = .fixed(150),
    .height = .grow(),
    .direction = .column,
    .padding = .xy(0, 8),
    .background = .{ .color = PANEL },
    .border_width = .edges(0, 1, 0, 0),
    .border_color = .{ .color = BORDER },
};

/// .tab-item: a 2px left rail that turns amber when active.
pub const tab_item: Style = .{
    .width = .grow(),
    .justify = .start,
    .padding = .init(6, 14, 6, 8),
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .font = FONT_SEMIBOLD,
    .radius = .none,
    .border_width = .edges(0, 0, 0, 2),
    .border_color = .transparent,
    .hover = &.{ .background = .{ .color = SURFACE }, .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const tab_item_active: Style = tab_item.with(.{
    .background = .{ .color = SURFACE_ALT },
    .foreground = .{ .color = TEXT },
    .border_color = .accent,
    .hover = &.{ .state_layer = 0 },
});

/// The tab's content; scrolls unless the tab fills it itself.
pub const content_scroll: Style = .{
    .width = .grow(),
    .height = .grow(),
    .direction = .column,
    .gap = 8,
    .padding = .init(8, SCROLLBAR_GUTTER, 8, 8),
    .overflow = .scroll_y,
};
pub const content_fill: Style = content_scroll.with(.{ .padding = .all(8), .overflow = .visible });

pub const roster: Style = .{
    .width = .fixed(175),
    .height = .grow(),
    .direction = .column,
    .overflow = .scroll_y,
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .lg,
};

/// .roster-row, a Button so the whole row is clickable.
pub const roster_row: Style = .{
    .width = .grow(),
    .height = .fit(),
    .justify = .start,
    .gap = 6,
    .padding = .init(6, 8, 6, 6),
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .radius = .none,
    .border_width = .edges(0, 0, 1, 2),
    .border_color = .{ .color = color("#26282c") },
    .hover = &.{ .background = .{ .color = SURFACE }, .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const roster_row_selected: Style = roster_row.with(.{
    .background = .{ .color = SURFACE },
    .foreground = .{ .color = TEXT },
    .border_color = .accent,
});

pub const roster_name: Style = .{ .width = .grow() };
pub const roster_name_selected: Style = .{ .width = .grow(), .font = FONT_SEMIBOLD };
pub const roster_empty: Style = .{ .padding = .xy(8, 6), .font_size = .xs, .foreground = .{ .color = MUTED } };

pub const index_chip: Style = .{
    .padding = .xy(2, 1),
    .font_size = .xs,
    .background = .{ .color = SURFACE_ALT },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .md,
};

pub const detail_stack: Style = .{
    .width = .grow(),
    .height = .grow(),
    .direction = .column,
    .gap = 8,
    .padding = .init(8, SCROLLBAR_GUTTER, 8, 8),
    .overflow = .scroll_y,
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .lg,
};

pub const detail_header: Style = .{
    .width = .grow(),
    .direction = .row,
    .@"align" = .center,
    .gap = 8,
    .padding = .init(0, 0, 8, 0),
    .border_width = .edges(0, 0, 1, 0),
    .border_color = .{ .color = BORDER },
};

pub const text_input: Style = .{
    .width = .grow(),
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(8, 4),
    .background = .{ .color = SURFACE },
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
    .hover = &.{ .border_color = .accent },
    .focus = &.{ .border_color = .accent },
};

pub const heading: Style =.{ .font = FONT_SEMIBOLD, .font_size = .md, .foreground = .{ .color = TEXT } };

pub const subheading: Style = .{
    .width = .grow(),
    .padding = .init(8, 0, 2, 0),
    .border_width = .edges(0, 0, 1, 0),
    .border_color = .{ .color = BORDER },
    .font = FONT_SEMIBOLD,
    .foreground = .{ .color = TEXT_SECONDARY },
};

/// No italics: Cascadia Code ships them as a separate face we don't embed.
pub const hint: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED }, .wrap = true, .width = .grow() };

/// The accent tints it, like the page's warning banner.
pub const notice: Style = .{
    .width = .grow(),
    .wrap = true,
    .padding = .xy(10, 6),
    .foreground = .accent,
    .border_width = .all(1),
    .border_color = .accent,
    .radius = .md,
};

pub const not_ported: Style = .{
    .width = .grow(),
    .wrap = true,
    .padding = .xy(8, 6),
    .font_size = .xs,
    .foreground = .{ .color = TEXT_SECONDARY },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .md,
};

pub const scope_chip: Style = .{
    .padding = .xy(5, 1),
    .font_size = .{ .px = 9 },
    .foreground = .{ .color = MUTED },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .{ .fixed = 2 },
};

pub const label: Style = .{ .width = .fixed(LABEL_WIDTH), .wrap = true, .foreground = .{ .color = TEXT_SECONDARY } };

pub const number_input: Style = .{
    .width = .fixed(80),
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(8, 4),
    .background = .{ .color = SURFACE },
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
    .hover = &.{ .border_color = .accent },
    .focus = &.{ .border_color = .accent },
};

/// No fill: the page's range track is one colour either side of the thumb.
pub const slider_track: Style = .{ .height = .fixed(6), .background = .{ .color = BORDER }, .radius = .md };
pub const slider_fill: Style = .{ .background = .{ .color = BORDER } };
pub const slider_thumb: Style = .{ .width = .fixed(16), .background = .accent };

pub const slider_value: Style = .{ .width = .fixed(48), .foreground = .{ .color = TEXT_SECONDARY } };

pub const select: Style = .{
    .width = .fixed(230),
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(8, 4),
    .font_size = .sm,
    .background = .{ .color = SURFACE },
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
    .hover = &.{ .border_color = .accent },
};

pub const checkbox: Style = .{ .gap = 6 };
/// On the label, not the checkbox: a custom foreground there restarts the box's transition every frame, so knots never stops redrawing.
pub const checkbox_label: Style = .{ .foreground = .{ .color = TEXT_SECONDARY } };
pub const checkbox_box: Style = .{
    .width = .fixed(14),
    .height = .fixed(14),
    .background = .transparent,
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .{ .fixed = 2 },
};

pub const color_picker: Style = .{
    .width = .fit(),
    .padding = .xy(4, 3),
    .background = .{ .color = SURFACE },
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
    .hover = &.{ .border_color = .accent },
};
pub const color_swatch: Style = .{ .width = .fixed(20), .height = .fixed(20) };
/// Above the modal layer, so a picker inside a prompt opens over it rather than under it.
pub const color_popup: Style = .{ .layer = ui.Layer.fromIndex(ui.Layer.modal.z + 1) };
/// Likewise for a dropdown's option list.
pub const select_popup: Style = .{ .layer = ui.Layer.fromIndex(ui.Layer.modal.z + 1) };

pub const footer: Style = .{
    .width = .grow(),
    .direction = .row,
    .@"align" = .center,
    .gap = 8,
    .padding = .xy(12, 8),
    .background = .{ .color = PANEL },
    .border_width = .edges(1, 0, 0, 0),
    .border_color = .{ .color = BORDER },
};

/// wordmark.svg at the page's 6rem height.
pub const wordmark: Style = .{ .width = .fixed(269), .height = .fixed(96) };

/// The page's `<strong>` inside a hint.
pub const fact_label: Style = .{ .font = FONT_SEMIBOLD, .font_size = .xs, .foreground = .{ .color = MUTED } };
pub const hint_plain: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED } };

/// A text link, a Button so it's clickable and focusable.
pub const link: Style = .{
    .padding = .all(0),
    .background = .transparent,
    .foreground = .accent,
    .font_size = .xs,
    .radius = .none,
    .hover = &.{ .foreground = .accented, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};

/// One of three equal columns, like the page's credits grid.
pub const thanks_name: Style = .{ .width = .grow(), .font_size = .xs, .foreground = .{ .color = MUTED } };

/// #profile-header.
pub const header: Style = .{
    .width = .grow(),
    .height = .fixed(44),
    .direction = .row,
    .@"align" = .center,
    .gap = 8,
    .padding = .xy(12, 8),
    .background = .{ .color = PANEL },
    .border_width = .edges(0, 0, 1, 0),
    .border_color = .{ .color = BORDER },
};

pub const app_mark: Style = .{ .width = .fixed(18), .height = .fixed(18) };
pub const app_name: Style = .{ .font = FONT_SEMIBOLD, .font_size = .md, .foreground = .{ .color = TEXT } };

pub const profile_select: Style = select.with(.{ .width = .fixed(170) });

/// .button-icon: a square plain button holding a drawn icon.
pub const icon_button: Style = plain_button.with(.{ .width = .fixed(CONTROL_HEIGHT), .padding = .all(0), .justify = .center });
pub const icon_button_disabled: Style = disabled_button.with(.{ .width = .fixed(CONTROL_HEIGHT), .padding = .all(0), .justify = .center });

pub const danger_button: Style = plain_button.with(.{
    .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .{ .color = DESTRUCTIVE }, .foreground = .{ .color = DESTRUCTIVE }, .state_layer = 0 },
});

pub const modal_actions: Style = .{ .width = .grow(), .direction = .row, .gap = 8, .justify = .end };

pub const status_info: Style = .{ .foreground = .{ .color = TEXT_SECONDARY } };
pub const status_success: Style = .{ .foreground = .{ .color = SUCCESS } };
pub const status_failure: Style = .{ .foreground = .{ .color = ERROR } };

pub const unsaved_chip: Style = .{
    .padding = .xy(6, 2),
    .font_size = .xs,
    .foreground = .accent,
    .border_width = .all(1),
    .border_color = .accent,
    .radius = .{ .fixed = 2 },
};

/// The page's plain `button`: surface fill, accent border on hover.
pub const plain_button: Style = .{
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(12, 0),
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER_STRONG },
    .foreground = .{ .color = TEXT },
    .radius = .md,
    .hover = &.{ .background = .{ .color = SURFACE_ALT }, .border_color = .accent, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};

/// Picked in code for a disabled button: knots' own disabled variant doesn't dim it.
pub const disabled_button: Style = .{
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(12, 0),
    .background = .transparent,
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .foreground = .{ .color = MUTED },
    .radius = .md,
    .hover = &.{ .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};

pub const modal: Style = .{
    .width = .fixed(360),
    .gap = 12,
    .background = .{ .color = PANEL },
    .border_color = .{ .color = BORDER },
    .radius = .lg,
};

pub const modal_text: Style = .{ .foreground = .{ .color = TEXT_SECONDARY }, .wrap = true, .width = .grow() };

/// .button-primary: outlined in the accent at rest, filled on hover.
pub const primary_button: Style = .{
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(12, 0),
    .background = .transparent,
    .border_width = .all(1),
    .border_color = .accent,
    .foreground = .accent,
    .font = FONT_SEMIBOLD,
    .radius = .md,
    .hover = &.{ .background = .accented, .border_color = .accented, .foreground = .on_accent, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};

fn color(comptime hex: []const u8) Color {
    return Color.hex(hex) catch unreachable;
}

pub const muted_text: Style = .{ .foreground = .{ .color = MUTED } };

pub const select_wide: Style = select.with(.{ .width = .fixed(300) });
pub const select_narrow: Style = select.with(.{ .width = .fixed(130) });

/// The row of sub-tabs at the top of a tab, underlined like the page's tab rail but horizontal.
pub const sub_tabs: Style = .{
    .width = .grow(),
    .direction = .row,
    .gap = 4,
    .border_width = .edges(0, 0, 1, 0),
    .border_color = .{ .color = BORDER },
};
pub const sub_tab: Style = .{
    .padding = .init(6, 14, 6, 14),
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .font = FONT_SEMIBOLD,
    .radius = .none,
    .border_width = .edges(0, 0, 2, 0),
    .border_color = .transparent,
    .hover = &.{ .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const sub_tab_active: Style = sub_tab.with(.{ .foreground = .{ .color = TEXT }, .border_color = .accent });

/// A row of a settings grid: the label column, then fixed-width cells so columns line up.
pub const grid_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
pub const grid_check_cell: Style = .{ .width = .fixed(GRID_CHECK_WIDTH) };
pub const grid_cells: Style = .{ .direction = .row, .@"align" = .center, .gap = 8 };
/// The cells of a row whose setting is off: still editable, but visibly not in effect.
pub const grid_cells_dimmed: Style = grid_cells.with(.{ .opacity = 0.45 });
pub const grid_header: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED } };
pub const grid_header_check: Style = grid_header.with(.{ .width = .fixed(GRID_CHECK_WIDTH) });
/// Matches number_input's width, so the header sits over its column.
pub const grid_header_number: Style = grid_header.with(.{ .width = .fixed(80) });
pub const grid_header_select: Style = grid_header.with(.{ .width = .fixed(130) });
const GRID_CHECK_WIDTH = 40;

/// The text overlay list beside the selected overlay's settings.
pub const overlay_list: Style = .{
    .width = .fixed(190),
    .direction = .column,
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .lg,
};
pub const overlay_row: Style = .{
    .width = .grow(),
    .direction = .row,
    .@"align" = .center,
    .gap = 2,
    .padding = .init(4, 6, 4, 8),
    .border_width = .edges(0, 0, 1, 2),
    .border_color = .{ .color = BORDER },
};
pub const overlay_row_selected: Style = overlay_row.with(.{ .background = .{ .color = SURFACE }, .border_color = .accent });
pub const overlay_name: Style = .{
    .width = .grow(),
    .justify = .start,
    .padding = .xy(4, 2),
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .radius = .none,
    .hover = &.{ .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const overlay_name_selected: Style = overlay_name.with(.{ .foreground = .{ .color = TEXT }, .font = FONT_SEMIBOLD });
pub const overlay_detail: Style = .{
    .width = .grow(),
    .direction = .column,
    .gap = 8,
    .padding = .all(10),
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .lg,
};

/// widgets.segmented: buttons joined into one outlined strip.
pub const segmented: Style = .{
    .direction = .row,
    .padding = .all(2),
    .gap = 2,
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .md,
};
pub const segment: Style = .{
    .height = .fixed(22),
    .padding = .xy(10, 0),
    .font_size = .xs,
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .radius = .sm,
    .hover = &.{ .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const segment_on: Style = segment.with(.{ .background = .{ .color = SURFACE_ALT }, .foreground = .{ .color = TEXT } });

/// The stage's card: the editable thumbnail with its controls above and its hint below.
pub const stage_card: Style = .{
    .width = .grow(),
    .direction = .column,
    .@"align" = .center,
    .gap = 10,
    .padding = .all(12),
    .background = .{ .color = PANEL },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .md,
};
pub const stage_toolbar: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };

/// Wide enough for a label column beside a standard dropdown.
pub const POPOVER_WIDTH = 470;
/// A Dialog panel used as a popover beside what it edits.
pub const popover: Style = .{
    .width = .fixed(POPOVER_WIDTH),
    .gap = 8,
    .padding = .all(12),
    .background = .{ .color = PANEL },
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .lg,
};
pub const popover_title: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .justify = .space_between };
pub const popover_close: Style = plain_button.with(.{ .width = .fixed(CONTROL_HEIGHT), .padding = .all(0), .justify = .center });
