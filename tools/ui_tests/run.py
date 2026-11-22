"""End-to-end checks of the built app against simulated clients.

Usage: python tools/ui_tests/run.py [name-substring ...]

Each test gets its own sandboxed app. Windows appear and take focus while it runs; don't type
or click until it finishes.
"""

import sys
import time
import traceback

from harness import GENERIC_CHARACTER_NAME, Session, TestFailure, ensure_ready, wait_for

ALPHA, BRAVO, CHARLIE = "Alpha Pilot", "Bravo Pilot", "Charlie Pilot"
VK_F24 = 0x87


def check(condition: bool, message: str):
    if not condition:
        raise TestFailure(message)


def scaled(value: int, scale: float) -> int:
    return round(value * scale)


# Detection

def test_each_client_gets_a_thumbnail_titled_with_its_character():
    with Session() as session:
        session.start_clients(ALPHA, BRAVO, CHARLIE)
        session.wait_for_thumbnails({ALPHA, BRAVO, CHARLIE})


def test_closing_a_client_removes_its_thumbnail():
    with Session() as session:
        alpha, _ = session.start_clients(ALPHA, BRAVO)
        session.wait_for_thumbnails({ALPHA, BRAVO})
        alpha.close()
        session.wait_for_thumbnails({BRAVO})


# Login and logout

def test_logging_out_keeps_the_thumbnail_under_the_generic_name():
    with Session() as session:
        alpha, _ = session.start_clients(ALPHA, BRAVO)
        session.wait_for_thumbnails({ALPHA, BRAVO})
        alpha.log_out()
        thumbnails = session.wait_for_thumbnails({GENERIC_CHARACTER_NAME, BRAVO})
        check(thumbnails[GENERIC_CHARACTER_NAME].source_hwnd == alpha.hwnd,
              "the logged-out thumbnail isn't the one that showed Alpha's client")


def test_logging_back_in_restores_the_character_name():
    with Session() as session:
        alpha = session.start_client(ALPHA)
        session.wait_for_thumbnails({ALPHA})
        alpha.log_out()
        session.wait_for_thumbnails({GENERIC_CHARACTER_NAME})
        alpha.log_in()
        session.wait_for_thumbnails({ALPHA})


# Placement

def test_thumbnails_take_the_profile_size_scaled_for_dpi():
    with Session() as session:
        session.start_client(ALPHA)
        window = session.wait_for_thumbnails({ALPHA})[ALPHA].window
        expected = (scaled(240, window.scale), scaled(135, window.scale))
        check(abs(window.width - expected[0]) <= 1 and abs(window.height - expected[1]) <= 1,
              f"size {window.width}x{window.height}, expected {expected[0]}x{expected[1]}")


def test_unplaced_thumbnails_line_up_from_the_start_position():
    with Session() as session:
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


def test_a_saved_position_is_used_and_others_still_start_the_row():
    profile = {"characters": [{"name": ALPHA, "position": {"x": 700, "y": 400}}]}
    with Session(profile) as session:
        session.start_clients(ALPHA, BRAVO)
        thumbnails = session.wait_for_thumbnails({ALPHA, BRAVO})
        time.sleep(0.5)
        thumbnails = session.thumbnails()
        alpha, bravo = thumbnails[ALPHA].window, thumbnails[BRAVO].window
        check((alpha.left, alpha.top) == (700, 400), f"Alpha at {(alpha.left, alpha.top)}, expected its saved (700, 400)")
        start = (scaled(100, bravo.scale), scaled(100, bravo.scale))
        check((bravo.left, bravo.top) == start, f"Bravo at {(bravo.left, bravo.top)}, expected the row's first slot {start}")


def test_saved_positions_are_ignored_when_not_honored():
    profile = {"display": {"honorSavedPositions": False}, "characters": [{"name": ALPHA, "position": {"x": 700, "y": 400}}]}
    with Session(profile) as session:
        session.start_client(ALPHA)
        session.wait_for_thumbnails({ALPHA})
        time.sleep(0.5)
        alpha = session.thumbnails()[ALPHA].window
        start = (scaled(100, alpha.scale), scaled(100, alpha.scale))
        check((alpha.left, alpha.top) == start, f"Alpha at {(alpha.left, alpha.top)}, expected the row's first slot {start}")


def test_a_thumbnail_space_fits_its_group_inside_the_region_without_overlap():
    region = {"x": 100, "y": 100, "width": 600, "height": 200}
    profile = {
        "display": {"placementMode": "ThumbnailSpaces"},
        "hotkeyGroups": [{"name": "Fleet", "characters": [ALPHA, BRAVO, CHARLIE]}],
        "thumbnailSpaces": [{"name": "Fleet Space", "enabled": True, "groups": ["Fleet"], "spacing": 10, **region}],
    }
    with Session(profile) as session:
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


# Visibility

def test_hide_active_hides_only_the_focused_clients_thumbnail():
    with Session({"thumbnail": {"activeThumbnailHidden": True}}) as session:
        session.start_clients(ALPHA, BRAVO)
        # Either may already be hidden, as the last client started has focus.
        wait_for("the app to see both clients", lambda: len(session.thumbnail_list()) == 2)
        session.switch_to(ALPHA)
        session.wait_for_thumbnails({BRAVO})
        session.switch_to(BRAVO)
        session.wait_for_thumbnails({ALPHA})


def test_a_characters_hide_thumbnail_setting_hides_only_that_thumbnail():
    with Session({"characters": [{"name": BRAVO, "hideThumbnail": True}]}) as session:
        session.start_clients(ALPHA, BRAVO)
        session.wait_for_thumbnails({ALPHA})
        bravo = next(t for t in session.thumbnail_list() if t.character_name == BRAVO)
        check(bravo.is_hidden_by_character, "Bravo's thumbnail isn't reported as hidden by its character setting")


def test_toggle_visibility_hides_and_restores_every_thumbnail():
    with Session() as session:
        session.start_clients(ALPHA, BRAVO)
        session.wait_for_thumbnails({ALPHA, BRAVO})
        session.protocol("evemajpreview://hotkey/toggle_visibility")
        session.wait_for_thumbnails(set())
        session.protocol("evemajpreview://hotkey/toggle_visibility")
        session.wait_for_thumbnails({ALPHA, BRAVO})


# Switching and cycling

def test_a_switch_link_brings_the_client_forward_and_marks_it_active():
    with Session() as session:
        session.start_clients(ALPHA, BRAVO)
        session.wait_for_thumbnails({ALPHA, BRAVO})
        bravo = session.clients[BRAVO]
        session.switch_to(ALPHA)
        session.switch_to(BRAVO)
        wait_for("the app to report Bravo as active", lambda: session.active_hwnd() == bravo.hwnd)


def test_cycling_all_clients_visits_each_once_before_repeating():
    with Session() as session:
        names = (ALPHA, BRAVO, CHARLIE)
        session.start_clients(*names)
        session.wait_for_thumbnails(set(names))
        session.switch_to(ALPHA)
        visited = []
        for _ in range(len(names)):
            before = session.foreground_client()
            session.protocol("evemajpreview://hotkey/next_all_clients")
            wait_for("focus to move", lambda: session.foreground_client() not in (None, before),
                     details=session.foreground_client)
            visited.append(session.foreground_client())
        check(sorted(visited) == sorted(names) and visited[-1] == ALPHA,
              f"visited {visited}, expected each client once, ending back on {ALPHA}")


def test_a_group_cycles_in_its_listed_order():
    profile = {"hotkeyGroups": [{"name": "Fleet", "characters": [CHARLIE, ALPHA, BRAVO]}]}
    with Session(profile) as session:
        session.start_clients(ALPHA, BRAVO, CHARLIE)
        session.wait_for_thumbnails({ALPHA, BRAVO, CHARLIE})
        session.switch_to(CHARLIE)
        for expected in (ALPHA, BRAVO, CHARLIE):
            session.protocol("evemajpreview://group/next/Fleet")
            session.wait_for_foreground(expected)


def test_a_group_cycles_backward_in_reverse_order():
    profile = {"hotkeyGroups": [{"name": "Fleet", "characters": [CHARLIE, ALPHA, BRAVO]}]}
    with Session(profile) as session:
        session.start_clients(ALPHA, BRAVO, CHARLIE)
        session.wait_for_thumbnails({ALPHA, BRAVO, CHARLIE})
        session.switch_to(CHARLIE)
        for expected in (BRAVO, ALPHA, CHARLIE):
            session.protocol("evemajpreview://group/previous/Fleet")
            session.wait_for_foreground(expected)


def test_a_groups_forward_key_cycles_it():
    profile = {"hotkeyGroups": [{"name": "Fleet", "characters": [ALPHA, BRAVO], "forwardKey": f"0x{VK_F24:02X}"}]}
    with Session(profile) as session:
        session.start_clients(ALPHA, BRAVO)
        session.wait_for_thumbnails({ALPHA, BRAVO})
        session.switch_to(ALPHA)
        session.press(VK_F24)
        session.wait_for_foreground(BRAVO)
        session.press(VK_F24)
        session.wait_for_foreground(ALPHA)


def test_cycling_logged_out_clients_reaches_the_one_at_the_login_screen():
    with Session() as session:
        _, bravo = session.start_clients(ALPHA, BRAVO)
        session.wait_for_thumbnails({ALPHA, BRAVO})
        bravo.log_out()
        session.wait_for_thumbnails({ALPHA, GENERIC_CHARACTER_NAME})
        session.switch_to(ALPHA)
        session.protocol("evemajpreview://hotkey/next_not_logged_in")
        session.wait_for_foreground(BRAVO)


def test_minimize_all_minimizes_every_client():
    with Session() as session:
        clients = session.start_clients(ALPHA, BRAVO)
        session.wait_for_thumbnails({ALPHA, BRAVO})
        session.protocol("evemajpreview://hotkey/minimize_all")
        wait_for("every client to be minimized", lambda: all(c.window().is_minimized for c in clients),
                 details=lambda: {c.name: c.window().is_minimized for c in clients})


def main(filters: list[str]) -> int:
    ensure_ready()
    tests = [(name, fn) for name, fn in globals().items() if name.startswith("test_") and callable(fn)]
    tests = [(name, fn) for name, fn in tests if not filters or any(f in name for f in filters)]
    failures = 0
    for name, fn in tests:
        started = time.monotonic()
        try:
            fn()
            print(f"PASS  {name}  ({time.monotonic() - started:.1f}s)")
        except TestFailure as failure:
            failures += 1
            print(f"FAIL  {name}: {failure}")
        except Exception:
            failures += 1
            print(f"ERROR {name}")
            traceback.print_exc()
    print(f"\n{len(tests) - failures}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
