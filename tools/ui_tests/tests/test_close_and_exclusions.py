"""Cycle exclusions, and which clients minimize-all and close-all leave alone."""

from harness import ALPHA, BRAVO, GENERIC_CHARACTER_NAME, VK_F13, covers, fresh, stays, wait_for

CLOSE_ALL = VK_F13


def close_all_key(**profile) -> dict:
    return {"hotkeys": {"hotkeyCloseAll": f"0x{CLOSE_ALL:02X}"}, **profile}


def start(session, *names: str):
    session.start_clients(*names)
    session.wait_for_thumbnails(set(names))


def exclude(session, name: str):
    session.switch_to(name)
    session.protocol("evemajpreview://hotkey/toggle_exclusion")
    wait_for(f"'{name}' to be excluded", lambda: name in session.excluded(), details=session.excluded)


def close_all(session, survivors: set[str]):
    session.switch_to(next(iter(session.running_names())))
    session.press(CLOSE_ALL)
    wait_for(f"only {sorted(survivors)} to stay open", lambda: session.running_names() == survivors, details=session.running_names)
    stays(f"{sorted(survivors)} to stay open", lambda: session.running_names() == survivors, 0.5, details=session.running_names)


@covers("CharacterConfig.excludeFromCloseAll")
def test_close_all_spares_a_character_excluded_from_it(session):
    session.use(close_all_key(characters=[{"name": ALPHA, "excludeFromCloseAll": True}]))
    start(session, ALPHA, BRAVO)
    close_all(session, {ALPHA})


@covers("CloseAllConfig.excludeCycleExcludedClients")
def test_close_all_can_spare_cycle_excluded_clients(session):
    session.use(close_all_key(closeAll={"excludeCycleExcludedClients": True}))
    start(session, ALPHA, BRAVO)
    exclude(session, BRAVO)
    close_all(session, {BRAVO})


def test_close_all_closes_cycle_excluded_clients_by_default(session):
    session.use(close_all_key())
    start(session, ALPHA, BRAVO)
    exclude(session, BRAVO)
    close_all(session, set())


@covers("CloseAllConfig.excludeLoginScreenClients")
def test_close_all_can_spare_clients_at_the_login_screen(session):
    session.use(close_all_key(closeAll={"excludeLoginScreenClients": True}))
    start(session, ALPHA, BRAVO)
    session.clients[BRAVO].log_out()
    session.wait_for_thumbnails({ALPHA, GENERIC_CHARACTER_NAME})
    close_all(session, {BRAVO})


@covers("ExclusionConfig.autoMinimizeExcluded")
def test_excluding_a_client_can_minimize_it(session):
    session.use({"exclusion": {"autoMinimizeExcluded": True}})
    start(session, ALPHA, BRAVO)
    exclude(session, BRAVO)
    wait_for("Bravo to be minimized", lambda: session.clients[BRAVO].window().is_minimized)


@covers("ExclusionConfig.logoutClearsExclusion")
def test_logging_out_clears_the_exclusion_by_default(session):
    session.use()
    start(session, ALPHA, BRAVO)
    exclude(session, BRAVO)
    session.clients[BRAVO].log_out()
    wait_for("Bravo's exclusion to clear", lambda: session.excluded() == [], details=session.excluded)


def test_logging_out_can_keep_the_exclusion(session):
    session.use({"exclusion": {"logoutClearsExclusion": False}})
    start(session, ALPHA, BRAVO)
    exclude(session, BRAVO)
    session.clients[BRAVO].log_out()
    session.wait_for_thumbnails({ALPHA, GENERIC_CHARACTER_NAME})
    stays("Bravo to stay excluded", lambda: session.excluded() == [BRAVO], 1.0, details=session.excluded)


# Protocol links can close things only when the global settings allow it.

def protocol_close(session, url: str, closes: bool, expected_open: set[str]):
    session.use({"hotkeyGroups": [{"name": "Fleet", "characters": [ALPHA]}]})
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.protocol(url)
    if closes:
        wait_for(f"only {sorted(expected_open)} to stay open", lambda: session.running_names() == expected_open, details=session.running_names)
    else:
        stays("both clients to stay open", lambda: session.running_names() == {ALPHA, BRAVO}, 1.5, details=session.running_names)


def test_links_cant_close_anything_by_default(session):
    for url in ("evemajpreview://hotkey/close_all", "evemajpreview://hotkey/close_active", "evemajpreview://group/close/Fleet"):
        protocol_close(session, url, closes=False, expected_open={ALPHA, BRAVO})
    session.protocol("evemajpreview://hotkey/exit_app")
    stays("the app to keep running", lambda: session.app.poll() is None, 1.0)


@fresh({"protocolLinks": {"allowCloseAll": True}})
@covers("ProtocolLinksConfig.allowCloseAll")
def test_links_can_close_all_when_allowed(session):
    protocol_close(session, "evemajpreview://hotkey/close_all", closes=True, expected_open=set())


@fresh({"protocolLinks": {"allowCloseActive": True}})
@covers("ProtocolLinksConfig.allowCloseActive")
def test_links_can_close_the_active_client_when_allowed(session):
    protocol_close(session, "evemajpreview://hotkey/close_active", closes=True, expected_open={BRAVO})


@fresh({"protocolLinks": {"allowCloseGroup": True}})
@covers("ProtocolLinksConfig.allowCloseGroup")
def test_links_can_close_a_group_when_allowed(session):
    protocol_close(session, "evemajpreview://group/close/Fleet", closes=True, expected_open={BRAVO})


@fresh({"protocolLinks": {"allowExitApp": True}})
@covers("ProtocolLinksConfig.allowExitApp")
def test_links_can_exit_the_app_when_allowed(session):
    session.use()
    session.protocol("evemajpreview://hotkey/exit_app")
    wait_for("the app to exit", lambda: session.app.poll() is not None)
