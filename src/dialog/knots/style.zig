//! The configuration window's look: colours, sizes and every component's style.
const ui = @import("ui");

const Color = ui.Color;
const Style = ui.Style;

/// The window's frame (sidebar, header, footer, title bar): the darkest layer.
pub const CHROME = color("#0b0c0d");
/// The content area behind the cards.
pub const BG = color("#111214");
/// Cards, modals and popovers: a step lighter than BG, so they stand out by shade rather than outline.
pub const PANEL = color("#18191c");
pub const SURFACE = color("#1f2124");
pub const SURFACE_ALT = color("#26282c");
pub const BORDER = color("#35383d");
/// A card's outline: quiet, since its shade already sets it apart.
pub const CARD_BORDER = color("#24262a");
/// Between rows inside a section: quieter than BORDER.
pub const DIVIDER = color("#2a2c30");
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
    .bg = .{ .hex = "#111214" },
    .elevated = .{ .hex = "#18191c" },
    .muted = .{ .hex = "#1f2124" },
    // The accent's hover shade; form.applyAccent sets both from the profile's accentColor.
    .accented = .{ .hex = "#e8b75f" },
    .inverted = .{ .hex = "#111214" },
    .text = .{ .hex = "#e8e6e1" },
    .highlighted = .{ .hex = "#e8e6e1" },
    .toned = .{ .hex = "#6b6e75" },
    .dimmed = .{ .hex = "#8b8f96" },
    .radius = 6,
    .font_size = .{ 11, 12, 14, 16, 20 },
    .scrollbar_thickness = SCROLLBAR_THICKNESS,
    .scrollbar_min_thumb = 24,
    .scrollbar_track_color = .{ .hex = "#111214" },
    .scrollbar_thumb_color = .{ .hex = "#35383d" },
    .scrollbar_thumb_hover_color = .{ .hex = "#6b6e75" },
    .scrollbar_corner_radius = 4,
});

pub const FONT_REGULAR = "regular";
pub const FONT_SEMIBOLD = "semibold";
/// For numbers being edited, so digits line up.
pub const FONT_MONO = "mono";
pub const FONT_REGULAR_DATA = @embedFile("../../assets/fonts/Geist-Regular.ttf");
pub const FONT_SEMIBOLD_DATA = @embedFile("../../assets/fonts/Geist-SemiBold.ttf");
pub const FONT_MONO_DATA = @embedFile("../../assets/fonts/GeistMono-Regular.ttf");

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
    .border_color = .{ .color = CARD_BORDER },
    .radius = .md,
};

/// A section that fills its tab, like the Characters list's.
pub const fill_section: Style = section.with(.{ .height = .grow() });

/// Fits the longest label inside the inset items; knots can't size a rail to stretched children.
pub const sidebar: Style = .{
    .width = .fixed(184),
    .height = .grow(),
    .direction = .column,
    .padding = .xy(6, 6),
    .overflow = .scroll_y,
    .background = .{ .color = CHROME },
    .border_width = .edges(0, 1, 0, 0),
    .border_color = .{ .color = DIVIDER },
};

/// .tab-item: holds the glyph and label; the active one is lit by its fill, amber glyph and brighter label.
pub const tab_item: Style = .{
    .width = .grow(),
    .justify = .start,
    .gap = 8,
    .padding = .init(6, 14, 6, 10),
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .font = FONT_SEMIBOLD,
    .radius = .md,
    .hover = &.{ .background = .{ .color = SURFACE }, .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const tab_item_active: Style = tab_item.with(.{
    .background = .{ .color = SURFACE_ALT },
    .foreground = .{ .color = TEXT },
    .hover = &.{ .state_layer = 0 },
});
/// .nav-category: the small heading over a group of tabs, lined up with their glyphs.
pub const tab_category: Style = .{ .width = .grow(), .padding = .init(14, 10, 4, 10) };
pub const tab_category_text: Style = .{ .font = FONT_SEMIBOLD, .font_size = .{ .px = 10 }, .foreground = .{ .color = MUTED } };
pub const tab_label: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = MUTED } };
pub const tab_label_lit: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = TEXT } };
pub const tab_glyph: Style = .{ .width = .fixed(14), .height = .fixed(14) };
/// widgets.openScrollPane's looks: the pane, the pane with its scrollbar gutter, and the column inside it.
pub const ScrollPane = struct { pane: *const Style, scrolling: *const Style, content: *const Style };

/// The tab's content when it scrolls. Vertical padding is on the column, so the pane's height compares straight against it.
pub const content_scroll: ScrollPane = .{
    .pane = &content_scroll_pane,
    .scrolling = &content_scroll_pane.with(.{ .padding = .init(0, SCROLLBAR_GUTTER, 0, 8) }),
    .content = &.{ .width = .grow(), .direction = .column, .gap = 8, .padding = .xy(0, 8) },
};
const content_scroll_pane: Style = .{
    .width = .grow(),
    .height = .grow(),
    .direction = .column,
    .padding = .xy(8, 0),
    .overflow = .scroll_y,
};
/// The tab's content when the tab fills it itself.
pub const content_fill: Style = .{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 8, .padding = .all(8) };

/// An inset well, darker than its section, rather than another bordered box.
pub const roster: Style = .{
    .width = .fixed(175),
    .height = .grow(),
    .direction = .column,
    .overflow = .hidden,
    .gap = 2,
    .padding = .all(4),
    .background = .{ .color = BG },
    .radius = .md,
};
/// widgets.openRoster's rows, scrolling above its footer.
pub const roster_rows: Style = .{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 2, .overflow = .scroll_y };
pub const roster_rows_fit: Style = .{ .width = .grow(), .direction = .column, .gap = 2 };
/// Every master list's add buttons, ruled off from its rows.
pub const roster_footer: Style = .{
    .width = .grow(),
    .direction = .row,
    .@"align" = .center,
    .gap = 2,
    .padding = .init(2, 0, 0, 0),
    .border_width = .edges(1, 0, 0, 0),
    .border_color = .{ .color = DIVIDER },
};

/// .roster-row, a Button so the whole row is clickable; inset like the sidebar's tabs.
pub const roster_row: Style = .{
    .width = .grow(),
    .height = .fit(),
    .justify = .start,
    .gap = 6,
    .padding = .xy(6, 6),
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .radius = .md,
    .hover = &.{ .background = .{ .color = SURFACE }, .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const roster_row_selected: Style = roster_row.with(.{
    .background = .{ .color = SURFACE_ALT },
    .foreground = .{ .color = TEXT },
    .hover = &.{ .state_layer = 0 },
});

/// Wraps: knots doesn't clip text, so a long name would otherwise run under the row's badge.
pub const roster_name: Style = .{ .width = .grow(), .wrap = true };
pub const roster_name_selected: Style = roster_name.with(.{ .font = FONT_SEMIBOLD });
pub const roster_empty: Style = .{ .width = .grow(), .padding = .xy(8, 6) };
pub const roster_empty_text: Style = .{ .width = .grow(), .wrap = true, .font_size = .xs, .foreground = .{ .color = MUTED } };

pub const roster_portrait: Style = .{ .width = .fixed(16), .height = .fixed(16), .radius = .sm };
/// Holds a portrait's place until it loads, or when it can't.
pub const roster_portrait_blank: Style = roster_portrait.with(.{ .background = .{ .color = SURFACE_ALT } });

/// Around a row's number, unboxed so it doesn't outshine the name.
/// widgets.dragHandle: no fill of its own, so it reads as part of its row.
pub const drag_handle: Style = .{
    .direction = .row,
    .@"align" = .center,
    .gap = 2,
    .padding = .xy(2, 4),
    .background = .transparent,
    .radius = .sm,
    .hover = &.{ .background = .{ .color = SURFACE }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const DRAG_GRIP_SIZE = 12;
pub const drag_grip: Style = .{ .width = .fixed(DRAG_GRIP_SIZE), .height = .fixed(DRAG_GRIP_SIZE) };
pub const index_chip_text: Style = .{ .font = FONT_MONO, .font_size = .xs, .foreground = .{ .color = MUTED } };

/// A master-detail list's details: unboxed, since the section around it is already a card.
pub const detail_scroll: ScrollPane = .{
    .pane = &detail_scroll_pane,
    .scrolling = &detail_scroll_pane.with(.{ .padding = .init(0, SCROLLBAR_GUTTER, 0, 8) }),
    .content = &.{ .width = .grow(), .direction = .column, .gap = 8 },
};
const detail_scroll_pane: Style = .{
    .width = .grow(),
    .height = .grow(),
    .direction = .column,
    .padding = .init(0, 0, 0, 8),
    .overflow = .scroll_y,
};

/// A master-detail pane's label column, narrower than label to leave its controls room.
pub const detail_label: Style = label.with(.{ .width = .fixed(110) });
/// widgets.openFieldGroup's row: its label stays at the top beside a taller column.
pub const field_group: Style = .{ .width = .grow(), .direction = .row, .@"align" = .start, .gap = 8 };
/// Drops the label to line up with the first control's text, and insets it like a row's own label.
pub const field_group_label: Style = .{ .padding = .init(6, 0, 0, ROW_INSET) };
pub const field_group_column: Style = .{ .width = .grow(), .direction = .column, .gap = 6 };

pub const detail_header: Style = .{
    .width = .grow(),
    .direction = .row,
    .@"align" = .center,
    .gap = 8,
    .padding = .init(0, ROW_INSET, 8, ROW_INSET),
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

/// Fixed in an aligned row, like select and slider_box_aligned, so a growing label can't squeeze it.
pub const text_input_aligned: Style = text_input.with(.{ .width = .fixed(230) });

pub const heading: Style = .{ .font = FONT_SEMIBOLD, .font_size = .md, .foreground = .{ .color = TEXT } };

/// Set apart by the space above it, not a rule; the row after it starts a new run with no divider.
pub const subheading_box: Style = .{ .width = .grow(), .padding = .init(16, 0, 0, 0) };
pub const subheading: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = TEXT } };

/// No italics: Geist ships them as a separate face we don't embed.
pub const hint: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED }, .wrap = true, .width = .grow(), .padding = .xy(ROW_INSET, 0) };
/// A hint that always shows, warning that a setting won't take effect.
pub const hint_warning: Style = hint.with(.{ .foreground = .accent });

/// A warning, tinted by the accent: widgets.boxedText's outline, around notice_text.
pub const notice: Style = .{
    .width = .grow(),
    .padding = .xy(10, 6),
    .border_width = .all(1),
    .border_color = .accent,
    .radius = .md,
};
pub const notice_text: Style = .{ .width = .grow(), .wrap = true, .foreground = .accent };

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

pub const label: Style = .{ .width = .fixed(LABEL_WIDTH), .wrap = true, .foreground = .{ .color = TEXT } };
/// Grows to push the row's controls to its right edge.
pub const label_aligned: Style = label.with(.{ .width = .grow() });
/// A row's label under a field group's own, softer so the group's label leads.
pub const label_aligned_grouped: Style = label_aligned.with(.{ .foreground = .{ .color = TEXT_SECONDARY } });
/// widgets.separator's rule, coloured like the dividers between aligned rows.
pub const separator: Style = .{ .width = .grow(), .height = .fixed(1), .background = .{ .color = DIVIDER } };
/// Takes a row's spare width, pushing what follows it to the right edge.
pub const spacer: Style = .{ .width = .grow() };
/// As tall as a control, so a checkbox row spaces like one with a box in it.
pub const aligned_row: Style = .{
    .width = .grow(),
    .height = .{ .kind = .fit, .min = CONTROL_HEIGHT },
    .direction = .row,
    .@"align" = .center,
    .gap = 8,
};
/// Wraps a row after a section's first; its padding matches the section's gap, so the divider sits midway between two rows' controls.
pub const row_divider: Style = .{
    .width = .grow(),
    .padding = .init(ROW_DIVIDER_SPACE, 0, 0, 0),
    .border_width = .edges(1, 0, 0, 0),
    .border_color = .{ .color = DIVIDER },
};
/// A detail pane's row: label column, then controls straight after.
pub const binding_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
/// A row's sides inside its hover highlight, so the label doesn't touch the highlight's edge.
pub const ROW_INSET = 6;
/// A shade past SURFACE; text boxes on a lit row keep their outline to stand out.
pub const ROW_HOVER = color("#212327");
const ROW_DIVIDER_SPACE = 8;

/// widgets.toggleSwitch's track; the switch slides its knob across by SWITCH_TRAVEL itself.
pub const switch_off: Style = .{
    .width = .fixed(SWITCH_WIDTH),
    .height = .fixed(SWITCH_HEIGHT),
    .padding = .all(SWITCH_INSET),
    .justify = .start,
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .{ .fixed = SWITCH_HEIGHT / 2 },
    .hover = &.{ .border_color = .accent, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
    .transition = .{ .duration_ms = SWITCH_ANIMATION_MS },
};
pub const switch_on: Style = switch_off.with(.{
    .background = .accent,
    .border_color = .accent,
});
pub const switch_knob_off: Style = .{
    .width = .fixed(SWITCH_KNOB),
    .height = .fixed(SWITCH_KNOB),
    .background = .{ .color = TEXT_SECONDARY },
    .radius = .{ .fixed = SWITCH_KNOB / 2 },
    .transition = .{ .duration_ms = SWITCH_ANIMATION_MS },
};
pub const switch_knob_on: Style = switch_knob_off.with(.{ .background = .{ .color = INK_DARK } });
pub const SWITCH_ANIMATION_MS = 200;
/// How far the knob moves from off to on.
pub const SWITCH_TRAVEL = SWITCH_WIDTH - 2 * SWITCH_INSET - SWITCH_KNOB;
const SWITCH_WIDTH = 30;
const SWITCH_HEIGHT = 16;
const SWITCH_INSET = 2;
const SWITCH_KNOB = SWITCH_HEIGHT - 2 * SWITCH_INSET;

pub const slider_box: Style = .{ .width = .grow(), .padding = .xy(8, 0) };
/// Fixed, so it doesn't share the row's spare width with a growing label.
pub const slider_box_aligned: Style = .{ .width = .fixed(220), .padding = .xy(8, 0) };
/// Narrower, to fit beside its label in a detail pane's field group.
pub const slider_box_grouped: Style = slider_box_aligned.with(.{ .width = .fixed(140) });

pub const segmented: Style = .{
    .direction = .row,
    .gap = 2,
    .padding = .all(2),
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
};
pub const segment: Style = .{
    // Inside segmented's 2px padding, so the whole control is as tall as an input.
    .height = .fixed(CONTROL_HEIGHT - 4),
    .padding = .xy(10, 0),
    .background = .transparent,
    // The control's radius less its padding, so the corners nest.
    .radius = .{ .fixed = 4 },
    .hover = &.{ .background = .{ .color = SURFACE_ALT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const segment_selected: Style = segment.with(.{
    .background = .accent,
    .hover = &.{ .state_layer = 0 },
});
/// Set on the label itself: knots' button label otherwise takes the theme's on-accent ink, which the accent can wash out.
pub const segment_label: Style = .{
    .foreground = .{ .color = TEXT_SECONDARY },
    .hover = &.{ .foreground = .{ .color = TEXT } },
};
pub const segment_label_selected: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = INK_DARK } };

pub const number_input: Style = .{
    .width = .fixed(80),
    .font = FONT_MONO,
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(8, 4),
    .background = .{ .color = SURFACE },
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
    .hover = &.{ .border_color = .accent },
    .focus = &.{ .border_color = .accent },
};
/// A number box with its unit inside, e.g. "85 %": this field draws the box, around unit_field_input and the unit.
pub const unit_field: Style = .{
    .width = .fixed(64),
    .height = .fixed(CONTROL_HEIGHT),
    .direction = .row,
    .@"align" = .center,
    .padding = .init(0, 8, 0, 0),
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
};
pub const unit_field_focused: Style = unit_field.with(.{ .border_color = .accent });
pub const unit_field_input: Style = number_input.with(.{
    .width = .grow(),
    .padding = .init(4, 2, 4, 8),
    .background = .transparent,
    .border_width = .zero,
});

/// No fill: the track is one colour either side of the thumb.
pub const slider_track: Style = .{ .height = .fixed(6), .background = .{ .color = BORDER }, .radius = .md };
pub const slider_fill: Style = .{ .background = .{ .color = BORDER } };
/// knots grows the knob and draws a halo around it on hover and drag, both scaled from this width, so it's kept small.
pub const slider_thumb: Style = .{ .width = .fixed(12), .background = .accent };

pub const slider_value: Style = .{ .width = .fixed(48), .font = FONT_MONO, .foreground = .{ .color = TEXT_SECONDARY } };

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
pub const checkbox_label: Style = .{ .foreground = .{ .color = TEXT } };
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
/// color_picker_swatch's colour, filling it inside its 1px border, with the corners nested in its own.
pub const color_swatch_fill: Style = .{ .width = .fixed(CONTROL_HEIGHT - 2), .height = .fixed(CONTROL_HEIGHT - 2), .radius = .{ .fixed = 5 } };
/// A picker drawn without its hex: just the swatch, centred. Its popup still has a hex box.
pub const color_picker_swatch: Style = color_picker.with(.{
    .width = .fixed(CONTROL_HEIGHT),
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .all(0),
    .justify = .center,
});
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
    .background = .{ .color = CHROME },
    .border_width = .edges(1, 0, 0, 0),
    .border_color = .{ .color = DIVIDER },
};

/// wordmark.svg at 96px high.
pub const wordmark: Style = .{ .width = .fixed(269), .height = .fixed(96) };

/// A bold lead-in inside a hint, e.g. "Version:".
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

/// One of three equal columns, as the credits list them.
pub const thanks_name: Style = .{ .width = .grow(), .font_size = .xs, .foreground = .{ .color = MUTED } };

/// #profile-header.
pub const header: Style = .{
    .width = .grow(),
    .height = .fixed(44),
    .direction = .row,
    .@"align" = .center,
    .gap = 8,
    .padding = .xy(12, 8),
    .background = .{ .color = CHROME },
    .border_width = .edges(0, 0, 1, 0),
    .border_color = .{ .color = DIVIDER },
};

pub const app_mark: Style = .{ .width = .fixed(18), .height = .fixed(18) };
pub const app_name: Style = .{ .font = FONT_SEMIBOLD, .font_size = .md, .foreground = .{ .color = TEXT } };

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
    .radius = .md,
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

/// A plain button: surface fill, accent border on hover.
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

/// Not scrolled, unlike knots' default panel: its wrapped text can measure a fraction over the panel and show a scrollbar.
pub const modal: Style = .{
    .width = .fixed(360),
    .gap = 12,
    .overflow = .visible,
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
/// primary_button for a destructive action: outlined in red at rest, filled on hover.
pub const danger_primary_button: Style = primary_button.with(.{
    .border_color = .{ .color = DESTRUCTIVE },
    .foreground = .{ .color = DESTRUCTIVE },
    .hover = &.{ .background = .{ .color = DESTRUCTIVE_FILL_HOVER }, .border_color = .{ .color = DESTRUCTIVE_FILL_HOVER }, .foreground = .{ .color = WHITE }, .state_layer = 0 },
});

fn color(comptime hex: []const u8) Color {
    return Color.hex(hex) catch unreachable;
}

pub const muted_text: Style = .{ .foreground = .{ .color = MUTED } };

/// Stands in on a preview for each character's or system's own colour while a "unique colors" setting is on.
pub const UNIQUE_SAMPLE: u32 = 0xFF5EC9C9;

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

/// openGroup's column.
pub const group: Style = .{ .width = .grow(), .direction = .column, .gap = 8 };
pub const group_fill: Style = group.with(.{ .height = .grow() });
/// openInlineGroup's run of controls within a row.
pub const group_inline: Style = .{ .direction = .row, .@"align" = .center, .gap = 8 };
/// Strong enough that a lit switch under the veil reads as off.
const GROUP_VEIL_ALPHA = 0.7;
/// Veils a disabled group and takes its clicks; knots' opacity wouldn't fade the children's boxes and borders.
pub const group_blocker: Style = .{
    .position = .absolute,
    .offset = .{ 0, 0 },
    .padding = .all(0),
    .background = .{ .color = .{ .value = .{ PANEL.value[0], PANEL.value[1], PANEL.value[2], GROUP_VEIL_ALPHA } } },
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

/// Centres a Placement tab screen preview in its section.
pub const screen_map_row: Style = .{ .width = .grow(), .direction = .row, .justify = .center };
/// Laid over a monitor on a screen preview, centring its number; ScreenMap.show sets its offset and size.
pub const monitor_label: Style = .{ .position = .absolute, .justify = .center, .@"align" = .center };
pub const monitor_label_text: Style = .{ .font_size = .{ .px = 13 }, .foreground = .{ .color = MUTED } };

/// #overlayLayoutStage's frame: a 1px border, centred in its section.
pub const stage_frame: Style = .{
    .padding = .all(1),
    .background = .{ .color = BORDER },
    .radius = .md,
    .overflow = .hidden,
};
pub const stage_row: Style = .{ .width = .grow(), .justify = .center };

/// A thumbnail space's colour in the roster; the roster sets its colour.
pub const space_dot: Style = .{ .width = .fixed(10), .height = .fixed(10), .radius = .{ .fixed = 2 } };
/// A space's Holds grid of hotkey group pills; the dialog sets its rows.
pub const group_chip_grid: Style = .{ .width = .grow(), .direction = .grid, .gap = 6 };
pub const GROUP_CHIP_HEIGHT = 26;
/// A hotkey group's pill; the held ones are filled with the accent.
pub const group_chip: Style = .{
    .justify = .center,
    .@"align" = .center,
    .padding = .xy(8, 0),
    .overflow = .hidden,
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .{ .fixed = GROUP_CHIP_HEIGHT / 2 },
    .hover = &.{ .border_color = .accent, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const group_chip_held: Style = group_chip.with(.{ .background = .accent, .border_color = .accent });
pub const group_chip_label: Style = .{ .foreground = .{ .color = TEXT_SECONDARY } };
pub const group_chip_label_held: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = INK_DARK } };

/// A text overlay's tag on the stage; the stage sets its offset, and outlines the selected one.
pub const overlay_chip: Style = .{
    .position = .absolute,
    .direction = .row,
    .@"align" = .center,
    .gap = 5,
    .padding = .xy(5, 3),
    .background = .accent,
    .border_width = .all(1),
    .border_color = .accent,
    .radius = .{ .fixed = 3 },
    .hover = &.{ .border_color = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const overlay_chip_label_box: Style = .{};
pub const overlay_chip_label: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = INK_DARK } };
/// Laid across the label while its overlay is off; the stage sets its width and height position.
pub const overlay_chip_strike: Style = .{
    .position = .absolute,
    .height = .fixed(1),
    .background = .{ .color = INK_DARK },
};
pub const overlay_chip_glyph: Style = .{ .width = .fixed(12), .height = .fixed(12) };

/// An icon button with a text glyph, e.g. × to clear a region.
pub const icon_button_danger_text: Style = icon_button.with(.{
    .foreground = .{ .color = MUTED },
    .font_size = .{ .px = 15 },
    .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .{ .color = DESTRUCTIVE }, .foreground = .{ .color = DESTRUCTIVE }, .state_layer = 0 },
});
pub const icon_button_disabled_text: Style = icon_button_disabled.with(.{ .font_size = .{ .px = 15 } });
pub const icon_button_confirm: Style = confirm_button.with(.{ .width = .fixed(CONTROL_HEIGHT), .padding = .all(0), .justify = .center });

/// .master-detail outside a filling tab: a roster beside the selected item's details, both sized to their content.
pub const master_detail: Style = .{ .width = .grow(), .direction = .row, .gap = 8 };
/// A master-detail filling the rest of its section, for a tab that fills the window.
pub const master_detail_fill: Style = master_detail.with(.{ .height = .grow() });
/// A filling roster, at roster_filters' width.
pub const roster_wide: Style = roster.with(.{ .width = .fixed(WIDE_ROSTER_WIDTH) });
pub const roster_filters: Style = roster.with(.{ .width = .fixed(WIDE_ROSTER_WIDTH), .height = .fit(), .overflow = .visible });
const WIDE_ROSTER_WIDTH = 195;
pub const detail_fit: Style = .{ .width = .grow(), .direction = .column, .gap = 8, .padding = .init(0, 0, 0, 8) };
/// .roster-hotkey-badge, e.g. a filter's Disabled.
pub const roster_badge: Style = .{ .font_size = .{ .px = 10 }, .foreground = .{ .color = MUTED } };
pub const roster_badge_warning: Style = roster_badge.with(.{ .foreground = .accent });
pub const inline_label: Style = .{ .foreground = .{ .color = TEXT } };
pub const select_fill: Style = select.with(.{ .width = .grow() });

/// A field hint with a link after it.
pub const hint_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 4 };
pub const hint_inline: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED }, .wrap = true };

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
/// Several labelled controls on one line.
pub const inline_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
/// .placeholder-chips: small buttons that insert a {placeholder}, at the right edge like an aligned row's controls.
pub const chip_row: Style = .{ .width = .grow(), .direction = .row, .justify = .end, .padding = .xy(ROW_INSET, 0) };
/// As wide as a custom text box and its clear button, so the chips start under the box.
pub const chip_box: Style = .{ .width = .fixed(CUSTOM_TEXT_WIDTH + 8 + CONTROL_HEIGHT), .direction = .row, .gap = 4, .wrap = true };
/// A notification's custom text box: wider than an even split with its short state label.
pub const custom_text_input: Style = text_input.with(.{ .width = .fixed(CUSTOM_TEXT_WIDTH) });
const CUSTOM_TEXT_WIDTH = 190;
pub const placeholder_chip: Style = plain_button.with(.{ .height = .fixed(22), .padding = .xy(6, 0), .font_size = .xs });
/// widgets.boxedText's box around path_text, clipping a long file name so the row's buttons stay in view.
pub const path_box: Style = .{ .width = .{ .kind = .fit, .max = 110 }, .overflow = .hidden };
pub const path_text: Style = .{ .foreground = .{ .color = TEXT } };
pub const path_text_empty: Style = .{ .foreground = .{ .color = MUTED } };

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
/// A roster row with the drop line above or below it while another is dragged.
/// Square on the side without the line: a rounded corner there leaks accent pixels.
/// .detail-value: a read-only value in a detail form, e.g. the file an import reads.
pub const detail_value: Style = .{ .width = .grow(), .foreground = .{ .color = TEXT_SECONDARY } };

/// widgets.openMarkedBinding's label and mark, outside aligned rows.
pub const label_cell: Style = .{ .direction = .row, .@"align" = .center, .gap = 8 };
/// .binding-dir: the arrow marking a pair's half.
pub const binding_arrow: Style = .{ .width = .fixed(14), .foreground = .{ .color = MUTED } };

/// .hkgroup-tab-add: the roster's own add button, under its rows.
pub const roster_add: Style = .{
    .width = .grow(),
    .justify = .start,
    .padding = .xy(6, 6),
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .radius = .md,
    .hover = &.{ .background = .{ .color = SURFACE }, .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
/// A roster footer's icon-only button, sized to its glyph.
pub const roster_icon_button: Style = roster_add.with(.{ .width = .fit(), .justify = .center });
/// .hkgroup-chars-list: a group's members, each a draggable row.
pub const members_list: Style = .{ .width = .grow(), .direction = .column, .gap = 4 };
pub const member_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 6, .border_width = .edges(2, 0, 2, 0), .border_color = .transparent };
/// A member row lifted by a drag: padded so its contents clear the lifted outline.
pub const member_row_lift: Style = member_row.with(.{ .padding = .xy(4, 2) });
/// Laid over a row's own style while it's dragged, raised under the cursor; ReorderList sets its width and place.
pub const lifted_row: Style = .{
    .position = .absolute,
    .background = .{ .color = SURFACE_ALT },
    .border_width = .all(1),
    .border_color = .accent,
    .radius = .md,
    .hover = &.{ .background = .{ .color = SURFACE_ALT }, .state_layer = 0 },
};
/// Where a dragged row would land; ReorderList sets its height.
pub const reorder_gap: Style = .{ .width = .grow(), .background = .{ .color = SURFACE }, .radius = .md };

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

/// .modal-content.modal-wide: room for the Import dialog's lists, scrolling once they outgrow the window.
pub const modal_wide: Style = modal.with(.{ .width = .fixed(520), .overflow = .scroll_y });

/// Modal text that sits on a line with something after it, e.g. a link.
pub const modal_text_inline: Style = .{ .foreground = .{ .color = TEXT_SECONDARY } };
