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
pub const DESTRUCTIVE_FILL = color("#ad4527");
pub const DESTRUCTIVE_FILL_HOVER = color("#bb4f30");
pub const WHITE = color("#ffffff");
/// Text on the accent: dark on a light accent, light on a dark one.
pub const INK_DARK = color("#1a1408");
pub const INK_LIGHT = color("#f5f0e6");
pub const SUCCESS = color("#5ec98f");
pub const ERROR = color("#e05a4e");
pub const PURPLE = color("#a988d1");
pub const SKY = color("#7fb3d9");

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

/// Fits Resource Overlay, the longest label; knots can't size a rail to stretched children, as the page's hugs its content.
pub const sidebar: Style = .{
    .width = .fixed(172),
    .height = .grow(),
    .direction = .column,
    .padding = .xy(0, 6),
    .overflow = .scroll_y,
    .background = .{ .color = PANEL },
    .border_width = .edges(0, 1, 0, 0),
    .border_color = .{ .color = BORDER },
};

/// .tab-item: a 2px left rail that turns amber when active; holds the glyph and label.
pub const tab_item: Style = .{
    .width = .grow(),
    .justify = .start,
    .gap = 8,
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
pub const tab_label: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = MUTED } };
pub const tab_label_lit: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = TEXT } };
pub const tab_glyph: Style = .{ .width = .fixed(14), .height = .fixed(14) };

/// .subheader-item: a section of the open tab, indented to line up with the tab's label.
pub const subheader_item: Style = .{
    .width = .grow(),
    .justify = .start,
    .padding = .init(3, 10, 3, 32),
    .font_size = .{ .px = 10 },
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .radius = .none,
    .hover = &.{ .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const subheader_item_active: Style = subheader_item.with(.{ .foreground = .{ .color = TEXT }, .font = FONT_SEMIBOLD });

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

pub const heading: Style = .{ .font = FONT_SEMIBOLD, .font_size = .md, .foreground = .{ .color = TEXT } };

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

pub const section_heading: Style = .{ .width = .grow(), .direction = .row, .justify = .space_between, .@"align" = .center };
pub const section_heading_actions: Style = .{ .direction = .row, .@"align" = .center, .gap = 6 };

/// The section's ? button, filled while its field hints show.
pub const hint_toggle: Style = .{
    .padding = .xy(5, 1),
    .font_size = .{ .px = 9 },
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .{ .fixed = 2 },
    .hover = &.{ .border_color = .accent, .foreground = .accent, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const hint_toggle_on: Style = hint_toggle.with(.{
    .background = .accent,
    .foreground = .on_accent,
    .border_color = .accent,
    .hover = &.{ .state_layer = 0 },
});

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

/// .changes-pending: the dot and label, outlined in the accent.
pub const unsaved_chip: Style = .{
    .height = .fixed(CONTROL_HEIGHT),
    .direction = .row,
    .@"align" = .center,
    .gap = 4,
    .padding = .xy(8, 0),
    .border_width = .all(1),
    .border_color = .accent,
    .radius = .{ .fixed = 2 },
};
pub const unsaved_text: Style = .{ .foreground = .accent };
pub const unsaved_dot: Style = .{ .font_size = .{ .px = 10 }, .foreground = .accent };

/// .button-outline: quieter than a plain button until hovered.
pub const outline_button: Style = plain_button.with(.{
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .hover = &.{ .background = .{ .color = SURFACE }, .foreground = .{ .color = TEXT }, .border_color = .accent, .state_layer = 0 },
});

/// The header's icon buttons each hover in their own colour, like .button-icon-add and its siblings.
pub const icon_button_add: Style = icon_button.with(.{ .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .{ .color = SUCCESS }, .state_layer = 0 } });
pub const icon_button_danger: Style = icon_button.with(.{ .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .{ .color = DESTRUCTIVE }, .state_layer = 0 } });
pub const icon_button_reset: Style = icon_button.with(.{ .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .{ .color = PURPLE }, .state_layer = 0 } });
pub const icon_button_import: Style = icon_button.with(.{ .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .{ .color = SKY }, .state_layer = 0 } });

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

/// A row of a settings grid: the label column, then fixed-width cells so columns line up.
pub const grid_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
/// A row's checkbox and its label, which turns the row's settings on.
pub const grid_state_cell: Style = .{ .width = .fixed(GRID_STATE_WIDTH) };
pub const grid_cells: Style = .{ .direction = .row, .@"align" = .center, .gap = 8 };
/// The cells of a row whose setting is off: still editable, but visibly not in effect.
pub const grid_cells_dimmed: Style = grid_cells.with(.{ .opacity = 0.45 });
pub const grid_header: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED } };
pub const grid_header_state: Style = grid_header.with(.{ .width = .fixed(GRID_STATE_WIDTH) });
/// Matches number_input's width, so the header sits over its column.
pub const grid_header_number: Style = grid_header.with(.{ .width = .fixed(80) });
pub const grid_header_select: Style = grid_header.with(.{ .width = .fixed(130) });
const GRID_STATE_WIDTH = 140;

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

/// Wide enough for a label column beside a standard dropdown.
pub const POPOVER_WIDTH = 420;
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

/// openGroup's column, which dims like the page's .is-disabled.
pub const group: Style = .{ .width = .grow(), .direction = .column, .gap = 8 };
pub const group_disabled: Style = group.with(.{ .opacity = 0.5 });
/// Laid over a disabled group to take its clicks; sized from the group's last layout.
pub const group_blocker: Style = .{
    .position = .absolute,
    .offset = .{ 0, 0 },
    .padding = .all(0),
    .background = .transparent,
    .radius = .none,
    .hover = &.{ .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};

/// button.confirm-delete: a remove button waiting for its second click.
pub const confirm_button: Style = plain_button.with(.{
    .background = .{ .color = DESTRUCTIVE_FILL },
    .border_color = .{ .color = DESTRUCTIVE_FILL_HOVER },
    .foreground = .{ .color = WHITE },
    .hover = &.{ .background = .{ .color = DESTRUCTIVE_FILL_HOVER }, .foreground = .{ .color = WHITE }, .state_layer = 0 },
});
/// .button-remove: as wide as its armed Confirm label, so arming it doesn't resize it.
pub const remove_button: Style = danger_button.with(.{ .width = .fixed(REMOVE_BUTTON_WIDTH) });
pub const confirm_remove_button: Style = confirm_button.with(.{ .width = .fixed(REMOVE_BUTTON_WIDTH) });
const REMOVE_BUTTON_WIDTH = 80;
pub const button_text: Style = .{ .foreground = .{ .color = TEXT } };
/// .full-width-btn under a list.
pub const full_width_button: Style = plain_button.with(.{ .width = .grow() });
/// .button-row-flex: buttons sharing a line.
pub const button_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
/// One item of a list, e.g. a system colour: its fields then a Remove button.
pub const list_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
pub const list: Style = .{ .width = .grow(), .direction = .column, .gap = 8 };

/// #overlayLayoutStage's frame: a 1px border, centred in its section.
pub const stage_frame: Style = .{
    .padding = .all(1),
    .background = .{ .color = BORDER },
    .radius = .md,
    .overflow = .hidden,
};
pub const stage_row: Style = .{ .width = .grow(), .justify = .center };

/// Fields sharing one row with their labels above them, like the page's Font Name, Size and Weight.
pub const stacked_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .end, .gap = 8 };
pub const stacked_field: Style = .{ .direction = .column, .gap = 4 };
pub const stacked_label: Style = .{ .foreground = .{ .color = TEXT_SECONDARY } };

/// .button-icon with a text glyph, like the page's × clear-region button.
pub const icon_button_danger_text: Style = icon_button.with(.{
    .foreground = .{ .color = MUTED },
    .font_size = .{ .px = 15 },
    .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .{ .color = DESTRUCTIVE }, .foreground = .{ .color = DESTRUCTIVE }, .state_layer = 0 },
});
pub const icon_button_disabled_text: Style = icon_button_disabled.with(.{ .font_size = .{ .px = 15 } });
pub const icon_button_confirm: Style = confirm_button.with(.{ .width = .fixed(CONTROL_HEIGHT), .padding = .all(0), .justify = .center });

/// .master-detail outside a filling tab: a roster beside the selected item's details, both sized to their content.
pub const master_detail: Style = .{ .width = .grow(), .direction = .row, .gap = 8 };
pub const roster_filters: Style = roster.with(.{ .width = .fixed(190), .height = .fit(), .overflow = .visible });
pub const detail_fit: Style = detail_stack.with(.{ .height = .fit(), .overflow = .visible, .padding = .all(8) });
/// .roster-hotkey-badge, e.g. a filter's Disabled.
pub const roster_badge: Style = .{ .font_size = .{ .px = 10 }, .foreground = .{ .color = MUTED } };
pub const inline_label: Style = .{ .foreground = .{ .color = TEXT_SECONDARY } };
pub const select_fill: Style = select.with(.{ .width = .grow() });

/// A field hint with a link after it.
pub const hint_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 4 };
pub const hint_inline: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED }, .wrap = true };

/// Side-by-side columns inside a section, like the page's .row of .column.
pub const columns: Style = .{ .width = .grow(), .direction = .row, .@"align" = .start, .gap = 16 };
pub const column: Style = .{ .width = .grow(), .direction = .column, .gap = 8 };

/// #overlayPopoverBody's label column, as wide as its longest label.
pub const popover_label: Style = label.with(.{ .width = .fixed(150) });

/// .notification-types-table: bordered rows with a category column, as the ore price table shows them.
pub const table: Style = .{
    .width = .grow(),
    .direction = .column,
    .background = .{ .color = PANEL },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
};
pub const table_header: Style = .{
    .width = .grow(),
    .direction = .row,
    .@"align" = .center,
    .padding = .xy(6, 4),
    .gap = 8,
    .border_width = .edges(0, 0, 1, 0),
    .border_color = .{ .color = BORDER },
};
pub const table_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .padding = .xy(6, 2), .gap = 8 };
/// The first row of a new category, ruled off from the one before.
pub const table_row_separated: Style = table_row.with(.{ .border_width = .edges(1, 0, 0, 0), .border_color = .{ .color = BORDER } });
pub const table_category_cell: Style = .{ .width = .fixed(60), .font_size = .xs, .foreground = .{ .color = MUTED } };
pub const table_name_cell: Style = .{ .width = .grow(), .font_size = .xs, .foreground = .{ .color = TEXT_SECONDARY } };
pub const table_heading_grow: Style = .{ .width = .grow(), .font = FONT_SEMIBOLD, .font_size = .xs, .foreground = .{ .color = TEXT } };
pub const table_heading_price: Style = .{ .width = .fixed(PRICE_INPUT_WIDTH), .font = FONT_SEMIBOLD, .font_size = .xs, .foreground = .{ .color = TEXT } };
pub const price_input: Style = number_input.with(.{ .width = .fixed(PRICE_INPUT_WIDTH), .height = .fixed(24) });
const PRICE_INPUT_WIDTH = 140;

/// A search box with its clear button, above a roster.
pub const search_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 4 };
pub const roster_events: Style = roster.with(.{ .width = .fixed(175), .height = .fit(), .overflow = .visible });
/// .detail-form: a label rail beside each row's stacked controls.
pub const rail_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .start, .gap = 12 };
pub const rail_label: Style = label.with(.{ .width = .fixed(RAIL_LABEL_WIDTH) });
const RAIL_LABEL_WIDTH = 110;
pub const rail_body: Style = .{ .width = .grow(), .direction = .column, .gap = 6 };
/// Several labelled controls on one line.
pub const inline_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
pub const inline_label_fixed: Style = inline_label.with(.{ .width = .fixed(90) });
/// .placeholder-chips: small buttons that insert a {placeholder}.
pub const chip_row: Style = .{ .width = .grow(), .direction = .row, .gap = 4, .wrap = true };
pub const placeholder_chip: Style = plain_button.with(.{ .height = .fixed(22), .padding = .xy(6, 0), .font_size = .xs });
/// A read-only path, shown as a box like the page's readonly input.
pub const path_box: Style = .{
    .width = .grow(),
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(8, 4),
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .md,
    .foreground = .{ .color = TEXT },
};
pub const path_box_empty: Style = path_box.with(.{ .foreground = .{ .color = MUTED } });

/// .keycap-field: a hotkey's combos drawn as key caps; clicking it records a new one.
pub const hotkey_box: Style = .{
    .width = .grow(),
    .height = .fixed(CONTROL_HEIGHT),
    .direction = .row,
    .justify = .start,
    .@"align" = .center,
    .gap = 3,
    .padding = .xy(6, 0),
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
    .overflow = .hidden,
    .hover = &.{ .border_color = .accent, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const hotkey_box_recording: Style = hotkey_box.with(.{ .border_color = .accent });
/// input.hotkey-conflict: a combo bound to something else too.
pub const hotkey_box_conflict: Style = hotkey_box.with(.{ .border_color = .{ .color = ERROR }, .background = .{ .color = ERROR_TINT } });
pub const hotkey_placeholder: Style = .{ .foreground = .{ .color = MUTED } };
pub const hotkey_prompt: Style = .{ .foreground = .accent };
pub const hotkey_edit_on: Style = icon_button.with(.{ .background = .{ .color = SUCCESS }, .border_color = .{ .color = SUCCESS } });
pub const ERROR_TINT = color("#2a1614");
/// .keycap: the heavier bottom edge reads as a key rather than a chip.
pub const keycap: Style = .{
    .padding = .init(3, 5, 3, 5),
    .background = .{ .color = SURFACE_ALT },
    .border_width = .edges(1, 1, 2, 1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
};
pub const keycap_text: Style = .{ .font_size = .{ .px = 10 }, .foreground = .{ .color = TEXT } };
pub const keycap_modifier_text: Style = keycap_text.with(.{ .foreground = .{ .color = MUTED } });
pub const keycap_plus: Style = .{ .font_size = .{ .px = 9 }, .foreground = .{ .color = MUTED } };
pub const keycap_separator: Style = .{ .font_size = .sm, .foreground = .{ .color = MUTED } };
pub const inline_label_wide: Style = inline_label.with(.{ .width = .fixed(150) });
/// A roster row with the drop line above or below it while another is dragged.
pub const roster_row_drop_above: Style = roster_row.with(.{ .border_width = .edges(2, 0, 1, 2), .border_color = .accent });
pub const roster_row_drop_below: Style = roster_row.with(.{ .border_width = .edges(0, 0, 2, 2), .border_color = .accent });
/// .detail-value: a read-only value in a detail form, e.g. a saved position.
pub const detail_value: Style = .{ .width = .grow(), .foreground = .{ .color = TEXT_SECONDARY } };

/// The Hotkeys tab's one label column, wide enough for its longest label.
pub const binding_label: Style = label.with(.{ .width = .fixed(BINDING_LABEL_WIDTH) });
const BINDING_LABEL_WIDTH = 240;
/// .binding-paired's label: narrower by the arrow and its gap, which hang into the label column.
pub const binding_label_paired: Style = label.with(.{ .width = .fixed(BINDING_LABEL_WIDTH - BINDING_ARROW_OFFSET) });
pub const rail_label_paired: Style = label.with(.{ .width = .fixed(RAIL_LABEL_WIDTH - BINDING_ARROW_OFFSET) });
/// --binding-dir-offset: the arrow's width plus the row gap after it.
const BINDING_ARROW_OFFSET = 14 + 8;
/// .binding-control: a binding's backward and forward halves side by side, each taking half.
pub const pair_column: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 12 };
/// .binding-dir: the arrow marking a pair's half.
pub const binding_arrow: Style = .{ .width = .fixed(14), .foreground = .{ .color = MUTED } };

/// .hkgroup-tab-add: the roster's own add button, under its rows.
pub const roster_add: Style = .{
    .width = .grow(),
    .justify = .start,
    .padding = .init(6, 8, 6, 8),
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .radius = .none,
    .hover = &.{ .foreground = .accent, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
/// .hkgroup-chars-list: a group's members, each a draggable row.
pub const members_list: Style = .{ .width = .grow(), .direction = .column, .gap = 4 };
pub const member_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 6, .border_width = .edges(2, 0, 2, 0), .border_color = .transparent };
pub const member_row_drop_above: Style = member_row.with(.{ .border_color = .accent, .border_width = .edges(2, 0, 0, 0) });
pub const member_row_drop_below: Style = member_row.with(.{ .border_color = .accent, .border_width = .edges(0, 0, 2, 0) });

/// Laid out of sight: absolute so it takes no room, and clipped to nothing.
pub const section_hidden: Style = .{
    .position = .absolute,
    .offset = .{ 0, 0 },
    .width = .fixed(0),
    .height = .fixed(0),
    .overflow = .hidden,
};
/// #search-container, at the footer's left.
pub const search_container: Style = .{ .width = .fixed(180), .direction = .row, .@"align" = .center, .gap = 2 };
pub const search_input: Style = text_input.with(.{ .width = .grow() });
/// .button-clear: inside the box's right edge, quiet until hovered.
pub const search_clear: Style = .{
    .width = .fixed(22),
    .height = .fixed(22),
    .padding = .all(0),
    .justify = .center,
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .radius = .sm,
    .hover = &.{ .foreground = .{ .color = TEXT }, .background = .{ .color = SURFACE_ALT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const search_count_none: Style = .{ .width = .fixed(60), .foreground = .{ .color = ERROR } };
pub const search_count_some: Style = .{ .width = .fixed(60), .foreground = .accent };

/// #client-suggest: open clients' names offered under a name box.
pub const suggest_list: Style = .{
    .width = .grow(),
    .direction = .column,
    .padding = .all(2),
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
};
pub const suggest_row: Style = .{
    .width = .grow(),
    .justify = .start,
    .padding = .xy(8, 4),
    .background = .transparent,
    .foreground = .{ .color = TEXT_SECONDARY },
    .radius = .sm,
    .hover = &.{ .background = .{ .color = SURFACE_ALT }, .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};

/// .modal-content.modal-wide: room for the Import dialog's lists.
pub const modal_wide: Style = modal.with(.{ .width = .fixed(520) });
