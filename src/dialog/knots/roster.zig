//! A master list's rows, each clicked to select what the details beside the list show; main thread only.
const ui = @import("ui");
const style = @import("style.zig");
const widgets = @import("widgets.zig");

const Button = ui.component.Button;
const Text = ui.component.Text;

/// A row keys its name as its own key indexed by this, clear of the index Button keys its label with.
const NAME_INDEX = 20;
/// Like NAME_INDEX, for the badge.
const BADGE_INDEX = 21;

/// Text after the name, e.g. a hotkey or a state.
pub const Badge = struct {
    /// Empty for none.
    text: []const u8 = "",
    text_style: *const ui.Style = &style.roster_badge,
};

/// Open from `open` until `close`; between them the caller draws what leads the name, e.g. a dot or portrait.
pub const Row = struct {
    button: Button,
    is_selected: bool,
    /// Clicked while another row was selected; the caller selects this one.
    is_picked: bool,

    /// `lifted_style` while it's being dragged, otherwise the roster's own.
    pub fn open(context: *ui.Frame, key: ui.Key, is_selected: bool, lifted_style: ?*const ui.Style) !Row {
        const button = Button{ .key = key, .style = lifted_style orelse rowStyle(is_selected) };
        const is_picked = (try widgets.openRosterRow(context, button)).clicked and !is_selected;
        if (is_picked) context.requestRedraw();
        return .{ .button = button, .is_selected = is_selected, .is_picked = is_picked };
    }

    /// Draws `name` and `badge`, then closes the row; `lead_width` is what the caller drew before them, 0 for nothing.
    pub fn close(self: Row, context: *ui.Frame, name: []const u8, lead_width: f32, badge: Badge) !void {
        const key = self.button.key;
        try context.e(Text{
            .selectable = false,
            .key = key.indexed(NAME_INDEX),
            .content = name,
            .style = if (self.is_selected) &style.roster_name_selected else &style.roster_name,
        });
        if (badge.text.len > 0) try context.e(Text{ .selectable = false, .key = key.indexed(BADGE_INDEX), .content = badge.text, .style = badge.text_style });
        try widgets.fitRosterRow(context, name, lead_width, badge.text);
        try self.button.close(context);
    }
};

/// What a dragged row's lifted style is built on.
pub fn rowStyle(is_selected: bool) *const ui.Style {
    return if (is_selected) &style.roster_row_selected else &style.roster_row;
}
