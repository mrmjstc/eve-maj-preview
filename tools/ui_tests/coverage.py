"""Lists every setting in src/config/ and which end-to-end tests prove it.

Usage: python tools/ui_tests/coverage.py [--all]

A setting is `Struct.field`, read from the Zig source by following Config's and GlobalConfig's
fields; alert types are `NotificationType.X`. Tests claim settings with @covers. Without --all,
only structs with untested settings are listed.
"""

import importlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent
REPO = HERE.parents[1]
CONFIG_DIR = REPO / "src" / "config"
NOTIFICATION_FILE = REPO / "src" / "notifications" / "notification.zig"

ROOTS = ("Config", "GlobalConfig")
# Types saved as one value, though declared as structs.
VALUE_TYPES = {"KeyList", "Argb", "Position", "WindowSize"}
# Runtime bookkeeping, not settings.
SKIPPED_FIELDS = {"allocator", "profile_name", "app", "formatVersion", "id", "load_report", "lastUsedProfile",
                  "orePricesFetchedAtSeconds", "evestarsTokenProtected", "dialogX", "dialogY"}

# Settings with nothing an end-to-end test can observe, or deliberately left manual; each with why.
NOT_TESTED = {
    "WindowFilterConfig.name": "a label in the dialog only",
    "HotkeyGroupConfig.name": "covered through showBadge and group links",
    "GlobalConfig.runOnStartup": "writes the real Run registry key",
    "GlobalConfig.autoRegisterProtocol": "writes the real protocol registration",
    "GlobalConfig.disableUpdateChecks": "network",
    "GlobalConfig.evestarsEnabled": "network",
    "GlobalConfig.evestarsToken": "network",
    "GlobalConfig.alwaysOnTop": "the config dialog's own window",
    "GlobalConfig.advancedMode": "the config dialog only",
    "TimerConfig.scanIntervalMs": "tick timing only; new windows are found by a once-a-second scan regardless",
    "CharacterConfig.name": "the key every other character setting is found by",
    "CharacterConfig.windowSize": "only for the config dialog's preview",
    "ThumbnailSpace.name": "a label in the dialog only",
    "DisplayConfig.hideThumbnailsDuringRegionSelect": "the config dialog's region tool",
    "InteractionConfig.animationStyle": "turns Windows' animation off only for the instant of each call; restoring it is tested",
    "InteractionConfig.hideTaskbarOverClients": "Explorer keeps the fullscreen marks, with no way to read them back",
    "NotificationType.Generic": "only the config dialog's Test button raises it",
    "NotificationTypeConfig.sound_volume": "audio output",
    "NotificationConfig.tts_volume": "audio output",
    "NotificationConfig.tts_rate": "audio output",
    "NotificationConfig.tts_max_waiting": "audio output",
    "NotificationConfig.tts_speak_character_name": "the spoken words, which aren't recorded",
    "NotificationConfig.tts_use_display_name": "the spoken words, which aren't recorded",
    "ChatlogConfig.idlePollThreshold": "poll backoff on quiet logs; timing only",
    "ChatlogConfig.maxPollMultiplier": "poll backoff on quiet logs; timing only",
    "ChatAlertConfig.name": "a label in the dialog only",
    "PingTextStyle.shown": "needs a client connected to a game server",
    "PingTextStyle.color": "needs a client connected to a game server",
    "PingTextStyle.bg_color": "needs a client connected to a game server",
    "PingTextStyle.font_size": "needs a client connected to a game server",
    "PingTextStyle.font_name": "needs a client connected to a game server",
    "PingTextStyle.font_weight": "needs a client connected to a game server",
    "PingTextStyle.position": "needs a client connected to a game server",
    "PingTextStyle.offset_x": "needs a client connected to a game server",
    "PingTextStyle.offset_y": "needs a client connected to a game server",
    "PingConfig.update_interval_ms": "needs a client connected to a game server",
    "ThumbnailConfig.systemConnectionJumps": "drawn into the connection map's image only",
    "ThumbnailConfig.showSystemConnectionIntel": "drawn into the connection map's image only",
    "GlobalConfig.language": "words only the config dialog and the drag hint draw, neither recorded",
    "UrlHotkeyConfig.uploadClipboard": "network",
    "IntelConfig.shrinkSec": "drawn into the map's image only",
    "IntelConfig.showClear": "drawn into the map's image only",
    "MapPanelConfig.showIntel": "the pins are drawn into the map's image only",
    "MapPanelConfig.liveStats": "network",
    "MapPanelConfig.trafficSpan": "network",
    "MapPanelConfig.showStorms": "network",
    "MapPanelConfig.showIncursions": "network",
    "MapPanelConfig.showSovTimers": "network",
    "MapPanelConfig.showWormholes": "network",
    "MapPanelConfig.showAnsiblex": "network",
    "MapPanelConfig.showKills": "network",
    "MapPanelConfig.killLifetimeMin": "network",
    "MapPanelConfig.routePreference": "routes are sent to the game through ESI",
    "MapPanelConfig.routeEveryWaypoint": "routes are sent to the game through ESI",
    "MapPanelConfig.routeAnsiblex": "network",
    "MapPanelConfig.routeAvoidZone1": "network",
    "MapPanelConfig.routeAvoidZone2": "network",
    "MapPanelConfig.routeAvoidZone3": "network",
    "MapPanelConfig.routeAvoidZone4": "network",
    "MapPanelConfig.routeAvoidZone5": "network",
}


def parse_structs() -> dict[str, list[tuple[str, str]]]:
    """Struct name to its (field, type) pairs, across src/config/."""
    structs: dict[str, list[tuple[str, str]]] = {}
    for path in [CONFIG_DIR.with_suffix(".zig"), *CONFIG_DIR.glob("*.zig")]:
        source = path.read_text(encoding="utf-8")
        # Top-level, multi-line declarations only: a nested or one-line one would run on to a later closing brace.
        for match in re.finditer(r"^pub const (\w+) = struct \{\n(.*?)\n\};", source, re.S | re.M):
            fields = re.findall(r"^    ([a-zA-Z]\w*): ([^=\n]+?)\s*(?:=|,)", match.group(2), re.M)
            structs.setdefault(match.group(1), []).extend(fields)
    return structs


def notification_types() -> list[str]:
    source = NOTIFICATION_FILE.read_text(encoding="utf-8")
    body = re.search(r"pub const NotificationType = enum[^{]*\{(.*?)\n\s*(?:pub fn|\};)", source, re.S).group(1)
    return re.findall(r"^\s+([A-Z]\w*),", body, re.M)


def settings() -> dict[str, list[str]]:
    """Struct name to its setting fields, for every struct reachable from ROOTS."""
    structs = parse_structs()
    found: dict[str, list[str]] = {}
    pending = list(ROOTS)
    while pending:
        name = pending.pop()
        if name in found:
            continue
        found[name] = []
        for field, type_text in structs.get(name, []):
            if field in SKIPPED_FIELDS:
                continue
            nested = [t for t in re.findall(r"\w+", type_text) if t in structs and t not in VALUE_TYPES]
            if "NotificationTypeConfigs" in nested:
                pending.append("NotificationTypeConfig")
            elif nested:
                pending.extend(nested)
            else:
                found[name].append(field)
    found["NotificationType"] = notification_types()
    return {name: fields for name, fields in found.items() if fields}


def claimed() -> dict[str, list[str]]:
    """Setting to the tests that claim it."""
    sys.path.insert(0, str(HERE))
    sys.path.insert(0, str(HERE / "tests"))
    claims: dict[str, list[str]] = {}
    for path in sorted((HERE / "tests").glob("test_*.py")):
        module = importlib.import_module(path.stem)
        for name, test in vars(module).items():
            for key in getattr(test, "covers", ()):
                claims.setdefault(key, []).append(f"{path.stem}.{name}")
    return claims


def main(show_all: bool) -> int:
    all_settings = settings()
    claims = claimed()
    known = {f"{struct}.{field}" for struct, fields in all_settings.items() for field in fields}
    unknown = sorted(set(claims) - known)

    total = covered = manual = 0
    for struct in sorted(all_settings):
        fields = all_settings[struct]
        keys = [f"{struct}.{field}" for field in fields]
        tested = [k for k in keys if k in claims]
        skipped = [k for k in keys if k in NOT_TESTED and k not in claims]
        untested = [k for k in keys if k not in claims and k not in NOT_TESTED]
        total += len(keys)
        covered += len(tested)
        manual += len(skipped)
        if untested or show_all:
            print(f"{struct}: {len(tested)}/{len(keys)} tested")
            for key in untested:
                print(f"    untested  {key.split('.', 1)[1]}")
            if show_all:
                for key in skipped:
                    print(f"    manual    {key.split('.', 1)[1]}  ({NOT_TESTED[key]})")
    print(f"\n{covered}/{total} settings tested, {manual} manual or not observable, {total - covered - manual} untested")
    if unknown:
        print("\n@covers names that match no setting (typo or a renamed field):")
        for key in unknown:
            print(f"    {key}  ({', '.join(claims[key])})")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main("--all" in sys.argv[1:]))
