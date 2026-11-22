"""What the client list and the History, Intel and Map panels list, read from the text each one last drew."""

import time

from eve_logs import bounty, combat_in, combat_out, mined, pace
from harness import ALPHA, BRAVO, check, client_to_screen, covers, monitors, stays, wait_for

GLOBAL_SETTINGS = {"chatlog": {"enabled": True}}
QUIET_MAP = {"liveStats": False, "showKills": False, "showAnsiblex": False}
LIST, HISTORY, INTEL, MAP = "client_list", "history", "intel", "map"
LIST_CLASS, INTEL_CLASS = "EVE_LIST_CLASS", "EVE_INTEL_PANEL_CLASS"
CHAT, INTEL_CHANNEL = "Test Chat", "Test Intel"
NAMES = {ALPHA, BRAVO}
RGB = 0x00FFFFFF
# src/panels/list_look.zig's NAME (palette.TEXT), for a row that's neither active nor coloured.
LIST_NAME_COLOR = 0xFFE8E6E1
REGIONS = {"The Forge": 10000002, "Domain": 10000043, "Lonetrek": 10000016, "Sinq Laison": 10000032}


def strings(session, kind: str) -> list[str]:
    return session.panel_strings(kind)


def text_named(session, kind: str, text: str) -> dict | None:
    return next((t for t in session.panel_texts(kind) if t["text"] == text), None)


def same_color(first: int, second: int) -> bool:
    return first & RGB == second & RGB


# The client list

# Beside thumbnails the list takes their colours and focus hiding; its own apply only to the list alone.
LIST_ALONE = "ClientList"


def show_list(session, **list_settings):
    session.use({"display": {"viewMode": LIST_ALONE}, "listView": {"x": 700, "y": 300, "columnWidth": 320, **list_settings},
                 "mapPanel": QUIET_MAP})


def list_two(session, **list_settings):
    """Alpha in Jita and Bravo in Amarr, Alpha active."""
    show_list(session, **list_settings)
    alpha = session.start_logged_client(ALPHA, system="Jita")
    session.start_logged_client(BRAVO, system="Amarr")
    session.switch_to(ALPHA)
    session.wait_for_panel_window(LIST_CLASS)
    for name in NAMES:
        session.wait_for_panel_text(LIST, name)
    return alpha


def name_top(session, name: str) -> int:
    return session.wait_for_panel_text(LIST, name)["top"]


@covers("ListViewConfig.order")
def test_the_client_list_orders_rows_as_set(session):
    for order, first in (("ConfiguredCharacters", BRAVO), ("Alphabetical", ALPHA)):
        session.use({"display": {"viewMode": LIST_ALONE}, "listView": {"order": order}, "mapPanel": QUIET_MAP,
                     "characters": [{"name": BRAVO}, {"name": ALPHA}]})
        session.start_clients(ALPHA, BRAVO)
        session.wait_for_panel_window(LIST_CLASS)
        tops = lambda: {name: (text_named(session, LIST, name) or {}).get("top") for name in NAMES}
        second = (NAMES - {first}).pop()
        wait_for(f"{order}: {first} listed above {second}",
                 lambda: None not in tops().values() and tops()[first] < tops()[second], details=tops)


@covers("CharacterConfig.hideFromClientList")
def test_a_character_hidden_from_the_client_list_gets_no_row(session):
    session.use({"display": {"viewMode": "ThumbnailsAndList"}, "mapPanel": QUIET_MAP,
                 "characters": [{"name": BRAVO, "hideFromClientList": True}]})
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_panel_text(LIST, ALPHA)
    stays("no row for Bravo", lambda: BRAVO not in strings(session, LIST), 1.0, details=lambda: strings(session, LIST))


@covers("ListViewConfig.columns")
def test_the_client_list_lays_rows_out_in_columns(session):
    for columns, side_by_side in ((2, True), (1, False)):
        show_list(session, columns=columns)
        session.start_clients(ALPHA, BRAVO)
        window = session.wait_for_panel_window(LIST_CLASS)
        alpha, bravo = (session.wait_for_panel_text(LIST, name) for name in (ALPHA, BRAVO))
        check((alpha["top"] == bravo["top"]) == side_by_side, f"columns={columns}: names at tops {alpha['top']} and {bravo['top']}")
        width = lambda: session.panel_window(LIST_CLASS).width
        wait_for(f"columns={columns}: the list {columns * 320} wide", lambda: width() == columns * 320, details=width)


@covers("ListViewConfig.fontSize")
def test_a_bigger_font_makes_taller_rows(session):
    heights = []
    for size in (12, 20):
        show_list(session, fontSize=size)
        session.start_client(ALPHA)
        heights.append(session.wait_for_panel_window(LIST_CLASS).height)
    check(heights[1] > heights[0], f"the list is {heights[1]} high at font size 20, {heights[0]} at 12")


@covers("ListViewConfig.showSystemName", "ListViewConfig.systemNameColor")
def test_each_row_names_its_system_in_the_system_colour(session):
    list_two(session, systemNameColor="0xFF2468AC")
    jita = session.wait_for_panel_text(LIST, "Jita")
    check(same_color(jita["color"], 0xFF2468AC), f"Jita drawn in {jita['color']:08X}, expected FF2468AC")
    list_two(session, showSystemName=False)
    stays("no system names", lambda: not {"Jita", "Amarr"} & set(strings(session, LIST)), 1.0, details=lambda: strings(session, LIST))


@covers("ListViewConfig.showSystemSecurity")
def test_system_security_shows_beside_the_name_as_set(session):
    list_two(session, showSystemSecurity=True)
    # Jita and Amarr (0.99) both read 0.9: security is cut to tenths, not rounded.
    session.wait_for_panel_text(LIST, "0.9")
    list_two(session, showSystemSecurity=False)
    stays("no security figures", lambda: "0.9" not in strings(session, LIST), 1.0, details=lambda: strings(session, LIST))


@covers("ListViewConfig.groupBySystem")
def test_grouping_by_system_puts_rows_under_system_headings(session):
    list_two(session, groupBySystem=True)
    session.wait_for_panel_text(LIST, "JITA")
    session.wait_for_panel_text(LIST, "AMARR")
    check("Jita" not in strings(session, LIST), "grouped rows still name their system")
    list_two(session, groupBySystem=False)
    stays("no system headings", lambda: "JITA" not in strings(session, LIST), 1.0, details=lambda: strings(session, LIST))


@covers("ListViewConfig.useUniqueSystemColors")
def test_unique_system_colours_tell_systems_apart(session):
    list_two(session, useUniqueSystemColors=True, systemNameColor="0xFF2468AC")
    jita, amarr = (session.wait_for_panel_text(LIST, system)["color"] for system in ("Jita", "Amarr"))
    check(not same_color(jita, amarr), f"Jita and Amarr share {jita:08X}")
    check(not same_color(jita, 0xFF2468AC), "Jita kept the plain system colour")


@covers("ListViewConfig.useUniqueCharacterNameColors")
def test_unique_name_colours_tell_characters_apart(session):
    list_two(session, useUniqueCharacterNameColors=False)
    # Bravo opened last, so its row is drawn active until the switch to Alpha redraws it.
    bravo_color = lambda: (text_named(session, LIST, BRAVO) or {}).get("color", 0)
    wait_for("Bravo's row in the plain name colour", lambda: same_color(bravo_color(), LIST_NAME_COLOR),
             details=lambda: f"{bravo_color():08X}")
    plain = bravo_color()
    list_two(session, useUniqueCharacterNameColors=True)
    alpha, bravo = (session.wait_for_panel_text(LIST, name)["color"] for name in (ALPHA, BRAVO))
    check(not same_color(alpha, bravo), f"Alpha and Bravo share {alpha:08X}")
    check(not same_color(bravo, plain), "Bravo kept the plain name colour")


@covers("ListViewConfig.showNotifications", "ListViewConfig.notificationColor")
def test_a_row_shows_its_newest_alert_in_the_alert_colour(session):
    alpha = list_two(session, notificationColor="0xFF13579B")
    alpha.alert("CargoFull")
    text = session.wait_for_alert(ALPHA, "CargoFull")["text"]
    drawn = session.wait_for_panel_text(LIST, text)
    check(same_color(drawn["color"], 0xFF13579B), f"the alert drawn in {drawn['color']:08X}, expected FF13579B")

    alpha = list_two(session, showNotifications=False)
    alpha.alert("CargoFull")
    session.wait_for_alert(ALPHA, "CargoFull")
    stays("no alert text in the list", lambda: text not in strings(session, LIST), 1.0, details=lambda: strings(session, LIST))


# Each rate: its settings' stem, its prefix, and lines that give it.
STATS = {
    "incoming": ("Incoming", "Dps", "IN: ", lambda i: combat_in(100)),
    "outgoing": ("Outgoing", "Dps", "OUT: ", lambda i: combat_out(150)),
    "mining": ("Mining", "Rate", "M: ", lambda i: mined(110)),
    "bounty": ("Bounty", "Rate", "ISK: ", lambda i: bounty(250000)),
}
STAT_COLOR = 0xFF9A3C7E


def make_stat_test(stat: str):
    stem, suffix, prefix, line = STATS[stat]
    shown, prefixed, colored = f"show{stem}{suffix}", f"show{stem}Prefix", f"{stem[0].lower()}{stem[1:]}{suffix}Color"

    @covers(f"ListViewConfig.{shown}", f"ListViewConfig.{prefixed}", f"ListViewConfig.{colored}")
    def test(session):
        for has_prefix in (True, False):
            show_list(session, **{shown: True, prefixed: has_prefix, colored: f"0x{STAT_COLOR:08X}"})
            logs = session.start_logged_client(ALPHA)
            # Mining and bounty rates wait until their lines span 3 s (activity/tracker.zig's MIN_RATE_SPAN_MS).
            for i in range(6):
                logs.game(line(i))
                pace(0.8)
            drawn = wait_for(f"Alpha's {stat} rate in the list", lambda: next(
                (t for t in session.panel_texts(LIST) if same_color(t["color"], STAT_COLOR) and t["text"][-1:].isalnum()), None),
                timeout_s=8.0, details=lambda: strings(session, LIST))
            check(drawn["text"].startswith(prefix) == has_prefix, f"{prefixed}={has_prefix}: the rate reads '{drawn['text']}'")

        show_list(session, **{shown: False})
        logs = session.start_logged_client(ALPHA)
        for i in range(4):
            logs.game(line(i))
            pace(0.3)
        stays(f"no {stat} rate with {shown} off", lambda: not any(same_color(t["color"], STAT_COLOR) for t in session.panel_texts(LIST)),
              1.5, details=lambda: strings(session, LIST))

    test.__name__ = f"test_the_client_list_shows_the_{stat}_rate_with_its_prefix_and_colour"
    return test


for _stat in STATS:
    _test = make_stat_test(_stat)
    globals()[_test.__name__] = _test


@covers("ListViewConfig.showTotals")
def test_a_totals_line_adds_up_the_shown_rates(session):
    for totals in (True, False):
        show_list(session, showIncomingDps=True, showTotals=totals)
        logs = session.start_logged_client(ALPHA)
        for _ in range(4):
            logs.game(combat_in(100))
            pace(0.3)
        if totals:
            session.wait_for_panel_text(LIST, "TOTAL")
        else:
            stays("no totals line", lambda: "TOTAL" not in strings(session, LIST), 1.5, details=lambda: strings(session, LIST))


# The History Panel

def show_history(session, alerts: tuple[str, ...] = (), rules: list | None = None, **history_settings):
    """Shows the panel with Alpha logged in; `alerts` are types whose throttle is lifted so each repeats."""
    session.use({"historyPanel": {"show": True, "x": 700, "y": 200, "width": 600, "height": 600, **history_settings},
                 "notifications": {"type_configs": {t: {"throttle_ms": 0} for t in alerts}}, "chatAlerts": rules or [],
                 "mapPanel": QUIET_MAP})
    logs = session.start_logged_client(ALPHA, channels=(CHAT,))
    session.wait_for_panel_window("EVE_HISTORY_PANEL_CLASS")
    return logs


def drawn_as_row(session, kind: str, entry_text: str) -> bool:
    """Whether the panel drew the entry's words, whole or split around a coloured lead."""
    return any(t == entry_text or (len(t) >= 8 and t in entry_text and t not in NAMES) for t in strings(session, kind))


def entry_text(session, notification_type: str) -> str:
    entry = wait_for(f"a {notification_type} history entry",
                     lambda: next((e for e in session.history() if e["notification_type"] == notification_type), None))
    return entry["text"]


def rows_drawn(session, texts: list[str]) -> int:
    return sum(drawn_as_row(session, HISTORY, text) for text in set(texts))


FIVE_TYPES = ("FleetInvite", "CargoFull", "WarpScrambled", "Docking", "ConversationInvite")


@covers("HistoryPanelConfig.maxRows")
def test_the_history_panel_lists_alerts_up_to_its_row_limit(session):
    for max_rows, expected in ((3, 3), (30, 5)):
        logs = show_history(session, maxRows=max_rows)
        for notification_type in FIVE_TYPES:
            logs.alert(notification_type)
            pace(0.2)
        texts = [entry_text(session, t) for t in FIVE_TYPES]
        wait_for(f"maxRows={max_rows}: {expected} rows", lambda: rows_drawn(session, texts) == expected,
                 details=lambda: strings(session, HISTORY))


@covers("HistoryPanelConfig.showTimestamp")
def test_history_rows_show_their_age_as_set(session):
    for shows in (True, False):
        logs = show_history(session, showTimestamp=shows)
        logs.alert("CargoFull")
        entry_text(session, "CargoFull")
        if shows:
            session.wait_for_panel_text(HISTORY, "just now")
        else:
            stays("no ages", lambda: "just now" not in strings(session, HISTORY), 1.0, details=lambda: strings(session, HISTORY))


@covers("HistoryPanelConfig.mergeEnabled", "HistoryPanelConfig.mergeWindowSec")
def test_repeated_alerts_merge_into_one_row_within_the_window(session):
    for settings, gap_s, merges in (({"mergeEnabled": True, "mergeWindowSec": 10}, 0.3, True), ({"mergeEnabled": False}, 0.3, False),
                                    ({"mergeEnabled": True, "mergeWindowSec": 1}, 2.5, False)):
        logs = show_history(session, alerts=("CargoFull",), **settings)
        logs.alert("CargoFull")
        time.sleep(gap_s)
        logs.alert("CargoFull")
        wait_for("two Cargo Full entries", lambda: session.history_count("CargoFull") == 2, details=lambda: session.history_count("CargoFull"))
        if merges:
            session.wait_for_panel_text(HISTORY, "×2")
        else:
            stays(f"{settings}: no merged row", lambda: "×2" not in strings(session, HISTORY), 1.0, details=lambda: strings(session, HISTORY))


@covers("HistoryPanelConfig.showCategoryFilters")
def test_the_category_chips_show_as_set(session):
    chips = {"Fleet", "Mining", "Combat", "Nav", "Chat", "General"}
    show_history(session, showCategoryFilters=True)
    wait_for("every category chip", lambda: chips <= set(strings(session, HISTORY)), details=lambda: strings(session, HISTORY))
    show_history(session, showCategoryFilters=False)
    stays("no category chips", lambda: not chips & set(strings(session, HISTORY)), 1.0, details=lambda: strings(session, HISTORY))


CHAT_RULE = {"name": "Cynos", "kind": "keyword", "channels": CHAT, "keywords": "cyno", "cooldown_ms": 0}
# Each category's filter, an alert in it, and an alert outside it to show the filter left the rest alone.
CATEGORIES = {
    "Fleet": ("showFleet", "FleetInvite", "CargoFull"),
    "Mining": ("showMining", "CargoFull", "FleetInvite"),
    "Combat": ("showCombat", "WarpScrambled", "CargoFull"),
    "Navigation": ("showNavigation", "Docking", "CargoFull"),
    "Chat": ("showChat", "ChatKeyword", "CargoFull"),
    "General": ("showGeneral", "ConversationInvite", "CargoFull"),
}


def make_category_test(category: str):
    field, inside, outside = CATEGORIES[category]

    @covers(f"HistoryPanelConfig.{field}")
    def test(session):
        logs = show_history(session, rules=[CHAT_RULE], **{field: False})
        for notification_type in (inside, outside):
            if notification_type == "ChatKeyword":
                logs.say(CHAT, "Scout", "cyno up on the gate")
            else:
                logs.alert(notification_type)
            pace(0.2)
        hidden, shown = entry_text(session, inside), entry_text(session, outside)
        wait_for(f"the {outside} row", lambda: drawn_as_row(session, HISTORY, shown), details=lambda: strings(session, HISTORY))
        check(not drawn_as_row(session, HISTORY, hidden), f"{field} off, yet the {inside} row shows")

    test.__name__ = f"test_the_{category.lower()}_filter_hides_its_alerts"
    return test


for _category in CATEGORIES:
    _test = make_category_test(_category)
    globals()[_test.__name__] = _test


# The Intel Panel: Alpha sits in Jita; Perimeter is one jump away, Amarr many.

INTEL_RULE = {"name": "Intel", "kind": "intel", "channels": INTEL_CHANNEL, "max_jumps": 30, "cooldown_ms": 0}


def show_intel(session, map_settings: dict | None = None, rule_alert: dict | None = None, **intel_settings):
    """`rule_alert`: the intel rule's own alert settings, which a chat alert uses in place of its type's."""
    rule = {**INTEL_RULE, "alert": rule_alert} if rule_alert else INTEL_RULE
    session.use({"intelPanel": {"show": True, "attached": False, "x": 700, "y": 200, "width": 500, "height": 500, **intel_settings},
                 "mapPanel": {**QUIET_MAP, **(map_settings or {})}, "chatAlerts": [rule]})
    return session.start_logged_client(ALPHA, system="Jita", channels=(INTEL_CHANNEL,))


_report_count = 0


def report(logs, text: str, speaker: str = "Scout") -> str:
    """Posts `text` with a number of its own, as the app drops a line it saw in the last 5 s, whatever the profile."""
    global _report_count
    _report_count += 1
    numbered = f"{text} {_report_count}"
    logs.say(INTEL_CHANNEL, speaker, numbered)
    pace(0.2)
    return numbered


def repeat_report(logs, text: str):
    """The same line from a second scout, which the app keeps, as only one speaker's repeat is a duplicate."""
    numbered = report(logs, text)
    logs.say(INTEL_CHANNEL, "Second Scout", numbered)
    pace(0.2)


@covers("IntelPanelConfig.range")
def test_the_intel_range_filter_keeps_far_reports_out(session):
    for intel_range, shows_far in (("All", True), ("OneJump", False)):
        logs = show_intel(session, range=intel_range)
        report(logs, "Amarr +1 neut")
        report(logs, "Perimeter +1 neut")
        session.wait_for_panel_text(INTEL, "Perimeter")
        if shows_far:
            session.wait_for_panel_text(INTEL, "Amarr")
        else:
            stays(f"range {intel_range}: no Amarr row", lambda: "Amarr" not in strings(session, INTEL), 1.0, details=lambda: strings(session, INTEL))


@covers("IntelPanelConfig.attached")
def test_attached_intel_shows_inside_the_map_instead_of_its_own_window(session):
    logs = show_intel(session, map_settings={"show": True, "hideWhenNoCharacters": False}, attached=True)
    map_window = session.wait_for_panel_window("EVE_MAP_PANEL_CLASS")
    report(logs, "Perimeter +1 neut")
    # The map's Intel card starts folded to its header; a click on the header opens it.
    header = session.wait_for_panel_text(MAP, "Intel")
    session.click(*client_to_screen(map_window.hwnd, header["left"] + 4, header["top"] + 4))
    session.wait_for_panel_text(MAP, "Perimeter")
    check(session.panel_window(INTEL_CLASS) is None, "attached intel opened its own window")


@covers("IntelPanelConfig.showTimestamp", "IntelPanelConfig.mergeEnabled", "IntelPanelConfig.mergeWindowSec")
def test_intel_rows_show_their_age_and_merge_repeats(session):
    logs = show_intel(session, showTimestamp=True, mergeEnabled=True, mergeWindowSec=30)
    repeat_report(logs, "Perimeter +1 neut")
    session.wait_for_panel_text(INTEL, "just now")
    session.wait_for_panel_text(INTEL, "×2")
    logs = show_intel(session, showTimestamp=False, mergeEnabled=False)
    repeat_report(logs, "Perimeter +1 neut")
    session.wait_for_panel_text(INTEL, "Perimeter")
    stays("no age and no merged row", lambda: not {"just now", "×2"} & set(strings(session, INTEL)), 1.0,
          details=lambda: strings(session, INTEL))


@covers("IntelPanelConfig.colorSystemNames")
def test_intel_rows_can_draw_systems_in_their_name_colour(session):
    colors = []
    for colored in (True, False):
        logs = show_intel(session, colorSystemNames=colored)
        report(logs, "Perimeter +1 neut")
        colors.append(session.wait_for_panel_text(INTEL, "Perimeter")["color"])
    check(not same_color(*colors), f"Perimeter drawn in {colors[0]:08X} either way")


@covers("IntelPanelConfig.muteSounds")
def test_muting_the_intel_panel_silences_intel_sounds(session):
    for muted, plays in ((False, True), (True, False)):
        logs = show_intel(session, rule_alert={"sound_enabled": True, "sound_path": "missing.wav"}, muteSounds=muted)
        before = (session.state() or {}).get("sounds_played", 0)
        report(logs, "Perimeter +1 neut")
        session.wait_for_alert(ALPHA, "ChatIntel")
        played = lambda: (session.state() or {}).get("sounds_played", 0) - before
        if plays:
            wait_for("the intel sound to play", lambda: played() == 1, details=played)
        else:
            stays("no intel sound while muted", lambda: played() == 0, 1.0, details=played)


# The Map Panel

def show_map(session, **map_settings):
    # Nearly the whole screen, so a client's tag finds room among The Forge's names; a crowded one is left off.
    left, top, right, bottom = monitors()[0].work_area
    session.use({"mapPanel": {**QUIET_MAP, "show": True, "hideWhenNoCharacters": False, "x": left + 20, "y": top + 20,
                              "width": right - left - 60, "height": bottom - top - 80, **map_settings}})
    session.wait_for_panel_window("EVE_MAP_PANEL_CLASS")


def map_names(session, wanted) -> set[str]:
    """The region names any of the map's texts mention."""
    return {name for name in wanted if any(name in text for text in strings(session, MAP))}


@covers("MapPanelConfig.regionId")
def test_the_map_opens_on_its_region(session):
    show_map(session, regionId=REGIONS["Domain"], followActive=False)
    wait_for("the map to show Domain", lambda: map_names(session, REGIONS) == {"Domain"}, details=lambda: strings(session, MAP))


@covers("MapPanelConfig.extraRegionId1", "MapPanelConfig.extraRegionId2", "MapPanelConfig.extraRegionId3")
def test_the_map_shows_up_to_three_more_regions(session):
    show_map(session, regionId=REGIONS["The Forge"], extraRegionId1=REGIONS["Domain"], extraRegionId2=REGIONS["Lonetrek"],
             extraRegionId3=REGIONS["Sinq Laison"], followActive=False)
    wait_for("the map to name all four regions", lambda: map_names(session, REGIONS) == set(REGIONS), details=lambda: strings(session, MAP))


@covers("MapPanelConfig.followActive")
def test_the_map_follows_the_active_client_into_its_region_as_set(session):
    # Not following first: a map that followed into Domain stays there while the next profile names the same region it did.
    for follows, expected in ((False, "The Forge"), (True, "Domain")):
        show_map(session, regionId=REGIONS["The Forge"], followActive=follows)
        session.start_logged_client(ALPHA, system="Amarr")
        session.switch_to(ALPHA)
        wait_for(f"followActive={follows}: the map on {expected}", lambda: map_names(session, REGIONS) == {expected},
                 details=lambda: strings(session, MAP))
        stays(f"followActive={follows}: the map to stay on {expected}", lambda: map_names(session, REGIONS) == {expected}, 1.0,
              details=lambda: strings(session, MAP))


@covers("MapPanelConfig.showCharacterNames")
def test_the_map_names_characters_beside_their_systems_as_set(session):
    for shows in (True, False):
        # Following, so the map is on Jita's region whatever the last test left it on.
        show_map(session, regionId=REGIONS["The Forge"], followActive=True, showCharacterNames=shows)
        session.start_logged_client(ALPHA, system="Jita")
        session.switch_to(ALPHA)
        if shows:
            session.wait_for_panel_text(MAP, ALPHA)
        else:
            stays("no character names on the map", lambda: ALPHA not in strings(session, MAP), 1.5, details=lambda: strings(session, MAP))
