"""Combat, mining and bounty rates read from the gamelog, and the alerts they raise."""

import time

from eve_logs import bounty, combat_in, combat_out, mined, pace
from harness import ALPHA, check, covers, fresh, stays, wait_for

GLOBAL_SETTINGS = {"chatlog": {"enabled": True}}
# The trackers only run while something shows their rates.
SHOWN = {"thumbnail": {"combatText": {"shown": True}, "miningText": {"shown": True}, "bountyText": {"shown": True}}}
NOCXITE_VOLUME_M3 = 4.0
# Mining and bounty rates wait until their lines span 3 s (activity/tracker.zig's MIN_RATE_SPAN_MS).
RATED_SPACING_S = 0.8


def profile(**sections) -> dict:
    merged = {key: dict(value) for key, value in SHOWN.items()}
    for key, value in sections.items():
        merged[key] = {**merged.get(key, {}), **value}
    return merged


def rate(session, name: str, field: str):
    return session.client_state(name).get(field)


def hits(logs, line_for, count: int, spacing_s: float = 0.3):
    for i in range(count):
        logs.game(line_for(i))
        pace(spacing_s)


def wait_for_rate(session, field: str, timeout_s: float = 6.0) -> float:
    return wait_for(f"Alpha's {field} to be measured", lambda: (rate(session, ALPHA, field) or 0) > 0 and rate(session, ALPHA, field),
                    timeout_s, details=lambda: rate(session, ALPHA, field))


def test_incoming_and_outgoing_damage_give_dps(session):
    session.use(profile())
    logs = session.start_logged_client(ALPHA)
    hits(logs, lambda i: combat_in(100) if i % 2 else combat_out(150), 10)
    wait_for_rate(session, "incoming_dps")
    wait_for_rate(session, "outgoing_dps")


@covers("NotificationType.TakingDamage")
def test_taking_damage_raises_an_alert(session):
    session.use(profile())
    logs = session.start_logged_client(ALPHA)
    hits(logs, lambda _: combat_in(100), 3)
    session.wait_for_alert(ALPHA, "TakingDamage")


@covers("CombatConfig.damage_alert_excluded_weapons")
def test_hits_from_an_excluded_weapon_raise_no_damage_alert(session):
    session.use(profile(combat={"damage_alert_excluded_weapons": "Heavy Missile"}))
    logs = session.start_logged_client(ALPHA)
    hits(logs, lambda _: combat_in(100, "Heavy Missile"), 3)
    stays("no TakingDamage alert", lambda: "TakingDamage" not in session.alerts(ALPHA), 2.0, details=lambda: session.alerts(ALPHA))
    hits(logs, lambda _: combat_in(100, "Light Missile"), 2)
    session.wait_for_alert(ALPHA, "TakingDamage")


@covers("CombatConfig.window_seconds")
def test_dps_falls_to_zero_once_the_window_passes_quietly(session):
    for window, drops in ((5, True), (60, False)):
        session.use(profile(combat={"window_seconds": window}))
        logs = session.start_logged_client(ALPHA)
        hits(logs, lambda _: combat_in(100), 8)
        wait_for_rate(session, "incoming_dps")
        time.sleep(window + 2 if drops else 7)
        current = rate(session, ALPHA, "incoming_dps") or 0
        check((current == 0) == drops, f"window {window}s: incoming dps {current} after the quiet spell")


@covers("CombatConfig.update_interval_ms")
def test_dps_updates_no_more_often_than_the_interval(session):
    session.use(profile(combat={"update_interval_ms": 8000}))
    logs = session.start_logged_client(ALPHA)
    hits(logs, lambda _: combat_in(50), 6)
    first = wait_for_rate(session, "incoming_dps", timeout_s=10.0)
    hits(logs, lambda _: combat_in(2000), 6)
    stays("the dps to hold until the next update", lambda: rate(session, ALPHA, "incoming_dps") == first, 3.0,
          details=lambda: rate(session, ALPHA, "incoming_dps"))


def test_mining_yields_give_a_mining_rate(session):
    session.use(profile())
    logs = session.start_logged_client(ALPHA)
    hits(logs, lambda _: mined(110), 6, RATED_SPACING_S)
    wait_for_rate(session, "mining_rate")
    wait_for_rate(session, "mining_isk_rate")


@fresh({"oreTable": [{"name": "Nocxite", "price": 1000}]})
@covers("OrePriceConfig.name", "OrePriceConfig.price")
def test_the_ore_table_prices_the_mining_isk_rate(session):
    session.use(profile())
    logs = session.start_logged_client(ALPHA)
    hits(logs, lambda _: mined(110), 6, RATED_SPACING_S)
    wait_for_rate(session, "mining_isk_rate")
    # Each yield is units x price in ISK and units x volume in m3, so the rates differ by price / volume.
    ratio = rate(session, ALPHA, "mining_isk_rate") / rate(session, ALPHA, "mining_rate")
    check(abs(ratio - 1000 / NOCXITE_VOLUME_M3) < 1, f"ISK per m3 is {ratio:.1f}, expected {1000 / NOCXITE_VOLUME_M3}")


def test_bounty_payouts_give_a_bounty_rate(session):
    session.use(profile())
    logs = session.start_logged_client(ALPHA)
    hits(logs, lambda i: bounty(100000 + i), 5, RATED_SPACING_S)
    wait_for_rate(session, "bounty_isk_rate")


# The mining alerts' windows are 30s at the least, so these are slow.

@covers("NotificationType.MiningStopped", "MiningConfig.stopped_alert_window_seconds")
def test_mining_that_stops_raises_an_alert_after_the_window(session):
    session.use(profile(mining={"stopped_alert_window_seconds": 30, "idle_alert_window_seconds": 600}))
    logs = session.start_logged_client(ALPHA)
    hits(logs, lambda _: mined(110), 3)
    stays("no MiningStopped alert before the window", lambda: "MiningStopped" not in session.alerts(ALPHA), 20.0)
    session.wait_for_alert(ALPHA, "MiningStopped", timeout_s=15.0)


@covers("NotificationType.MiningIdle", "MiningConfig.idle_alert_window_seconds", "MiningConfig.idle_alert_threshold")
def test_mining_that_slows_below_the_threshold_raises_an_idle_alert(session):
    session.use(profile(mining={"idle_alert_window_seconds": 30, "idle_alert_threshold": 5, "stopped_alert_window_seconds": 600}))
    logs = session.start_logged_client(ALPHA)
    # One yield every 8s: few enough to count as idle, often enough never to count as stopped.
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        logs.game(mined(110))
        if "MiningIdle" in session.alerts(ALPHA):
            return
        time.sleep(8)
    check("MiningIdle" in session.alerts(ALPHA), "no MiningIdle alert after 45s of slow mining")
