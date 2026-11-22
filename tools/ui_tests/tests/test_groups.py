"""Hotkey groups: cycling order, their keys, membership and badges."""

import time

from harness import ALPHA, BRAVO, CHARLIE, GENERIC_CHARACTER_NAME, VK_F13, check, covers, stays, wait_for

DELTA = "Delta Pilot"
FORWARD, BACKWARD, ASSIGN, MINIMIZE, CLOSE = (VK_F13 + i for i in range(5))


def key(virtual_key: int) -> str:
    return f"0x{virtual_key:02X}"


def fleet(*characters: str, **options) -> dict:
    return {"hotkeyGroups": [{"name": "Fleet", "characters": list(characters), **options}]}


def start(session, *names: str):
    session.start_clients(*names)
    session.wait_for_thumbnails(set(names))


@covers("HotkeyGroupConfig.characters")
def test_a_group_cycles_in_its_listed_order(session):
    session.use(fleet(CHARLIE, ALPHA, BRAVO))
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(CHARLIE)
    for expected in (ALPHA, BRAVO, CHARLIE):
        session.protocol("evemajpreview://group/next/Fleet")
        session.wait_for_foreground(expected)


def test_a_group_cycles_backward_in_reverse_order(session):
    session.use(fleet(CHARLIE, ALPHA, BRAVO))
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(CHARLIE)
    for expected in (BRAVO, ALPHA, CHARLIE):
        session.protocol("evemajpreview://group/previous/Fleet")
        session.wait_for_foreground(expected)


@covers("HotkeyGroupConfig.forwardKey")
def test_a_groups_forward_key_cycles_it(session):
    session.use(fleet(ALPHA, BRAVO, CHARLIE, forwardKey=key(FORWARD)))
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(ALPHA)
    for expected in (BRAVO, CHARLIE, ALPHA):
        session.press(FORWARD)
        session.wait_for_foreground(expected)


@covers("HotkeyGroupConfig.backwardKey")
def test_a_groups_backward_key_cycles_it_in_reverse(session):
    session.use(fleet(ALPHA, BRAVO, CHARLIE, backwardKey=key(BACKWARD)))
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(ALPHA)
    for expected in (CHARLIE, BRAVO, ALPHA):
        session.press(BACKWARD)
        session.wait_for_foreground(expected)


@covers("HotkeyGroupConfig.stopAtEnds")
def test_stop_at_ends_holds_on_the_last_member(session):
    session.use(fleet(ALPHA, BRAVO, stopAtEnds=True, forwardKey=key(FORWARD)))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.press(FORWARD)
    session.wait_for_foreground(BRAVO)
    session.press(FORWARD)
    stays("Bravo to keep focus at the group's end", lambda: session.foreground_client() == BRAVO, 1.0,
          details=session.foreground_client)


@covers("HotkeyGroupConfig.includeNotLoggedIn")
def test_include_not_logged_in_appends_login_screen_clients(session):
    session.use(fleet(ALPHA, BRAVO, includeNotLoggedIn=True, forwardKey=key(FORWARD)))
    start(session, ALPHA, BRAVO, CHARLIE)
    session.clients[CHARLIE].log_out()
    session.wait_for_thumbnails({ALPHA, BRAVO, GENERIC_CHARACTER_NAME})
    session.switch_to(BRAVO)
    session.press(FORWARD)
    session.wait_for_foreground(CHARLIE)


def test_a_group_skips_excluded_members(session):
    session.use(fleet(ALPHA, BRAVO, CHARLIE, forwardKey=key(FORWARD)))
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(BRAVO)
    session.protocol("evemajpreview://hotkey/toggle_exclusion")
    wait_for("Bravo to be excluded", lambda: session.excluded() == [BRAVO], details=session.excluded)
    session.switch_to(ALPHA)
    session.press(FORWARD)
    session.wait_for_foreground(CHARLIE)


@covers("HotkeysConfig.resetGroupIndexOnNonGroupFocus")
def test_focusing_outside_the_group_restarts_it_when_reset_is_on(session):
    session.use({**fleet(ALPHA, BRAVO, CHARLIE, forwardKey=key(FORWARD)), "hotkeys": {"resetGroupIndexOnNonGroupFocus": True}})
    start(session, ALPHA, BRAVO, CHARLIE, DELTA)
    session.switch_to(BRAVO)
    session.switch_to(DELTA)
    session.press(FORWARD)
    session.wait_for_foreground(ALPHA)


def test_focusing_outside_the_group_keeps_its_place_by_default(session):
    session.use(fleet(ALPHA, BRAVO, CHARLIE, forwardKey=key(FORWARD)))
    start(session, ALPHA, BRAVO, CHARLIE, DELTA)
    session.switch_to(BRAVO)
    session.switch_to(DELTA)
    session.press(FORWARD)
    session.wait_for_foreground(CHARLIE)


@covers("HotkeyGroupConfig.assignKey")
def test_the_assign_key_toggles_the_hovered_character_in_and_out(session):
    session.use(fleet(ALPHA, assignKey=key(ASSIGN)))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.hover(BRAVO)
    session.press(ASSIGN)
    wait_for("Bravo to join the group", lambda: session.group_members("Fleet") == [ALPHA, BRAVO],
             details=lambda: session.group_members("Fleet"))
    session.press(ASSIGN)
    wait_for("Bravo to leave the group", lambda: session.group_members("Fleet") == [ALPHA],
             details=lambda: session.group_members("Fleet"))


def test_assigning_to_a_saved_group_saves_the_profile(session):
    session.use(fleet(ALPHA, assignKey=key(ASSIGN)))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.hover(BRAVO)
    session.press(ASSIGN)
    wait_for("the saved profile to list Bravo in the group",
             lambda: session.read_profile()["hotkeyGroups"][0]["characters"] == [ALPHA, BRAVO],
             details=lambda: session.read_profile()["hotkeyGroups"][0]["characters"])


@covers("HotkeyGroupConfig.temporaryMembership")
def test_assigning_to_a_temporary_group_leaves_the_saved_profile_alone(session):
    session.use(fleet(ALPHA, assignKey=key(ASSIGN), temporaryMembership=True))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.hover(BRAVO)
    session.press(ASSIGN)
    wait_for("Bravo to join the group", lambda: BRAVO in session.group_members("Fleet"),
             details=lambda: session.group_members("Fleet"))
    time.sleep(0.5)
    saved = session.read_profile()["hotkeyGroups"][0]["characters"]
    check(BRAVO not in saved, f"the saved profile lists {saved}, but temporary members shouldn't be saved")


@covers("HotkeyGroupConfig.minimizeKey")
def test_the_minimize_key_minimizes_only_the_groups_members(session):
    session.use(fleet(ALPHA, BRAVO, minimizeKey=key(MINIMIZE)))
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(CHARLIE)
    session.press(MINIMIZE)
    clients = session.clients
    wait_for("Alpha and Bravo to be minimized", lambda: clients[ALPHA].window().is_minimized and clients[BRAVO].window().is_minimized)
    check(not clients[CHARLIE].window().is_minimized, "Charlie, outside the group, was minimized too")


@covers("HotkeyGroupConfig.closeKey")
def test_the_close_key_closes_only_the_groups_members(session):
    session.use(fleet(ALPHA, BRAVO, closeKey=key(CLOSE)))
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(CHARLIE)
    session.press(CLOSE)
    wait_for("Alpha and Bravo to close", lambda: session.running_names() == {CHARLIE}, details=session.running_names)


@covers("HotkeyGroupConfig.showBadge", "HotkeyGroupConfig.name")
def test_show_badge_puts_the_group_name_on_its_members_thumbnails(session):
    session.use(fleet(ALPHA, showBadge=True))
    start(session, ALPHA, BRAVO)
    wait_for("Alpha's badge to name the group", lambda: "Fleet" in session.thumbnails()[ALPHA].group_badge,
             details=lambda: {n: t.group_badge for n, t in session.thumbnails().items()})
    check(session.thumbnails()[BRAVO].group_badge == "", "Bravo, outside the group, shows a badge")


def test_a_group_without_show_badge_puts_no_badge_on_its_members(session):
    session.use(fleet(ALPHA))
    start(session, ALPHA)
    stays("Alpha to show no badge", lambda: session.thumbnails()[ALPHA].group_badge == "", 1.0,
          details=lambda: session.thumbnails()[ALPHA].group_badge)
