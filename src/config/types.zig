//! Enums used by settings; their tag names are saved in profiles, so renaming a tag breaks existing profiles.
const fonts = @import("../platform/fonts.zig");

/// Kept with the other setting types, though defined where platform/ can use it.
pub const FontWeight = fonts.FontWeight;

pub const BorderStyle = enum {
    Solid,
    Dashed,
    Dotted,
    Double,
    DiagonalHatch,
    DashDot,
    CornerBrackets,
};

/// The overlay on characters excluded from hotkey cycling.
pub const ExclusionOverlayStyle = enum {
    X,
    DiagonalSlash,
    DiagonalHatch,
    Checkerboard,
    SolidTint,
    CircleSlash,
    None,
};

/// For restoring and minimizing clients.
pub const AnimationStyle = enum {
    NoAnimation,
    OriginalAnimation,
};

pub const ClickTrigger = enum {
    MouseDown,
    MouseUp,
};

/// System cursor shown while hovering a thumbnail; `Default` leaves the window class's arrow in place.
pub const HoverCursor = enum {
    Default,
    Hand,
    Crosshair,
    Move,
    Help,
};

pub const TextPosition = enum {
    TopLeft,
    TopCenter,
    TopRight,
    LeftCenter,
    Center,
    RightCenter,
    BottomLeft,
    BottomCenter,
    BottomRight,
};

/// What the Map Panel's markers show; saved into profiles by name.
pub const MapMetric = enum { Security, ShipKills, NpcKills, Jumps };
/// Which side of the Map Panel the Intel Panel sits on.
pub const PanelSide = enum { Left, Right };

/// In the order the Display tab offers them.
pub const ViewMode = enum {
    Thumbnails,
    ClientList,
    /// The list follows the thumbnails' colours and auto-hide rather than its own.
    ThumbnailsAndList,
    Nothing,

    pub fn showsThumbnails(self: ViewMode) bool {
        return switch (self) {
            .Thumbnails, .ThumbnailsAndList => true,
            .ClientList, .Nothing => false,
        };
    }

    pub fn showsClientList(self: ViewMode) bool {
        return switch (self) {
            .ClientList, .ThumbnailsAndList => true,
            .Thumbnails, .Nothing => false,
        };
    }
};

pub const ListViewOrder = enum {
    Tracked,
    Alphabetical,
    ConfiguredCharacters,
};

pub const ListIndicatorStyle = enum {
    Dot,
    Square,
    None,
};

/// How thumbnails get their position: dragged by hand, or filled into thumbnail spaces.
pub const PlacementMode = enum {
    Manual,
    ThumbnailSpaces,
};

/// A thumbnail space's fill order: configured character list, or grouped by hotkey group membership.
pub const RegionFitOrder = enum {
    Characters,
    HotkeyGroups,
};

/// A thumbnail space's fill direction.
pub const RegionFitDirection = enum {
    RowFirst_LTR_TTB,
    RowFirst_RTL_TTB,
    RowFirst_LTR_BTT,
    RowFirst_RTL_BTT,
    ColumnFirst_TTB_LTR,
    ColumnFirst_TTB_RTL,
    ColumnFirst_BTT_LTR,
    ColumnFirst_BTT_RTL,
};

/// The app's language, in the configuration window and on-screen hints; each has its own file in src/lang/.
pub const Language = enum { en, de, es, fr, pl, pt, ru };
