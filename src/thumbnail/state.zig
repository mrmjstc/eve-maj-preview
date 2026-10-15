//! Whether a thumbnail is shown, or hidden by hand or automatically, and which state's style it draws with.
const std = @import("std");
const thumbnail = @import("../config/thumbnail.zig");

const ThumbnailState = thumbnail.ThumbnailState;

/// What the focus auto-hide decides from.
pub const FocusHide = struct {
    is_enabled: bool,
    is_eve_focused: bool,
};

/// What decides a thumbnail's state style.
pub const RenderFacts = struct {
    is_dragged: bool,
    has_alert: bool,
    is_focused: bool,
    is_minimized: bool,
};

pub const VisibilityState = enum {
    visible,
    /// Auto-hidden via hideWhenNoEveFocus; can be auto-shown again.
    hidden_automatic,
    /// Persists until the user manually toggles it again.
    hidden_manual,

    pub fn isVisible(self: VisibilityState) bool {
        return self == .visible;
    }

    /// Hidden only while the auto-hide is on and no EVE client has focus; one hidden by hand stays hidden.
    pub fn afterAutoHide(self: VisibilityState, focus: FocusHide) VisibilityState {
        if (self == .hidden_manual) return self;
        return if (focus.is_enabled and !focus.is_eve_focused) .hidden_automatic else .visible;
    }
};

/// A drag outranks an alert, which outranks focus, which outranks being minimized.
pub fn renderState(facts: RenderFacts) ThumbnailState {
    if (facts.is_dragged) return .dragging;
    if (facts.has_alert) return .alert;
    if (facts.is_focused) return .active;
    if (facts.is_minimized) return .minimized;
    return .inactive;
}

const testing = std.testing;

test "the auto-hide hides a visible thumbnail once no EVE client has focus" {
    try testing.expectEqual(VisibilityState.hidden_automatic, VisibilityState.visible.afterAutoHide(.{ .is_enabled = true, .is_eve_focused = false }));
}

test "regaining EVE focus shows an auto-hidden thumbnail" {
    try testing.expectEqual(VisibilityState.visible, VisibilityState.hidden_automatic.afterAutoHide(.{ .is_enabled = true, .is_eve_focused = true }));
}

test "turning the auto-hide off shows an auto-hidden thumbnail" {
    try testing.expectEqual(VisibilityState.visible, VisibilityState.hidden_automatic.afterAutoHide(.{ .is_enabled = false, .is_eve_focused = false }));
}

test "a thumbnail hidden by hand stays hidden whatever the focus or auto-hide" {
    for ([_]bool{ false, true }) |is_enabled| {
        for ([_]bool{ false, true }) |is_eve_focused| {
            try testing.expectEqual(VisibilityState.hidden_manual, VisibilityState.hidden_manual.afterAutoHide(.{ .is_enabled = is_enabled, .is_eve_focused = is_eve_focused }));
        }
    }
}

test "a dragged thumbnail draws as dragging even with an alert and focus" {
    try testing.expectEqual(ThumbnailState.dragging, renderState(.{ .is_dragged = true, .has_alert = true, .is_focused = true, .is_minimized = true }));
}

test "an alert outranks focus" {
    try testing.expectEqual(ThumbnailState.alert, renderState(.{ .is_dragged = false, .has_alert = true, .is_focused = true, .is_minimized = false }));
}

test "a focused client draws as active even if minimized" {
    try testing.expectEqual(ThumbnailState.active, renderState(.{ .is_dragged = false, .has_alert = false, .is_focused = true, .is_minimized = true }));
}

test "an unfocused client draws as minimized or inactive" {
    try testing.expectEqual(ThumbnailState.minimized, renderState(.{ .is_dragged = false, .has_alert = false, .is_focused = false, .is_minimized = true }));
    try testing.expectEqual(ThumbnailState.inactive, renderState(.{ .is_dragged = false, .has_alert = false, .is_focused = false, .is_minimized = false }));
}
