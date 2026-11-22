"""Alerts raised from gamelog lines, and each alert setting, tried on Cargo Full."""

import time

from eve_logs import ALERT_LINES, pace
from harness import ALPHA, BRAVO, CHARLIE, VK_F13, check, covers, fresh, stays, wait_for

GLOBAL_SETTINGS = {"chatlog": {"enabled": True}}
RED, GREEN = 0xFFFF0000, 0xFF00FF00
CARGO = "CargoFull"


def cargo(**type_config) -> dict:
    return {"notifications": {"type_configs": {CARGO: type_config}}}


def no_alert(session, name: str, notification_type: str, for_s: float = 1.5):
    stays(f"no {notification_type} alert on {name}", lambda: notification_type not in session.alerts(name), for_s,
          details=lambda: session.alerts(name))


@covers(*(f"NotificationType.{t}" for t in ALERT_LINES))
def test_each_gamelog_alert_line_raises_its_alert(session):
    session.use()
    logs = session.start_logged_client(ALPHA)
    missing = []
    for notification_type in ALERT_LINES:
        logs.alert(notification_type)
        try:
            session.wait_for_alert(ALPHA, notification_type, timeout_s=3.0)
        except AssertionError:
            missing.append(notification_type)
        pace()
    check(not missing, f"no alert for {missing}")


@covers("NotificationType.SystemChange", "ChatlogConfig.enabled", "ChatlogConfig.chatlogDir", "ChatlogConfig.gamelogDir")
def test_a_jump_moves_the_client_and_raises_a_system_change(session):
    session.use()
    logs = session.start_logged_client(ALPHA, system="Jita")
    logs.jump("Perimeter")
    wait_for("Alpha to be in Perimeter", lambda: session.system_of(ALPHA) == "Perimeter", details=lambda: session.system_of(ALPHA))
    session.wait_for_alert(ALPHA, "SystemChange")


def test_a_local_change_moves_the_client(session):
    session.use()
    logs = session.start_logged_client(ALPHA, system="Jita")
    logs.local_change("Amarr")
    wait_for("Alpha to be in Amarr", lambda: session.system_of(ALPHA) == "Amarr", details=lambda: session.system_of(ALPHA))


def test_lines_are_read_quickly_at_a_short_poll_interval(session):
    session.use()
    logs = session.start_logged_client(ALPHA)
    time.sleep(0.5)
    logs.alert(CARGO)
    session.wait_for_alert(ALPHA, CARGO, timeout_s=1.0)


@fresh({"chatlog": {"enabled": True, "pollIntervalMs": 4000}})
@covers("ChatlogConfig.pollIntervalMs")
def test_lines_wait_for_a_long_poll_interval(session):
    session.use()
    logs = session.start_logged_client(ALPHA)
    time.sleep(0.5)
    logs.alert(CARGO)
    no_alert(session, ALPHA, CARGO, 1.0)
    session.wait_for_alert(ALPHA, CARGO, timeout_s=6.0)


# Each alert setting, tried on Cargo Full.

@covers("NotificationTypeConfig.enabled")
def test_a_type_turned_off_shows_nothing_and_leaves_no_history(session):
    session.use(cargo(enabled=False))
    logs = session.start_logged_client(ALPHA)
    logs.alert(CARGO)
    no_alert(session, ALPHA, CARGO)
    check(session.history_count(CARGO) == 0, "a turned-off alert was recorded in history")


@covers("NotificationConfig.enabled")
def test_alerts_turned_off_show_nothing(session):
    session.use({"notifications": {"enabled": False}})
    logs = session.start_logged_client(ALPHA)
    logs.alert(CARGO)
    no_alert(session, ALPHA, CARGO)


@covers("CharacterConfig.notificationsMuted")
def test_a_muted_character_gets_no_alerts(session):
    session.use({"characters": [{"name": ALPHA, "notificationsMuted": True}]})
    logs = session.start_logged_client(ALPHA)
    logs.alert(CARGO)
    no_alert(session, ALPHA, CARGO)


def test_an_alert_is_recorded_in_history(session):
    session.use()
    logs = session.start_logged_client(ALPHA)
    logs.alert(CARGO)
    wait_for("a Cargo Full history entry for Alpha",
             lambda: any(e["notification_type"] == CARGO and e["character_name"] == ALPHA for e in session.history()))


@covers("NotificationTypeConfig.show_text")
def test_show_text_off_keeps_the_alert_without_words(session):
    session.use(cargo(show_text=False))
    logs = session.start_logged_client(ALPHA)
    logs.alert(CARGO)
    check(session.wait_for_alert(ALPHA, CARGO)["shows_text"] is False, "the alert still shows its text")


@covers("NotificationTypeConfig.duration_ms")
def test_an_alert_goes_after_its_duration(session):
    for duration, stays_up in ((800, False), (10000, True)):
        session.use(cargo(duration_ms=duration))
        logs = session.start_logged_client(ALPHA)
        logs.alert(CARGO)
        session.wait_for_alert(ALPHA, CARGO)
        time.sleep(2.0)
        check((CARGO in session.alerts(ALPHA)) == stays_up, f"duration {duration}: alert {'gone' if stays_up else 'still up'} after 2s")


@covers("NotificationTypeConfig.suppress_when_focused")
def test_suppress_when_focused_holds_the_alert_back_from_the_focused_client(session):
    session.use(cargo(suppress_when_focused=True))
    logs = session.start_logged_client(ALPHA)
    session.switch_to(ALPHA)
    logs.alert(CARGO)
    no_alert(session, ALPHA, CARGO)
    check(session.history_count(CARGO) == 1, "a held-back alert should still be recorded in history")


@covers("NotificationTypeConfig.suppress_when_clicked", "NotificationConfig.suppress_click_duration_ms")
def test_suppress_when_clicked_holds_alerts_back_just_after_a_click(session):
    session.use({"notifications": {"suppress_click_duration_ms": 2000, "type_configs": {CARGO: {"suppress_when_clicked": True}}}})
    logs = session.start_logged_client(ALPHA)
    session.start_client(BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    session.switch_to(BRAVO)
    session.click_thumbnail(ALPHA)
    session.switch_to(BRAVO)
    logs.alert(CARGO)
    no_alert(session, ALPHA, CARGO, 1.0)
    time.sleep(1.5)
    logs.alert(CARGO)
    session.wait_for_alert(ALPHA, CARGO)
    session.park_cursor()


@covers("NotificationTypeConfig.show_hidden_thumbnail")
def test_an_alert_can_show_a_hidden_thumbnail_while_it_lasts(session):
    for reveals in (True, False):
        session.use(cargo(show_hidden_thumbnail=reveals, duration_ms=3000))
        logs = session.start_logged_client(ALPHA)
        session.wait_for_thumbnails({ALPHA})
        session.protocol("evemajpreview://hotkey/toggle_visibility")
        session.wait_for_thumbnails(set())
        logs.alert(CARGO)
        if reveals:
            session.wait_for_thumbnails({ALPHA})
        else:
            session.assert_thumbnails_stay(set(), 1.5)
        session.protocol("evemajpreview://hotkey/toggle_visibility")


@covers("NotificationTypeConfig.throttle_ms")
def test_throttle_drops_a_repeat_shown_too_soon(session):
    for throttle, repeats in ((10000, False), (0, True)):
        session.use(cargo(duration_ms=500, throttle_ms=throttle))
        logs = session.start_logged_client(ALPHA)
        logs.alert(CARGO)
        session.wait_for_alert(ALPHA, CARGO)
        wait_for("the first alert to go", lambda: CARGO not in session.alerts(ALPHA))
        logs.alert(CARGO)
        if repeats:
            session.wait_for_alert(ALPHA, CARGO)
        else:
            no_alert(session, ALPHA, CARGO, 1.0)


@covers("NotificationTypeConfig.border_color", "NotificationTypeConfig.text_color",
        "NotificationTypeConfig.show_border", "NotificationTypeConfig.flash_border")
def test_an_alerts_border_and_text_follow_its_settings(session):
    session.use(cargo(border_color=f"0x{RED:08X}", text_color=f"0x{GREEN:08X}", show_border=True, flash_border=True))
    logs = session.start_logged_client(ALPHA)
    logs.alert(CARGO)
    alert = session.wait_for_alert(ALPHA, CARGO)
    expected = {"border_color": RED, "text_color": GREEN, "shows_border": True, "flashes_border": True}
    actual = {key: alert[key] for key in expected}
    check(actual == expected, f"alert looks like {actual}, expected {expected}")


@covers("NotificationTypeConfig.custom_text")
def test_custom_text_fills_its_placeholders(session):
    session.use(cargo(custom_text="{module} full on {character}"))
    logs = session.start_logged_client(ALPHA)
    logs.alert(CARGO)
    text = session.wait_for_alert(ALPHA, CARGO)["text"]
    check(text == f"Miner II full on {ALPHA}", f"alert text is '{text}'")


@covers("NotificationTypeConfig.custom_text_alt", "NotificationType.CycleExclusion")
def test_the_second_custom_text_is_for_the_types_other_state(session):
    # Given in part, so this also checks the rest keeps CycleExclusion's defaults: without its zero throttle, the second toggle is held back.
    session.use({"notifications": {"type_configs": {"CycleExclusion": {"custom_text": "Out: {character}", "custom_text_alt": "Back: {character}"}}}})
    session.start_logged_client(ALPHA)
    session.switch_to(ALPHA)
    newest_text = lambda: next((a["text"] for a in session.client_state(ALPHA).get("alerts", []) if a["notification_type"] == "CycleExclusion"), None)
    session.protocol("evemajpreview://hotkey/toggle_exclusion")
    wait_for("the excluded wording", lambda: newest_text() == f"Out: {ALPHA}", details=newest_text)
    session.protocol("evemajpreview://hotkey/toggle_exclusion")
    wait_for("the included wording", lambda: newest_text() == f"Back: {ALPHA}", details=newest_text)


def plays(session) -> tuple[int, int]:
    state = session.state() or {}
    return state.get("sounds_played", 0), state.get("speeches_started", 0)


@covers("NotificationTypeConfig.tts_enabled", "NotificationTypeConfig.sound_enabled", "NotificationTypeConfig.sound_path")
def test_an_alert_speaks_and_plays_its_sound_when_set_to(session):
    # A path that doesn't exist, so nothing is actually heard.
    for type_config, expected in (({"tts_enabled": True}, (0, 1)), ({"sound_enabled": True, "sound_path": "missing.wav"}, (1, 0)),
                                  ({"sound_enabled": True}, (0, 0))):
        session.use(cargo(**type_config))
        logs = session.start_logged_client(ALPHA)
        before = plays(session)
        logs.alert(CARGO)
        session.wait_for_alert(ALPHA, CARGO)
        time.sleep(0.3)
        after = plays(session)
        played = (after[0] - before[0], after[1] - before[1])
        check(played == expected, f"{type_config}: played (sounds, speeches) {played}, expected {expected}")


@covers("HotkeysConfig.hotkeyToggleAlertMute")
def test_the_mute_key_silences_alerts_until_pressed_again(session):
    session.use({**cargo(tts_enabled=True, throttle_ms=0), "hotkeys": {"hotkeyToggleAlertMute": f"0x{VK_F13:02X}"}})
    logs = session.start_logged_client(ALPHA)
    session.switch_to(ALPHA)
    session.press(VK_F13)
    wait_for("alerts to be muted", lambda: (session.state() or {}).get("are_alerts_muted"))
    before = plays(session)
    logs.alert(CARGO)
    session.wait_for_alert(ALPHA, CARGO)
    time.sleep(0.3)
    check(plays(session) == before, "a muted alert still spoke")
    session.press(VK_F13)
    wait_for("alerts to be unmuted", lambda: not (session.state() or {}).get("are_alerts_muted"))
    logs.alert(CARGO)
    wait_for("the alert to speak once unmuted", lambda: plays(session)[1] == before[1] + 1)


@covers("HotkeysConfig.hotkeyClearNotificationHistory")
def test_the_clear_history_key_empties_the_history(session):
    session.use({"hotkeys": {"hotkeyClearNotificationHistory": f"0x{VK_F13:02X}"}})
    logs = session.start_logged_client(ALPHA)
    logs.alert(CARGO)
    wait_for("a history entry", lambda: session.history_count(CARGO) == 1)
    session.switch_to(ALPHA)
    session.press(VK_F13)
    wait_for("the history to empty", lambda: session.history() == [], details=session.history)


@covers("HotkeysConfig.hotkeyCycleNotified", "HotkeysConfig.hotkeyPreviousNotified")
def test_the_notified_keys_visit_clients_with_recent_alerts(session):
    session.use({"hotkeys": {"hotkeyCycleNotified": f"0x{VK_F13:02X}", "hotkeyPreviousNotified": f"0x{VK_F13 + 1:02X}"}})
    session.start_logged_client(ALPHA)
    bravo = session.start_logged_client(BRAVO)
    charlie = session.start_logged_client(CHARLIE)
    bravo.alert(CARGO)
    pace(0.3)
    charlie.alert(CARGO)
    session.wait_for_alert(CHARLIE, CARGO)
    session.switch_to(ALPHA)
    visited = []
    for _ in range(2):
        session.press(VK_F13)
        reached = lambda: (lambda name: name if name in (BRAVO, CHARLIE) and name not in visited else None)(session.foreground_client())
        visited.append(wait_for("focus to reach a notified client", reached, details=session.foreground_client))
    check(sorted(visited) == [BRAVO, CHARLIE], f"visited {visited}")
    session.press(VK_F13 + 1)
    session.wait_for_foreground(visited[0])


@covers("NotificationConfig.notified_cycle_retention_seconds")
def test_a_client_drops_out_of_the_notified_cycle_after_the_retention(session):
    session.use({"notifications": {"notified_cycle_retention_seconds": 5}, "hotkeys": {"hotkeyCycleNotified": f"0x{VK_F13:02X}"}})
    session.start_logged_client(ALPHA)
    bravo = session.start_logged_client(BRAVO)
    bravo.alert(CARGO)
    session.wait_for_alert(BRAVO, CARGO)
    time.sleep(6)
    session.switch_to(ALPHA)
    session.press(VK_F13)
    stays("Alpha to keep focus", lambda: session.foreground_client() == ALPHA, 1.0, details=session.foreground_client)


# Alerts on the user's own actions.

@covers("NotificationType.HotkeySuspend")
def test_suspending_hotkeys_raises_an_alert(session):
    session.use({"hotkeys": {"hotkeySuspend": f"0x{VK_F13:02X}"}})
    session.start_logged_client(ALPHA)
    session.switch_to(ALPHA)
    session.press(VK_F13)
    session.wait_for_alert(ALPHA, "HotkeySuspend")
    session.press(VK_F13)


@covers("NotificationType.AutoMinimizeToggle")
def test_toggling_auto_minimize_raises_an_alert(session):
    session.use({"hotkeys": {"hotkeyToggleAutoMinimize": f"0x{VK_F13:02X}"}})
    session.start_logged_client(ALPHA)
    session.switch_to(ALPHA)
    session.press(VK_F13)
    session.wait_for_alert(ALPHA, "AutoMinimizeToggle")


@covers("NotificationType.SavedPositionMove")
def test_moving_clients_to_saved_positions_raises_an_alert(session):
    session.use({"characters": [{"name": ALPHA, "windowPosition": {"x": 300, "y": 200}}]})
    session.start_logged_client(ALPHA)
    session.protocol("evemajpreview://hotkey/move_to_saved_positions")
    session.wait_for_alert(ALPHA, "SavedPositionMove")


@covers("NotificationType.ProfileSwitch")
def test_switching_profile_raises_an_alert(session):
    session.use()
    session.start_logged_client(ALPHA)
    session.write_profile("other.json")
    session.protocol("evemajpreview://profile/other.json")
    session.wait_for_alert(ALPHA, "ProfileSwitch")


@covers("NotificationType.GroupMembership")
def test_assigning_to_a_group_raises_an_alert(session):
    session.use({"hotkeyGroups": [{"name": "Fleet", "characters": [], "assignKey": f"0x{VK_F13:02X}"}]})
    session.start_logged_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    session.switch_to(ALPHA)
    session.hover(ALPHA)
    session.press(VK_F13)
    session.wait_for_alert(ALPHA, "GroupMembership")
    session.park_cursor()
