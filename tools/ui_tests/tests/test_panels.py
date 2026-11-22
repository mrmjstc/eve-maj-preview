"""The client list and the History, Map and Intel panels as windows: where they show, when, and how they drag and snap."""

from dataclasses import dataclass

from harness import (ALPHA, PANEL_HEADER_HEIGHT, VK_F13, backdrop, check, client_size, covers, extended_style, layered_alpha,
                     monitors, pixel, stays, wait_for)

WS_EX_TOPMOST = 0x00000008
KEY = VK_F13
# Away from every screen edge and from where thumbnails start, so only the snapping under test can apply.
AT = (700, 300)
# The map would otherwise reach out to ESI, EVE-Scout and zKillboard while it shows.
QUIET_MAP = {"liveStats": False, "showKills": False, "showAnsiblex": False}


@dataclass(frozen=True)
class Panel:
    kind: str
    section: str
    struct: str
    class_name: str
    has_show: bool
    is_sized: bool
    folds: bool
    hides_without_characters: bool
    is_native: bool
    toggle_hotkey: str | None


PANELS = [
    Panel("client_list", "listView", "ListViewConfig", "EVE_LIST_CLASS", has_show=False, is_sized=False, folds=True,
          hides_without_characters=False, is_native=False, toggle_hotkey=None),
    Panel("history", "historyPanel", "HistoryPanelConfig", "EVE_HISTORY_PANEL_CLASS", has_show=True, is_sized=True, folds=True,
          hides_without_characters=True, is_native=False, toggle_hotkey="hotkeyToggleNotificationHistory"),
    Panel("intel", "intelPanel", "IntelPanelConfig", "EVE_INTEL_PANEL_CLASS", has_show=True, is_sized=True, folds=True,
          hides_without_characters=True, is_native=False, toggle_hotkey="hotkeyToggleIntelPanel"),
    Panel("map", "mapPanel", "MapPanelConfig", "EVE_MAP_PANEL_CLASS", has_show=True, is_sized=True, folds=False,
          hides_without_characters=True, is_native=True, toggle_hotkey="hotkeyToggleMapPanel"),
]
HISTORY = PANELS[1]
INTEL = PANELS[2]


def key() -> str:
    return f"0x{KEY:02X}"


def profile_for(panel: Panel, shows: bool = True, **settings) -> dict:
    """A profile showing `panel`, at AT unless `settings` say otherwise, with nothing else that could hide it."""
    section = {"x": AT[0], "y": AT[1], **settings}
    profile: dict = {"mapPanel": dict(QUIET_MAP)}
    if panel.kind == "client_list":
        # Alone, so its own focus hiding applies rather than the thumbnails'.
        profile["display"] = {"viewMode": "ClientList" if shows else "Thumbnails"}
    else:
        section = {"show": shows, "hideWhenNoCharacters": False, **section}
        if panel.kind == "intel":
            section = {"attached": False, **section}
    profile[panel.section] = {**profile.get(panel.section, {}), **section}
    return profile


def open_panel(session, panel: Panel, with_client: bool = False, extra: dict | None = None, **settings):
    """Switches to a profile showing `panel` and waits for its window; the client list always needs a client to list."""
    profile = profile_for(panel, **settings)
    for name, value in (extra or {}).items():
        profile[name] = {**profile.get(name, {}), **value}
    session.use(profile)
    if with_client or panel.kind == "client_list":
        session.start_client(ALPHA)
        session.switch_to(ALPHA)
    return session.wait_for_panel_window(panel.class_name)


def window_of(session, panel: Panel):
    return session.panel_window(panel.class_name)


def no_window(session, panel: Panel, why: str, for_s: float = 1.5):
    stays(f"{why}: no {panel.kind} window", lambda: window_of(session, panel) is None, for_s)


def grab_point(panel: Panel, window) -> tuple[int, int]:
    """On the header, clear of its buttons: the title bar for the map, which has a normal frame."""
    if panel.is_native:
        return window.left + window.width // 2, window.top + 12
    return window.left + window.width * 35 // 100, window.top + PANEL_HEADER_HEIGHT // 2


def drag_panel(session, panel: Panel, window, by: tuple[int, int]):
    start = grab_point(panel, window)
    session.drag(start, (start[0] + by[0], start[1] + by[1]))


def make_place_test(panel: Panel):
    keys = ["x", "y"] + (["width", "height"] if panel.is_sized else ["columnWidth"])

    @covers(*(f"{panel.struct}.{k}" for k in keys))
    def test(session):
        size = {"width": 420, "height": 380} if panel.is_sized else {"columnWidth": 260}
        if panel.kind == "map":
            size = {"width": 640, "height": 420}
        window = open_panel(session, panel, x=820, y=340, **size)
        check((window.left, window.top) == (820, 340), f"{panel.kind} at ({window.left}, {window.top}), expected (820, 340)")
        if panel.is_native:
            measured, expected = client_size(window.hwnd), (size["width"], size["height"])
        elif panel.is_sized:
            measured, expected = (window.width, window.height), (size["width"], size["height"])
        else:
            measured, expected = window.width, size["columnWidth"]
        check(measured == expected, f"{panel.kind} is {measured}, expected {expected}")

    test.__name__ = f"test_the_{panel.kind}_takes_its_place_and_size"
    return test


def make_show_test(panel: Panel):
    @covers(f"{panel.struct}.show")
    def test(session):
        session.use(profile_for(panel, shows=False))
        no_window(session, panel, "show off")
        session.use(profile_for(panel, shows=True))
        session.wait_for_panel_window(panel.class_name)

    test.__name__ = f"test_the_{panel.kind}_shows_only_while_its_show_setting_is_on"
    return test


def make_on_top_test(panel: Panel):
    @covers(f"{panel.struct}.alwaysOnTop")
    def test(session):
        for on_top in (True, False):
            window = open_panel(session, panel, alwaysOnTop=on_top)
            is_topmost = lambda: bool(extended_style(window.hwnd) & WS_EX_TOPMOST)
            wait_for(f"alwaysOnTop={on_top}: topmost {on_top}", lambda: is_topmost() == on_top, details=is_topmost)

    test.__name__ = f"test_the_{panel.kind}_stays_on_top_as_set"
    return test


def make_opacity_test(panel: Panel):
    @covers(f"{panel.struct}.opacity")
    def test(session):
        window = open_panel(session, panel, opacity=128)
        if panel.is_native:
            wait_for(f"the {panel.kind} at alpha 128", lambda: layered_alpha(window.hwnd) == 128, details=lambda: layered_alpha(window.hwnd))
            return
        # Drawn with per-pixel alpha, which Windows can't report: read how much of what's behind shows through instead.
        point = (window.left + window.width * 4 // 5, window.top + (PANEL_HEADER_HEIGHT + window.height) // 2)
        around = (window.left - 20, window.top - 20, window.right + 20, window.bottom + 20)
        seen = {}
        for color in ("#ff0000", "#0000ff"):
            with backdrop(around, color):
                seen[color] = pixel(*point)
        red_gap, blue_gap = seen["#ff0000"][0] - seen["#0000ff"][0], seen["#0000ff"][2] - seen["#ff0000"][2]
        # At alpha 128, 127/255 of the backdrop shows through: about 127 of each channel.
        check(abs(red_gap - 127) <= 24 and abs(blue_gap - 127) <= 24,
              f"over red then blue the {panel.kind} read {seen['#ff0000']} and {seen['#0000ff']}, expected half the backdrop through")

    test.__name__ = f"test_the_{panel.kind}_takes_its_opacity"
    return test


def make_fold_test(panel: Panel):
    @covers(f"{panel.struct}.collapsed")
    def test(session):
        window = open_panel(session, panel, collapsed=False)
        check(window.height > PANEL_HEADER_HEIGHT, f"the open {panel.kind} is only {window.height} high")
        open_panel(session, panel, collapsed=True)
        height = lambda: (window_of(session, panel) or window).height
        wait_for(f"the folded {panel.kind} to be its header's height", lambda: height() == PANEL_HEADER_HEIGHT, details=height)

    test.__name__ = f"test_the_{panel.kind}_folds_to_its_header"
    return test


def make_lock_test(panel: Panel):
    @covers(f"{panel.struct}.lockPosition")
    def test(session):
        for locked in (False, True):
            window = open_panel(session, panel, extra={"panelSnapping": {"enabled": False}}, lockPosition=locked)
            drag_panel(session, panel, window, (150, 100))
            expected = (window.left, window.top) if locked else (window.left + 150, window.top + 100)
            at = lambda: (lambda w: (w.left, w.top) if w else None)(window_of(session, panel))
            wait_for(f"lockPosition={locked}: the {panel.kind} at {expected}", lambda: at() == expected, details=at)

    test.__name__ = f"test_dragging_the_{panel.kind}_header_moves_it_unless_locked"
    return test


def make_remember_test(panel: Panel):
    @covers(f"{panel.struct}.rememberPosition")
    def test(session):
        for remembers in (True, False):
            window = open_panel(session, panel, extra={"panelSnapping": {"enabled": False}}, rememberPosition=remembers)
            drag_panel(session, panel, window, (150, 100))
            saved = lambda: (lambda s: (s.get("x"), s.get("y")))(session.read_profile().get(panel.section, {}))
            if remembers:
                expected = (window.left + 150, window.top + 100)
                wait_for(f"the dragged {panel.kind}'s place saved as {expected}", lambda: saved() == expected, details=saved)
            else:
                stays(f"the {panel.kind}'s saved place to stay {AT}", lambda: saved() == AT, 1.5, details=saved)

    test.__name__ = f"test_the_{panel.kind}_remembers_a_dragged_place_as_set"
    return test


def make_presence_test(panel: Panel):
    @covers(f"{panel.struct}.hideWhenNoCharacters")
    def test(session):
        session.use(profile_for(panel, hideWhenNoCharacters=False))
        session.wait_for_panel_window(panel.class_name)
        session.use(profile_for(panel, hideWhenNoCharacters=True))
        no_window(session, panel, "no character logged in")
        session.start_client(ALPHA)
        session.wait_for_panel_window(panel.class_name)

    test.__name__ = f"test_the_{panel.kind}_hides_while_no_character_is_logged_in_as_set"
    return test


def make_focus_test(panel: Panel):
    @covers(f"{panel.struct}.hideWhenNoEveFocus", f"{panel.struct}.hideDebounceMs")
    def test(session):
        open_panel(session, panel, with_client=True, hideWhenNoEveFocus=True, hideDebounceMs=0)
        session.start_bystander()
        wait_for(f"the {panel.kind} to hide once EVE loses focus", lambda: window_of(session, panel) is None)
        session.switch_to(ALPHA)
        session.wait_for_panel_window(panel.class_name)

        open_panel(session, panel, with_client=True, hideWhenNoEveFocus=True, hideDebounceMs=3000)
        session.start_bystander()
        stays(f"the {panel.kind} to wait out its 3 s delay", lambda: window_of(session, panel) is not None, 1.2)
        wait_for(f"the {panel.kind} to hide after its delay", lambda: window_of(session, panel) is None, timeout_s=5.0)

        open_panel(session, panel, with_client=True, hideWhenNoEveFocus=False)
        session.start_bystander()
        stays(f"the {panel.kind} to stay without hideWhenNoEveFocus", lambda: window_of(session, panel) is not None, 1.5)

    test.__name__ = f"test_the_{panel.kind}_hides_when_eve_loses_focus_after_its_delay"
    return test


def make_toggle_test(panel: Panel):
    @covers(f"HotkeysConfig.{panel.toggle_hotkey}")
    def test(session):
        profile = profile_for(panel, shows=False)
        profile["hotkeys"] = {panel.toggle_hotkey: key()}
        session.use(profile)
        session.start_client(ALPHA)
        session.switch_to(ALPHA)
        session.press(KEY)
        session.wait_for_panel_window(panel.class_name)
        session.switch_to(ALPHA)
        session.press(KEY)
        wait_for(f"the {panel.kind} to close on a second press", lambda: window_of(session, panel) is None)

    test.__name__ = f"test_the_{panel.kind}_toggle_key_opens_and_closes_it"
    return test


for _panel in PANELS:
    _makers = [make_place_test, make_on_top_test, make_opacity_test, make_lock_test, make_remember_test, make_focus_test]
    if _panel.has_show:
        _makers.append(make_show_test)
    if _panel.folds:
        _makers.append(make_fold_test)
    if _panel.hides_without_characters:
        _makers.append(make_presence_test)
    if _panel.toggle_hotkey:
        _makers.append(make_toggle_test)
    for _make in _makers:
        _test = _make(_panel)
        globals()[_test.__name__] = _test


# Snapping, tried on the History Panel, which needs no client to show.

def monitor_left_of(window) -> int:
    return next(m.bounds[0] for m in monitors() if m.bounds[0] <= window.left < m.bounds[2])


def drag_history_to(session, window, left: int, top: int | None = None):
    drag_panel(session, HISTORY, window, (left - window.left, (top if top is not None else window.top) - window.top))


def history_left(session) -> int | None:
    window = window_of(session, HISTORY)
    return window.left if window else None


def lands_at_x(session, expected: int, why: str):
    wait_for(f"{why}: the History Panel's left at {expected}", lambda: history_left(session) == expected,
             timeout_s=2.0, details=lambda: history_left(session))


@covers("PanelSnappingConfig.enabled", "PanelSnappingConfig.screenEdges", "PanelSnappingConfig.threshold")
def test_a_panel_dragged_near_the_screen_edge_snaps_to_it(session):
    for snapping, snaps in (({}, True), ({"enabled": False}, False), ({"screenEdges": False}, False), ({"threshold": 3}, False)):
        window = open_panel(session, HISTORY, extra={"panelSnapping": snapping})
        screen_left = monitor_left_of(window)
        drag_history_to(session, window, screen_left + 6)
        lands_at_x(session, screen_left if snaps else screen_left + 6, f"panelSnapping {snapping}")


@covers("PanelSnappingConfig.thumbnailEdges")
def test_a_panel_dragged_near_a_thumbnail_snaps_to_its_edge(session):
    for snapping, snaps in (({}, True), ({"thumbnailEdges": False}, False)):
        window = open_panel(session, HISTORY, with_client=True, extra={"panelSnapping": snapping, "display": {"startX": 400, "startY": 350}}, x=1000)
        thumbnail = session.wait_for_thumbnails({ALPHA})[ALPHA].window
        drag_history_to(session, window, thumbnail.right + 5)
        lands_at_x(session, thumbnail.right if snaps else thumbnail.right + 5, f"panelSnapping {snapping}")


@covers("PanelSnappingConfig.panelEdges")
def test_a_panel_dragged_near_another_panel_snaps_to_its_edge(session):
    for snapping, snaps in (({}, True), ({"panelEdges": False}, False)):
        intel_profile = profile_for(INTEL, x=1200, y=AT[1])["intelPanel"]
        window = open_panel(session, HISTORY, extra={"panelSnapping": snapping, "intelPanel": intel_profile})
        intel = session.wait_for_panel_window(INTEL.class_name)
        target = intel.left - window.width
        drag_history_to(session, window, target - 5)
        lands_at_x(session, target if snaps else target - 5, f"panelSnapping {snapping}")
