"""Chat alerts: keyword and intel rules on chat channels."""

from eve_logs import pace
from harness import ALPHA, BRAVO, check, covers, stays, wait_for

GLOBAL_SETTINGS = {"chatlog": {"enabled": True}}
CHANNEL = "Test Chat"
INTEL = "Test Intel"


def keyword_rule(**options) -> dict:
    return {"name": "Cynos", "kind": "keyword", "channels": CHANNEL, "keywords": "cyno", "cooldown_ms": 0, **options}


def intel_rule(**options) -> dict:
    return {"name": "Intel", "kind": "intel", "channels": INTEL, "max_jumps": 5, "cooldown_ms": 0, **options}


def start(session, rules: list[dict], **profile):
    session.use({"chatAlerts": rules, **profile})
    return session.start_logged_client(ALPHA, system="Jita", channels=(CHANNEL, INTEL))


def no_alert(session, notification_type: str, for_s: float = 1.5):
    stays(f"no {notification_type} alert", lambda: notification_type not in session.alerts(ALPHA), for_s,
          details=lambda: session.alerts(ALPHA))


@covers("ChatAlertConfig.kind", "ChatAlertConfig.keywords", "ChatAlertConfig.channels", "NotificationType.ChatKeyword")
def test_a_keyword_in_a_watched_channel_raises_an_alert(session):
    logs = start(session, [keyword_rule()])
    logs.say(CHANNEL, "Scout", "cyno up on the gate")
    session.wait_for_alert(ALPHA, "ChatKeyword")


def test_a_message_without_the_keyword_raises_nothing(session):
    logs = start(session, [keyword_rule()])
    logs.say(CHANNEL, "Scout", "all quiet here")
    no_alert(session, "ChatKeyword")


def test_a_keyword_in_another_channel_raises_nothing(session):
    logs = start(session, [keyword_rule(channels="Somewhere Else")])
    logs.say(CHANNEL, "Scout", "cyno up on the gate")
    no_alert(session, "ChatKeyword")


def test_a_channel_pattern_matches_by_wildcard(session):
    logs = start(session, [keyword_rule(channels="Test C*")])
    logs.say(CHANNEL, "Scout", "cyno up on the gate")
    session.wait_for_alert(ALPHA, "ChatKeyword")


@covers("ChatAlertConfig.exclude")
def test_an_excluded_word_stops_the_alert(session):
    logs = start(session, [keyword_rule(exclude="fake")])
    logs.say(CHANNEL, "Scout", "fake cyno, ignore")
    no_alert(session, "ChatKeyword")


@covers("ChatAlertConfig.enabled")
def test_a_disabled_rule_raises_nothing(session):
    logs = start(session, [keyword_rule(enabled=False)])
    logs.say(CHANNEL, "Scout", "cyno up on the gate")
    no_alert(session, "ChatKeyword")


@covers("ChatAlertConfig.cooldown_ms")
def test_the_cooldown_keeps_a_repeat_quiet(session):
    for cooldown, entries in ((60000, 1), (0, 2)):
        # A word of its own each round: a cooldown is kept by rule position and word, across profiles, so earlier hits
        # on "cyno" would count. Lines of their own too, as the app drops a line it saw in the last 5 s.
        word = f"beacon{cooldown}"
        logs = start(session, [keyword_rule(keywords=word, cooldown_ms=cooldown)])
        logs.say(CHANNEL, "Scout", f"{word} up on the gate")
        session.wait_for_alert(ALPHA, "ChatKeyword")
        pace(0.3)
        logs.say(CHANNEL, "Scout", f"{word} up on the gate again")
        wait_for(f"cooldown {cooldown}: {entries} history entr{'y' if entries == 1 else 'ies'}",
                 lambda: session.history_count("ChatKeyword") >= entries, details=lambda: session.history_count("ChatKeyword"))
        stays(f"cooldown {cooldown}: exactly {entries}", lambda: session.history_count("ChatKeyword") == entries, 1.0,
              details=lambda: session.history_count("ChatKeyword"))


def test_a_rule_has_its_own_alert_settings(session):
    logs = start(session, [keyword_rule(alert={"show_text": False, "show_border": True})])
    logs.say(CHANNEL, "Scout", "cyno up on the gate")
    alert = session.wait_for_alert(ALPHA, "ChatKeyword")
    check((alert["shows_text"], alert["shows_border"]) == (False, True), f"alert shows_text={alert['shows_text']}, shows_border={alert['shows_border']}")


@covers("CharacterConfig.excludeFromChatAlerts")
def test_a_character_excluded_from_chat_alerts_gets_none(session):
    logs = start(session, [keyword_rule()], characters=[{"name": ALPHA, "excludeFromChatAlerts": True}])
    session.start_logged_client(BRAVO, system="Jita", channels=(CHANNEL,))
    logs.say(CHANNEL, "Scout", "cyno up on the gate")
    no_alert(session, "ChatKeyword")


# Intel: Alpha sits in Jita; Perimeter is one jump away and Amarr many.

@covers("NotificationType.ChatIntel", "ChatAlertConfig.max_jumps")
def test_intel_near_a_client_raises_an_alert_and_far_intel_doesnt(session):
    logs = start(session, [intel_rule()])
    logs.say(INTEL, "Scout", "Amarr +1 neut")
    no_alert(session, "ChatIntel")
    logs.say(INTEL, "Scout", "Perimeter +1 neut")
    session.wait_for_alert(ALPHA, "ChatIntel")


def test_intel_out_of_range_raises_nothing(session):
    logs = start(session, [intel_rule(max_jumps=0)])
    logs.say(INTEL, "Scout", "Perimeter +1 neut")
    no_alert(session, "ChatIntel")


def test_every_intel_report_is_listed_shown_or_not(session):
    logs = start(session, [intel_rule(max_jumps=0)])
    logs.say(INTEL, "Scout", "Perimeter +1 neut")
    wait_for("the report in the intel history", lambda: (session.state() or {}).get("intel_history"),
             details=lambda: (session.state() or {}).get("intel_history"))
