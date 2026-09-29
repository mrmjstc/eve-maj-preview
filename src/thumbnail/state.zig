//! A thumbnail's visibility, and the state that picks its look.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("state");

pub const VisibilityState = enum {
    visible,
    /// Auto-hidden via hideWhenNoEveFocus; can be auto-shown again.
    hidden_automatic,
    /// Persists until the user manually toggles it again.
    hidden_manual,

    pub fn canTransitionTo(self: VisibilityState, next: VisibilityState) bool {
        return switch (self) {
            .visible => true,
            .hidden_automatic => next == .visible or next == .hidden_manual,
            .hidden_manual => next == .visible or next == .hidden_automatic,
        };
    }

    pub fn isVisible(self: VisibilityState) bool {
        return self == .visible;
    }
};

/// Used purely as a style-lookup key (config.zig's getStateConfig) - never persisted per-thumbnail; see ThumbnailWindow.effectiveRenderState.
pub const ThumbnailState = enum {
    inactive,
    active,
    alert,
    minimized,
    dragging,
};

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
