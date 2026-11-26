"""The config dialog, driven through UI Automation: every switch on a tab saves exactly its own setting."""

import json
import time

from harness import ALPHA, TestFailure, check, top_level_windows, wait_for
from uia import Dialog, UiaError

# Advanced Mode shows every tab's advanced settings.
GLOBAL_SETTINGS = {"advancedMode": True}
# One of each listed thing, so the list tabs show a selected item's settings.
PROFILE = {"characters": [{"name": ALPHA}], "hotkeyGroups": [{"name": "Group A"}], "chatAlerts": [{"name": "Watch", "channels": "Test Chat"}]}
# Mining, About and Backups have no switches.
TABS = ("Characters", "Hotkey Groups", "Client Windows", "Appearance", "Placement", "Map & Intel", "Hotkeys", "Mouse",
        "Alert Options", "Game Events", "Chat Events", "Alert History", "General")
# Left alone, as they'd touch the registry or the network.
UNSAFE_SWITCHES = {"Run on Startup", "Auto-Register Protocol Handler", "Check for Updates", "Enable Eve Stars"}
# The dialog's own state: Show Off ghosts a preview's off parts, Window Filters is on while the list has filters, Same for All Texts copies styling as you edit.
UNSAVED_SWITCHES = {"Show Off", "Enable Window Filters", "Same for All Texts"}
SKIPPED_SWITCHES = UNSAFE_SWITCHES | UNSAVED_SWITCHES
SAVE_WAIT_S = 3.0


def open_dialog(session) -> Dialog:
    session.protocol("evemajpreview://config")
    window = wait_for("the config dialog", lambda: next((w for w in top_level_windows()
                                                         if w.pid == session.app.pid and w.class_name == "KnotsWindow" and w.is_visible), None))
    return Dialog(window.hwnd)


def close_dialog(session, dialog: Dialog):
    try:
        dialog.invoke("Close")
        wait_for("the config dialog to close", lambda: not any(w.pid == session.app.pid and w.class_name == "KnotsWindow" and w.is_visible
                                                                for w in top_level_windows()))
    finally:
        dialog.close()


def flatten(value, prefix: str = "") -> dict:
    """Every leaf of a JSON value by its dotted path, list items by index."""
    if isinstance(value, dict):
        return {path: leaf for key, item in value.items() for path, leaf in flatten(item, f"{prefix}{key}.").items()}
    if isinstance(value, list) and value and all(isinstance(item, (dict, list)) for item in value):
        return {path: leaf for index, item in enumerate(value) for path, leaf in flatten(item, f"{prefix}{index}.").items()}
    return {prefix.rstrip("."): value}


def saved(session) -> dict:
    """The profile and the global settings as last written, flattened."""
    profiles = session.dir / "profiles"
    read = lambda name: json.loads((profiles / name).read_text(encoding="utf-8"))
    return {**flatten(read(session.profile_name()), "profile."), **flatten(read("global.settings.json"), "global.")}


def changes(before: dict, after: dict) -> dict:
    return {path: (before.get(path), after.get(path)) for path in before.keys() | after.keys() if before.get(path) != after.get(path)}


def save(session, dialog: Dialog, before: dict) -> dict:
    """Clicks Save and returns what's written, or `before` once SAVE_WAIT_S passes with nothing new."""
    dialog.invoke("Save")
    deadline = time.monotonic() + SAVE_WAIT_S
    while time.monotonic() < deadline:
        try:
            after = saved(session)
        except (OSError, ValueError):
            after = before
        if after != before:
            return after
        time.sleep(0.1)
    return before


def invoke_when_ready(dialog: Dialog, name: str):
    """Presses `name` once the dialog has drawn it; a window just opened may not have yet."""
    def pressed():
        try:
            dialog.invoke(name)
            return True
        except UiaError:
            return False
    wait_for(f"'{name}' in the dialog", pressed)


def test_a_save_that_fails_to_write_can_be_retried(session):
    session.use(PROFILE)
    path = session.dir / "profiles" / session.profile_name()
    dialog = open_dialog(session)
    try:
        invoke_when_ready(dialog, "Appearance")
        switches = wait_for("the tab's switches", lambda: dialog.controls("CheckBox"))
        position = next(position for position, switch in enumerate(switches) if switch["name"] and switch["name"] not in SKIPPED_SWITCHES)
        was_on = switches[position].get("toggled")
        dialog.toggle(position)
        wait_for("the switch to flip", lambda: dialog.controls("CheckBox")[position].get("toggled") != was_on)
        # A frame for the dialog to see the edit, as Save does nothing while the profile looks unchanged.
        time.sleep(0.3)
        before = saved(session)
        # Held open without delete sharing, as a scanner or sync tool might, so the save can't replace it.
        with open(path, "rb"):
            dialog.invoke("Save")
            wait_for("a log line about the failed save", lambda: session.log_lines("Failed to save the configuration"),
                     details=lambda: session.log_text()[-600:])
        # A failed save once marked the profile saved, so this one wrote nothing.
        check(save(session, dialog, before) != before, "the retried Save wrote nothing")
    finally:
        close_dialog(session, dialog)


def make_switch_test(tab: str):
    def test(session):
        session.use(PROFILE)
        dialog = open_dialog(session)
        try:
            dialog.invoke(tab)
            time.sleep(0.5)
            switches = dialog.controls("CheckBox")
            check(switches, f"no switches on the {tab} tab")
            # Save writes nothing unchanged, so one switch flipped there and back fills in what the test's profile left out.
            warm_up = next(position for position, switch in enumerate(switches) if switch["name"] and switch["name"] not in SKIPPED_SWITCHES)
            dialog.toggle(warm_up)
            before = save(session, dialog, saved(session))
            dialog.toggle(warm_up)
            before = save(session, dialog, before)
            problems = []
            for position, switch in enumerate(switches):
                name = switch["name"]
                if name in SKIPPED_SWITCHES:
                    continue
                if not name:
                    problems.append(f"switch {position} has no name")
                    continue
                dialog.toggle(position)
                flipped = save(session, dialog, before)
                changed = changes(before, flipped)
                if len(changed) != 1 or not all(isinstance(new, bool) for _, new in changed.values()):
                    problems.append(f"'{name}' saved {changed or 'nothing'}")
                # Found again by position: a switch shows or hides only what comes after it.
                current = dialog.controls("CheckBox")
                if position >= len(current) or current[position]["name"] != name:
                    problems.append(f"'{name}' moved after it was flipped, so the rest of the tab went unchecked")
                    break
                dialog.toggle(position)
                restored = save(session, dialog, flipped)
                if changes(before, restored):
                    problems.append(f"'{name}' didn't save back: {changes(before, restored)}")
                before = restored
            if problems:
                raise TestFailure(f"{tab}: " + "; ".join(problems))
        finally:
            close_dialog(session, dialog)

    test.__name__ = f"test_every_{tab.lower().replace(' & ', '_').replace(' ', '_')}_switch_saves_its_own_setting"
    return test


for _tab in TABS:
    _test = make_switch_test(_tab)
    globals()[_test.__name__] = _test
