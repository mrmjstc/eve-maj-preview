"""What each thumbnail draws: its texts and where they sit, its border in each state, and its overlays.

Read from the state file's record of each thumbnail's last render (src/thumbnail/overlay.zig's Drawn),
in overlay pixels, plus a few screen pixels for the border styles and the blank fill.
"""

import time
from dataclasses import dataclass, field

from eve_logs import bounty, combat_in, combat_out, mined, pace
from harness import ALPHA, BRAVO, GENERIC_CHARACTER_NAME, check, check_font, close_to, covers, pixel, wait_for

GLOBAL_SETTINGS = {"chatlog": {"enabled": True}}
RED, GREEN, BLUE = 0xFFFF0000, 0xFF00FF00, 0xFF0000FF
TEXT_COLOR, BG_COLOR = 0xFF112233, 0xCC445566
# Text backgrounds keep their own alpha only with this off; on, the default, they're drawn opaque.
OWN_BG_ALPHA = {"thumbnail": {"applyOpacityToOverlayTexts": False}}
ANCHORS = ("TopLeft", "TopCenter", "TopRight", "LeftCenter", "Center", "RightCenter", "BottomLeft", "BottomCenter", "BottomRight")


def hex_color(value: int) -> str:
    return f"0x{value:08X}"


def merged(base: dict, patch: dict) -> dict:
    result = dict(base)
    for key, value in patch.items():
        result[key] = merged(result[key], value) if isinstance(value, dict) and isinstance(result.get(key), dict) else value
    return result


def placed(anchor: str, size: tuple[int, int], box: tuple[int, int], offset: tuple[int, int] = (0, 0)) -> tuple[int, int]:
    """Where src/thumbnail/draw.zig's placedOrigin puts something `size` big in `box`."""
    horizontal = 0 if "Left" in anchor else 2 if "Right" in anchor else 1
    vertical = 0 if anchor.startswith("Top") else 2 if anchor.startswith("Bottom") else 1
    origin = []
    for axis, step in enumerate((horizontal, vertical)):
        free = max(0, box[axis] - size[axis])
        origin.append(min(max(free * step // 2 + offset[axis], 0), free))
    return origin[0], origin[1]


def block(texts: list[dict]) -> dict:
    """The box around a stacked element's lines."""
    left = min(t["box"]["left"] for t in texts)
    top = min(t["box"]["top"] for t in texts)
    right = max(t["box"]["left"] + t["box"]["width"] for t in texts)
    bottom = max(t["box"]["top"] + t["box"]["height"] for t in texts)
    return {"left": left, "top": top, "width": right - left, "height": bottom - top}


# Each text element: where its settings live, how to make it show, and what feeds it.

@dataclass
class Element:
    struct: str
    section: str
    keys: dict
    show: dict = field(default_factory=dict)
    feed: object = None


def thumbnail_keys(prefix: str) -> dict:
    names = ("Position", "OffsetX", "OffsetY", "FontName", "FontSize", "FontWeight", "Color", "BgColor")
    return {snake: prefix + name for snake, name in zip(("position", "offset_x", "offset_y", "font_name", "font_size", "font_weight", "color", "bg_color"), names)}


def stat_keys(prefix: str = "") -> dict:
    return {snake: prefix + snake for snake in ("position", "offset_x", "offset_y", "font_name", "font_size", "font_weight", "color", "bg_color")}


# Mining and bounty rates wait until their lines span 3 s (activity/tracker.zig's MIN_RATE_SPAN_MS).
RATED_SPACING_S = 0.8


def feed_lines(make_line, count: int = 8, spacing_s: float = 0.3):
    def feed(logs):
        for i in range(count):
            logs.game(make_line(i))
            pace(spacing_s)
    return feed


ELEMENTS = {
    "character_name": Element("ThumbnailConfig", "thumbnail", thumbnail_keys("characterName")),
    "system_name": Element("ThumbnailConfig", "thumbnail", thumbnail_keys("systemName"), {"thumbnail": {"showSystemName": True}}),
    "group_badge": Element("ThumbnailConfig", "thumbnail", thumbnail_keys("quickGroupBadge"),
                           {"thumbnail": {"showQuickGroupBadge": True}, "hotkeyGroups": [{"name": "Fleet", "characters": [ALPHA], "showBadge": True}]}),
    "session_timer": Element("ThumbnailConfig", "thumbnail", thumbnail_keys("sessionTimer"), {"thumbnail": {"showSessionTimer": True}}),
    "incoming_dps": Element("CombatTextStyle", "combatText", stat_keys("incoming_"), {"thumbnail": {"combatText": {"shown": True}}}, feed_lines(lambda _: combat_in(100))),
    "outgoing_dps": Element("CombatTextStyle", "combatText", stat_keys("outgoing_"), {"thumbnail": {"combatText": {"shown": True}}}, feed_lines(lambda _: combat_out(100))),
    "mining": Element("MiningTextStyle", "miningText", stat_keys(), {"thumbnail": {"miningText": {"shown": True}}}, feed_lines(lambda _: mined(110), 6, RATED_SPACING_S)),
    "bounty": Element("BountyTextStyle", "bountyText", stat_keys(), {"thumbnail": {"bountyText": {"shown": True}}}, feed_lines(lambda i: bounty(100000 + i), 5, RATED_SPACING_S)),
    "resources": Element("ResourcesTextStyle", "resourcesText", stat_keys(), {"thumbnail": {"resourcesText": {"shown": True}}, "resources": {"update_interval_ms": 1000}}),
}


def element_settings(spec: Element, **values) -> dict:
    """`values` keyed by the snake-case names in Element.keys."""
    settings = {spec.keys[name]: value for name, value in values.items()}
    return {"thumbnail": settings} if spec.section == "thumbnail" else {"thumbnail": {spec.section: settings}}


def show_element(session, name: str, profile: dict | None = None) -> list[dict]:
    """Starts Alpha with the element shown and fed, and returns its drawn lines."""
    spec = ELEMENTS[name]
    session.use(merged(merged(OWN_BG_ALPHA, spec.show), profile or {}))
    logs = session.start_logged_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    if spec.feed:
        spec.feed(logs)
    session.wait_for_text(ALPHA, name, timeout_s=8.0)
    time.sleep(0.3)
    return session.drawn_texts(ALPHA, name)


def make_style_test(name: str, spec: Element):
    keys = ("position", "offset_x", "offset_y", "font_size", "color", "bg_color", "font_name", "font_weight")

    @covers(*(f"{spec.struct}.{spec.keys[key]}" for key in keys))
    def test(session):
        styled = element_settings(spec, position="BottomRight", offset_x=-6, offset_y=-3, font_size=10,
                                  color=hex_color(TEXT_COLOR), bg_color=hex_color(BG_COLOR), font_name="Segoe UI", font_weight="Regular")
        lines = show_element(session, name, styled)
        overlay = session.overlay(ALPHA)
        box = block(lines)
        expected = placed("BottomRight", (box["width"], box["height"]), (overlay["width"], overlay["height"]), (-6, -3))
        check((box["left"], box["top"]) == expected, f"{name} at ({box['left']}, {box['top']}), expected {expected}")
        check((lines[0]["color"], lines[0]["bg_color"]) == (TEXT_COLOR, BG_COLOR),
              f"{name} colours {lines[0]['color']:08X}/{lines[0]['bg_color']:08X}, expected {TEXT_COLOR:08X}/{BG_COLOR:08X}")
        check_font(name, lines[0], "Segoe UI", is_bold=False, is_italic=False)

        restyled = show_element(session, name, merged(styled, element_settings(spec, font_size=22, font_name="Courier New", font_weight="BoldItalic")))
        check(block(restyled)["height"] > box["height"], f"{name} is {block(restyled)['height']} high at font size 22, {box['height']} at 10")
        check_font(name, restyled[0], "Courier New", is_bold=True, is_italic=True)

    test.__name__ = f"test_the_{name}_text_takes_its_position_offset_colours_and_font"
    return test


for _name, _spec in ELEMENTS.items():
    _test = make_style_test(_name, _spec)
    globals()[_test.__name__] = _test


@covers("ThumbnailConfig.characterNamePosition")
def test_the_character_name_sits_at_each_anchor(session):
    for anchor in ANCHORS:
        session.use({"thumbnail": {"characterNamePosition": anchor}})
        session.start_logged_client(ALPHA)
        session.wait_for_text(ALPHA, "character_name")
        time.sleep(0.2)
        text = session.drawn_texts(ALPHA, "character_name")[0]
        overlay = session.overlay(ALPHA)
        expected = placed(anchor, (text["box"]["width"], text["box"]["height"]), (overlay["width"], overlay["height"]))
        check((text["box"]["left"], text["box"]["top"]) == expected, f"{anchor}: at ({text['box']['left']}, {text['box']['top']}), expected {expected}")


# What shows and what it says.

@covers("ThumbnailConfig.showText")
def test_show_text_off_draws_no_text(session):
    session.use({"thumbnail": {"showText": False, "showSessionTimer": True}})
    session.start_logged_client(ALPHA)
    session.overlay(ALPHA)
    time.sleep(0.3)
    check(session.overlay(ALPHA)["texts"] == [], f"drew {[t['element'] for t in session.overlay(ALPHA)['texts']]}")


@covers("ThumbnailConfig.showCharacterName", "ThumbnailConfig.showSystemName", "ThumbnailConfig.showQuickGroupBadge",
        "ThumbnailConfig.showSessionTimer")
def test_each_name_text_shows_only_when_turned_on(session):
    group = [{"name": "Fleet", "characters": [ALPHA], "showBadge": True}]
    on = {"showCharacterName": True, "showSystemName": True, "showQuickGroupBadge": True, "showSessionTimer": True}
    for settings in (on, {key: False for key in on}):
        session.use({"thumbnail": settings, "hotkeyGroups": group})
        session.start_logged_client(ALPHA)
        session.overlay(ALPHA)
        time.sleep(0.5)
        drawn = sorted(t["element"] for t in session.overlay(ALPHA)["texts"])
        expected = sorted(["character_name", "system_name", "group_badge", "session_timer"]) if settings is on else []
        check(drawn == expected, f"with every name text {'on' if settings is on else 'off'}: drew {drawn}")


def test_the_texts_say_the_character_system_badge_and_session_time(session):
    session.use({"thumbnail": {"showSystemName": True, "showQuickGroupBadge": True, "showSessionTimer": True},
                 "hotkeyGroups": [{"name": "Fleet", "characters": [ALPHA], "showBadge": True}]})
    session.start_logged_client(ALPHA, system="Jita")
    said = {element: session.wait_for_text(ALPHA, element)["text"] for element in ("character_name", "system_name", "group_badge", "session_timer")}
    expected = {"character_name": ALPHA, "system_name": "Jita", "group_badge": "Fleet", "session_timer": "0m"}
    check(said == expected, f"texts say {said}, expected {expected}")


@covers("CharacterConfig.displayName", "CharacterConfig.nameColor")
def test_a_characters_display_name_and_colour_replace_its_own(session):
    session.use({"characters": [{"name": ALPHA, "displayName": "Main", "nameColor": hex_color(RED)}]})
    session.start_logged_client(ALPHA)
    text = session.wait_for_text(ALPHA, "character_name")
    check((text["text"], text["color"]) == ("Main", RED), f"name reads '{text['text']}' in {text['color']:08X}")


@covers("CombatTextStyle.shown", "CombatTextStyle.show_incoming", "CombatTextStyle.show_outgoing",
        "CombatTextStyle.incoming_show_prefix", "CombatTextStyle.outgoing_show_prefix")
def test_the_combat_texts_show_and_prefix_as_set(session):
    for show_in, show_out, prefixed in ((True, True, True), (True, False, False), (False, True, True)):
        combat = {"shown": True, "show_incoming": show_in, "show_outgoing": show_out, "incoming_show_prefix": prefixed, "outgoing_show_prefix": prefixed}
        session.use({"thumbnail": {"combatText": combat}})
        logs = session.start_logged_client(ALPHA)
        feed_lines(lambda i: combat_in(100) if i % 2 else combat_out(100), 10)(logs)
        wanted = [e for e, shown in (("incoming_dps", show_in), ("outgoing_dps", show_out)) if shown]
        for element in wanted:
            text = session.wait_for_text(ALPHA, element)["text"]
            prefix = "IN: " if element == "incoming_dps" else "OUT: "
            check(text.startswith(prefix) == prefixed, f"{combat}: {element} reads '{text}'")
        unwanted = {"incoming_dps", "outgoing_dps"} - set(wanted)
        for element in unwanted:
            check(not session.drawn_texts(ALPHA, element), f"{combat}: {element} shows")


@covers("MiningTextStyle.shown", "MiningTextStyle.show_prefix", "MiningTextStyle.show_isk_rate",
        "MiningConfig.m3_rate_unit", "MiningConfig.isk_rate_unit")
def test_the_mining_text_shows_its_isk_line_prefix_and_units_as_set(session):
    for settings, units, lines in (({"show_prefix": True, "show_isk_rate": True}, ("minute", "minute"), 2),
                                   ({"show_prefix": False, "show_isk_rate": False}, ("hour", "hour"), 1)):
        session.use({"thumbnail": {"miningText": {"shown": True, **settings}}, "mining": {"m3_rate_unit": units[0], "isk_rate_unit": units[1]}})
        logs = session.start_logged_client(ALPHA)
        feed_lines(lambda _: mined(110), 6, RATED_SPACING_S)(logs)
        session.wait_for_text(ALPHA, "mining", timeout_s=8.0)
        time.sleep(0.3)
        texts = [t["text"] for t in session.drawn_texts(ALPHA, "mining")]
        suffix = "min" if units[0] == "minute" else "hr"
        check(len(texts) == lines, f"{settings}: {len(texts)} mining line(s) {texts}, expected {lines}")
        check(texts[0].startswith("M: ") == settings["show_prefix"], f"{settings}: mining reads '{texts[0]}'")
        check(texts[0].endswith(f"m3/{suffix}"), f"m3_rate_unit={units[0]}: mining reads '{texts[0]}'")
        if lines == 2:
            check(texts[1].endswith(f"ISK/{suffix}"), f"isk_rate_unit={units[1]}: ISK line reads '{texts[1]}'")


@covers("BountyTextStyle.shown", "BountyTextStyle.show_prefix", "BountyConfig.isk_rate_unit")
def test_the_bounty_text_shows_its_prefix_and_unit_as_set(session):
    for prefixed, unit in ((True, "hour"), (False, "minute")):
        session.use({"thumbnail": {"bountyText": {"shown": True, "show_prefix": prefixed}}, "bounty": {"isk_rate_unit": unit}})
        logs = session.start_logged_client(ALPHA)
        feed_lines(lambda i: bounty(100000 + i), 5, RATED_SPACING_S)(logs)
        text = session.wait_for_text(ALPHA, "bounty", timeout_s=8.0)["text"]
        suffix = "hr" if unit == "hour" else "min"
        check(text.startswith("ISK: ") == prefixed and text.endswith(f"ISK/{suffix}"), f"prefix {prefixed}, unit {unit}: bounty reads '{text}'")


@covers("ResourcesTextStyle.shown", "ResourcesTextStyle.show_cpu", "ResourcesTextStyle.show_ram", "ResourcesTextStyle.show_vram",
        "ResourcesConfig.update_interval_ms")
def test_the_resources_text_shows_the_lines_turned_on(session):
    for settings, starts in (({"show_cpu": True, "show_ram": True, "show_vram": False}, ["CPU:", "RAM:"]),
                             ({"show_cpu": False, "show_ram": True, "show_vram": False}, ["RAM:"])):
        session.use({"thumbnail": {"resourcesText": {"shown": True, **settings}}, "resources": {"update_interval_ms": 1000}})
        session.start_logged_client(ALPHA)
        session.wait_for_text(ALPHA, "resources", timeout_s=8.0)
        time.sleep(0.3)
        texts = [t["text"] for t in session.drawn_texts(ALPHA, "resources")]
        check([t.split(" ")[0] for t in texts] == starts, f"{settings}: resources read {texts}")


# Alert text.

def raise_cargo_alert(session, profile: dict) -> dict:
    session.use(profile)
    logs = session.start_logged_client(ALPHA)
    session.start_client(BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    session.switch_to(BRAVO)
    logs.alert("CargoFull")
    session.wait_for_alert(ALPHA, "CargoFull")
    return wait_for("the alert text on Alpha's thumbnail", lambda: session.overlay(ALPHA)["notifications"] and session.overlay(ALPHA))


@covers("AlertTextStyle.position", "AlertTextStyle.offset_x", "AlertTextStyle.offset_y", "AlertTextStyle.bg_color", "NotificationConfig.color")
def test_alert_text_sits_where_set_in_its_colours(session):
    alert_text = {"position": "TopRight", "offset_x": -8, "offset_y": 6, "bg_color": hex_color(BG_COLOR)}
    overlay = raise_cargo_alert(session, merged(OWN_BG_ALPHA, {"thumbnail": {"alertText": alert_text}, "notifications": {"color": hex_color(GREEN)}}))
    box = overlay["notifications"]
    expected = placed("TopRight", (box["width"], box["height"]), (overlay["width"], overlay["height"]), (-8, 6))
    check((box["left"], box["top"]) == expected, f"alert text at ({box['left']}, {box['top']}), expected {expected}")
    check((overlay["notifications_bg_color"], overlay["notification_color"]) == (BG_COLOR, GREEN),
          f"alert colours {overlay['notifications_bg_color']:08X}/{overlay['notification_color']:08X}")


@covers("AlertTextStyle.font_size", "AlertTextStyle.font_name", "AlertTextStyle.font_weight")
def test_alert_text_takes_its_font(session):
    base = {"font_size": 10, "font_name": "Segoe UI", "font_weight": "Regular"}
    sizes = {}
    for label, change in (("base", {}), ("size", {"font_size": 22}), ("name", {"font_name": "Courier New"}), ("weight", {"font_weight": "Bold"})):
        sizes[label] = raise_cargo_alert(session, {"thumbnail": {"alertText": {**base, **change}}})["notifications"]
    check(sizes["size"]["height"] > sizes["base"]["height"], f"alert text {sizes['size']['height']} high at 22, {sizes['base']['height']} at 10")
    check(sizes["name"]["width"] != sizes["base"]["width"], "alert text kept its width in another font")
    check(sizes["weight"]["width"] > sizes["base"]["width"], "alert text isn't wider in bold")


# Borders and states. Alpha has focus; Bravo doesn't.

def two_clients(session, profile: dict | None = None, logged: bool = False):
    session.use(profile or {})
    logs = session.start_logged_client(ALPHA) if logged else session.start_client(ALPHA)
    session.start_client(BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    session.switch_to(ALPHA)
    time.sleep(0.4)
    return logs


def border(session, name: str) -> dict:
    overlay = session.overlay(name)
    return {key: overlay[key] for key in ("shows_border", "border_width", "border_color", "border_style")}


def wait_for_border(session, name: str, expected: dict, label: str):
    wait_for(f"{label}: {name}'s border {expected}", lambda: {k: border(session, name)[k] for k in expected} == expected,
             timeout_s=3.0, details=lambda: border(session, name))


@covers("ThumbnailConfig.showBorderWhenFocused", "ThumbnailConfig.borderWidth", "ThumbnailConfig.borderColor", "ThumbnailConfig.borderStyle")
def test_the_focused_thumbnail_has_the_focused_border(session):
    two_clients(session, {"thumbnail": {"borderWidth": 4, "borderColor": hex_color(RED), "borderStyle": "Dashed"}})
    wait_for_border(session, ALPHA, {"shows_border": True, "border_width": 4, "border_color": RED, "border_style": "Dashed"}, "focused")
    two_clients(session, {"thumbnail": {"showBorderWhenFocused": False}})
    wait_for_border(session, ALPHA, {"shows_border": False}, "focused border off")


@covers("Config.accentColor")
def test_the_focused_border_follows_the_accent_colour_by_default(session):
    two_clients(session, {"accentColor": hex_color(BLUE)})
    wait_for_border(session, ALPHA, {"border_color": BLUE}, "accent")


@covers("ThumbnailConfig.showBorderWhenInactive", "ThumbnailConfig.inactiveBorderWidth", "ThumbnailConfig.inactiveBorderColor",
        "ThumbnailConfig.inactiveBorderStyle")
def test_an_unfocused_thumbnail_has_the_inactive_border_when_turned_on(session):
    two_clients(session)
    wait_for_border(session, BRAVO, {"shows_border": False}, "inactive border off by default")
    two_clients(session, {"thumbnail": {"showBorderWhenInactive": True, "inactiveBorderWidth": 3, "inactiveBorderColor": hex_color(GREEN),
                                        "inactiveBorderStyle": "Dotted"}})
    wait_for_border(session, BRAVO, {"shows_border": True, "border_width": 3, "border_color": GREEN, "border_style": "Dotted"}, "inactive")


@covers("StateVisualConfig.borderWidth", "StateVisualConfig.borderColor", "StateVisualConfig.borderStyle", "StateVisualConfig.showBorder",
        "StateVisualConfig.textColor", "StateVisualConfig.textBgColor")
def test_a_states_own_look_overrides_the_base_border_and_text(session):
    look = {"showBorder": True, "borderWidth": 5, "borderColor": hex_color(BLUE), "borderStyle": "Double",
            "textColor": hex_color(TEXT_COLOR), "textBgColor": hex_color(BG_COLOR)}
    two_clients(session, merged(OWN_BG_ALPHA, {"thumbnail": {"inactive": look}}))
    wait_for_border(session, BRAVO, {"shows_border": True, "border_width": 5, "border_color": BLUE, "border_style": "Double"}, "inactive state")
    name = session.drawn_texts(BRAVO, "character_name")[0]
    check((name["color"], name["bg_color"]) == (TEXT_COLOR, BG_COLOR), f"Bravo's name in {name['color']:08X}/{name['bg_color']:08X}")


@covers("StateVisualConfig.showThumbnail")
def test_a_state_can_hide_the_thumbnail(session):
    session.use({"thumbnail": {"inactive": {"showThumbnail": False}}})
    session.start_clients(ALPHA, BRAVO)
    # Alpha's thumbnail starts hidden, so wait on the app's client list before switching to it.
    wait_for("the app to find both clients", lambda: session.client_state(ALPHA) and session.client_state(BRAVO))
    session.switch_to(ALPHA)
    session.wait_for_thumbnails({ALPHA})


def test_the_active_state_look_applies_to_the_focused_thumbnail(session):
    two_clients(session, {"thumbnail": {"active": {"borderColor": hex_color(GREEN)}, "borderColor": hex_color(RED)}})
    wait_for_border(session, ALPHA, {"border_color": GREEN}, "active state")


def test_the_minimized_state_look_applies_to_a_minimized_client(session):
    two_clients(session, {"thumbnail": {"minimized": {"showBorder": True, "borderColor": hex_color(BLUE)}}})
    session.clients[BRAVO].minimize()
    wait_for_border(session, BRAVO, {"shows_border": True, "border_color": BLUE}, "minimized state")


def test_the_alert_state_look_applies_while_an_alert_is_up(session):
    logs = two_clients(session, {"thumbnail": {"alert": {"showBorder": True, "borderColor": hex_color(BLUE)}},
                                 "notifications": {"type_configs": {"CargoFull": {"show_border": True}}}}, logged=True)
    session.switch_to(BRAVO)
    logs.alert("CargoFull")
    wait_for_border(session, ALPHA, {"shows_border": True, "border_color": BLUE}, "alert state")


def test_the_dragging_state_look_applies_mid_drag(session):
    two_clients(session, {"thumbnail": {"dragging": {"showBorder": True, "borderColor": hex_color(BLUE)}}})
    seen = []
    session.drag_thumbnail(BRAVO, (900, 700), while_held=lambda: seen.append(border(session, BRAVO)))
    check(seen and seen[0]["shows_border"] and seen[0]["border_color"] == BLUE, f"mid-drag border {seen}")


@covers("CharacterBorderColorsConfig.activeBorderColor", "CharacterBorderColorsConfig.inactiveBorderColor")
def test_a_characters_own_border_colours_win(session):
    profile = {"thumbnail": {"showBorderWhenInactive": True},
               "characters": [{"name": ALPHA, "borderColors": {"activeBorderColor": hex_color(RED), "inactiveBorderColor": hex_color(GREEN)}}]}
    two_clients(session, profile)
    wait_for_border(session, ALPHA, {"border_color": RED}, "Alpha focused")
    session.switch_to(BRAVO)
    wait_for_border(session, ALPHA, {"border_color": GREEN}, "Alpha unfocused")


@covers("ThumbnailConfig.useUniqueCharacterBorderColors", "ThumbnailConfig.useUniqueCharacterNameColors")
def test_unique_colours_give_each_character_its_own(session):
    two_clients(session, {"thumbnail": {"useUniqueCharacterBorderColors": True, "useUniqueCharacterNameColors": True,
                                        "showBorderWhenInactive": True, "borderColor": hex_color(RED), "characterNameColor": hex_color(RED)}})
    time.sleep(0.5)
    names = {n: session.drawn_texts(n, "character_name")[0]["color"] for n in (ALPHA, BRAVO)}
    check(names[ALPHA] != names[BRAVO] and RED not in names.values(), f"name colours {names}")
    borders = {n: border(session, n)["border_color"] for n in (ALPHA, BRAVO)}
    check(borders[ALPHA] != borders[BRAVO] and RED not in borders.values(), f"border colours {borders}")


@covers("SystemColorConfig.systemName", "SystemColorConfig.color")
def test_a_systems_own_colour_colours_its_name(session):
    session.use({"thumbnail": {"showSystemName": True}, "systemColors": [{"systemName": "Jita", "color": hex_color(RED)}]})
    session.start_logged_client(ALPHA, system="Jita")
    check(session.wait_for_text(ALPHA, "system_name")["color"] == RED, "Jita isn't in its own colour")


@covers("ThumbnailConfig.useUniqueSystemColors")
def test_unique_system_colours_tell_systems_apart(session):
    session.use({"thumbnail": {"showSystemName": True, "useUniqueSystemColors": True, "systemNameColor": hex_color(RED)}})
    session.start_logged_client(ALPHA, system="Jita")
    session.start_logged_client(BRAVO, system="Amarr")
    colors = {n: session.wait_for_text(n, "system_name")["color"] for n in (ALPHA, BRAVO)}
    check(colors[ALPHA] != colors[BRAVO] and RED not in colors.values(), f"system colours {colors}")


@covers("ThumbnailConfig.exclusionOverlayStyle", "ThumbnailConfig.exclusionOverlayColor")
def test_an_excluded_client_shows_the_exclusion_overlay(session):
    two_clients(session, {"thumbnail": {"exclusionOverlayStyle": "Checkerboard", "exclusionOverlayColor": hex_color(BG_COLOR)}})
    session.protocol("evemajpreview://hotkey/toggle_exclusion")
    wait_for("Alpha's exclusion overlay", lambda: session.overlay(ALPHA)["shows_exclusion"])
    overlay = session.overlay(ALPHA)
    check((overlay["exclusion_style"], overlay["exclusion_color"]) == ("Checkerboard", BG_COLOR),
          f"overlay {overlay['exclusion_style']} in {overlay['exclusion_color']:08X}")
    check(not session.overlay(BRAVO)["shows_exclusion"], "Bravo, not excluded, shows the overlay")


@covers("ThumbnailConfig.applyOpacityToOverlayTexts")
def test_window_opacity_can_apply_to_the_texts(session):
    for applies in (True, False):
        two_clients(session, {"thumbnail": {"thumbnailOpacity": 150, "applyOpacityToOverlayTexts": applies, "characterNameBgColor": hex_color(BG_COLOR)}})
        time.sleep(0.3)
        overlay = session.overlay(ALPHA)
        bg_alpha = session.drawn_texts(ALPHA, "character_name")[0]["bg_color"] >> 24
        if applies:
            check(overlay["text_alpha"] == 150 and bg_alpha == 0xFF, f"applied: text alpha {overlay['text_alpha']}, background alpha {bg_alpha:02X}")
        else:
            check(overlay["text_alpha"] != 150 and bg_alpha == BG_COLOR >> 24, f"not applied: text alpha {overlay['text_alpha']}, background alpha {bg_alpha:02X}")


@covers("ThumbnailConfig.showSystemConnections", "ThumbnailConfig.systemConnectionMapWidth", "ThumbnailConfig.systemConnectionMapHeight")
def test_system_connections_draw_a_map_in_place_of_the_system_name(session):
    sizes = []
    for width, height in ((120, 90), (200, 150)):
        session.use({"thumbnail": {"width": 480, "height": 270, "showSystemName": True, "showSystemConnections": True,
                                   "systemConnectionMapWidth": width, "systemConnectionMapHeight": height}})
        session.start_logged_client(ALPHA, system="Jita")
        overlay = wait_for("Alpha's connection map", lambda: session.overlay(ALPHA)["connection_map"] and session.overlay(ALPHA))
        check(not session.drawn_texts(ALPHA, "system_name"), "the plain system name shows beside the map")
        sizes.append(overlay["connection_map"])
    check(sizes[1]["width"] > sizes[0]["width"] and sizes[1]["height"] > sizes[0]["height"], f"maps {sizes[0]} then {sizes[1]}")


# Screen pixels: what a border style and the blank fill actually look like.

def top_edge_share(window, color: tuple[int, int, int], samples: int = 40) -> float:
    """How much of the top border row is `color`, from just inside the corner to just inside the other."""
    hits = 0
    for i in range(samples):
        x = window.left + 3 + (window.width - 6) * i // (samples - 1)
        hits += close_to(pixel(x, window.top + 1), color, 70)
    return hits / samples


def test_each_border_style_draws_its_own_pattern(session):
    shares = {}
    for style in ("Solid", "Dashed", "Dotted", "DashDot", "CornerBrackets"):
        session.use({"thumbnail": {"borderWidth": 4, "borderColor": hex_color(RED), "borderStyle": style, "showLivePreview": False,
                                   "blankThumbnailColor": "0xFF000000", "showCharacterName": False}})
        session.start_client(ALPHA)
        session.switch_to(ALPHA)
        window = session.wait_for_thumbnails({ALPHA})[ALPHA].window
        time.sleep(0.5)
        shares[style] = top_edge_share(window, (255, 0, 0))
    check(shares["Solid"] > 0.9, f"a solid border covers {shares['Solid']:.0%} of its edge")
    for style in ("Dashed", "Dotted", "DashDot"):
        check(0.1 < shares[style] < 0.9, f"a {style} border covers {shares[style]:.0%} of its edge")
    check(shares["CornerBrackets"] < 0.6, f"corner brackets cover {shares['CornerBrackets']:.0%} of the edge")


@covers("ThumbnailConfig.blankDimsBorder")
def test_a_blank_thumbnail_can_fill_with_its_border_colour_dimmed(session):
    session.use({"thumbnail": {"showLivePreview": False, "blankDimsBorder": True, "borderColor": hex_color(RED), "showCharacterName": False}})
    session.start_client(ALPHA)
    window = session.wait_for_thumbnails({ALPHA})[ALPHA].window
    time.sleep(0.5)
    r, g, b = pixel(*window.point(0.5, 0.5))
    check(r > 30 and r > g + 20 and r > b + 20 and r < 230, f"the fill is ({r}, {g}, {b}), expected a dimmed red")


def test_a_logged_out_client_shows_the_generic_name(session):
    session.use()
    session.start_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    session.clients[ALPHA].log_out()
    session.wait_for_thumbnails({GENERIC_CHARACTER_NAME})
    text = session.wait_for_text(GENERIC_CHARACTER_NAME, "character_name")
    check(text["text"] == GENERIC_CHARACTER_NAME, f"the name reads '{text['text']}'")
