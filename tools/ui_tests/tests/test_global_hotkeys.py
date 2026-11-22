"""Hotkeys kept in the global settings, shared by every profile."""

from harness import ALPHA, BRAVO, CHARLIE, GENERIC_CHARACTER_NAME, VK_F13, check, covers, fresh, wait_for

ALL_FORWARD, ALL_BACKWARD, LOGGED_OUT_FORWARD, LOGGED_OUT_BACKWARD, NEXT_PROFILE, PREVIOUS_PROFILE, TO_TARGET = (VK_F13 + i for i in range(7))


def key(virtual_key: int) -> str:
    return f"0x{virtual_key:02X}"


GLOBAL_SETTINGS = {
    "hotkeyCycleAllClientsForward": key(ALL_FORWARD),
    "hotkeyCycleAllClientsBackward": key(ALL_BACKWARD),
    "hotkeyCycleNotLoggedInForward": key(LOGGED_OUT_FORWARD),
    "hotkeyCycleNotLoggedInBackward": key(LOGGED_OUT_BACKWARD),
    "hotkeyNextProfile": key(NEXT_PROFILE),
    "hotkeyPreviousProfile": key(PREVIOUS_PROFILE),
    "profileSwitchHotkeys": [{"hotkey": key(TO_TARGET), "targetProfile": "target.json"}],
}


def start(session, *names: str):
    session.start_clients(*names)
    session.wait_for_thumbnails(set(names))


def cycle_with(session, virtual_key: int, steps: int) -> list[str]:
    visited = []
    for _ in range(steps):
        before = session.foreground_client()
        session.press(virtual_key)
        wait_for("focus to move", lambda: session.foreground_client() not in (None, before), details=session.foreground_client)
        visited.append(session.foreground_client())
    return visited


@covers("GlobalConfig.hotkeyCycleAllClientsForward", "GlobalConfig.hotkeyCycleAllClientsBackward")
def test_the_all_clients_keys_cycle_every_client_both_ways(session):
    session.use()
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(ALPHA)
    forward = cycle_with(session, ALL_FORWARD, 3)
    check(sorted(forward) == [ALPHA, BRAVO, CHARLIE] and forward[-1] == ALPHA, f"forward visited {forward}")
    backward = cycle_with(session, ALL_BACKWARD, 2)
    check(backward == list(reversed(forward[:2])), f"backward visited {backward}, expected {list(reversed(forward[:2]))}")


@covers("GlobalConfig.hotkeyCycleNotLoggedInForward", "GlobalConfig.hotkeyCycleNotLoggedInBackward")
def test_the_logged_out_keys_cycle_login_screen_clients_both_ways(session):
    session.use()
    start(session, ALPHA, BRAVO, CHARLIE)
    session.clients[BRAVO].log_out()
    session.clients[CHARLIE].log_out()
    wait_for("two clients at the login screen",
             lambda: sum(t.character_name == GENERIC_CHARACTER_NAME for t in session.thumbnail_list()) == 2)
    session.switch_to(ALPHA)
    forward = cycle_with(session, LOGGED_OUT_FORWARD, 2)
    check(sorted(forward) == [BRAVO, CHARLIE], f"forward visited {forward}")
    session.press(LOGGED_OUT_BACKWARD)
    session.wait_for_foreground(forward[0])


@covers("GlobalConfig.hotkeyNextProfile", "GlobalConfig.hotkeyPreviousProfile")
def test_the_profile_keys_step_to_another_profile_and_back(session):
    session.use()
    start(session, ALPHA)
    session.switch_to(ALPHA)
    original = session.profile_name()
    session.press(NEXT_PROFILE)
    wait_for("another profile to load", lambda: session.profile_name() not in ("", original), details=session.profile_name)
    session.switch_to(ALPHA)
    session.press(PREVIOUS_PROFILE)
    wait_for(f"'{original}' to load again", lambda: session.profile_name() == original, details=session.profile_name)


@covers("ProfileSwitchHotkeyConfig.hotkey", "ProfileSwitchHotkeyConfig.targetProfile")
def test_a_profile_switch_key_loads_its_target(session):
    session.use()
    session.write_profile("target.json")
    start(session, ALPHA)
    session.switch_to(ALPHA)
    session.press(TO_TARGET)
    wait_for("'target.json' to load", lambda: session.profile_name() == "target.json", details=session.profile_name)


@fresh({"cycleAllClientsRespectExclusions": True, "hotkeyCycleAllClientsForward": key(ALL_FORWARD)})
@covers("GlobalConfig.cycleAllClientsRespectExclusions")
def test_cycling_all_clients_can_skip_excluded_ones(session):
    session.use()
    start(session, ALPHA, BRAVO, CHARLIE)
    session.switch_to(BRAVO)
    session.protocol("evemajpreview://hotkey/toggle_exclusion")
    wait_for("Bravo to be excluded", lambda: session.excluded() == [BRAVO], details=session.excluded)
    session.switch_to(ALPHA)
    visited = cycle_with(session, ALL_FORWARD, 4)
    check(BRAVO not in visited, f"visited {visited}, which includes excluded Bravo")


@fresh({"moveOnProfileSwitch": True})
@covers("GlobalConfig.moveOnProfileSwitch")
def test_switching_profile_moves_clients_to_the_new_profiles_positions(session):
    session.use()
    start(session, ALPHA)
    session.write_profile("moved.json", {"characters": [{"name": ALPHA, "windowPosition": {"x": 320, "y": 240}}]})
    session.protocol("evemajpreview://profile/moved.json")
    window = lambda: session.clients[ALPHA].window()
    wait_for("Alpha's window to reach (320, 240)", lambda: abs(window().left - 320) <= 10 and abs(window().top - 240) <= 10,
             details=lambda: (window().left, window().top))
