"""Which thumbnails show."""

from harness import ALPHA, BRAVO, check, close_to, covers, layered_alpha, pixel, wait_for


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


def focus_bystander(session):
    session.start_bystander()
    session.wait_for_foreground("Bystander")


@covers("ThumbnailConfig.hideWhenNoEveFocus")
def test_thumbnails_hide_while_no_client_has_focus(session):
    session.use({"thumbnail": {"hideWhenNoEveFocus": True, "hideDebounceMs": 200}})
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    focus_bystander(session)
    session.wait_for_thumbnails(set())
    session.switch_to(ALPHA)
    session.wait_for_thumbnails({ALPHA, BRAVO})


def test_thumbnails_stay_when_focus_leaves_by_default(session):
    session.use()
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    focus_bystander(session)
    session.assert_thumbnails_stay({ALPHA, BRAVO}, 1.5)


@covers("ThumbnailConfig.hideDebounceMs")
def test_hiding_waits_for_the_debounce(session):
    session.use({"thumbnail": {"hideWhenNoEveFocus": True, "hideDebounceMs": 2500}})
    session.start_clients(ALPHA)
    session.wait_for_thumbnails({ALPHA})
    focus_bystander(session)
    session.assert_thumbnails_stay({ALPHA}, 1.5)
    session.wait_for_thumbnails(set(), timeout_s=5.0)


def alphas(session) -> dict[str, int | None]:
    return {name: layered_alpha(t.window.hwnd) for name, t in session.thumbnails().items()}


@covers("ThumbnailConfig.thumbnailOpacity", "CharacterConfig.opacity")
def test_opacity_comes_from_the_profile_unless_the_character_sets_its_own(session):
    session.use({"thumbnail": {"thumbnailOpacity": 150}, "characters": [{"name": BRAVO, "opacity": 90}]})
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    wait_for("Alpha at the profile's 150 and Bravo at its own 90", lambda: alphas(session) == {ALPHA: 150, BRAVO: 90}, details=lambda: alphas(session))


GREEN = (0, 255, 0)


def interior_color(session, name: str):
    """Below the middle and right of centre, clear of the name text, the client's own text and the border."""
    return pixel(*session.thumbnails()[name].window.point(0.75, 0.82))


def shows_blank(session, name: str) -> bool:
    return close_to(interior_color(session, name), GREEN)


@covers("ThumbnailConfig.showLivePreview", "ThumbnailConfig.blankThumbnailColor")
def test_turning_live_preview_off_fills_the_thumbnail_with_the_blank_colour(session):
    for live, blank in ((False, True), (True, False)):
        session.use({"thumbnail": {"showLivePreview": live, "blankThumbnailColor": "0xFF00FF00"}})
        session.start_client(ALPHA)
        session.wait_for_thumbnails({ALPHA})
        wait_for(f"showLivePreview={live}: {'the blank fill' if blank else 'the live client'}",
                 lambda: shows_blank(session, ALPHA) == blank, details=lambda: interior_color(session, ALPHA))


@covers("CharacterConfig.preview", "CharacterConfig.blankThumbnailColor")
def test_a_character_can_override_live_preview_and_its_blank_colour(session):
    session.use({"thumbnail": {"showLivePreview": True},
                 "characters": [{"name": BRAVO, "preview": "Blank", "blankThumbnailColor": "0xFF00FF00"}]})
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    wait_for("Bravo to show its blank colour", lambda: shows_blank(session, BRAVO), details=lambda: interior_color(session, BRAVO))
    check(not shows_blank(session, ALPHA), "Alpha, on the profile's live preview, shows the blank colour")
    session.use({"thumbnail": {"showLivePreview": False, "blankThumbnailColor": "0xFF00FF00"},
                 "characters": [{"name": BRAVO, "preview": "Live"}]})
    session.start_clients(ALPHA, BRAVO)
    session.wait_for_thumbnails({ALPHA, BRAVO})
    wait_for("Alpha to show the blank colour", lambda: shows_blank(session, ALPHA), details=lambda: interior_color(session, ALPHA))
    check(not shows_blank(session, BRAVO), "Bravo, set to Live, shows the blank colour")
