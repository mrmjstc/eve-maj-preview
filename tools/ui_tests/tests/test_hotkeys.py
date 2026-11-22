"""Profile hotkeys pressed for real, and the rules for when a key counts."""

import time

from harness import ALPHA, BRAVO, CHARLIE, VK_F13, VK_SHIFT, check, covers, stays, wait_for

KEY = VK_F13


def key(virtual_key: int = KEY) -> str:
    return f"0x{virtual_key:02X}"


def bound(field: str, **extra) -> dict:
    return {"hotkeys": {field: key(), **extra}}


def start(session, *names: str):
    session.start_clients(*names)
    session.wait_for_thumbnails(set(names))


def minimized(session, *names: str) -> bool:
    return all(session.clients[name].window().is_minimized for name in names)


@covers("HotkeysConfig.hotkeyMinimizeAll")
def test_the_minimize_all_key_minimizes_every_client(session):
    session.use(bound("hotkeyMinimizeAll"))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.press(KEY)
    wait_for("every client to be minimized", lambda: minimized(session, ALPHA, BRAVO))


@covers("HotkeysConfig.hotkeyCloseAll")
def test_the_close_all_key_closes_every_client(session):
    session.use(bound("hotkeyCloseAll"))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.press(KEY)
    wait_for("every client to close", lambda: not session.running_names(), details=session.running_names)


@covers("HotkeysConfig.hotkeyCloseActive")
def test_the_close_active_key_closes_only_the_focused_client(session):
    session.use(bound("hotkeyCloseActive"))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.press(KEY)
    wait_for("only Alpha to close", lambda: session.running_names() == {BRAVO}, details=session.running_names)


@covers("HotkeysConfig.hotkeyToggleVisibility")
def test_the_toggle_visibility_key_hides_and_restores_thumbnails(session):
    session.use(bound("hotkeyToggleVisibility"))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.press(KEY)
    session.wait_for_thumbnails(set())
    session.press(KEY)
    session.wait_for_thumbnails({ALPHA, BRAVO})


@covers("HotkeysConfig.hotkeyToggleExclusion")
def test_the_toggle_exclusion_key_excludes_and_includes_the_focused_client(session):
    session.use(bound("hotkeyToggleExclusion"))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.press(KEY)
    wait_for("Alpha to be excluded", lambda: session.excluded() == [ALPHA], details=session.excluded)
    session.press(KEY)
    wait_for("Alpha to be included again", lambda: session.excluded() == [], details=session.excluded)


@covers("HotkeysConfig.hotkeyNextExcluded", "HotkeysConfig.hotkeyPreviousExcluded")
def test_the_excluded_keys_cycle_only_excluded_clients(session):
    session.use({"hotkeys": {"hotkeyNextExcluded": key(KEY), "hotkeyPreviousExcluded": key(KEY + 1)}})
    start(session, ALPHA, BRAVO, CHARLIE)
    for name in (ALPHA, BRAVO):
        session.switch_to(name)
        session.protocol("evemajpreview://hotkey/toggle_exclusion")
    wait_for("Alpha and Bravo to be excluded", lambda: sorted(session.excluded()) == [ALPHA, BRAVO], details=session.excluded)
    session.switch_to(CHARLIE)
    session.press(KEY)
    first = wait_for("an excluded client to take focus", lambda: session.foreground_client() in (ALPHA, BRAVO) and session.foreground_client(),
                     details=session.foreground_client)
    other = BRAVO if first == ALPHA else ALPHA
    session.press(KEY)
    session.wait_for_foreground(other)
    session.press(KEY + 1)
    session.wait_for_foreground(first)


@covers("HotkeysConfig.hotkeySuspend")
def test_the_suspend_key_stops_other_hotkeys_until_pressed_again(session):
    session.use({"hotkeys": {"hotkeySuspend": key(KEY), "hotkeyMinimizeAll": key(KEY + 1)}})
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.press(KEY)
    wait_for("hotkeys to be suspended", lambda: (session.state() or {}).get("are_hotkeys_suspended"))
    session.press(KEY + 1)
    stays("clients to stay open while suspended", lambda: not minimized(session, ALPHA), 1.0)
    session.press(KEY)
    wait_for("hotkeys to resume", lambda: not (session.state() or {}).get("are_hotkeys_suspended"))
    session.press(KEY + 1)
    wait_for("every client to be minimized", lambda: minimized(session, ALPHA, BRAVO))


@covers("HotkeysConfig.hotkeyExitApp")
def test_the_exit_key_quits_the_app(session):
    session.use(bound("hotkeyExitApp"))
    start(session, ALPHA)
    session.switch_to(ALPHA)
    session.press(KEY)
    wait_for("the app to exit", lambda: session.app.poll() is not None)


@covers("HotkeysConfig.hotkeyMoveToSavedPositions", "CharacterConfig.windowPosition")
def test_the_move_to_saved_positions_key_moves_clients_there(session):
    session.use({**bound("hotkeyMoveToSavedPositions"), "characters": [{"name": ALPHA, "windowPosition": {"x": 300, "y": 200}}]})
    start(session, ALPHA)
    session.switch_to(ALPHA)
    session.press(KEY)
    window = lambda: session.clients[ALPHA].window()
    wait_for("Alpha's window to reach (300, 200)", lambda: abs(window().left - 300) <= 10 and abs(window().top - 200) <= 10,
             details=lambda: (window().left, window().top))


@covers("CharacterConfig.hotkey")
def test_a_characters_own_key_focuses_that_client(session):
    session.use({"characters": [{"name": BRAVO, "hotkey": key()}]})
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.press(KEY)
    session.wait_for_foreground(BRAVO)


@covers("HotkeysConfig.requireEveFocus")
def test_require_eve_focus_ignores_keys_pressed_in_other_apps(session):
    session.use(bound("hotkeyMinimizeAll", requireEveFocus=True))
    start(session, ALPHA)
    session.start_bystander()
    session.wait_for_foreground("Bystander")
    session.press(KEY)
    stays("Alpha to stay open", lambda: not minimized(session, ALPHA), 1.0)
    session.switch_to(ALPHA)
    session.press(KEY)
    wait_for("Alpha to be minimized", lambda: minimized(session, ALPHA))


def test_keys_work_in_other_apps_by_default(session):
    session.use(bound("hotkeyMinimizeAll"))
    start(session, ALPHA)
    session.start_bystander()
    session.wait_for_foreground("Bystander")
    session.press(KEY)
    wait_for("Alpha to be minimized", lambda: minimized(session, ALPHA))


@covers("HotkeysConfig.exactHotkeyModifiers")
def test_exact_modifiers_ignore_a_key_pressed_with_an_extra_modifier(session):
    session.use(bound("hotkeyMinimizeAll", exactHotkeyModifiers=True))
    start(session, ALPHA)
    session.switch_to(ALPHA)
    session.press(KEY, modifiers=(VK_SHIFT,))
    stays("Alpha to stay open", lambda: not minimized(session, ALPHA), 1.0)


def test_an_extra_modifier_still_triggers_the_key_by_default(session):
    session.use(bound("hotkeyMinimizeAll"))
    start(session, ALPHA)
    session.switch_to(ALPHA)
    session.press(KEY, modifiers=(VK_SHIFT,))
    wait_for("Alpha to be minimized", lambda: minimized(session, ALPHA))


def held_cycle(session, allows_repeat: bool) -> str:
    """Holds a group's forward key through one auto-repeat and says where focus ends up."""
    session.use({"hotkeyGroups": [{"name": "Fleet", "characters": [ALPHA, BRAVO, CHARLIE], "forwardKey": key()}],
                 "hotkeys": {"allowHotkeyAutoRepeat": allows_repeat}})
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(ALPHA)
    session.key_down(KEY)
    session.wait_for_foreground(BRAVO)
    session.key_down(KEY)
    session.key_up(KEY)
    time.sleep(0.5)
    return session.foreground_client()


@covers("HotkeysConfig.allowHotkeyAutoRepeat")
def test_auto_repeat_cycles_again_while_the_key_is_held(session):
    check(held_cycle(session, True) == CHARLIE, "holding the key didn't cycle a second time")


def test_a_held_key_cycles_once_by_default(session):
    check(held_cycle(session, False) == BRAVO, "holding the key cycled more than once")
