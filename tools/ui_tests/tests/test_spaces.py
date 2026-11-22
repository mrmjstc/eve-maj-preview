"""Thumbnail spaces: which space takes each thumbnail, and how a space fills."""

import time

from harness import ALPHA, BRAVO, CHARLIE, GENERIC_CHARACTER_NAME, check, covers, wait_for

DELTA = "Delta Pilot"
# A space wide enough for one row of three thumbnails at their configured size.
ROW = {"x": 100, "y": 100, "width": 900, "height": 160}
# Another region, apart from ROW, for a second space.
ASIDE = {"x": 100, "y": 400, "width": 900, "height": 160}


def spaces_profile(spaces: list[dict], groups: list[dict] | None = None, **extra) -> dict:
    return {"display": {"placementMode": "ThumbnailSpaces"}, "thumbnailSpaces": spaces, "hotkeyGroups": groups or [], **extra}


def space(name: str, region: dict, **options) -> dict:
    return {"name": name, "enabled": True, "spacing": 10, **region, **options}


def inside(window, region: dict) -> bool:
    return (window.left >= region["x"] and window.top >= region["y"]
            and window.right <= region["x"] + region["width"] and window.bottom <= region["y"] + region["height"])


def settled_thumbnails(session, names: set[str]):
    session.wait_for_thumbnails(names)
    # Let any late layout pass settle before reading positions.
    time.sleep(0.5)
    return session.thumbnails()


def check_inside(thumbnails, names, region: dict, label: str):
    for name in names:
        window = thumbnails[name].window
        check(inside(window, region), f"{name} at ({window.left}, {window.top})-({window.right}, {window.bottom}) isn't in {label}")


@covers("ThumbnailSpace.holdsLoginScreen")
def test_the_login_screen_space_holds_clients_at_the_login_screen(session):
    session.use(spaces_profile([space("Login Screen", ROW, holdsLoginScreen=True)]))
    alpha = session.start_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    alpha.log_out()
    thumbnails = settled_thumbnails(session, {GENERIC_CHARACTER_NAME})
    check_inside(thumbnails, [GENERIC_CHARACTER_NAME], ROW, "the Login Screen space")


@covers("ThumbnailSpace.takesLoginScreen")
def test_a_space_taking_login_screens_holds_them_after_its_own(session):
    groups = [{"name": "Fleet", "characters": [ALPHA]}]
    session.use(spaces_profile([space("Fleet Space", ROW, groups=["Fleet"], takesLoginScreen=True)], groups))
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    session.clients[BRAVO].log_out()
    thumbnails = settled_thumbnails(session, {ALPHA, GENERIC_CHARACTER_NAME})
    check_inside(thumbnails, [ALPHA, GENERIC_CHARACTER_NAME], ROW, "the Fleet space")
    check(thumbnails[ALPHA].window.left < thumbnails[GENERIC_CHARACTER_NAME].window.left,
          "the login-screen client fills in before the space's own member")


@covers("ThumbnailSpace.holdsUnassigned")
def test_the_unassigned_space_holds_characters_in_no_space(session):
    groups = [{"name": "Fleet", "characters": [ALPHA]}]
    session.use(spaces_profile([space("Unassigned Characters", ASIDE, holdsUnassigned=True), space("Fleet Space", ROW, groups=["Fleet"])], groups))
    session.start_clients(ALPHA, BRAVO)
    thumbnails = settled_thumbnails(session, {ALPHA, BRAVO})
    check_inside(thumbnails, [ALPHA], ROW, "the Fleet space")
    check_inside(thumbnails, [BRAVO], ASIDE, "the Unassigned Characters space")


@covers("ThumbnailSpace.takesUnassigned")
def test_a_space_taking_unassigned_characters_holds_them_after_its_own(session):
    groups = [{"name": "Fleet", "characters": [ALPHA]}]
    session.use(spaces_profile([space("Fleet Space", ROW, groups=["Fleet"], takesUnassigned=True)], groups))
    session.start_clients(ALPHA, BRAVO)
    thumbnails = settled_thumbnails(session, {ALPHA, BRAVO})
    check_inside(thumbnails, [ALPHA, BRAVO], ROW, "the Fleet space")
    check(thumbnails[ALPHA].window.left < thumbnails[BRAVO].window.left, "the unassigned character fills in before the space's own member")


def test_characters_in_no_space_are_placed_by_hand(session):
    groups = [{"name": "Fleet", "characters": [ALPHA]}]
    # ASIDE, not ROW, which overlaps where hand-placed thumbnails start.
    session.use(spaces_profile([space("Fleet Space", ASIDE, groups=["Fleet"])], groups))
    session.start_clients(ALPHA, BRAVO)
    thumbnails = settled_thumbnails(session, {ALPHA, BRAVO})
    check_inside(thumbnails, [ALPHA], ASIDE, "the Fleet space")
    check(not inside(thumbnails[BRAVO].window, ASIDE), "Bravo, in no space, was put in the Fleet space")


def test_a_disabled_space_places_nothing(session):
    groups = [{"name": "Fleet", "characters": [ALPHA]}]
    session.use(spaces_profile([space("Fleet Space", ASIDE, groups=["Fleet"], enabled=False)], groups))
    session.start_client(ALPHA)
    thumbnails = settled_thumbnails(session, {ALPHA})
    check(not inside(thumbnails[ALPHA].window, ASIDE), "a disabled space still placed Alpha")


# Fill order: each direction lays four thumbnails out in a 2x2 grid in its own order.

GRID = {"x": 100, "y": 100, "width": 520, "height": 300}
DIRECTIONS = {
    # direction: the (column, row) of the 1st, 2nd, 3rd and 4th character.
    "RowFirst_LTR_TTB": [(0, 0), (1, 0), (0, 1), (1, 1)],
    "RowFirst_RTL_TTB": [(1, 0), (0, 0), (1, 1), (0, 1)],
    "RowFirst_LTR_BTT": [(0, 1), (1, 1), (0, 0), (1, 0)],
    "RowFirst_RTL_BTT": [(1, 1), (0, 1), (1, 0), (0, 0)],
    "ColumnFirst_TTB_LTR": [(0, 0), (0, 1), (1, 0), (1, 1)],
    "ColumnFirst_TTB_RTL": [(1, 0), (1, 1), (0, 0), (0, 1)],
    "ColumnFirst_BTT_LTR": [(0, 1), (0, 0), (1, 1), (1, 0)],
    "ColumnFirst_BTT_RTL": [(1, 1), (1, 0), (0, 1), (0, 0)],
}


def cells(thumbnails, names) -> list[tuple[int, int]]:
    lefts = sorted({thumbnails[n].window.left for n in names})
    tops = sorted({thumbnails[n].window.top for n in names})
    return [(lefts.index(thumbnails[n].window.left), tops.index(thumbnails[n].window.top)) for n in names]


@covers("ThumbnailSpace.direction")
def test_each_fill_direction_lays_the_grid_out_in_its_order(session):
    names = [ALPHA, BRAVO, CHARLIE, DELTA]
    groups = [{"name": "Fleet", "characters": names}]
    characters = [{"name": n} for n in names]
    for direction, expected in DIRECTIONS.items():
        session.use(spaces_profile([space("Fleet Space", GRID, groups=["Fleet"], direction=direction)], groups, characters=characters))
        session.start_clients(*names)
        thumbnails = settled_thumbnails(session, set(names))
        actual = cells(thumbnails, names)
        check(actual == expected, f"{direction}: cells {actual}, expected {expected}")


@covers("ThumbnailSpace.order")
def test_hotkey_group_order_fills_by_group_rather_than_the_characters_list(session):
    groups = [{"name": "First", "characters": [CHARLIE]}, {"name": "Second", "characters": [ALPHA, BRAVO]}]
    characters = [{"name": n} for n in (ALPHA, BRAVO, CHARLIE)]
    for order, expected in (("Characters", [ALPHA, BRAVO, CHARLIE]), ("HotkeyGroups", [CHARLIE, ALPHA, BRAVO])):
        session.use(spaces_profile([space("Fleet Space", ROW, groups=["First", "Second"], order=order)], groups, characters=characters))
        session.start_clients(ALPHA, BRAVO, CHARLIE)
        thumbnails = settled_thumbnails(session, {ALPHA, BRAVO, CHARLIE})
        actual = sorted(thumbnails, key=lambda n: thumbnails[n].window.left)
        check(actual == expected, f"{order}: filled {actual}, expected {expected}")


@covers("ThumbnailSpace.spacing")
def test_spacing_sets_the_gap_between_neighbours(session):
    groups = [{"name": "Fleet", "characters": [ALPHA, BRAVO]}]
    for spacing in (0, 40):
        session.use(spaces_profile([space("Fleet Space", ROW, groups=["Fleet"], spacing=spacing)], groups))
        session.start_clients(ALPHA, BRAVO)
        thumbnails = settled_thumbnails(session, {ALPHA, BRAVO})
        first, second = sorted((t.window for t in thumbnails.values()), key=lambda w: w.left)
        gap = second.left - first.right
        check(abs(gap - spacing) <= 1, f"spacing {spacing}: gap {gap}")


@covers("ThumbnailSpace.limitToThumbnailSize")
def test_limit_to_thumbnail_size_stops_cells_growing_past_it(session):
    big = {"x": 100, "y": 100, "width": 1200, "height": 700}
    groups = [{"name": "Fleet", "characters": [ALPHA]}]
    for limits, grows in ((False, True), (True, False)):
        session.use(spaces_profile([space("Fleet Space", big, groups=["Fleet"], limitToThumbnailSize=limits)], groups))
        session.start_client(ALPHA)
        window = settled_thumbnails(session, {ALPHA})[ALPHA].window
        capped = round(240 * window.scale)
        if grows:
            check(window.width > capped + 1, f"without the limit, width {window.width} didn't grow past {capped}")
        else:
            check(abs(window.width - capped) <= 1, f"with the limit, width {window.width}, expected {capped}")
