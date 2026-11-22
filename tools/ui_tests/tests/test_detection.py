"""Finding clients, following their logins, and window filters."""

from harness import ALPHA, BRAVO, GENERIC_CHARACTER_NAME, check, covers


def test_each_client_gets_a_thumbnail_titled_with_its_character(session):
    session.use()
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})


def test_closing_a_client_removes_its_thumbnail(session):
    session.use()
    alpha, _ = session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    alpha.close()
    session.wait_for_thumbnails({BRAVO})


def test_logging_out_keeps_the_thumbnail_under_the_generic_name(session):
    session.use()
    alpha, _ = session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    alpha.log_out()
    thumbnails = session.wait_for_thumbnails({GENERIC_CHARACTER_NAME, BRAVO})
    check(thumbnails[GENERIC_CHARACTER_NAME].source_hwnd == alpha.hwnd,
          "the logged-out thumbnail isn't the one that showed Alpha's client")


def test_logging_back_in_restores_the_character_name(session):
    session.use()
    alpha = session.start_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    alpha.log_out()
    session.wait_for_thumbnails({GENERIC_CHARACTER_NAME})
    alpha.log_in()
    session.wait_for_thumbnails({ALPHA})


def eve_filter(**overrides) -> dict:
    return {"name": "EVE", "class_names": ["trinityWindow"], "executable_names": ["exefile.exe"], **overrides}


@covers("WindowFilterConfig.enabled")
def test_a_disabled_window_filter_finds_no_clients(session):
    session.use({"windowFilters": [eve_filter(enabled=False)]})
    session.start_client(ALPHA)
    session.assert_thumbnails_stay(set())


@covers("WindowFilterConfig.class_names")
def test_a_window_filter_for_another_class_finds_no_clients(session):
    session.use({"windowFilters": [eve_filter(class_names=["NotTrinity"])]})
    session.start_client(ALPHA)
    session.assert_thumbnails_stay(set())


@covers("WindowFilterConfig.executable_names")
def test_a_window_filter_for_another_executable_finds_no_clients(session):
    session.use({"windowFilters": [eve_filter(executable_names=["other.exe"])]})
    session.start_client(ALPHA)
    session.assert_thumbnails_stay(set())
