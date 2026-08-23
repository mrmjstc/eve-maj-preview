const std = @import("std");
const log = @import("log.zig");
const slog = log.scoped("state");

pub const VisibilityState = enum {
    Visible,
    /// Auto-hidden via hideWhenNoEveFocus; can be auto-shown again.
    HiddenAutomatic,
    /// Persists until the user manually toggles it again.
    HiddenManual,

    pub fn canTransitionTo(self: VisibilityState, next: VisibilityState) bool {
        return switch (self) {
            .Visible => true,
            .HiddenAutomatic => next == .Visible or next == .HiddenManual,
            .HiddenManual => next == .Visible or next == .HiddenAutomatic,
        };
    }

    pub fn isVisible(self: VisibilityState) bool {
        return self == .Visible;
    }
};

pub const ThumbnailState = enum {
    Inactive,
    Active,
    Hover,
    Alert,
    Minimized,
    Dragging,
    Hidden,

    pub fn canTransitionTo(self: ThumbnailState, next: ThumbnailState) bool {
        return switch (self) {
            .Inactive => true,
            .Active => true,
            .Hover => next != .Minimized,
            .Alert => true,
            .Minimized => next != .Hover,
            .Dragging => next != .Hover and next != .Hidden,
            .Hidden => next != .Dragging,
        };
    }

    /// Whether this thumbnail state can coexist with hidden visibility.
    pub fn canBeHidden(self: ThumbnailState) bool {
        return switch (self) {
            .Active, .Inactive, .Minimized => true,
            .Hover, .Alert, .Dragging, .Hidden => false,
        };
    }
};

/// Returns error.InvalidStateTransition if the transition isn't allowed.
pub fn transitionState(
    current: ThumbnailState,
    next: ThumbnailState,
    context_name: []const u8,
) !ThumbnailState {
    if (!current.canTransitionTo(next)) {
        slog.warn("Invalid state transition for '{s}': {} -> {}", .{
            context_name,
            current,
            next,
        });
        return error.InvalidStateTransition;
    }

    return next;
}

/// Like transitionState, but returns `current` instead of erroring on an invalid transition.
pub fn tryTransitionState(
    current: ThumbnailState,
    next: ThumbnailState,
    context_name: []const u8,
) ThumbnailState {
    return transitionState(current, next, context_name) catch current;
}

/// Returns error.InvalidVisibilityTransition if the transition isn't allowed.
pub fn transitionVisibility(
    current: VisibilityState,
    next: VisibilityState,
    context_name: []const u8,
) !VisibilityState {
    if (!current.canTransitionTo(next)) {
        slog.warn("Invalid visibility transition for '{s}': {} -> {}", .{
            context_name,
            current,
            next,
        });
        return error.InvalidVisibilityTransition;
    }

    if (current != next) {
        slog.debug("Visibility transition for '{s}': {} -> {}", .{
            context_name,
            current,
            next,
        });
    }

    return next;
}

/// Like transitionVisibility, but returns `current` instead of erroring on an invalid transition.
pub fn tryTransitionVisibility(
    current: VisibilityState,
    next: VisibilityState,
    context_name: []const u8,
) VisibilityState {
    return transitionVisibility(current, next, context_name) catch current;
}
