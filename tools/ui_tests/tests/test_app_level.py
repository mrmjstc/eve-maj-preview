"""App-wide behaviour: hotkeys for other apps and URLs, the log level, and how profiles load."""

from harness import ALPHA, BYSTANDER_EXES, VK_F13, check, covers, fresh, stays, wait_for

TO_BYSTANDER, TO_ONLOOKER, NEXT_APP, PREVIOUS_APP, LAST_APP, OPEN_URL = (VK_F13 + i for i in range(6))
BYSTANDER, ONLOOKER = "Bystander", "Onlooker"
# Run by the URL hotkey from the app's folder, the sandbox: it leaves OPENED_MARKER beside itself.
URL_SCRIPT = "opened.cmd"
OPENED_MARKER = "opened.txt"


def key(virtual_key: int) -> str:
    return f"0x{virtual_key:02X}"


GLOBAL_SETTINGS = {
    "appHotkeys": [{"hotkey": key(TO_BYSTANDER), "executableName": BYSTANDER_EXES[0]},
                   {"hotkey": key(TO_ONLOOKER), "executableName": BYSTANDER_EXES[1]}],
    "hotkeyCycleAppsForward": key(NEXT_APP),
    "hotkeyCycleAppsBackward": key(PREVIOUS_APP),
    "hotkeyReturnToLastApp": key(LAST_APP),
    "urlHotkeys": [{"hotkey": key(OPEN_URL), "url": URL_SCRIPT}],
}


def start_apps(session):
    """Both bystanders, Onlooker last, then Alpha, which opens in front."""
    session.use()
    session.start_bystander(BYSTANDER_EXES[0], BYSTANDER)
    session.start_bystander(BYSTANDER_EXES[1], ONLOOKER)
    session.wait_for_foreground(ONLOOKER)
    # Started rather than switched to: a switch link from behind two bystanders didn't bring it forward.
    session.start_client(ALPHA)
    session.wait_for_foreground(ALPHA)


def press_to(session, virtual_key: int, name: str):
    session.press(virtual_key)
    session.wait_for_foreground(name)


@covers("AppHotkeyConfig.hotkey", "AppHotkeyConfig.executableName")
def test_an_app_hotkey_brings_its_app_forward(session):
    start_apps(session)
    press_to(session, TO_BYSTANDER, BYSTANDER)
    press_to(session, TO_ONLOOKER, ONLOOKER)


@covers("GlobalConfig.hotkeyCycleAppsForward", "GlobalConfig.hotkeyCycleAppsBackward")
def test_the_cycle_app_keys_step_through_the_app_hotkeys_apps(session):
    start_apps(session)
    press_to(session, NEXT_APP, BYSTANDER)
    press_to(session, NEXT_APP, ONLOOKER)
    press_to(session, PREVIOUS_APP, BYSTANDER)


@covers("GlobalConfig.hotkeyReturnToLastApp")
def test_the_return_key_goes_back_to_the_last_app_before_eve(session):
    start_apps(session)
    session.press(LAST_APP)
    target = session.clients[ONLOOKER].hwnd
    wait_for("Onlooker in the foreground", lambda: session.foreground_client() == ONLOOKER,
             details=lambda: f"{session.foreground_client()}; onlooker hwnd {target}; log: {session.log_lines('last app', 'last non-EVE')[-4:]}")


@covers("UrlHotkeyConfig.hotkey", "UrlHotkeyConfig.url")
def test_a_url_hotkey_opens_its_url(session):
    session.use()
    marker = session.dir / OPENED_MARKER
    marker.unlink(missing_ok=True)
    (session.dir / URL_SCRIPT).write_text(f'@echo opened>"%~dp0{OPENED_MARKER}"\r\n', encoding="utf-8", newline="")
    session.start_client(ALPHA)
    session.switch_to(ALPHA)
    session.press(OPEN_URL)
    wait_for("the URL to be opened", marker.exists, timeout_s=8.0)


# Logging

@fresh({"logLevel": "debug"})
@covers("GlobalConfig.logLevel")
def test_the_debug_log_level_writes_debug_lines(session):
    session.use()
    session.start_client(ALPHA)
    wait_for("a DEBUG line in the log", lambda: "][DEBUG][" in session.log_text(), details=lambda: session.log_text()[-600:])


@fresh({"logLevel": "err"})
def test_the_error_log_level_leaves_out_info_lines(session):
    session.use()
    session.start_client(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    stays("no INFO or DEBUG lines", lambda: not any(level in session.log_text() for level in ("][INFO][", "][DEBUG][")), 1.0,
          details=lambda: session.log_text()[-600:])


# Profiles

@fresh({"lastUsedProfile": "gone.json"})
def test_a_missing_last_profile_falls_back_to_the_default(session):
    wait_for("the default profile", lambda: session.profile_name() == "default.json", details=session.profile_name)
    check(session.log_lines("not found, falling back"), "no log line about the missing profile")


def test_an_unreadable_profile_is_backed_up_and_runs_on_defaults(session):
    session.use()
    broken = "{ this isn't json"
    (session.dir / "profiles" / "broken.json").write_text(broken, encoding="utf-8", newline="")
    session.protocol("evemajpreview://profile/broken.json")
    wait_for("the broken profile to load", lambda: session.profile_name() == "broken.json", details=session.profile_name)
    backups = lambda: list((session.dir / "profiles" / "backup").glob("*_broken.json"))
    wait_for("a backup of the broken profile", backups)
    check(backups()[0].read_text(encoding="utf-8") == broken, "the backup doesn't hold the broken file's words")
