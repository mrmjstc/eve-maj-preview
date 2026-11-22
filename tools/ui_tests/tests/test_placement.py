"""Where thumbnails go and how big they are."""

import time

from harness import ALPHA, BRAVO, CHARLIE, check, covers, scaled


@covers("ThumbnailConfig.width", "ThumbnailConfig.height")
def test_thumbnails_take_the_profile_size_scaled_for_dpi(session):
    session.use()
    session.start_client(ALPHA)
    window = session.wait_for_thumbnails({ALPHA})[ALPHA].window
    expected = (scaled(240, window.scale), scaled(135, window.scale))
    check(abs(window.width - expected[0]) <= 1 and abs(window.height - expected[1]) <= 1,
          f"size {window.width}x{window.height}, expected {expected[0]}x{expected[1]}")


@covers("DisplayConfig.startX", "DisplayConfig.startY", "DisplayConfig.newThumbnailSpacing")
def test_unplaced_thumbnails_line_up_from_the_start_position(session):
    session.use()
    names = (ALPHA, BRAVO, CHARLIE)
    session.start_clients(*names)
    thumbnails = session.wait_for_thumbnails(set(names))
    scale = next(iter(thumbnails.values())).window.scale
    step = scaled(240, scale) + scaled(10, scale)
    expected = {(scaled(100, scale) + i * step, scaled(100, scale)) for i in range(len(names))}
    # Let any late layout pass settle before reading positions.
    time.sleep(0.5)
    actual = {(t.window.left, t.window.top) for t in session.thumbnails().values()}
    check(actual == expected, f"positions {sorted(actual)}, expected {sorted(expected)}")


@covers("CharacterConfig.position")
def test_a_saved_position_is_used_and_others_still_start_the_row(session):
    session.use({"characters": [{"name": ALPHA, "position": {"x": 700, "y": 400}}]})
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    time.sleep(0.5)
    thumbnails = session.thumbnails()
    alpha, bravo = thumbnails[ALPHA].window, thumbnails[BRAVO].window
    check((alpha.left, alpha.top) == (700, 400), f"Alpha at {(alpha.left, alpha.top)}, expected its saved (700, 400)")
    start = (scaled(100, bravo.scale), scaled(100, bravo.scale))
    check((bravo.left, bravo.top) == start, f"Bravo at {(bravo.left, bravo.top)}, expected the row's first slot {start}")


@covers("DisplayConfig.honorSavedPositions")
def test_saved_positions_are_ignored_when_not_honored(session):
    session.use({"display": {"honorSavedPositions": False}, "characters": [{"name": ALPHA, "position": {"x": 700, "y": 400}}]})
    session.start_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    time.sleep(0.5)
    alpha = session.thumbnails()[ALPHA].window
    start = (scaled(100, alpha.scale), scaled(100, alpha.scale))
    check((alpha.left, alpha.top) == start, f"Alpha at {(alpha.left, alpha.top)}, expected the row's first slot {start}")


@covers("DisplayConfig.placementMode", "ThumbnailSpace.groups", "ThumbnailSpace.x", "ThumbnailSpace.y",
        "ThumbnailSpace.width", "ThumbnailSpace.height", "ThumbnailSpace.enabled")
def test_a_thumbnail_space_fits_its_group_inside_the_region_without_overlap(session):
    region = {"x": 100, "y": 100, "width": 600, "height": 200}
    session.use({
        "display": {"placementMode": "ThumbnailSpaces"},
        "hotkeyGroups": [{"name": "Fleet", "characters": [ALPHA, BRAVO, CHARLIE]}],
        "thumbnailSpaces": [{"name": "Fleet Space", "enabled": True, "groups": ["Fleet"], "spacing": 10, **region}],
    })
    session.start_clients(ALPHA, BRAVO, CHARLIE)
    session.wait_for_thumbnails({ALPHA, BRAVO, CHARLIE})
    time.sleep(0.5)
    windows = [t.window for t in session.thumbnails().values()]
    right, bottom = region["x"] + region["width"], region["y"] + region["height"]
    for w in windows:
        check(w.left >= region["x"] and w.top >= region["y"] and w.right <= right and w.bottom <= bottom,
              f"'{w.title}' at ({w.left}, {w.top})-({w.right}, {w.bottom}) is outside the region")
    for i, first in enumerate(windows):
        for second in windows[i + 1:]:
            check(not first.overlaps(second), f"'{first.title}' and '{second.title}' overlap")
    check(len({(w.width, w.height) for w in windows}) == 1, f"sizes differ: {[(w.width, w.height) for w in windows]}")
    aspect = windows[0].width / windows[0].height
    check(abs(aspect - 240 / 135) < 0.05, f"aspect {aspect:.3f} isn't the profile's 16:9")
