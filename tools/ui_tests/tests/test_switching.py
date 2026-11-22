"""Switching between clients through protocol links, which run the same code as the hotkeys."""

from harness import ALPHA, BRAVO, CHARLIE, GENERIC_CHARACTER_NAME, check, wait_for


def test_a_switch_link_brings_the_client_forward_and_marks_it_active(session):
    session.use()
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    bravo = session.clients[BRAVO]
    session.switch_to(ALPHA)
    session.switch_to(BRAVO)
    wait_for("the app to report Bravo as active", lambda: session.active_hwnd() == bravo.hwnd)


def test_cycling_all_clients_visits_each_once_before_repeating(session):
    session.use()
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


def test_cycling_logged_out_clients_reaches_the_one_at_the_login_screen(session):
    session.use()
    _, bravo = session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    bravo.log_out()
    session.wait_for_thumbnails({ALPHA, GENERIC_CHARACTER_NAME})
    session.switch_to(ALPHA)
    session.protocol("evemajpreview://hotkey/next_not_logged_in")
    session.wait_for_foreground(BRAVO)


def test_minimize_all_minimizes_every_client(session):
    session.use()
    clients = session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    session.protocol("evemajpreview://hotkey/minimize_all")
    wait_for("every client to be minimized", lambda: all(c.window().is_minimized for c in clients),
             details=lambda: {c.name: c.window().is_minimized for c in clients})
