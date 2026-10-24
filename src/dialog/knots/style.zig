//! The configuration window's look: colours, sizes and every component's style.
const ui = @import("ui");
const fonts = @import("../../platform/fonts.zig");
const glyphs = @import("glyphs.zig");

const Color = ui.Color;
const Style = ui.Style;

/// The window's frame (save bar, title bar): the darkest layer.
pub const CHROME = color("#0b0c0d");
/// The content area behind the cards.
pub const BG = color("#111214");
/// Cards, modals and popovers: a step lighter than BG, so they stand out by shade rather than outline.
pub const PANEL = color("#18191c");
/// Modals, menus and popovers: a step above PANEL, so they stand off the cards under them.
pub const RAISED = color("#1e1f22");
pub const SURFACE = color("#2a2b2e");
/// A lit row: between PANEL and SURFACE, so the controls on it still stand out.
pub const ROW_HOVER = color("#242528");
pub const SURFACE_ALT = color("#2f3033");
pub const BORDER = color("#414245");
/// A card's outline: stronger than DIVIDER, so a card's edge outweighs the lines between its rows.
pub const CARD_BORDER = color("#2a2b2f");
/// Between rows inside a section: quieter than BORDER.
pub const DIVIDER = color("#2f3033");
pub const BORDER_STRONG = color("#6b6e75");
pub const TEXT = color("#e8e6e1");
pub const TEXT_SECONDARY = color("#c4c0b6");
pub const MUTED = color("#96948f");
/// Hints and intros: lighter than MUTED so small text stays readable, still a step under labels.
pub const HINT_TEXT = color("#aeaca7");
pub const DESTRUCTIVE = color("#d3673f");
pub const DESTRUCTIVE_FILL = color("#ad4527");
pub const DESTRUCTIVE_FILL_HOVER = color("#bb4f30");
pub const WHITE = color("#ffffff");
/// Text on the accent: dark on a light accent, light on a dark one.
pub const INK_DARK = color("#1a1408");
pub const INK_LIGHT = color("#f5f0e6");
pub const SUCCESS = color("#5ec98f");
pub const ERROR = color("#e05a4e");
/// Behind a hotkey whose combo conflicts.
pub const ERROR_TINT = color("#2a1614");
/// Around a text, number or select box at rest: quieter than BORDER_STRONG, so a page of boxes doesn't look busy.
pub const INPUT_BORDER = color("#36383d");
pub const INPUT_BORDER_HOVER = color("#4a4c52");
/// A plain button's fill, a step above the cards it sits on.
pub const BUTTON = color("#1f2024");
pub const BUTTON_HOVER = color("#26272c");
/// A switch's track while off.
pub const SWITCH_OFF = color("#33353a");
/// The chosen option of a segmented control: a neutral raised chip, since gold is kept for what's on.
pub const SEGMENT_CHOSEN = color("#2c2d32");
/// A colour swatch's faint edge, so a swatch the colour of the card still shows.
pub const SWATCH_EDGE: Color = .{ .value = .{ 1, 1, 1, 0.16 } };
pub const PURPLE = color("#a988d1");
pub const SKY = color("#7fb3d9");

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
    .elevated = .{ .hex = "#1e1f22" },
    .muted = .{ .hex = "#2a2b2e" },
    // The accent's hover shade; form.applyAccent sets both from the profile's accentColor.
    .accented = .{ .hex = "#e8b75f" },
    .inverted = .{ .hex = "#111214" },
    .text = .{ .hex = "#e8e6e1" },
    .highlighted = .{ .hex = "#e8e6e1" },
    .toned = .{ .hex = "#6b6e75" },
    .dimmed = .{ .hex = "#96948f" },
    .radius = 6,
    // Smallest first: labels, body text (the default, `sm`), headings, then two larger steps.
    .font_size = .{ 11, 12, 14, 16, 20 },
    .scrollbar_thickness = SCROLLBAR_THICKNESS,
    .scrollbar_min_thumb = 24,
    .scrollbar_track_color = .{ .hex = "#111214" },
    .scrollbar_thumb_color = .{ .hex = "#414245" },
    .scrollbar_thumb_hover_color = .{ .hex = "#6b6e75" },
    .scrollbar_corner_radius = SCROLLBAR_THICKNESS / 2,
});

pub const FONT_REGULAR = "regular";
pub const FONT_SEMIBOLD = "semibold";
pub const FONT_REGULAR_DATA = fonts.GEIST_REGULAR_DATA;
pub const FONT_SEMIBOLD_DATA = fonts.GEIST_SEMIBOLD_DATA;

pub const CONTROL_HEIGHT = 30;
/// How far a section's text and controls sit in from its card's sides.
const SECTION_EDGE = 12;
/// Between sections: wider than a section's own gaps, so the space does the grouping.
const SECTION_GAP = 18;
/// Around a tab's content; the scrollbar draws inside its right side, so cards don't shift when a tab scrolls.
const CONTENT_MARGIN = 12;
const SCROLLBAR_THICKNESS = 6;
/// Just clears the scrollbar, since a pane of rows already sits a row's inset inside them.
pub const ROW_SCROLLBAR_GUTTER = SCROLLBAR_THICKNESS + 2;
pub const LABEL_WIDTH = 190;

/// The card under a section's heading; its sides are a row's inset short of SECTION_EDGE, so a row's hover fill reaches past its text.
pub const section: Style = .{
    .width = .grow(),
    .direction = .column,
    .gap = 8,
    .padding = .xy(SECTION_EDGE - ROW_INSET, 8),
    .background = .{ .color = PANEL },
    .border_width = .all(1),
    .border_color = .{ .color = CARD_BORDER },
    .radius = .{ .fixed = CARD_RADIUS },
};
const CARD_RADIUS = 10;

/// A section that fills its tab, like the Characters list's.
pub const fill_section: Style = section.with(.{ .height = .grow() });

/// A section's heading and its card; widgets.openSection gives it the card's height.
pub const section_block: Style = .{ .width = .grow(), .direction = .column, .gap = 8 };
/// The heading and description over the card, flush with its edge.
pub const section_intro: Style = .{ .width = .grow(), .direction = .column, .gap = 2 };

/// The categories across the top, each an equal share of the width; its rule runs under them all.
pub const category_bar: Style = .{
    .width = .grow(),
    .direction = .row,
    .padding = .xy(12, 0),
    .border_width = .edges(0, 0, 1, 0),
    .border_color = .{ .color = DIVIDER },
};
/// Glyph over label; the open one is underlined in the accent.
pub const category_item: Style = .{
    .width = .grow(),
    .direction = .column,
    .@"align" = .center,
    .gap = 4,
    .padding = .init(8, 0, 7, 0),
    .background = .transparent,
    .border_width = .edges(0, 0, 2, 0),
    .border_color = .transparent,
    .hover = &.{ .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const category_item_active: Style = category_item.with(.{ .border_color = .accent });
pub const category_label: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = HINT_TEXT } };
pub const category_label_lit: Style = category_label.with(.{ .foreground = .{ .color = TEXT } });
pub const CATEGORY_ICON_SIZE = 20;
pub const category_icon: Style = .{ .width = .fixed(CATEGORY_ICON_SIZE), .height = .fixed(CATEGORY_ICON_SIZE) };
/// A 16px glyph, e.g. the save bar's check.
pub const icon_glyph: Style = .{ .width = .fixed(glyphs.ICON_SIZE), .height = .fixed(glyphs.ICON_SIZE) };

/// The open category's tabs, as pills.
pub const page_tabs: Style = .{ .width = .grow(), .direction = .row, .gap = 2, .padding = .init(10, 12, 2, 12) };
pub const page_tab: Style = .{
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(12, 0),
    .background = .transparent,
    .foreground = .{ .color = HINT_TEXT },
    .font = FONT_SEMIBOLD,
    .radius = .{ .fixed = CONTROL_HEIGHT / 2 },
    .hover = &.{ .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const page_tab_active: Style = page_tab.with(.{ .background = .{ .color = SURFACE }, .foreground = .{ .color = TEXT } });

/// The small capitals heading a menu's entries or a list's group.
pub const tab_category_text: Style = .{ .font = FONT_SEMIBOLD, .font_size = .xs, .foreground = .{ .color = MUTED } };
pub const tab_glyph: Style = .{ .width = .fixed(glyphs.TAB_SIZE), .height = .fixed(glyphs.TAB_SIZE) };

/// Pads the column's top and bottom, not the pane's, so the pane's height compares straight against it.
pub const content_scroll: ScrollPane = .{
    .pane = &content_scroll_pane,
    .scrolling = &content_scroll_pane,
    .content = &.{ .width = .grow(), .direction = .column, .gap = SECTION_GAP, .padding = .xy(0, CONTENT_MARGIN) },
};
const content_scroll_pane: Style = .{
    .width = .grow(),
    .height = .grow(),
    .direction = .column,
    .padding = .xy(CONTENT_MARGIN, 0),
    .overflow = .scroll_y,
};
/// The tab's content when the tab fills it itself.
pub const content_fill: Style = .{ .width = .grow(), .height = .grow(), .direction = .column, .gap = SECTION_GAP, .padding = .all(CONTENT_MARGIN) };

/// Fits Characters' Add Character and refresh buttons in English; widgets widens it for longer translations.
pub const ROSTER_WIDTH = 170;
pub const ROSTER_MAX_WIDTH = 240;
/// An inset well, darker than its section, rather than another bordered box.
pub const roster: Style = .{
    .width = .fixed(ROSTER_WIDTH),
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
/// The scrollbar draws over its pane, so the gutter keeps it off the rows' badges and markers.
pub const roster_scroll: ScrollPane = .{
    .pane = &roster_rows,
    .scrolling = &roster_rows.with(.{ .padding = .init(0, ROW_SCROLLBAR_GUTTER, 0, 0) }),
    .content = &roster_rows_fit,
};
/// A roster whose rows fit rather than scroll, so it never needs the gutter.
pub const roster_fit: ScrollPane = .{ .pane = &roster_rows_fit, .scrolling = &roster_rows_fit, .content = &roster_rows_fit };
/// Every master list's add buttons, under its rows; bordered buttons, so no rule above them.
pub const roster_footer: Style = .{
    .width = .grow(),
    .direction = .row,
    .@"align" = .center,
    .gap = 4,
    .padding = .init(4, 0, 0, 0),
};

/// A Button so the whole row is clickable.
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
/// widgets.openEmptyState: centred in the space a list and its details would fill.
pub const empty_state: Style = .{ .width = .grow(), .height = .grow(), .direction = .column, .justify = .center, .@"align" = .center, .gap = 8 };
pub const empty_state_actions: Style = .{ .direction = .row, .gap = 8, .padding = .init(8, 0, 0, 0) };
pub const roster_empty: Style = .{ .width = .grow(), .padding = .xy(8, 6) };
pub const roster_empty_text: Style = .{ .width = .grow(), .wrap = true, .font_size = .xs, .foreground = .{ .color = MUTED } };

/// A list item opened for editing in its place, set off from the rows around it.
pub const inline_editor: Style = .{
    .width = .grow(),
    .direction = .column,
    .gap = 8,
    .padding = .all(8),
    .background = .{ .color = BG },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER },
    .radius = .md,
};
/// Buttons at the foot of an inline_editor, at its right edge.
pub const inline_editor_actions: Style = .{ .width = .grow(), .direction = .row, .justify = .end, .gap = 8, .padding = .init(4, ROW_INSET, 0, ROW_INSET) };
/// inline_editor's name box and its actions.
pub const inline_editor_header: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8, .padding = .xy(ROW_INSET, 0) };
/// A list page's buttons, over its card at the right edge.
pub const list_toolbar: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
/// A card of whole-row buttons, inset less than section so a row's hover fill nearly reaches the card's edge.
pub const list_section: Style = section.with(.{ .padding = .all(4), .gap = 0 });
pub const list_rows: Style = .{ .width = .grow(), .direction = .column, .gap = 2 };
/// A list row that opens the item's page: lead, name and detail, then trailing badges and a chevron.
pub const list_item: Style = .{
    .width = .grow(),
    .justify = .start,
    .gap = 12,
    .padding = .init(8, 12, 8, 10),
    .background = .transparent,
    .radius = .md,
    .hover = &.{ .background = .{ .color = ROW_HOVER }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const list_item_text: Style = .{ .width = .grow(), .direction = .column, .gap = 2 };
pub const list_item_name: Style = .{ .width = .grow(), .font = FONT_SEMIBOLD, .foreground = .{ .color = TEXT } };
pub const list_item_detail: Style = .{ .width = .grow(), .font_size = .xs, .foreground = .{ .color = MUTED } };
/// list_item_detail with chips after it, so it only takes its text's width.
pub const list_item_detail_fit: Style = list_item_detail.with(.{ .width = .fit() });
/// A list row's second line: its detail text, then chips such as a character's groups.
pub const list_item_meta: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 6 };
pub const list_chip: Style = .{ .padding = .xy(7, 1), .background = .{ .color = SURFACE }, .radius = .{ .fixed = 9 } };
pub const list_chip_text: Style = .{ .font_size = .xs, .foreground = .{ .color = TEXT_SECONDARY } };
pub const list_item_chevron: Style = .{ .font_size = .lg, .foreground = .{ .color = BORDER_STRONG } };
const LIST_PORTRAIT_SIZE = 32;
pub const list_portrait: Style = .{ .width = .fixed(LIST_PORTRAIT_SIZE), .height = .fixed(LIST_PORTRAIT_SIZE), .radius = .md };
pub const list_portrait_box: Style = .{ .width = .fixed(LIST_PORTRAIT_SIZE), .height = .fixed(LIST_PORTRAIT_SIZE) };
const PAGE_PORTRAIT_SIZE = 44;
pub const page_portrait: Style = .{ .width = .fixed(PAGE_PORTRAIT_SIZE), .height = .fixed(PAGE_PORTRAIT_SIZE), .radius = .md };
pub const page_portrait_box: Style = .{ .width = .fixed(PAGE_PORTRAIT_SIZE), .height = .fixed(PAGE_PORTRAIT_SIZE) };
const ONLINE_DOT_SIZE = 10;
/// On a portrait's bottom-right corner while the character is logged in; ringed in the card's colour to cut it from the portrait.
pub const online_dot: Style = .{
    .position = .absolute,
    .offset = .{ LIST_PORTRAIT_SIZE - ONLINE_DOT_SIZE + 2, LIST_PORTRAIT_SIZE - ONLINE_DOT_SIZE + 2 },
    .width = .fixed(ONLINE_DOT_SIZE),
    .height = .fixed(ONLINE_DOT_SIZE),
    .background = .{ .color = SUCCESS },
    .border_width = .all(2),
    .border_color = .{ .color = PANEL },
    .radius = .{ .fixed = ONLINE_DOT_SIZE / 2 },
};
/// online_dot on a page's larger portrait, on the page's background rather than a card.
pub const page_online_dot: Style = online_dot.with(.{
    .offset = .{ PAGE_PORTRAIT_SIZE - ONLINE_DOT_SIZE + 2, PAGE_PORTRAIT_SIZE - ONLINE_DOT_SIZE + 2 },
    .border_color = .{ .color = BG },
});

/// Back from an item's page to its list.
pub const back_link: Style = .{
    .padding = .xy(2, 2),
    .background = .transparent,
    .foreground = .{ .color = HINT_TEXT },
    .font = FONT_SEMIBOLD,
    .radius = .sm,
    .hover = &.{ .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
/// An item page's portrait or icon, its name, then its own actions.
pub const page_header: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 14, .padding = .xy(2, 0) };
pub const page_title: Style = .{ .width = .grow(), .font = FONT_SEMIBOLD, .font_size = .lg, .foreground = .{ .color = TEXT } };

/// widgets.dragHandle: no fill of its own, so it reads as part of its row.
pub const drag_handle: Style = .{
    .direction = .row,
    .@"align" = .center,
    .padding = .xy(2, 4),
    .background = .transparent,
    .radius = .sm,
    .hover = &.{ .background = .{ .color = SURFACE }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const DRAG_GRIP_SIZE = 12;
pub const drag_grip: Style = .{ .width = .fixed(DRAG_GRIP_SIZE), .height = .fixed(DRAG_GRIP_SIZE) };

/// A master-detail list's details: unboxed, since the section around it is already a card.
pub const detail_scroll: ScrollPane = .{
    .pane = &detail_scroll_pane,
    .scrolling = &detail_scroll_pane.with(.{ .padding = .init(0, ROW_SCROLLBAR_GUTTER, 0, 0) }),
    .content = &.{ .width = .grow(), .direction = .column, .gap = 8 },
};
const detail_scroll_pane: Style = .{
    .width = .grow(),
    .height = .grow(),
    .direction = .column,
    .overflow = .scroll_y,
};

/// Fits the longest detail label in English, e.g. Character Name; widgets widens it for a translation's longest word.
pub const DETAIL_LABEL_WIDTH = 96;
pub const DETAIL_LABEL_MAX_WIDTH = 150;
/// A master-detail pane's label column, narrower than label to leave its controls room.
pub const detail_label: Style = label.with(.{ .width = .fixed(DETAIL_LABEL_WIDTH) });
/// widgets.openFieldGroup's row: its label stays at the top beside a taller column.
pub const field_group: Style = .{ .width = .grow(), .direction = .row, .@"align" = .start, .gap = 8 };
/// Drops the label to line up with the first control's text, and insets it like a row's own label.
pub const field_group_label: Style = .{ .padding = .init(6, 0, 0, ROW_INSET) };
/// Short of detail_label by its rows' inset, so a group's row labels line up with plain detail rows' controls.
pub const field_group_label_text: Style = detail_label.with(.{ .width = .fixed(DETAIL_LABEL_WIDTH - ROW_INSET) });
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
    .padding = .xy(10, 4),
    .background = .{ .color = BG },
    .border_color = .{ .color = INPUT_BORDER },
    .radius = .md,
    .hover = &.{ .border_color = .{ .color = INPUT_BORDER_HOVER } },
    .focus = &.{ .border_color = .accent },
};

/// Fixed in an aligned row, like select and slider_box_aligned, so a growing label can't squeeze it.
pub const text_input_aligned: Style = text_input.with(.{ .width = .fixed(230) });
/// Around a folder path's box, so the box still takes the row's spare width.
pub const path_tooltip_trigger: Style = .{ .width = .grow() };
/// A row label's tooltip: wider than knots' 260, in its own colours since `.elevated` darkens inside a popover.
pub const row_tooltip: Style = .{
    .width = .{ .kind = .fit, .max = 360 },
    // Above the modal layer, like color_popup, or a disabled group's veil in a popover covers it.
    .layer = ui.Layer.fromIndex(ui.Layer.modal.z + 1),
    .background = .{ .color = CHROME },
    .border_color = .{ .color = BORDER },
    .foreground = .{ .color = TEXT },
};
/// Wider than knots' 260, so a full path rarely wraps.
pub const path_tooltip: Style = .{ .width = .{ .kind = .fit, .max = 480 } };

pub const heading: Style = .{ .font = FONT_SEMIBOLD, .font_size = .md, .foreground = .{ .color = TEXT } };
/// A section's heading over its card, in capitals (widgets.openSection capitalises it), quieter than the rows it heads.
pub const section_title: Style = .{ .font = FONT_SEMIBOLD, .font_size = .xs, .foreground = .{ .color = MUTED } };

/// Set apart by the space above it, not a rule; the row after it starts a new run with no divider.
pub const subheading_box: Style = .{ .width = .grow(), .padding = .init(16, ROW_INSET, 0, ROW_INSET) };
pub const subheading: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = TEXT } };
/// Inset like a row, for a section's content that isn't one, e.g. a table or a full-width button.
pub const inset_column: Style = .{ .width = .grow(), .direction = .column, .gap = 8, .padding = .xy(ROW_INSET, 0) };

/// No italics: Geist ships them as a separate face we don't embed.
pub const hint: Style = .{ .font_size = .xs, .foreground = .{ .color = HINT_TEXT }, .wrap = true, .width = .grow() };
/// Around a hint that goes with rows, so it starts where their labels do; knots ignores a Text's own padding.
pub const hint_box: Style = .{ .width = .grow(), .padding = .xy(ROW_INSET, 0) };
/// hint_box for a modal, whose rows aren't inset.
pub const modal_hint_box: Style = .{ .width = .grow() };
/// Inset like hint_box and pulled up into the gap after its row, since knots has no margins.
pub const hint_link_row: Style = hint_row.with(.{ .padding = .init(-HINT_LINK_PULL, ROW_INSET, 0, ROW_INSET) });
/// Less than any gap between rows, so the link row never overlaps the row above.
const HINT_LINK_PULL = 6;
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
/// notice with a button after its text.
pub const notice_with_button: Style = notice.with(.{ .direction = .row, .@"align" = .center, .gap = 12, .padding = .xy(10, 4) });
pub const notice_button: Style = plain_button.with(.{ .background = .transparent, .border_color = .accent, .foreground = .accent });

/// Flush with the section's heading, unlike hint_box.
pub const section_hint_box: Style = .{ .width = .grow() };

pub const label: Style = .{ .width = .fixed(LABEL_WIDTH), .wrap = true, .foreground = .{ .color = TEXT } };
/// Grows to push the row's controls to its right edge.
pub const label_aligned: Style = label.with(.{ .width = .grow() });
/// A row's label with its one-line description under it; widgets.rowLabel gives it the label's width.
pub const row_label_column: Style = .{ .direction = .column, .gap = 2, .padding = .xy(0, 6) };
pub const row_description: Style = .{ .width = .grow(), .wrap = true, .font_size = .xs, .foreground = .{ .color = MUTED } };
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
/// widgets.openWrappingBinding's row once its controls don't fit beside the label: they go under it, at the right edge.
pub const aligned_row_wrapped: Style = aligned_row.with(.{ .direction = .column, .@"align" = .end, .gap = 4 });
/// widgets.openStackedBinding's row: the label across the top, its controls across the row under it.
pub const aligned_row_stacked: Style = aligned_row.with(.{ .direction = .column, .@"align" = .start, .gap = 0 });
pub const row_controls_stacked: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8, .padding = .init(2, 0, 8, 0) };
/// Fits its content, so it measures the same beside the label or under it.
pub const row_controls: Style = .{ .width = .fit(), .direction = .row, .@"align" = .center };
/// Padding matches the section's gap, so the divider sits midway between rows.
pub const row_divider: Style = .{
    .width = .grow(),
    .padding = .init(ROW_DIVIDER_SPACE, 0, 0, 0),
    .border_width = .edges(1, 0, 0, 0),
    .border_color = .{ .color = DIVIDER },
};
/// row_divider for widgets.useCompactRows, matching popover's gap.
pub const row_divider_compact: Style = row_divider.with(.{ .padding = .init(COMPACT_GAP, 0, 0, 0) });
/// A detail pane's row: label column, then controls straight after.
pub const binding_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
/// A row's sides inside its hover highlight, so the label doesn't touch the highlight's edge.
pub const ROW_INSET = 6;
const ROW_DIVIDER_SPACE = 8;
/// Half ROW_DIVIDER_SPACE: a popover's gaps and its rows' divider space.
const COMPACT_GAP = 4;

/// widgets.toggleSwitch's track; the switch slides its knob across by SWITCH_TRAVEL itself.
pub const switch_off: Style = .{
    .width = .fixed(SWITCH_WIDTH),
    .height = .fixed(SWITCH_HEIGHT),
    .padding = .all(SWITCH_INSET),
    .justify = .start,
    .background = .{ .color = SWITCH_OFF },
    .border_width = .all(1),
    .border_color = .{ .color = SWITCH_OFF },
    .radius = .{ .fixed = SWITCH_HEIGHT / 2 },
    .hover = &.{ .border_color = .{ .color = INPUT_BORDER_HOVER }, .state_layer = 0 },
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
pub const SWITCH_TRAVEL = SWITCH_WIDTH - 2 * SWITCH_INSET - SWITCH_KNOB;
const SWITCH_WIDTH = 34;
const SWITCH_HEIGHT = 20;
const SWITCH_INSET = 3;
const SWITCH_KNOB = SWITCH_HEIGHT - 2 * SWITCH_INSET;

pub const slider_box: Style = .{ .width = .grow(), .padding = .xy(8, 0) };
/// Fixed, so it doesn't share the row's spare width with a growing label.
pub const slider_box_aligned: Style = .{ .width = .fixed(220), .padding = .xy(8, 0) };
/// Takes a field group row's spare width, since a detail pane may be too narrow for slider_box_aligned's.
pub const slider_box_grouped: Style = slider_box_aligned.with(.{ .width = .grow() });
/// Shorter, to fit a colour swatch after its % box.
pub const slider_box_short: Style = slider_box_aligned.with(.{ .width = .fixed(160) });

pub const segmented: Style = .{
    .direction = .row,
    .gap = 2,
    .padding = .all(2),
    .background = .{ .color = BG },
    .border_width = .all(1),
    .border_color = .{ .color = INPUT_BORDER },
    .radius = .md,
};
pub const segment: Style = .{
    // Inside segmented's 2px padding, so the whole control is as tall as an input.
    .height = .fixed(CONTROL_HEIGHT - 4),
    .padding = .xy(10, 0),
    .background = .transparent,
    // The control's radius less its padding, so the corners nest.
    .radius = .{ .fixed = 4 },
    .hover = &.{ .background = .{ .color = ROW_HOVER }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const segment_selected: Style = segment.with(.{
    .background = .{ .color = SEGMENT_CHOSEN },
    .hover = &.{ .state_layer = 0 },
});
/// Set on the label itself: knots' button label otherwise takes the theme's on-accent ink.
pub const segment_label: Style = .{
    .foreground = .{ .color = TEXT_SECONDARY },
    .hover = &.{ .foreground = .{ .color = TEXT } },
};
pub const segment_label_selected: Style = .{ .font = FONT_SEMIBOLD, .foreground = .{ .color = TEXT } };

/// Shared by number boxes with and without a unit inside, so their left edges line up; a unit box widens past it for a long unit.
pub const NUMBER_WIDTH = 64;
/// A unit box's room for its number and the box's own edges, which bind.openUnitField adds its unit's width to.
pub const UNIT_FIELD_NUMBER_ROOM = 48;
pub const number_input: Style = text_input.with(.{ .width = .fixed(NUMBER_WIDTH), .padding = .xy(8, 4) });
/// A number box with its unit inside, e.g. "85 %": this field draws the box, around unit_field_input and the unit.
pub const unit_field: Style = .{
    .width = .fixed(NUMBER_WIDTH),
    .height = .fixed(CONTROL_HEIGHT),
    .direction = .row,
    .@"align" = .center,
    .padding = .init(0, 8, 0, 0),
    .background = .{ .color = BG },
    .border_width = .all(1),
    .border_color = .{ .color = INPUT_BORDER },
    .radius = .md,
};
pub const unit_field_focused: Style = unit_field.with(.{ .border_color = .accent });
pub const unit_field_input: Style = number_input.with(.{
    .width = .grow(),
    .padding = .init(4, 2, 4, 8),
    .background = .transparent,
    .border_width = .zero,
});

/// The accent fills the track up to the thumb.
pub const slider_track: Style = .{ .height = .fixed(4), .background = .{ .color = SWITCH_OFF }, .radius = .md };
pub const slider_fill: Style = .{ .background = .accent };
/// knots grows the knob and draws a halo around it on hover and drag, both scaled from this width, so it's kept small.
pub const slider_thumb: Style = .{ .width = .fixed(14), .background = .{ .color = TEXT } };

pub const select: Style = .{
    .width = .fixed(230),
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(8, 4),
    .font_size = .sm,
    .background = .{ .color = BG },
    .border_color = .{ .color = INPUT_BORDER },
    .radius = .md,
    .hover = &.{ .border_color = .{ .color = INPUT_BORDER_HOVER } },
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
    .background = .{ .color = BG },
    .border_color = .{ .color = INPUT_BORDER },
    .radius = .md,
    .hover = &.{ .border_color = .{ .color = INPUT_BORDER_HOVER } },
};
pub const color_swatch: Style = .{ .width = .fixed(20), .height = .fixed(20) };
/// color_picker_swatch's colour, filling it inside its 1px border, with the corners nested in its own.
pub const color_swatch_fill: Style = .{ .width = .fixed(SWATCH_SIZE - 2), .height = .fixed(SWATCH_SIZE - 2), .radius = .{ .fixed = SWATCH_RADIUS - 1 } };
/// A picker drawn as just its swatch, centred, without the hex its popup still shows.
pub const color_picker_swatch: Style = color_picker.with(.{
    .width = .fixed(SWATCH_SIZE),
    .height = .fixed(SWATCH_SIZE),
    .padding = .all(0),
    .justify = .center,
    .background = .transparent,
    .border_color = .{ .color = SWATCH_EDGE },
    .radius = .{ .fixed = SWATCH_RADIUS },
    .hover = &.{ .border_color = .{ .color = TEXT_SECONDARY } },
});
const SWATCH_SIZE = 24;
const SWATCH_RADIUS = 6;
/// Above the modal layer, so a picker inside a prompt opens over it rather than under it.
pub const color_popup: Style = .{ .layer = ui.Layer.fromIndex(ui.Layer.modal.z + 1) };
/// Likewise for a dropdown's option list.
pub const select_popup: Style = .{ .layer = ui.Layer.fromIndex(ui.Layer.modal.z + 1) };

/// The save bar: the save state or last action's outcome, then Discard and Save.
pub const footer: Style = .{
    .width = .grow(),
    .direction = .row,
    .@"align" = .center,
    .gap = 8,
    .padding = .xy(16, 10),
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

/// The brand and profile button, on the content's background so they read as one block with the category bar.
pub const header: Style = .{
    .width = .grow(),
    .direction = .row,
    .@"align" = .center,
    .gap = 8,
    .padding = .init(12, 16, 8, 16),
};

pub const app_mark: Style = .{ .width = .fixed(26), .height = .fixed(26) };
pub const brand: Style = .{ .direction = .row, .@"align" = .center, .gap = 10 };
pub const brand_name: Style = .{ .font = FONT_SEMIBOLD, .font_size = .md, .foreground = .{ .color = TEXT } };

/// Opens the profile menu; as tall as the controls beside it.
pub const profile_button: Style = .{
    .width = .{ .kind = .fit, .min = 150 },
    .height = .fixed(CONTROL_HEIGHT),
    .justify = .start,
    .gap = 8,
    .padding = .xy(8, 0),
    .background = .{ .color = SURFACE },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
    .hover = &.{ .border_color = .accent, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const profile_button_open: Style = profile_button.with(.{ .border_color = .accent });
pub const profile_name: Style = .{ .width = .grow(), .foreground = .{ .color = TEXT } };
/// knots' select sizes its chevron to 10px at the dialog's text size.
pub const SELECT_CHEVRON_SIZE = 10;
pub const select_chevron: Style = .{ .width = .fixed(SELECT_CHEVRON_SIZE), .height = .fixed(SELECT_CHEVRON_SIZE) };
/// A profile's accent colour beside its name; the caller sets its colour.
pub const profile_swatch: Style = .{ .width = .fixed(10), .height = .fixed(10), .radius = .{ .fixed = 5 } };

pub const MENU_WIDTH = 260;
/// widgets.openMenu's panel.
pub const menu: Style = .{
    .width = .fixed(MENU_WIDTH),
    .gap = 2,
    .padding = .all(6),
    .background = .{ .color = RAISED },
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
};
/// The small heading over a menu's entries, lined up with their text.
pub const menu_caption: Style = .{ .width = .grow(), .padding = .init(6, 8, 4, 8) };
/// A menu entry: a Button, so the whole row is clickable.
pub const menu_item: Style = .{
    .width = .grow(),
    .justify = .start,
    .gap = 8,
    .padding = .xy(8, 7),
    .background = .transparent,
    .radius = .md,
    .hover = &.{ .background = .{ .color = SURFACE }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
/// The running profile, lit like a roster's selected row.
pub const menu_item_current: Style = menu_item.with(.{ .background = .{ .color = SURFACE_ALT }, .hover = &.{ .state_layer = 0 } });
pub const menu_item_disabled: Style = menu_item.with(.{ .hover = &.{ .state_layer = 0 } });
/// Around a disabled menu entry, so the tooltip saying why spans the whole entry.
pub const menu_item_tip: Style = .{ .width = .grow() };
pub const menu_label: Style = .{ .width = .grow(), .foreground = .{ .color = TEXT_SECONDARY } };
pub const menu_label_lit: Style = menu_label.with(.{ .foreground = .{ .color = TEXT } });
pub const menu_label_danger: Style = menu_label.with(.{ .foreground = .{ .color = DESTRUCTIVE } });
pub const menu_label_disabled: Style = menu_label.with(.{ .foreground = .{ .color = BORDER_STRONG } });
/// Around a separator between a menu's groups of entries.
pub const menu_divider: Style = .{ .width = .grow(), .padding = .xy(2, 4) };
pub const menu_glyph: Style = .{ .width = .fixed(glyphs.ICON_SIZE), .height = .fixed(glyphs.ICON_SIZE) };

/// Under a field whose value can't be used, saying why.
pub const field_error: Style = hint.with(.{ .foreground = .{ .color = ERROR } });
/// The accents offered beside the rainbow picker when naming a profile; the first is Config's default.
pub const ACCENT_PRESETS = [_]u32{ 0xFFD9A441, 0xFF5EC9C9, 0xFF7FB3D9, 0xFFA988D1, 0xFF5EC98F, 0xFFD3673F, 0xFFD97AA0 };
pub const accent_choices: Style = .{ .direction = .row, .@"align" = .center, .gap = 6 };
const ACCENT_RING_SIZE = 24;
const ACCENT_SWATCH_SIZE = 16;
/// Centres each accent choice so the rings line up; lit in the accent while chosen.
pub const accent_ring: Style = .{
    .width = .fixed(ACCENT_RING_SIZE),
    .height = .fixed(ACCENT_RING_SIZE),
    .justify = .center,
    .@"align" = .center,
    .border_width = .all(1),
    .border_color = .transparent,
    .radius = .md,
};
pub const accent_ring_chosen: Style = accent_ring.with(.{ .border_color = .accent });
/// A preset accent inside its ring; the caller sets its colour.
pub const accent_preset: Style = .{
    .width = .fixed(ACCENT_SWATCH_SIZE),
    .height = .fixed(ACCENT_SWATCH_SIZE),
    .padding = .all(0),
    .radius = .{ .fixed = 3 },
    .hover = &.{ .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
/// The picker for any other accent, drawn the size of a preset; it shows a rainbow rather than the colour.
pub const accent_custom: Style = color_picker.with(.{
    .width = .fixed(ACCENT_SWATCH_SIZE),
    .height = .fixed(ACCENT_SWATCH_SIZE),
    .padding = .all(0),
    .justify = .center,
    .border_width = .all(0),
    .radius = .{ .fixed = 3 },
});
pub const accent_custom_fill: Style = .{ .width = .fixed(ACCENT_SWATCH_SIZE), .height = .fixed(ACCENT_SWATCH_SIZE), .radius = .{ .fixed = 3 } };

/// A square plain button holding a drawn icon.
pub const icon_button: Style = plain_button.with(.{ .width = .fixed(CONTROL_HEIGHT), .padding = .all(0), .justify = .center });
pub const icon_button_disabled: Style = disabled_button.with(.{ .width = .fixed(CONTROL_HEIGHT), .padding = .all(0), .justify = .center });

pub const danger_button: Style = plain_button.with(.{
    .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .{ .color = DESTRUCTIVE }, .foreground = .{ .color = DESTRUCTIVE }, .state_layer = 0 },
});

pub const modal_actions: Style = .{ .width = .grow(), .direction = .row, .gap = 8, .justify = .end };

pub const status_info: Style = .{ .foreground = .{ .color = TEXT_SECONDARY } };
pub const status_success: Style = .{ .foreground = .{ .color = SUCCESS } };
pub const status_failure: Style = .{ .foreground = .{ .color = ERROR } };

/// The save bar's unsaved-changes dot and label: unboxed, so it reads as status rather than a button.
pub const unsaved_chip: Style = .{
    .direction = .row,
    .@"align" = .center,
    .gap = 6,
};
pub const unsaved_text: Style = .{ .foreground = .accent };
pub const unsaved_dot: Style = .{ .font_size = .xs, .foreground = .accent };

/// Quieter than a plain button until hovered, by its fill alone; its label matches every other button's.
pub const outline_button: Style = plain_button.with(.{
    .background = .transparent,
    .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .accent, .state_layer = 0 },
});

pub const plain_button: Style = .{
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(12, 0),
    .background = .{ .color = BUTTON },
    .border_width = .all(1),
    .border_color = .{ .color = INPUT_BORDER },
    .foreground = .{ .color = TEXT },
    .radius = .md,
    .hover = &.{ .background = .{ .color = BUTTON_HOVER }, .border_color = .{ .color = INPUT_BORDER_HOVER }, .state_layer = 0 },
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

/// Not scrolled: its wrapped text can measure a fraction over and show a scrollbar.
pub const modal: Style = .{
    .width = .fixed(360),
    .gap = 12,
    .overflow = .visible,
    .background = .{ .color = RAISED },
    .border_color = .{ .color = BORDER },
    .radius = .md,
};

/// Blurs the dialog behind on top of knots' dimming, so the modal reads as in front.
pub const modal_backdrop: Style = .{ .backdrop = .{ .blur = 3 } };

pub const modal_text: Style = .{ .foreground = .{ .color = TEXT_SECONDARY }, .wrap = true, .width = .grow() };

pub const primary_button: Style = .{
    .height = .fixed(CONTROL_HEIGHT),
    .padding = .xy(12, 0),
    .background = .transparent,
    .border_width = .all(1),
    .border_color = .accent,
    .foreground = .accent,
    .radius = .md,
    // Lit like a plain button rather than filled: thin dark text on the accent renders faint.
    .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .accented, .foreground = .accented, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
/// The save bar's Save: filled, unlike primary_button, and semibold so its dark label doesn't render faint.
pub const save_button: Style = primary_button.with(.{
    .padding = .xy(16, 0),
    .background = .accent,
    .foreground = .on_accent,
    .font = FONT_SEMIBOLD,
    .hover = &.{ .background = .accented, .border_color = .accented, .state_layer = 0 },
});
/// No outline until hovered, so it sits quieter than the Save beside it.
pub const ghost_button: Style = plain_button.with(.{
    .background = .transparent,
    .border_color = .transparent,
    .foreground = .{ .color = HINT_TEXT },
    .hover = &.{ .background = .{ .color = SURFACE }, .foreground = .{ .color = TEXT }, .state_layer = 0 },
});
pub const ghost_button_disabled: Style = ghost_button.with(.{ .foreground = .{ .color = BORDER_STRONG }, .hover = &.{ .state_layer = 0 } });
/// primary_button for a destructive action.
pub const danger_primary_button: Style = primary_button.with(.{
    .border_color = .{ .color = DESTRUCTIVE },
    .foreground = .{ .color = DESTRUCTIVE },
    .hover = &.{ .background = .{ .color = DESTRUCTIVE_FILL_HOVER }, .border_color = .{ .color = DESTRUCTIVE_FILL_HOVER }, .foreground = .{ .color = WHITE }, .state_layer = 0 },
});

pub const muted_text: Style = .{ .foreground = .{ .color = MUTED } };

/// Stands in on a preview for each character's or system's own colour while a "unique colors" setting is on.
pub const UNIQUE_SAMPLE: u32 = 0xFF5EC9C9;
/// How faded a preview's text is while it's turned off, so it can still be clicked to turn it back on.
pub const OFF_TEXT_OPACITY = 0.35;
/// An overlay text chip's outline at rest, so it reads as something to grab.
pub const CHIP_OUTLINE: Color = .{ .value = .{ 1, 1, 1, 0.3 } };
/// Behind a turned-off chip's text, so it reads over the preview image.
pub const CHIP_OFF_FILL: Color = .{ .value = .{ 0, 0, 0, 0.55 } };
/// The dashes of a turned-off chip's outline.
pub const CHIP_DASH_LENGTH = 3;

/// Wide enough for a text overlay's font, size, weight and colour beside their label.
pub const POPOVER_WIDTH = 436;
/// A Dialog panel used as a popover beside what it edits.
pub const popover: Style = .{
    .width = .fixed(POPOVER_WIDTH),
    .gap = COMPACT_GAP,
    .padding = .all(10),
    .background = .{ .color = RAISED },
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
};
/// Inset like a row's content, so the title and close button line up with the labels and controls below.
pub const popover_title: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .justify = .space_between, .padding = .xy(ROW_INSET, 0) };
pub const popover_close: Style = plain_button.with(.{ .width = .fixed(CONTROL_HEIGHT), .padding = .all(0), .justify = .center });

/// openGroup's column.
pub const group: Style = .{ .width = .grow(), .direction = .column, .gap = 8 };
/// openNestedGroup's column, indented under the setting it depends on.
pub const group_nested: Style = group.with(.{ .padding = .init(0, 0, 0, 20) });
/// widgets.openSectionsGroup's column.
pub const group_sections: Style = group.with(.{ .gap = SECTION_GAP });
/// openGroup's column under widgets.useCompactRows.
pub const group_compact: Style = group.with(.{ .gap = COMPACT_GAP });
/// openInlineGroup's run of controls within a row.
pub const group_inline: Style = .{ .direction = .row, .@"align" = .center, .gap = 8 };
/// Strong enough that the controls under the veil read as disabled.
const GROUP_VEIL_ALPHA = 0.7;
/// Veils a disabled group: knots' opacity wouldn't fade its children's boxes and borders.
pub const group_veil: Style = .{
    .position = .absolute,
    .offset = .{ 0, 0 },
    .padding = .all(0),
    .background = .{ .color = .{ .value = .{ PANEL.value[0], PANEL.value[1], PANEL.value[2], GROUP_VEIL_ALPHA } } },
    .radius = .none,
};

/// A remove button waiting for its second click.
pub const confirm_button: Style = plain_button.with(.{
    .background = .{ .color = DESTRUCTIVE_FILL },
    .border_color = .{ .color = DESTRUCTIVE_FILL_HOVER },
    .foreground = .{ .color = WHITE },
    .hover = &.{ .background = .{ .color = DESTRUCTIVE_FILL_HOVER }, .foreground = .{ .color = WHITE }, .state_layer = 0 },
});
pub const button_text: Style = .{ .foreground = .{ .color = TEXT } };
/// Lines up stacked buttons like Copy to All over Clear All; behavior.zig widens it for longer translations.
pub const PAIRED_BUTTON_WIDTH = 90;
pub const paired_button: Style = plain_button.with(.{ .width = .fixed(PAIRED_BUTTON_WIDTH), .justify = .center });
pub const paired_disabled_button: Style = disabled_button.with(.{ .width = .fixed(PAIRED_BUTTON_WIDTH), .justify = .center });
pub const paired_danger_button: Style = danger_button.with(.{ .width = .fixed(PAIRED_BUTTON_WIDTH), .justify = .center });
pub const paired_confirm_button: Style = confirm_button.with(.{ .width = .fixed(PAIRED_BUTTON_WIDTH), .justify = .center });
/// A button spanning its container, e.g. under a list.
pub const full_width_button: Style = plain_button.with(.{ .width = .grow() });
pub const button_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8, .padding = .xy(ROW_INSET, 0) };
/// button_row at the right edge, under its rows' controls.
pub const button_row_end: Style = button_row.with(.{ .justify = .end });
/// One item of a list, e.g. a system colour: its fields then a remove button.
pub const list_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8, .padding = .xy(ROW_INSET, 0) };
pub const list: Style = .{ .width = .grow(), .direction = .column, .gap = 8 };
/// widgets.emptyListRow's message, growing to push its add button to the right edge.
pub const empty_list_text: Style = .{ .width = .grow(), .wrap = true, .foreground = .{ .color = MUTED } };

/// Centres a Layout tab screen preview in its section.
pub const screen_map_row: Style = .{ .width = .grow(), .direction = .row, .justify = .center };
/// Laid over a monitor on a screen preview, centring its number and details; ScreenMap.show sets its offset and size.
pub const monitor_label: Style = .{ .position = .absolute, .direction = .column, .justify = .center, .@"align" = .center, .gap = 1 };
pub const monitor_label_text: Style = .{ .font_size = .{ .px = 13 }, .foreground = .{ .color = MUTED } };
/// A monitor's size and Primary under its number, a step quieter.
pub const monitor_detail_text: Style = .{ .font_size = .xs, .foreground = .{ .color = BORDER_STRONG } };

/// The thumbnail preview's frame: a 1px border, centred in its section.
pub const stage_frame: Style = .{
    .padding = .all(1),
    .background = .{ .color = BORDER },
    .radius = .md,
    .overflow = .hidden,
};
pub const stage_row: Style = .{ .width = .grow(), .justify = .center };

/// A thumbnail space's colour in the roster; the roster sets its colour.
pub const SPACE_DOT_SIZE = 10;
pub const space_dot: Style = .{ .width = .fixed(SPACE_DOT_SIZE), .height = .fixed(SPACE_DOT_SIZE), .radius = .{ .fixed = 2 } };
/// As tall as a text box, so the header doesn't jump between spaces.
pub const space_fixed_name: Style = .{ .width = .grow(), .height = .fixed(CONTROL_HEIGHT), .direction = .row, .@"align" = .center, .padding = .xy(8, 0) };
pub const space_fixed_name_text: Style = .{ .foreground = .{ .color = TEXT } };
/// Marks the built-in spaces; a radius of half its height makes it a pill.
pub const space_built_in_tag: Style = .{ .padding = .xy(8, 2), .border_width = .all(1), .border_color = .{ .color = BORDER_STRONG }, .radius = .{ .fixed = 9 } };
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

/// Wraps an overlay text's chip in its tooltip; the stage sets its place.
pub const overlay_text_trigger: Style = .{ .position = .absolute };
/// The stage sets its padding, background and outline from the overlay's settings.
pub const overlay_text: Style = .{
    .border_width = .all(1),
    .radius = .{ .fixed = 2 },
    .hover = &.{ .border_color = .accent, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};

/// An icon button with a text glyph, e.g. × to clear a region.
pub const icon_button_danger_text: Style = icon_button.with(.{
    .foreground = .{ .color = MUTED },
    .font_size = .{ .px = 15 },
    .hover = &.{ .background = .{ .color = SURFACE }, .border_color = .{ .color = DESTRUCTIVE }, .foreground = .{ .color = DESTRUCTIVE }, .state_layer = 0 },
});
/// An icon button whose icon is a character, e.g. a chevron.
pub const icon_button_text: Style = icon_button.with(.{ .font_size = .{ .px = 15 } });
pub const icon_button_disabled_text: Style = icon_button_disabled.with(.{ .font_size = .{ .px = 15 } });
pub const icon_button_confirm: Style = confirm_button.with(.{ .width = .fixed(CONTROL_HEIGHT), .padding = .all(0), .justify = .center });

/// Outside a filling tab: a roster beside the selected item's details, both sized to their content; only the roster side is inset, since the details' rows inset themselves.
pub const master_detail: Style = .{ .width = .grow(), .direction = .row, .gap = 8, .padding = .init(0, 0, 0, ROW_INSET) };
/// A master-detail filling the rest of its section, for a tab that fills the window.
pub const master_detail_fill: Style = master_detail.with(.{ .height = .grow() });
pub const roster_filters: Style = roster.with(.{ .height = .fit(), .overflow = .visible });
/// A roster in a scrolling tab whose rows scroll inside it, so adding one doesn't push it off the bottom.
pub const roster_fixed: Style = roster.with(.{ .height = .fixed(220) });
pub const detail_fit: Style = .{ .width = .grow(), .direction = .column, .gap = 8 };
/// A roster row's small trailing text, e.g. a filter's Disabled.
pub const roster_badge: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED } };
pub const roster_badge_warning: Style = roster_badge.with(.{ .foreground = .accent });
/// A heading over a run of list rows, its text lined up with theirs.
pub const list_category: Style = .{ .width = .grow(), .padding = .init(12, 10, 4, 10) };
/// An Event Alerts row: shorter than list_item, since it has no portrait or second line.
pub const event_item: Style = list_item.with(.{ .gap = 10, .padding = .init(7, 12, 7, 10) });
pub const event_name_off: Style = list_item_name.with(.{ .font = FONT_REGULAR, .foreground = .{ .color = MUTED } });
/// A list row's glyph after its name, e.g. an event's speech marker: the size of its square.
pub const ROSTER_MARKER_SIZE = 10;
pub const roster_marker: Style = .{ .width = .fixed(ROSTER_MARKER_SIZE), .height = .fixed(ROSTER_MARKER_SIZE) };
pub const inline_label: Style = .{ .foreground = .{ .color = TEXT } };
pub const select_fill: Style = select.with(.{ .width = .grow() });

/// A field hint with a link after it.
pub const hint_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 4 };
pub const hint_inline: Style = .{ .font_size = .xs, .foreground = .{ .color = HINT_TEXT } };

/// Bordered rows grouped by category, as the ore price table shows them.
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
    .padding = .xy(TABLE_INSET, 4),
    .gap = TABLE_COLUMN_GAP,
    .border_width = .edges(0, 0, 1, 0),
    .border_color = .{ .color = BORDER },
};
/// Two ores side by side, each a table_cell.
pub const table_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .padding = .xy(TABLE_INSET, 2), .gap = TABLE_COLUMN_GAP };
pub const table_cell: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
/// A full-width category heading over its ore rows.
pub const table_band: Style = .{ .width = .grow(), .padding = .xy(TABLE_INSET, 4), .background = .{ .color = SURFACE_ALT } };
pub const table_band_separated: Style = table_band.with(.{ .border_width = .edges(1, 0, 0, 0), .border_color = .{ .color = BORDER } });
pub const table_category_label: Style = .{ .font = FONT_SEMIBOLD, .font_size = .xs, .foreground = .{ .color = TEXT_SECONDARY } };
pub const table_name_cell: Style = .{ .width = .grow(), .font_size = .xs, .foreground = .{ .color = TEXT_SECONDARY } };
pub const table_heading_grow: Style = .{ .width = .grow(), .font = FONT_SEMIBOLD, .font_size = .xs, .foreground = .{ .color = TEXT } };
pub const table_heading_price: Style = .{ .width = .fixed(PRICE_INPUT_WIDTH), .font = FONT_SEMIBOLD, .font_size = .xs, .foreground = .{ .color = TEXT } };
pub const price_input: Style = number_input.with(.{ .width = .fixed(PRICE_INPUT_WIDTH), .height = .fixed(24) });
const PRICE_INPUT_WIDTH = 140;
/// The header's, bands' and rows' side padding, so their text starts on one edge.
const TABLE_INSET = 6;
/// Between the two ore columns, in the header and every row alike so they line up.
const TABLE_COLUMN_GAP = 24;

/// widgets.searchBox's box and clear button.
pub const search_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 4 };
/// Several labelled controls on one line.
pub const inline_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
/// Small buttons that insert a {placeholder}, at the right edge like an aligned row's controls.
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

/// Laid over a typed hotkey's box in an aligned row: wide enough for a long combo.
pub const hotkey_width_aligned: Style = .{ .width = .{ .kind = .fit, .min = 130 } };
/// Narrower, to fit beside its label in a detail pane's field group.
pub const hotkey_width_grouped: Style = .{ .width = .{ .kind = .fit, .min = 100 } };
pub const hotkey_prompt: Style = .{ .foreground = .{ .color = MUTED } };
/// One combo: its caps then its remove button, with no box, since caps already read as keys.
pub const hotkey_combo: Style = .{
    .direction = .row,
    .@"align" = .center,
    .gap = 3,
    .height = .fixed(CONTROL_HEIGHT - 4),
    .padding = .xy(6, 0),
    .background = .transparent,
    .radius = .md,
};
/// While hovered or focused, like a lit settings row.
pub const hotkey_combo_lit: Style = hotkey_combo.with(.{ .background = .{ .color = SURFACE } });
/// A Button, so the caps can be clicked or tabbed to and replaced.
pub const hotkey_caps: Style = .{
    .direction = .row,
    .@"align" = .center,
    .gap = 3,
    .padding = .all(0),
    .background = .transparent,
    .hover = &.{ .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
pub const HOTKEY_REMOVE_SIZE = 14;
/// How far the remove badge reaches past its combo's top-right corner.
pub const HOTKEY_REMOVE_OVERHANG = 3;
/// Removes one combo: a round badge laid over its corner, so it doesn't read as another key cap; the field sets its offset.
pub const hotkey_remove: Style = .{
    .position = .absolute,
    .width = .fixed(HOTKEY_REMOVE_SIZE),
    .height = .fixed(HOTKEY_REMOVE_SIZE),
    .padding = .all(0),
    .justify = .center,
    .font_size = .xs,
    .foreground = .{ .color = TEXT_SECONDARY },
    .background = .{ .color = SURFACE_ALT },
    .border_width = .all(1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .{ .fixed = HOTKEY_REMOVE_SIZE / 2 },
    .hover = &.{ .foreground = .{ .color = WHITE }, .background = .{ .color = DESTRUCTIVE_FILL }, .border_color = .{ .color = DESTRUCTIVE_FILL }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};
/// A hotkey's combos and buttons, at the row's right edge like an aligned row's controls; as tall as a control, so losing the + at the most combos a hotkey holds doesn't shrink the row.
pub const hotkey_row: Style = inline_row.with(.{ .justify = .end, .height = .{ .kind = .fit, .min = CONTROL_HEIGHT } });
/// hotkey_row in an aligned row, whose growing label already pushes it right.
pub const hotkey_row_fit: Style = hotkey_row.with(.{ .width = .fit() });
/// hotkey_row while a combo is typed in, so its box can fill a detail pane's row.
pub const hotkey_row_typing: Style = hotkey_row.with(.{ .justify = .start });
/// Around the + after a hotkey's combos: set further off than the row's gap, so it reads as an action rather than another combo.
pub const hotkey_add_gap: Style = .{ .padding = .init(0, 0, 0, 8) };
/// An empty hotkey's button: quieter than a plain button, since it stands in for keys not yet set.
pub const hotkey_set: Style = plain_button.with(.{
    .background = .transparent,
    .foreground = .{ .color = MUTED },
    .font_size = .xs,
    .hover = &.{ .background = .{ .color = BUTTON_HOVER }, .border_color = .{ .color = INPUT_BORDER_HOVER }, .foreground = .{ .color = TEXT }, .state_layer = 0 },
});
/// Between a hotkey's combos, since any one of them triggers it.
pub const hotkey_or: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED } };
pub const hotkey_edit_on: Style = icon_button.with(.{ .background = .{ .color = SUCCESS }, .border_color = .{ .color = SUCCESS } });
/// The heavier bottom edge reads as a key rather than a chip.
pub const keycap: Style = .{
    .padding = .init(3, 5, 3, 5),
    .background = .{ .color = SURFACE_ALT },
    .border_width = .edges(1, 1, 3, 1),
    .border_color = .{ .color = BORDER_STRONG },
    .radius = .md,
};
pub const keycap_text: Style = .{ .font_size = .xs, .foreground = .{ .color = TEXT } };
pub const keycap_modifier_text: Style = keycap_text.with(.{ .foreground = .{ .color = MUTED } });
/// A cap of a combo bound to something else too.
pub const keycap_conflict: Style = keycap.with(.{ .background = .{ .color = ERROR_TINT }, .border_color = .{ .color = ERROR } });
pub const keycap_conflict_text: Style = keycap_text.with(.{ .foreground = .{ .color = ERROR } });
pub const keycap_plus: Style = .{ .font_size = .xs, .foreground = .{ .color = MUTED } };

/// A plain button with widgets.glyphButton's glyph before its label, e.g. Add or Pick Running Window, at its natural width.
pub const add_button: Style = plain_button.with(.{ .gap = 6 });
/// The roster's own add button, add_button across its footer.
pub const roster_add: Style = add_button.with(.{ .width = .grow(), .justify = .center });
/// A group's members, each a draggable row.
pub const members_list: Style = .{ .width = .grow(), .direction = .column, .gap = 4 };
/// A group's members at their full height, since the page around them scrolls.
pub const members_fit: ScrollPane = .{ .pane = &members_list, .scrolling = &members_list, .content = &members_list };
/// A member's place in the cycle, before its portrait.
pub const member_number: Style = .{ .width = .fixed(14), .font_size = .xs, .foreground = .{ .color = MUTED } };
pub const member_portrait: Style = .{ .width = .fixed(22), .height = .fixed(22), .radius = .sm };
/// A group row's members' portraits, each overlapping the one before.
pub const portrait_stack: Style = .{ .direction = .row, .@"align" = .center, .gap = -6 };
/// Rings a stacked portrait in the card's colour, so the overlap reads as one in front of the other.
pub const portrait_stack_ring: Style = .{ .padding = .all(2), .background = .{ .color = PANEL }, .radius = .{ .fixed = 13 } };
pub const portrait_stack_image: Style = .{ .width = .fixed(22), .height = .fixed(22), .radius = .{ .fixed = 11 } };
pub const portrait_stack_more: Style = list_chip.with(.{ .padding = .xy(6, 3) });
/// Inset like a settings row, so its controls end where the rows' above do.
pub const member_row: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 6, .padding = .xy(ROW_INSET, 0), .border_width = .edges(2, 0, 2, 0), .border_color = .transparent };
/// The box and buttons under a group's members, inset like them.
pub const member_add_row: Style = inline_row.with(.{ .padding = .xy(ROW_INSET, 0) });
/// A member row lifted by a drag: padded so its contents clear the lifted outline.
pub const member_row_lift: Style = member_row.with(.{ .padding = .xy(ROW_INSET, 2) });
/// Over a dragged row's own style; ReorderList sets its width and place.
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
/// The settings search at the header's right: room for a 180px box, the gap and its clear button.
pub const search_container: Style = .{ .width = .fixed(180 + 4 + CONTROL_HEIGHT) };
pub const search_count_none: Style = .{ .foreground = .{ .color = ERROR } };
pub const search_count_some: Style = .{ .foreground = .accent };

/// Open clients' names offered under a name box.
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
    // Like a segment's hover, on suggest_list's SURFACE.
    .hover = &.{ .background = .{ .color = BORDER }, .foreground = .{ .color = TEXT }, .state_layer = 0 },
    .active = &.{ .state_layer = 0 },
};

/// The Import dialog's file line before a file is picked.
pub const import_file_none: Style = label_aligned.with(.{ .foreground = .{ .color = MUTED } });
/// Set apart by the space above it, like subheading_box.
pub const import_sections_heading: Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 12, .padding = .init(16, 0, 0, 0) };
/// The Import dialog's sections, two to a row.
pub const import_section_grid: Style = .{ .width = .grow(), .direction = .column, .gap = 6 };
/// import_section_grid under a group's checkbox, indented past it.
pub const import_section_grid_grouped: Style = import_section_grid.with(.{ .padding = .init(0, 0, 0, 20) });
pub const import_section_pair: Style = .{ .width = .grow(), .direction = .row, .gap = 8 };
pub const import_section_cell: Style = .{ .width = .grow() };
/// A group of the Import dialog's sections: its checkbox over its grid.
pub const import_section_group: Style = .{ .width = .grow(), .direction = .column, .gap = 6, .padding = .init(6, 0, 0, 0) };

/// Room for the Import dialog's lists and an update's notes, scrolling once they outgrow the window.
pub const modal_wide: Style = modal.with(.{ .width = .fixed(520), .overflow = .scroll_y });

/// Modal text that sits on a line with something after it, e.g. a link.
pub const modal_text_inline: Style = .{ .foreground = .{ .color = TEXT_SECONDARY } };

/// widgets.openScrollPane's looks: the pane, the pane with its scrollbar gutter, and the column inside it.
pub const ScrollPane = struct { pane: *const Style, scrolling: *const Style, content: *const Style };

fn color(comptime hex: []const u8) Color {
    return Color.hex(hex) catch unreachable;
}
