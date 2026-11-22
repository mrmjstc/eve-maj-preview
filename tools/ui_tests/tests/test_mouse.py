"""Clicking, dragging and hovering thumbnails with the real mouse."""

import ctypes
import time

from harness import (ALPHA, BRAVO, VK_CONTROL, VK_F13, VK_SHIFT, WS_EX_TRANSPARENT, check, covers, current_cursor,
                     extended_style, stays, system_cursor, wait_for)

GHOST = "Ghost Pilot"
# Thumbnails start here, away from every screen edge, so only the snapping under test can apply.
START = {"startX": 600, "startY": 400}


def use(session, profile: dict | None = None):
    profile = dict(profile or {})
    profile["display"] = {**START, **profile.get("display", {})}
    session.use(profile)
    session.park_cursor()


def start(session, *names: str):
    session.start_clients(*names)
    session.wait_for_thumbnails(set(names))
    time.sleep(0.3)


def top_left(session, name: str) -> tuple[int, int]:
    window = session.thumbnails()[name].window
    return window.left, window.top


def lands_at(session, name: str, expected: tuple[int, int]):
    wait_for(f"{name} at {expected}", lambda: top_left(session, name) == expected, timeout_s=2.0,
             details=lambda: top_left(session, name))


# Clicks

@covers("InteractionConfig.clickTrigger")
def test_a_click_activates_on_press_or_on_release_as_set(session):
    for trigger, on_press in (("MouseDown", True), ("MouseUp", False)):
        use(session, {"interaction": {"clickTrigger": trigger}})
        start(session, ALPHA, BRAVO)
        session.switch_to(BRAVO)
        session.mouse_down(*session.thumbnails()[ALPHA].window.point(0.5, 0.5))
        try:
            if on_press:
                session.wait_for_foreground(ALPHA)
            else:
                stays(f"{trigger}: Bravo to keep focus while the button is down", lambda: session.foreground_client() == BRAVO, 0.5)
        finally:
            session.mouse_up()
        session.wait_for_foreground(ALPHA)


@covers("ExclusionConfig.enableShiftClickExclude")
def test_shift_click_toggles_the_clients_exclusion(session):
    use(session)
    start(session, ALPHA, BRAVO)
    session.switch_to(BRAVO)
    session.click_thumbnail(ALPHA, modifiers=(VK_SHIFT,))
    wait_for("Alpha to be excluded", lambda: session.excluded() == [ALPHA], details=session.excluded)
    check(session.foreground_client() == BRAVO, "shift-click also activated Alpha")
    session.click_thumbnail(ALPHA, modifiers=(VK_SHIFT,))
    wait_for("Alpha to be included again", lambda: session.excluded() == [], details=session.excluded)


def test_shift_click_activates_when_exclusion_by_click_is_off(session):
    use(session, {"exclusion": {"enableShiftClickExclude": False}})
    start(session, ALPHA, BRAVO)
    session.switch_to(BRAVO)
    session.click_thumbnail(ALPHA, modifiers=(VK_SHIFT,))
    session.wait_for_foreground(ALPHA)
    check(session.excluded() == [], f"shift-click excluded {session.excluded()}")


@covers("InteractionConfig.clickThrough")
def test_click_through_passes_the_click_to_the_window_beneath(session):
    use(session, {"interaction": {"clickThrough": True}})
    alpha, bravo = session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    thumbnail = session.thumbnails()[ALPHA].window
    check(bool(extended_style(thumbnail.hwnd) & WS_EX_TRANSPARENT), "Alpha's thumbnail isn't click-through")
    # Bravo's own window sits under Alpha's thumbnail and Alpha's window is out of the way, so the click lands on Bravo.
    alpha.move(1600, 900)
    bravo.move(thumbnail.left - 50, thumbnail.top - 50)
    session.switch_to(ALPHA)
    session.click_thumbnail(ALPHA)
    session.wait_for_foreground(BRAVO)


# Hovering

@covers("InteractionConfig.hoverCursor")
def test_each_hover_cursor_shows_over_a_thumbnail(session):
    for name in ("Hand", "Crosshair", "Move", "Help", "Default"):
        use(session, {"interaction": {"hoverCursor": name}})
        start(session, ALPHA)
        session.hover(ALPHA)
        wait_for(f"the {name} cursor", lambda: current_cursor() == system_cursor(name), timeout_s=2.0)


def zoom_window(session):
    windows = session.extra_thumbnail_windows()
    return windows[0] if windows else None


@covers("InteractionConfig.hoverZoomEnabled", "InteractionConfig.hoverZoomPercent")
def test_hover_zoom_shows_an_enlarged_copy_at_the_set_size(session):
    use(session, {"interaction": {"hoverZoomEnabled": True, "hoverZoomPercent": 150}})
    start(session, ALPHA)
    base = session.thumbnails()[ALPHA].window
    session.hover(ALPHA)
    zoom = wait_for("the hover zoom", lambda: zoom_window(session))
    expected = (base.width * 150 // 100, base.height * 150 // 100)
    check(abs(zoom.width - expected[0]) <= 1 and abs(zoom.height - expected[1]) <= 1,
          f"zoom is {zoom.width}x{zoom.height}, expected {expected[0]}x{expected[1]}")
    session.park_cursor()
    wait_for("the hover zoom to close once the cursor leaves", lambda: zoom_window(session) is None)


def test_hover_zoom_is_off_by_default(session):
    use(session)
    start(session, ALPHA)
    session.hover(ALPHA)
    stays("no hover zoom", lambda: zoom_window(session) is None, 1.0)


@covers("InteractionConfig.hoverZoomAnchor")
def test_the_zoom_anchor_sets_which_point_stays_put(session):
    for anchor in ("TopLeft", "Center", "BottomRight"):
        use(session, {"interaction": {"hoverZoomEnabled": True, "hoverZoomPercent": 200, "hoverZoomAnchor": anchor}})
        start(session, ALPHA)
        base = session.thumbnails()[ALPHA].window
        session.hover(ALPHA)
        zoom = wait_for(f"{anchor}: the hover zoom", lambda: zoom_window(session))
        expected = {
            "TopLeft": (base.left, base.top),
            "Center": (base.left - base.width // 2, base.top - base.height // 2),
            "BottomRight": (base.right - zoom.width, base.bottom - zoom.height),
        }[anchor]
        check(abs(zoom.left - expected[0]) <= 1 and abs(zoom.top - expected[1]) <= 1,
              f"{anchor}: zoom at ({zoom.left}, {zoom.top}), expected {expected}")
        session.park_cursor()


# Dragging

@covers("InteractionConfig.enableDragging")
def test_dragging_moves_the_thumbnail_and_saves_its_position(session):
    use(session)
    start(session, ALPHA)
    session.drag_thumbnail(ALPHA, (900, 700))
    lands_at(session, ALPHA, (900, 700))
    saved = lambda: next((c.get("position") for c in session.read_profile().get("characters", []) if c["name"] == ALPHA), None)
    wait_for("the new position to be saved", lambda: saved() == {"x": 900, "y": 700}, details=saved)


def test_dragging_can_be_turned_off(session):
    use(session, {"interaction": {"enableDragging": False}})
    start(session, ALPHA)
    before = top_left(session, ALPHA)
    session.drag_thumbnail(ALPHA, (900, 700))
    stays("Alpha to stay put", lambda: top_left(session, ALPHA) == before, 0.5, details=lambda: top_left(session, ALPHA))


@covers("HotkeysConfig.hotkeyToggleDragging")
def test_the_toggle_dragging_key_turns_dragging_off(session):
    use(session, {"hotkeys": {"hotkeyToggleDragging": f"0x{VK_F13:02X}"}})
    start(session, ALPHA)
    session.switch_to(ALPHA)
    session.press(VK_F13)
    time.sleep(0.3)
    before = top_left(session, ALPHA)
    session.drag_thumbnail(ALPHA, (900, 700))
    stays("Alpha to stay put", lambda: top_left(session, ALPHA) == before, 0.5, details=lambda: top_left(session, ALPHA))


def test_a_thumbnail_in_a_space_cant_be_dragged(session):
    use(session, {"display": {"placementMode": "ThumbnailSpaces"},
                  "hotkeyGroups": [{"name": "Fleet", "characters": [ALPHA]}],
                  "thumbnailSpaces": [{"name": "Fleet Space", "enabled": True, "groups": ["Fleet"], "x": 600, "y": 400, "width": 400, "height": 300}]})
    start(session, ALPHA)
    before = top_left(session, ALPHA)
    session.drag_thumbnail(ALPHA, (1200, 800))
    stays("Alpha to stay in its space", lambda: top_left(session, ALPHA) == before, 0.5, details=lambda: top_left(session, ALPHA))


def test_dragging_with_ctrl_moves_every_thumbnail_together(session):
    use(session, {"snapping": {"enabled": False}})
    start(session, ALPHA, BRAVO)
    alpha_before, bravo_before = top_left(session, ALPHA), top_left(session, BRAVO)
    session.drag_thumbnail(ALPHA, (alpha_before[0] + 60, alpha_before[1] + 40), modifiers=(VK_CONTROL,))
    lands_at(session, ALPHA, (alpha_before[0] + 60, alpha_before[1] + 40))
    lands_at(session, BRAVO, (bravo_before[0] + 60, bravo_before[1] + 40))


# Snapping: each test drags to a few pixels off what it should snap to.

@covers("SnappingConfig.enabled", "SnappingConfig.screenEdges")
def test_a_drag_near_the_screen_edge_snaps_onto_it(session):
    for snapping, expected_y in (({}, 0), ({"enabled": False}, 4), ({"screenEdges": False}, 4)):
        use(session, {"snapping": snapping})
        start(session, ALPHA)
        session.drag_thumbnail(ALPHA, (900, 4))
        lands_at(session, ALPHA, (900, expected_y))


def saved_bravo(**snapping) -> dict:
    return {"snapping": {"ghostPositions": False, **snapping}, "characters": [{"name": BRAVO, "position": {"x": 1200, "y": 600}}]}


@covers("SnappingConfig.thumbnailEdges", "SnappingConfig.threshold")
def test_a_drag_near_another_thumbnail_snaps_to_its_edge(session):
    for snapping, snaps in (({}, True), ({"thumbnailEdges": False}, False), ({"threshold": 3}, False)):
        use(session, saved_bravo(**snapping))
        start(session, ALPHA, BRAVO)
        bravo = session.thumbnails()[BRAVO].window
        session.drag_thumbnail(ALPHA, (bravo.right + 5, bravo.top + 20))
        lands_at(session, ALPHA, (bravo.right if snaps else bravo.right + 5, bravo.top + 20))


@covers("SnappingConfig.panelEdges")
def test_a_drag_near_a_panel_snaps_to_its_edge(session):
    for snapping, snaps in (({}, True), ({"panelEdges": False}, False)):
        use(session, {"display": {"viewMode": "ThumbnailsAndList"}, "listView": {"x": 1200, "y": 600},
                      "snapping": {"ghostPositions": False, "thumbnailEdges": False, **snapping}})
        start(session, ALPHA)
        session.switch_to(ALPHA)
        panel = wait_for("the client list", lambda: (lambda w: w[0] if w else None)(session.app_windows("EVE_LIST_CLASS")))
        session.drag_thumbnail(ALPHA, (panel.right + 5, panel.top + 10))
        x = top_left(session, ALPHA)[0]
        # The panel's visible edge can sit a few pixels inside its window rect, so snapping lands within that.
        if snaps:
            check(abs(x - panel.right) <= 8 and x != panel.right + 5, f"Alpha at x={x}, expected snapped to the panel's edge near {panel.right}")
        else:
            check(x == panel.right + 5, f"Alpha at x={x}, expected unsnapped at {panel.right + 5}")


def ghost_profile(**snapping) -> dict:
    return {"snapping": {"thumbnailEdges": False, **snapping}, "characters": [{"name": GHOST, "position": {"x": 1200, "y": 700}}]}


@covers("SnappingConfig.ghostPositions")
def test_a_drag_near_a_saved_position_docks_onto_it(session):
    for snapping, expected in (({}, (1200, 700)), ({"ghostPositions": False}, (1206, 704))):
        use(session, ghost_profile(**snapping))
        start(session, ALPHA)
        session.drag_thumbnail(ALPHA, (1206, 704))
        lands_at(session, ALPHA, expected)


@covers("SnappingConfig.showGhostPositionBorders")
def test_saved_positions_show_outlines_while_dragging(session):
    for shows in (True, False):
        use(session, ghost_profile(showGhostPositionBorders=shows))
        start(session, ALPHA)
        seen = []
        session.drag_thumbnail(ALPHA, (900, 700), while_held=lambda: seen.append(bool(session.app_windows("EVE_GHOST_OVERLAY_CLASS"))))
        check(seen == [shows], f"showGhostPositionBorders={shows}: outlines {'shown' if seen[0] else 'hidden'} mid-drag")


def minimize_animation() -> int:
    """Windows' own minimize-animation setting (SPI_GETANIMATION)."""
    info = (ctypes.c_uint * 2)(8, 0)
    ctypes.windll.user32.SystemParametersInfoW(0x0048, 8, info, 0)
    return info[1]


def test_minimizing_without_animation_leaves_the_windows_setting_as_it_was(session):
    before = minimize_animation()
    use(session, {"interaction": {"animationStyle": "NoAnimation"}})
    start(session, ALPHA, BRAVO)
    session.protocol("evemajpreview://hotkey/minimize_all")
    wait_for("both clients to be minimized", lambda: all(c.window().is_minimized for c in session.clients.values()))
    time.sleep(0.3)
    check(minimize_animation() == before, f"the Windows minimize animation is {minimize_animation()}, was {before}")
