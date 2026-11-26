"""Travel mode: alerting a client the rest of its group has left behind."""

from eve_logs import pace
from harness import ALPHA, BRAVO, CHARLIE, VK_F13, covers, stays

GLOBAL_SETTINGS = {"chatlog": {"enabled": True}}
LEFT_BEHIND = "TravelLeftBehind"


def travel(**settings) -> dict:
    return {"travel": {"enabled": True, "window_seconds": 1, **settings}}


def split_up(logs: dict):
    """Alpha and Bravo jump to Perimeter while Charlie jumps the other way."""
    for name, destination in ((ALPHA, "Perimeter"), (BRAVO, "Perimeter"), (CHARLIE, "Maurasi")):
        logs[name].jump(destination)
        pace(0.2)


def start(session, profile: dict) -> dict:
    session.use(profile)
    return {name: session.start_logged_client(name, system="Jita") for name in (ALPHA, BRAVO, CHARLIE)}


def none_left_behind(session, for_s: float = 4.0):
    stays("no one alerted as left behind", lambda: all(LEFT_BEHIND not in session.alerts(n) for n in (ALPHA, BRAVO, CHARLIE)), for_s)


@covers("NotificationType.TravelLeftBehind", "TravelConfig.enabled", "TravelConfig.window_seconds",
        "TravelConfig.threshold_mode", "TravelConfig.threshold_percent")
def test_a_client_left_behind_by_most_of_the_group_is_alerted(session):
    split_up(start(session, travel(threshold_mode="percent", threshold_percent=50.0)))
    session.wait_for_alert(CHARLIE, LEFT_BEHIND, timeout_s=6.0)


def test_travel_mode_is_off_by_default(session):
    split_up(start(session, {"travel": {"window_seconds": 1}}))
    none_left_behind(session)


@covers("TravelConfig.threshold_count")
def test_a_count_threshold_needs_that_many_together(session):
    split_up(start(session, travel(threshold_mode="count", threshold_count=3)))
    none_left_behind(session)


@covers("HotkeysConfig.hotkeyToggleTravelMode")
def test_the_travel_mode_key_turns_it_on(session):
    logs = start(session, {"travel": {"window_seconds": 1}, "hotkeys": {"hotkeyToggleTravelMode": f"0x{VK_F13:02X}"}})
    session.switch_to(ALPHA)
    session.press(VK_F13)
    split_up(logs)
    session.wait_for_alert(CHARLIE, LEFT_BEHIND, timeout_s=6.0)
