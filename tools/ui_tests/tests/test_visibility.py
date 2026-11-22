"""Which thumbnails show."""

from harness import ALPHA, BRAVO, check, covers, wait_for


@covers("ThumbnailConfig.activeThumbnailHidden")
def test_hide_active_hides_only_the_focused_clients_thumbnail(session):
    session.use({"thumbnail": {"activeThumbnailHidden": True}})
    session.start_clients(ALPHA, BRAVO)
    # Either may already be hidden, as the last client started has focus.
    wait_for("the app to see both clients", lambda: len(session.thumbnail_list()) == 2)
    session.switch_to(ALPHA)
    session.wait_for_thumbnails({BRAVO})
    session.switch_to(BRAVO)
    session.wait_for_thumbnails({ALPHA})


@covers("CharacterConfig.hideThumbnail")
def test_a_characters_hide_thumbnail_setting_hides_only_that_thumbnail(session):
    session.use({"characters": [{"name": BRAVO, "hideThumbnail": True}]})
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA})
    bravo = next(t for t in session.thumbnail_list() if t.character_name == BRAVO)
    check(bravo.is_hidden_by_character, "Bravo's thumbnail isn't reported as hidden by its character setting")


def test_toggle_visibility_hides_and_restores_every_thumbnail(session):
    session.use()
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    session.protocol("evemajpreview://hotkey/toggle_visibility")
    session.wait_for_thumbnails(set())
    session.protocol("evemajpreview://hotkey/toggle_visibility")
    session.wait_for_thumbnails({ALPHA, BRAVO})
