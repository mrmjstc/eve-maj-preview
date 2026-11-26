"""Writes EVE's chatlogs and gamelogs the way the game does, for the app to read.

A port of src/sim/lines.zig and the file handling in src/sim/fleet.zig: chatlogs are UTF-16LE with
a BOM and a BOM before each line, gamelogs UTF-8 with a BOM, both stamped in UTC. The app finds a
character's logs by the Listener line in their headers, then follows each from its end, so a
session's logs must exist before its client starts, and later lines are appended.
"""

import hashlib
import time
from datetime import datetime, timezone
from pathlib import Path

LOCAL_CHANNEL = "Local"
FIXED_CHANNEL_IDS = {"Local": "local", "Corp": "corp", "Alliance": "alliance", "Fleet": "fleet_1207012318337"}
LINE_BOM = "﻿"
CHARACTER_ID_BASE = 1000000000
CHARACTER_ID_SPAN = 1147483647

# The one-shot gamelog lines from src/sim/lines.zig, each raising the NotificationType it's keyed by.
ALERT_LINES = {
    "FleetInvite": "(question) Someone wants you to join their fleet, do you accept?",
    "FleetFollow": "(notify) Following Fleet Commander in warp",
    "FleetRegroup": "(notify) Regrouping to Fleet Commander",
    "FleetDisband": "(notify) Your fleet is disbanding",
    "MiningCompression": "(notify) Successfully compressed Veldspar into 10 Compressed Veldspar",
    "AsteroidDepleted": "(notify) Your Miner II deactivates as it finds the resource it was harvesting a pale shadow of its former glory.",
    "CargoFull": "(notify) Your Miner II has completed operations. Ship's cargo hold is full.",
    "CrystalBroke": "(notify) Mining Laser Upgrade II deactivates due to the destruction of the Mining Crystal II.",
    "WarpScrambled": "(combat) Warp scramble attempt from Hostile Pilot to you!",
    "WarpDisrupted": "(combat) Warp disruption attempt from Hostile Pilot to you!",
    "Decloak": "(notify) Your cloak deactivates due to proximity to a nearby Purifier.",
    "ObservatoryDecloak": "(notify) Your cloak deactivates due to a pulse from a Mobile Observatory in the area.",
    "CloakFailed": "(notify) Your cloaking systems are unable to activate due to your ship being within 2000m of a hostile.",
    "BombLauncherEmpty": "(notify) Bomb Launcher II has run out of charges",
    "SelfDestruct": "(notify) Your Capsule will self-destruct in 5 seconds.",
    "WarpBubble": "(notify) You are within a warp disruption zone. Get 20000.0 meters from Warp Disrupt Probe to warp.",
    "Docking": "(notify) You cannot do that while docking.",
    "AutopilotReached": "(notify) Autopilot disabled - Waypoint reached",
    "AutopilotApproaching": "(notify) Autopilot approaching target",
    "JumpRange": "(notify) Please get within 2500 meters of the stargate to jump.",
    "AggressionCantJump": "(notify) The stargate denies you permission to jump for the moment due to your recent acts of aggression.",
    "CloakedCantWarp": "(notify) You cannot warp while you are cloaked.",
    "ConduitJump": "(notify) A Conduit Field jumps you to Jita.",
    "JumpCloning": "(notify) Starting clone jumping",
    "ConversationInvite": "(None) Some Pilot is inviting you to a conversation",
}


def combat_in(amount: int, weapon: str = "Heavy Missile") -> str:
    return (f"(combat) <color=0xffcc0000><b>{amount}</b> <color=0x77ffffff><font size=10>from</font> "
            f"<b><color=0xffffffff>Gist Seraphim</b><font size=10><color=0x77ffffff> - {weapon} - Hits")


def combat_out(amount: int) -> str:
    return (f"(combat) <color=0xff00ffff><b>{amount}</b> <color=0x77ffffff><font size=10>to</font> "
            f"<b><color=0xffffffff>Gistatis Tribunus</b><font size=10><color=0x77ffffff> - Nova Cruise Missile - Hits")


def bounty(isk: int) -> str:
    return (f"(bounty) <font size=12><b><color=0xff00aa00>{isk:,} ISK</b><color=0x77ffffff> "
            f"added to next bounty payout (payment adjusted)")


def mined(units: int, ore: str = "Nocxite II-Grade") -> str:
    return (f"(mining) <color=0x77ffffff>You mined <font size=12><color=#ff8dc169>{units}<color=0x77ffffff>"
            f"<font size=10> units of <color=0xffffffff><font size=12>{ore}")


def character_id(name: str) -> int:
    """As src/sim/lines.zig hashes it, so a character keeps one ID."""
    digest = hashlib.md5(name.encode("utf-8")).digest()
    return CHARACTER_ID_BASE + int.from_bytes(digest[:4], "little") % CHARACTER_ID_SPAN


def channel_id(channel: str) -> str:
    return FIXED_CHANNEL_IDS.get(channel) or "player_" + hashlib.md5(channel.encode("utf-8")).hexdigest()


def line_stamp(moment: datetime) -> str:
    return moment.strftime("%Y.%m.%d %H:%M:%S")


def file_stamp(moment: datetime) -> str:
    return moment.strftime("%Y%m%d_%H%M%S")


def now() -> datetime:
    return datetime.now(timezone.utc)


class CharacterLogs:
    """One character's session: its Local chatlog, its gamelog, and any other channels it's in."""

    def __init__(self, logs_dir: Path, name: str, system: str, channels: tuple[str, ...] = ()):
        self.name = name
        self.system = system
        self.chatlog_dir = logs_dir / "Chatlogs"
        self.gamelog_dir = logs_dir / "Gamelogs"
        self.chatlog_dir.mkdir(parents=True, exist_ok=True)
        self.gamelog_dir.mkdir(parents=True, exist_ok=True)
        started = now()
        identifier = character_id(name)
        self.local_path = self.chatlog_dir / f"{LOCAL_CHANNEL}_{file_stamp(started)}_{identifier}.txt"
        self._write_chatlog(self.local_path, self._chatlog_header(LOCAL_CHANNEL, started))
        self.gamelog_path = self.gamelog_dir / f"{file_stamp(started)}_{identifier}.txt"
        self.gamelog_path.write_bytes(("﻿" + self._gamelog_header(started)).encode("utf-8"))
        self.channel_paths: dict[str, Path] = {}
        for channel in channels:
            path = self.chatlog_dir / f"{channel}_{file_stamp(started)}_{identifier}.txt"
            self._write_chatlog(path, self._chatlog_header(channel, started))
            self.channel_paths[channel] = path

    def game(self, text: str):
        """A gamelog line: `text` is what follows the timestamp."""
        self._append(self.gamelog_path, f"[ {line_stamp(now())} ] {text}\r\n".encode("utf-8"))

    def alert(self, notification_type: str):
        self.game(ALERT_LINES[notification_type])

    def jump(self, to: str):
        self.game(f"Jumping from {self.system} to {to}")
        self.system = to

    def local_change(self, system: str):
        self._append_chatlog(self.local_path, self._chat_line("EVE System", f"Channel changed to Local : {system}"))
        self.system = system

    def say(self, channel: str, speaker: str, text: str):
        self._append_chatlog(self.channel_paths[channel], self._chat_line(speaker, text))

    def _chatlog_header(self, channel: str, started: datetime) -> str:
        dashes = "        ---------------------------------------------------------------"
        header = (f"\r\n\r\n\n\n{dashes}\n\n          Channel ID:      {channel_id(channel)}\n"
                  f"          Channel Name:    {channel}\n          Listener:        {self.name}\n"
                  f"          Session started: {line_stamp(started)}\n{dashes}\n\n")
        if channel == LOCAL_CHANNEL:
            return header + self._chat_line("EVE System", f"Channel changed to Local : {self.system}", started)
        return header + self._chat_line("EVE System", f"Channel MOTD: Welcome to {channel}.", started)

    def _gamelog_header(self, started: datetime) -> str:
        dashes = "------------------------------------------------------------"
        return (f"{dashes}\r\n  Gamelog\r\n  Listener: {self.name}\r\n  Session Started: {line_stamp(started)}\r\n"
                f"{dashes}\r\n[ {line_stamp(started)} ] (hint) Attempting to join a channel\r\n")

    @staticmethod
    def _chat_line(speaker: str, text: str, moment: datetime | None = None) -> str:
        return f"{LINE_BOM}[ {line_stamp(moment or now())} ] {speaker} > {text}\r\n"

    @staticmethod
    def _write_chatlog(path: Path, text: str):
        path.write_bytes(b"\xff\xfe" + text.encode("utf-16-le"))

    def _append_chatlog(self, path: Path, text: str):
        self._append(path, text.encode("utf-16-le"))

    @staticmethod
    def _append(path: Path, data: bytes):
        with path.open("ab") as file:
            file.write(data)


def pace(seconds: float = 0.05):
    """Spaces lines out, as two writes in one instant can land in one poll."""
    time.sleep(seconds)
