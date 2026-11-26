"""Auto-minimize and auto-move: what the app does to clients on its own."""

from harness import ALPHA, BRAVO, VK_F13, covers, stays, wait_for

TARGET = (300, 200)


def minimized(session, name: str) -> bool:
    return session.clients[name].window().is_minimized


def auto_minimize(**settings) -> dict:
    return {"autoMinimize": {"enabled": True, "delayMs": 500, **settings}}


def start(session, *names: str):
    session.start_clients(*names)
    session.wait_for_thumbnails(set(names))


@covers("AutoMinimizeConfig.enabled")
def test_auto_minimize_minimizes_clients_left_inactive(session):
    session.use(auto_minimize())
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    wait_for("Bravo to be minimized", lambda: minimized(session, BRAVO))
    stays("Alpha, focused, to stay open", lambda: not minimized(session, ALPHA), 1.0)


def test_auto_minimize_is_off_by_default(session):
    session.use({"autoMinimize": {"delayMs": 500}})
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    stays("Bravo to stay open", lambda: not minimized(session, BRAVO), 2.0)


@covers("AutoMinimizeConfig.delayMs")
def test_auto_minimize_waits_for_the_delay(session):
    session.use(auto_minimize(delayMs=3000))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    stays("Bravo to stay open before the delay", lambda: not minimized(session, BRAVO), 1.5)
    wait_for("Bravo to be minimized after the delay", lambda: minimized(session, BRAVO), timeout_s=4.0)


@covers("CharacterConfig.excludeFromMinimize")
def test_auto_minimize_spares_a_character_excluded_from_it(session):
    session.use({**auto_minimize(), "characters": [{"name": BRAVO, "excludeFromMinimize": True}]})
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    stays("Bravo to stay open", lambda: not minimized(session, BRAVO), 2.0)


def focus_leaves_eve(session, exempts: bool):
    session.use(auto_minimize(exemptLastActiveOnFocusLoss=exempts))
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    wait_for("Bravo to be minimized", lambda: minimized(session, BRAVO))
    session.start_bystander()
    session.wait_for_foreground("Bystander")


@covers("AutoMinimizeConfig.exemptLastActiveOnFocusLoss")
def test_leaving_eve_can_spare_the_last_active_client(session):
    focus_leaves_eve(session, exempts=True)
    stays("Alpha, the last active client, to stay open", lambda: not minimized(session, ALPHA), 2.0)


def test_leaving_eve_minimizes_the_last_active_client_by_default(session):
    focus_leaves_eve(session, exempts=False)
    wait_for("Alpha to be minimized", lambda: minimized(session, ALPHA))


@covers("AutoMinimizeConfig.startMinimized")
def test_start_minimized_minimizes_a_new_client(session):
    session.use({"autoMinimize": {"startMinimized": True}})
    session.start_client(ALPHA)
    wait_for("Alpha to start minimized", lambda: minimized(session, ALPHA))


@covers("HotkeysConfig.hotkeyToggleAutoMinimize")
def test_the_toggle_auto_minimize_key_turns_it_on_for_now(session):
    session.use({"autoMinimize": {"enabled": False, "delayMs": 500}, "hotkeys": {"hotkeyToggleAutoMinimize": f"0x{VK_F13:02X}"}})
    start(session, ALPHA, BRAVO)
    session.switch_to(ALPHA)
    session.press(VK_F13)
    wait_for("Bravo to be minimized", lambda: minimized(session, BRAVO))


# Auto-move

def auto_move(enabled: bool = True, **settings) -> dict:
    return {"autoMovePosition": {"enabled": enabled, **settings},
            "characters": [{"name": ALPHA, "windowPosition": {"x": TARGET[0], "y": TARGET[1]}}]}


def at_target(session) -> bool:
    window = session.clients[ALPHA].window()
    return abs(window.left - TARGET[0]) <= 10 and abs(window.top - TARGET[1]) <= 10


def position(session):
    window = session.clients[ALPHA].window()
    return window.left, window.top


@covers("AutoMovePositionConfig.enabled")
def test_auto_move_moves_a_new_client_to_its_saved_position(session):
    session.use(auto_move())
    session.start_client(ALPHA)
    wait_for(f"Alpha to reach {TARGET}", lambda: at_target(session), details=lambda: position(session))


def test_auto_move_is_off_by_default(session):
    session.use(auto_move(enabled=False))
    session.start_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    stays("Alpha to stay where it opened", lambda: not at_target(session), 1.5, details=lambda: position(session))


@covers("CharacterConfig.excludeFromAutoMove")
def test_auto_move_spares_a_character_excluded_from_it(session):
    profile = auto_move()
    profile["characters"][0]["excludeFromAutoMove"] = True
    session.use(profile)
    session.start_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    stays("Alpha to stay where it opened", lambda: not at_target(session), 1.5, details=lambda: position(session))


@covers("AutoMovePositionConfig.verifyIntervalMs", "AutoMovePositionConfig.verifyCount")
def test_a_client_that_drifts_after_the_move_is_moved_back_after_the_interval(session):
    session.use(auto_move(verifyIntervalMs=1500, verifyCount=6))
    session.start_client(ALPHA)
    wait_for(f"Alpha to reach {TARGET}", lambda: at_target(session), details=lambda: position(session))
    session.clients[ALPHA].move(600, 400)
    stays("Alpha to stay where it drifted within the interval", lambda: not at_target(session), 1.0, details=lambda: position(session))
    wait_for(f"Alpha to be moved back to {TARGET}", lambda: at_target(session), timeout_s=6.0, details=lambda: position(session))


def test_without_verification_a_drifted_client_stays_put(session):
    session.use(auto_move(verifyIntervalMs=250, verifyCount=0))
    session.start_client(ALPHA)
    wait_for(f"Alpha to reach {TARGET}", lambda: at_target(session), details=lambda: position(session))
    session.clients[ALPHA].move(600, 400)
    stays("Alpha to stay where it drifted", lambda: not at_target(session), 2.0, details=lambda: position(session))


@covers("AutoMovePositionConfig.moveOnStartup")
def test_move_on_startup_moves_clients_already_running(session):
    session.use(auto_move(enabled=False, moveOnStartup=True))
    session.start_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    # Restarted with the client still open, so the app finds it already running.
    session.stop()
    session.start()
    wait_for(f"Alpha to reach {TARGET}", lambda: at_target(session), details=lambda: position(session))
