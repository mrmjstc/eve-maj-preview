// The drag-and-drop overlay text layout preview.
import { app } from './state.js';
import { isChangeEventType } from './changes.js';
import { getFieldValue } from './form.js';
import { fitHotkeyGroupCharsList, selectedHotkeyGroupIndex } from './hotkey_groups.js';
import { labelColumnRealignJobs, updateHotkeyPlaceholders } from './hotkeys.js';
import { t } from './i18n.js';

// Drives each element's real (hidden) Position/Offset inputs by dispatching their normal events,
// so CONFIG_SCHEMA, getFieldValue/setFieldValue, and the live-preview pipeline don't need to know this exists.
// popoverTitleKey/labelKey store i18n key names, resolved via t() when the popover renders (see openOverlayPopover/buildOverlayPopoverField) rather than here, so a live language switch (see switchLanguage()) is reflected.
const OVERLAY_LAYOUT_ELEMENTS = [
    { chipId: 'overlayChip_characterName', showId: 'showCharacterName', positionId: 'characterNamePosition', offsetXId: 'characterNameOffsetX', offsetYId: 'characterNameOffsetY', colorId: 'characterNameColor', alsoRequiresIds: ['showText'],
        uniqueColorsId: 'useUniqueCharacterNameColors', fontNameId: 'characterNameFontName', fontWeightId: 'characterNameFontWeight', fontSizeId: 'characterNameFontSize',
        bgColorId: 'characterNameBgColor', bgOpacityId: 'characterNameBgOpacity',
        popoverTitleKey: 'dynamic.overlay.characterNameTitle', popoverFields: [
            { type: 'checkbox', id: 'showCharacterName', labelKey: 'field.showCharacterName.label' },
            { type: 'checkbox', id: 'useUniqueCharacterNameColors', labelKey: 'field.useUniqueCharacterNameColors.label', disables: 'characterNameColor' },
            { type: 'color', id: 'characterNameColor', labelKey: 'field.characterNameColor.label' },
            { type: 'font-name', id: 'characterNameFontName', labelKey: 'common.fontNameLabel' },
            { type: 'number', id: 'characterNameFontSize', labelKey: 'common.fontSizePxLabel', min: 6, max: 72 },
            { type: 'font-weight', id: 'characterNameFontWeight', labelKey: 'common.fontWeightLabel' },
            { type: 'color', id: 'characterNameBgColor', labelKey: 'dynamic.overlay.backgroundColorLabel' },
            { type: 'range', id: 'characterNameBgOpacity', labelKey: 'common.textBgOpacityLabel', min: 0, max: 100, unit: '%' },
        ] },
    { chipId: 'overlayChip_systemName', showId: 'showSystemName', positionId: 'systemNamePosition', offsetXId: 'systemNameOffsetX', offsetYId: 'systemNameOffsetY', colorId: 'systemNameColor', alsoRequiresIds: ['showText'],
        uniqueColorsId: 'useUniqueSystemColors', fontNameId: 'systemNameFontName', fontWeightId: 'systemNameFontWeight', fontSizeId: 'systemNameFontSize',
        bgColorId: 'systemNameBgColor', bgOpacityId: 'systemNameBgOpacity', requiresChatlog: true,
        popoverTitleKey: 'dynamic.overlay.systemNameTitle', popoverFields: [
            { type: 'checkbox', id: 'showSystemName', labelKey: 'field.showSystemName.label' },
            { type: 'checkbox', id: 'useUniqueSystemColors', labelKey: 'field.useUniqueSystemColors.label', disables: 'systemNameColor' },
            { type: 'color', id: 'systemNameColor', labelKey: 'field.systemNameColor.label' },
            { type: 'font-name', id: 'systemNameFontName', labelKey: 'common.fontNameLabel' },
            { type: 'number', id: 'systemNameFontSize', labelKey: 'common.fontSizePxLabel', min: 6, max: 72 },
            { type: 'font-weight', id: 'systemNameFontWeight', labelKey: 'common.fontWeightLabel' },
            { type: 'color', id: 'systemNameBgColor', labelKey: 'dynamic.overlay.backgroundColorLabel' },
            { type: 'range', id: 'systemNameBgOpacity', labelKey: 'common.textBgOpacityLabel', min: 0, max: 100, unit: '%' },
        ] },
    { chipId: 'overlayChip_quickGroupBadge', showId: 'showQuickGroupBadge', positionId: 'quickGroupBadgePosition', offsetXId: 'quickGroupBadgeOffsetX', offsetYId: 'quickGroupBadgeOffsetY', colorId: 'quickGroupBadgeColor',
        alsoRequiresIds: ['showText'],
        fontNameId: 'quickGroupBadgeFontName', fontWeightId: 'quickGroupBadgeFontWeight', fontSizeId: 'quickGroupBadgeFontSize',
        bgColorId: 'quickGroupBadgeBgColor', bgOpacityId: 'quickGroupBadgeBgOpacity',
        popoverTitleKey: 'dynamic.overlay.groupBadgeTitle', popoverFields: [
            { type: 'checkbox', id: 'showQuickGroupBadge', labelKey: 'field.showQuickGroupBadge.label' },
            { type: 'color', id: 'quickGroupBadgeColor', labelKey: 'field.quickGroupBadgeColor.label' },
            { type: 'font-name', id: 'quickGroupBadgeFontName', labelKey: 'common.fontNameLabel' },
            { type: 'number', id: 'quickGroupBadgeFontSize', labelKey: 'common.fontSizePxLabel', min: 6, max: 72 },
            { type: 'font-weight', id: 'quickGroupBadgeFontWeight', labelKey: 'common.fontWeightLabel' },
            { type: 'color', id: 'quickGroupBadgeBgColor', labelKey: 'dynamic.overlay.backgroundColorLabel' },
            { type: 'range', id: 'quickGroupBadgeBgOpacity', labelKey: 'common.textBgOpacityLabel', min: 0, max: 100, unit: '%' },
        ] },
    { chipId: 'overlayChip_notification', showId: 'notificationsEnabled', positionId: 'notificationPosition', offsetXId: 'notificationOffsetX', offsetYId: 'notificationOffsetY', colorId: 'characterNameColor', alsoRequiresIds: ['showText'],
        fontNameId: 'notificationFontName', fontWeightId: 'notificationFontWeight', fontSizeId: 'notificationFontSize',
        bgColorId: 'notificationBgColor', bgOpacityId: 'notificationBgOpacity', requiresChatlog: true,
        popoverTitleKey: 'dynamic.overlay.notificationTitle', popoverFields: [
            { type: 'checkbox', id: 'notificationsEnabled', labelKey: 'dynamic.overlay.showNotificationsLabel' },
            { type: 'font-name', id: 'notificationFontName', labelKey: 'common.fontNameLabel' },
            { type: 'number', id: 'notificationFontSize', labelKey: 'common.fontSizePxLabel', min: 6, max: 72 },
            { type: 'font-weight', id: 'notificationFontWeight', labelKey: 'common.fontWeightLabel' },
            { type: 'color', id: 'notificationBgColor', labelKey: 'dynamic.overlay.backgroundColorLabel' },
            { type: 'range', id: 'notificationBgOpacity', labelKey: 'common.textBgOpacityLabel', min: 0, max: 100, unit: '%' },
        ] },
    { chipId: 'overlayChip_combatIncoming', showId: 'combatShowIncoming', positionId: 'combatIncomingPosition', offsetXId: 'combatIncomingOffsetX', offsetYId: 'combatIncomingOffsetY', colorId: 'combatIncomingColor', alsoRequiresIds: ['combatEnabled', 'showText'],
        fontNameId: 'combatIncomingFontName', fontWeightId: 'combatIncomingFontWeight', fontSizeId: 'combatIncomingFontSize',
        bgColorId: 'combatIncomingBgColor', bgOpacityId: 'combatIncomingBgOpacity', requiresChatlog: true,
        popoverTitleKey: 'dynamic.overlay.incomingDpsTitle', popoverFields: [
            { type: 'checkbox', id: 'combatEnabled', labelKey: 'dynamic.overlay.enableCombatOverlaysLabel' },
            { type: 'checkbox', id: 'combatShowIncoming', labelKey: 'field.combatShowIncoming.label' },
            { type: 'checkbox', id: 'combatIncomingShowPrefix', labelKey: 'field.combatIncomingShowPrefix.label' },
            { type: 'color', id: 'combatIncomingColor', labelKey: 'common.textColorLabel' },
            { type: 'font-name', id: 'combatIncomingFontName', labelKey: 'common.fontNameLabel' },
            { type: 'number', id: 'combatIncomingFontSize', labelKey: 'dynamic.overlay.fontSizeLabel', min: 6, max: 72 },
            { type: 'font-weight', id: 'combatIncomingFontWeight', labelKey: 'common.fontWeightLabel' },
            { type: 'color', id: 'combatIncomingBgColor', labelKey: 'dynamic.overlay.backgroundColorLabel' },
            { type: 'range', id: 'combatIncomingBgOpacity', labelKey: 'common.textBgOpacityLabel', min: 0, max: 100, unit: '%' },
        ] },
    { chipId: 'overlayChip_combatOutgoing', showId: 'combatShowOutgoing', positionId: 'combatOutgoingPosition', offsetXId: 'combatOutgoingOffsetX', offsetYId: 'combatOutgoingOffsetY', colorId: 'combatOutgoingColor', alsoRequiresIds: ['combatEnabled', 'showText'],
        fontNameId: 'combatOutgoingFontName', fontWeightId: 'combatOutgoingFontWeight', fontSizeId: 'combatOutgoingFontSize',
        bgColorId: 'combatOutgoingBgColor', bgOpacityId: 'combatOutgoingBgOpacity', requiresChatlog: true,
        popoverTitleKey: 'dynamic.overlay.outgoingDpsTitle', popoverFields: [
            { type: 'checkbox', id: 'combatEnabled', labelKey: 'dynamic.overlay.enableCombatOverlaysLabel' },
            { type: 'checkbox', id: 'combatShowOutgoing', labelKey: 'field.combatShowOutgoing.label' },
            { type: 'checkbox', id: 'combatOutgoingShowPrefix', labelKey: 'field.combatOutgoingShowPrefix.label' },
            { type: 'color', id: 'combatOutgoingColor', labelKey: 'common.textColorLabel' },
            { type: 'font-name', id: 'combatOutgoingFontName', labelKey: 'common.fontNameLabel' },
            { type: 'number', id: 'combatOutgoingFontSize', labelKey: 'dynamic.overlay.fontSizeLabel', min: 6, max: 72 },
            { type: 'font-weight', id: 'combatOutgoingFontWeight', labelKey: 'common.fontWeightLabel' },
            { type: 'color', id: 'combatOutgoingBgColor', labelKey: 'dynamic.overlay.backgroundColorLabel' },
            { type: 'range', id: 'combatOutgoingBgOpacity', labelKey: 'common.textBgOpacityLabel', min: 0, max: 100, unit: '%' },
        ] },
    { chipId: 'overlayChip_mining', showId: 'miningEnabled', positionId: 'miningPosition', offsetXId: 'miningOffsetX', offsetYId: 'miningOffsetY', colorId: 'miningColor',
        alsoRequiresIds: ['showText'],
        fontNameId: 'miningFontName', fontWeightId: 'miningFontWeight', fontSizeId: 'miningFontSize',
        bgColorId: 'miningBgColor', bgOpacityId: 'miningBgOpacity', requiresChatlog: true,
        popoverTitleKey: 'dynamic.overlay.miningRateTitle', popoverFields: [
            { type: 'checkbox', id: 'miningEnabled', labelKey: 'dynamic.overlay.showMiningRateLabel' },
            { type: 'checkbox', id: 'miningShowPrefix', labelKey: 'field.miningShowPrefix.label' },
            { type: 'color', id: 'miningColor', labelKey: 'common.textColorLabel' },
            { type: 'font-name', id: 'miningFontName', labelKey: 'common.fontNameLabel' },
            { type: 'number', id: 'miningFontSize', labelKey: 'dynamic.overlay.fontSizeLabel', min: 6, max: 72 },
            { type: 'font-weight', id: 'miningFontWeight', labelKey: 'common.fontWeightLabel' },
            { type: 'color', id: 'miningBgColor', labelKey: 'dynamic.overlay.backgroundColorLabel' },
            { type: 'range', id: 'miningBgOpacity', labelKey: 'common.textBgOpacityLabel', min: 0, max: 100, unit: '%' },
        ] },
    { chipId: 'overlayChip_bounty', showId: 'bountyEnabled', positionId: 'bountyPosition', offsetXId: 'bountyOffsetX', offsetYId: 'bountyOffsetY', colorId: 'bountyColor',
        alsoRequiresIds: ['showText'],
        fontNameId: 'bountyFontName', fontWeightId: 'bountyFontWeight', fontSizeId: 'bountyFontSize',
        bgColorId: 'bountyBgColor', bgOpacityId: 'bountyBgOpacity', requiresChatlog: true,
        popoverTitleKey: 'dynamic.overlay.bountyRateTitle', popoverFields: [
            { type: 'checkbox', id: 'bountyEnabled', labelKey: 'dynamic.overlay.showBountyRateLabel' },
            { type: 'checkbox', id: 'bountyShowPrefix', labelKey: 'field.bountyShowPrefix.label' },
            { type: 'color', id: 'bountyColor', labelKey: 'common.textColorLabel' },
            { type: 'font-name', id: 'bountyFontName', labelKey: 'common.fontNameLabel' },
            { type: 'number', id: 'bountyFontSize', labelKey: 'dynamic.overlay.fontSizeLabel', min: 6, max: 72 },
            { type: 'font-weight', id: 'bountyFontWeight', labelKey: 'common.fontWeightLabel' },
            { type: 'color', id: 'bountyBgColor', labelKey: 'dynamic.overlay.backgroundColorLabel' },
            { type: 'range', id: 'bountyBgOpacity', labelKey: 'common.textBgOpacityLabel', min: 0, max: 100, unit: '%' },
        ] },
    { chipId: 'overlayChip_resources', showId: 'resourcesEnabled', positionId: 'resourcesPosition', offsetXId: 'resourcesOffsetX', offsetYId: 'resourcesOffsetY', colorId: 'resourcesColor',
        alsoRequiresIds: ['showText'],
        fontNameId: 'resourcesFontName', fontWeightId: 'resourcesFontWeight', fontSizeId: 'resourcesFontSize',
        bgColorId: 'resourcesBgColor', bgOpacityId: 'resourcesBgOpacity',
        popoverTitleKey: 'dynamic.overlay.resourceUsageTitle', popoverFields: [
            { type: 'checkbox', id: 'resourcesEnabled', labelKey: 'dynamic.overlay.showResourceUsageLabel' },
            { type: 'checkbox', id: 'resourcesShowCpu', labelKey: 'field.resourcesShowCpu.label' },
            { type: 'checkbox', id: 'resourcesShowRam', labelKey: 'field.resourcesShowRam.label' },
            { type: 'checkbox', id: 'resourcesShowVram', labelKey: 'field.resourcesShowVram.label' },
            { type: 'color', id: 'resourcesColor', labelKey: 'common.textColorLabel' },
            { type: 'font-name', id: 'resourcesFontName', labelKey: 'common.fontNameLabel' },
            { type: 'number', id: 'resourcesFontSize', labelKey: 'dynamic.overlay.fontSizeLabel', min: 6, max: 72 },
            { type: 'font-weight', id: 'resourcesFontWeight', labelKey: 'common.fontWeightLabel' },
            { type: 'color', id: 'resourcesBgColor', labelKey: 'dynamic.overlay.backgroundColorLabel' },
            { type: 'range', id: 'resourcesBgOpacity', labelKey: 'common.textBgOpacityLabel', min: 0, max: 100, unit: '%' },
        ] },
];

// Distance (in stage pixels) within which a drag magnetically locks flush to the current anchor (offset 0,0).
const OVERLAY_SNAP_THRESHOLD_PX = 5;

// Distance (in stage pixels) within which a drag aligns to another chip's edge/center, independently per axis.
const OVERLAY_ALIGN_THRESHOLD_PX = 3;

// Sub-pixel offsetLeft/offsetTop/offsetWidth/offsetHeight, converted from getBoundingClientRect()'s viewport-relative border box back to the stage's padding box.
function overlayChipStagePos(stage, chip) {
    const stageRect = stage.getBoundingClientRect();
    const stageStyle = getComputedStyle(stage);
    const originX = stageRect.left + parseFloat(stageStyle.borderLeftWidth);
    const originY = stageRect.top + parseFloat(stageStyle.borderTopWidth);
    const rect = chip.getBoundingClientRect();
    return { left: rect.left - originX, top: rect.top - originY, width: rect.width, height: rect.height };
}

function overlayChipRects() {
    const stage = document.getElementById('overlayLayoutStage');
    if (!stage) return [];
    return OVERLAY_LAYOUT_ELEMENTS.map(def => {
        const chip = document.getElementById(def.chipId);
        if (!chip) return null;
        return { chip, ...overlayChipStagePos(stage, chip) };
    }).filter(Boolean);
}

// Matches both same-edge alignment and flush-adjacency (my bottom meets your top, etc.) so chips snap when stacked or side-by-side.
function overlayFindAlignmentSnap(selfChipId, rawX, rawY, w, h) {
    let bestX = null, bestXDist = OVERLAY_ALIGN_THRESHOLD_PX, guideX = null;
    let bestY = null, bestYDist = OVERLAY_ALIGN_THRESHOLD_PX, guideY = null;

    overlayChipRects().forEach(other => {
        if (other.chip.id === selfChipId) return;
        const oLeft = other.left, oRight = other.left + other.width, oCenterX = other.left + other.width / 2;
        const oTop = other.top, oBottom = other.top + other.height, oCenterY = other.top + other.height / 2;

        // [selfValue, otherValue (also the guide line position), resulting snapped position]
        // Last two rows are flush-adjacency: my right edge to their left edge, and vice versa.
        const xCandidates = [
            [rawX, oLeft, oLeft],
            [rawX + w, oRight, oRight - w],
            [rawX + w / 2, oCenterX, oCenterX - w / 2],
            [rawX, oRight, oRight],
            [rawX + w, oLeft, oLeft - w],
        ];
        xCandidates.forEach(([selfVal, guideVal, snapVal]) => {
            const dist = Math.abs(selfVal - guideVal);
            if (dist < bestXDist) { bestXDist = dist; bestX = snapVal; guideX = guideVal; }
        });

        // Last two rows are flush-adjacency: my bottom edge to their top edge, and vice versa.
        const yCandidates = [
            [rawY, oTop, oTop],
            [rawY + h, oBottom, oBottom - h],
            [rawY + h / 2, oCenterY, oCenterY - h / 2],
            [rawY, oBottom, oBottom],
            [rawY + h, oTop, oTop - h],
        ];
        yCandidates.forEach(([selfVal, guideVal, snapVal]) => {
            const dist = Math.abs(selfVal - guideVal);
            if (dist < bestYDist) { bestYDist = dist; bestY = snapVal; guideY = guideVal; }
        });
    });

    return { x: bestX, y: bestY, guideX, guideY };
}

function overlayShowAlignmentGuides(guideX, guideY) {
    const guideXEl = document.getElementById('overlayGuideX');
    const guideYEl = document.getElementById('overlayGuideY');
    if (guideXEl) {
        guideXEl.style.display = guideX === null ? 'none' : 'block';
        if (guideX !== null) guideXEl.style.left = guideX + 'px';
    }
    if (guideYEl) {
        guideYEl.style.display = guideY === null ? 'none' : 'block';
        if (guideY !== null) guideYEl.style.top = guideY + 'px';
    }
}

function overlayAnchorBoxPos(anchor, w, h, W, H) {
    switch (anchor) {
        case 'TopLeft': return { x: 0, y: 0 };
        case 'TopCenter': return { x: (W - w) / 2, y: 0 };
        case 'TopRight': return { x: W - w, y: 0 };
        case 'LeftCenter': return { x: 0, y: (H - h) / 2 };
        case 'Center': return { x: (W - w) / 2, y: (H - h) / 2 };
        case 'RightCenter': return { x: W - w, y: (H - h) / 2 };
        case 'BottomLeft': return { x: 0, y: H - h };
        case 'BottomCenter': return { x: (W - w) / 2, y: H - h };
        case 'BottomRight': return { x: W - w, y: H - h };
        default: return { x: 0, y: 0 };
    }
}

// The TextPosition anchors laid out as the thirds of the thumbnail they sit in.
const OVERLAY_ZONES = [
    ['TopLeft', 'TopCenter', 'TopRight'],
    ['LeftCenter', 'Center', 'RightCenter'],
    ['BottomLeft', 'BottomCenter', 'BottomRight'],
];

// Invisible to the user - a drop just picks the nearest of these thirds as its stored anchor.
function overlayZoneForPoint(px, py, W, H) {
    const col = px < W / 3 ? 0 : px < (2 * W) / 3 ? 1 : 2;
    const row = py < H / 3 ? 0 : py < (2 * H) / 3 ? 1 : 2;
    return OVERLAY_ZONES[row][col];
}

function overlayClamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

// The field's own bounds, which the schema sets (see binding.js).
function overlayOffsetRange(fieldId) {
    const field = document.getElementById(fieldId);
    const min = parseFloat(field?.min);
    const max = parseFloat(field?.max);
    return { min: isNaN(min) ? -Infinity : min, max: isNaN(max) ? Infinity : max };
}

// Stage is drawn larger than the real thumbnail for grabbability, but offsetX/Y are stored in real pixels.
function overlayStageScale(stage) {
    if (!stage) return 1;
    const { width } = overlayStageContentSize(stage);
    if (width === 0) return 1;
    const realWidth = getFieldValue('thumbWidth');
    return realWidth > 0 ? width / realWidth : 1;
}

// Sub-pixel clientWidth/clientHeight: the aspect-ratio box often renders at a fractional size, and rounding that here (independently of a chip's own rounding) bakes in a mismatch at the far edge.
function overlayStageContentSize(stage) {
    const rect = stage.getBoundingClientRect();
    const style = getComputedStyle(stage);
    const borderX = parseFloat(style.borderLeftWidth) + parseFloat(style.borderRightWidth);
    const borderY = parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth);
    return { width: rect.width - borderX, height: rect.height - borderY };
}

// Programmatic .value writes don't fire native events, so dispatch one explicitly for the rest of the dialog to see.
function setOverlayFieldValue(fieldId, value) {
    const field = document.getElementById(fieldId);
    if (!field) return;
    field.value = value;
    field.dispatchEvent(new Event(isChangeEventType(field) ? 'change' : 'input', { bubbles: true }));
}

export function setOverlayCheckboxValue(fieldId, checked) {
    const field = document.getElementById(fieldId);
    if (!field) return;
    field.checked = checked;
    field.dispatchEvent(new Event('change', { bubbles: true }));
}

function placeOverlayChip(def) {
    const stage = document.getElementById('overlayLayoutStage');
    const chip = document.getElementById(def.chipId);
    if (!stage || !chip) return;

    const scale = overlayStageScale(stage);

    const shown = getFieldValue(def.showId) && (def.alsoRequiresIds || []).every(id => getFieldValue(id));
    chip.classList.toggle('dim', !shown);

    // Matches painter.zig's TEXT_PADDING_X/Y (5px/2px at real scale); left side is
    // tighter since the drag-handle glyph already carries its own visual weight there.
    chip.style.padding = `${2 * scale}px ${5 * scale}px ${2 * scale}px ${3 * scale}px`;

    // Preview chips always use the accent color and black text, ignoring each setting's own color/background config.
    chip.style.backgroundColor = 'var(--color-accent)';
    chip.style.color = '#000000';

    if (def.fontSizeId) {
        // Not * scale: that's tuned for a few px of padding, but stretches a 12px font to ~32px at default stage zoom.
        const size = getFieldValue(def.fontSizeId);
        if (size) chip.style.fontSize = `${size / 16}rem`;
    }

    const { width: W, height: H } = overlayStageContentSize(stage);
    const chipRect = chip.getBoundingClientRect();
    const w = chipRect.width, h = chipRect.height;
    const anchor = getFieldValue(def.positionId) || 'TopLeft';
    const anchorPos = overlayAnchorBoxPos(anchor, w, h, W, H);
    const ox = (getFieldValue(def.offsetXId) || 0) * scale;
    const oy = (getFieldValue(def.offsetYId) || 0) * scale;

    chip.style.left = overlayClamp(anchorPos.x + ox, 0, Math.max(0, W - w)) + 'px';
    chip.style.top = overlayClamp(anchorPos.y + oy, 0, Math.max(0, H - h)) + 'px';
}

// Mock thumbnail tracks the real aspect ratio so anchor math (Center/TopRight/etc.) matches how it'll actually render.
export function refreshOverlayLayoutPreview() {
    const stage = document.getElementById('overlayLayoutStage');
    if (!stage) return;
    const w = getFieldValue('thumbWidth') || 16;
    const h = getFieldValue('thumbHeight') || 9;
    stage.style.aspectRatio = `${w} / ${h}`;
    OVERLAY_LAYOUT_ELEMENTS.forEach(placeOverlayChip);
}

// Mirrors toggleInverseOption()'s real-tab dimming (e.g. Unique Character Name Colors disabling the color picker).
// Dims the label/input pair directly rather than their wrap div, which is display:contents and renders no box of its own to fade.
function applyPopoverInverseDisable(targetFieldId, disabled) {
    const body = document.getElementById('overlayPopoverBody');
    const input = body?.querySelector(`[data-popover-for="${targetFieldId}"]`);
    if (!input) return;
    Array.from(input.parentElement.children).forEach(el => el.classList.toggle('is-disabled', disabled));
}

// Writes back through setOverlayFieldValue()/setOverlayCheckboxValue() so it behaves like editing the real tab.
// Keys whose values get copied across every element when "Sync Fonts, Colors and Backgrounds" is on.
const OVERLAY_STYLE_SYNC_KEYS = ['fontNameId', 'fontSizeId', 'fontWeightId', 'bgColorId', 'bgOpacityId'];

// Copies sourceDef's current font/color/background fields onto every other element.
function syncOverlayStyleFrom(sourceDef) {
    OVERLAY_STYLE_SYNC_KEYS.forEach(key => {
        const sourceId = sourceDef[key];
        if (!sourceId) return;
        const sourceField = document.getElementById(sourceId);
        if (!sourceField) return;
        // getFieldValue() converts color inputs to Zig's 0xAARRGGBB format, but a color <input>'s
        // .value must stay '#rrggbb' - read the raw value directly for bgColorId.
        const value = key === 'bgColorId' ? sourceField.value : getFieldValue(sourceId);
        OVERLAY_LAYOUT_ELEMENTS.forEach(otherDef => {
            const targetId = otherDef[key];
            if (!targetId || targetId === sourceId) return;
            setOverlayFieldValue(targetId, value);
        });
    });
}

export function syncOverlayStyleFromCharacterName() {
    const characterNameDef = OVERLAY_LAYOUT_ELEMENTS.find(d => d.chipId === 'overlayChip_characterName');
    if (characterNameDef) syncOverlayStyleFrom(characterNameDef);
}

// After a synced-kind field is edited via its popover, re-propagate that element's full style to the rest.
function maybeSyncOverlayStyle(def) {
    if (document.getElementById('syncOverlayStyling')?.checked) syncOverlayStyleFrom(def);
}

// Reads/writes the markup carrying .hidden-by-layout-preview (index.html) - those inputs stay
// this popover's backing store even though the class itself has no CSS rule of its own.
function buildOverlayPopoverField(f, def) {
    const wrap = document.createElement('div');
    wrap.className = 'overlay-popover-field';
    const real = document.getElementById(f.id);

    if (f.type === 'checkbox') {
        const label = document.createElement('label');
        label.className = 'overlay-popover-checkbox-row';
        const input = document.createElement('input');
        input.type = 'checkbox';
        input.checked = !!(real && real.checked);
        input.addEventListener('change', () => {
            setOverlayCheckboxValue(f.id, input.checked);
            if (f.disables) applyPopoverInverseDisable(f.disables, input.checked);
        });
        const span = document.createElement('span');
        span.className = 'label-body';
        span.textContent = t(f.labelKey);
        label.appendChild(input);
        label.appendChild(span);
        wrap.appendChild(label);
        return wrap;
    }

    const label = document.createElement('label');
    label.textContent = t(f.labelKey);
    wrap.appendChild(label);

    let input;
    if (f.type === 'color') {
        input = document.createElement('input');
        input.type = 'color';
        input.value = real ? real.value : '#ffffff';
        if (real?.dataset.defaultColor) input.dataset.defaultColor = real.dataset.defaultColor;
        input.dataset.popoverFor = f.id;
        input.addEventListener('input', () => { setOverlayFieldValue(f.id, input.value); maybeSyncOverlayStyle(def); });
    } else if (f.type === 'number') {
        input = document.createElement('input');
        input.type = 'number';
        if (f.min !== undefined) input.min = f.min;
        if (f.max !== undefined) input.max = f.max;
        input.value = real ? real.value : '';
        input.addEventListener('input', () => { setOverlayFieldValue(f.id, input.value); maybeSyncOverlayStyle(def); });
    } else if (f.type === 'range') {
        input = document.createElement('input');
        input.type = 'range';
        if (f.min !== undefined) input.min = f.min;
        if (f.max !== undefined) input.max = f.max;
        input.value = real ? real.value : (f.min ?? 0);
        const valueSpan = document.createElement('span');
        valueSpan.textContent = input.value + (f.unit || '');
        input.addEventListener('input', () => {
            setOverlayFieldValue(f.id, input.value);
            valueSpan.textContent = input.value + (f.unit || '');
            maybeSyncOverlayStyle(def);
        });
        const control = document.createElement('div');
        control.className = 'overlay-popover-range-control';
        control.appendChild(input);
        control.appendChild(valueSpan);
        wrap.appendChild(control);
        return wrap;
    } else if (f.type === 'font-name' || f.type === 'font-weight') {
        // Offers the same choices as the form's own select, which it stands in for.
        input = document.createElement('select');
        Array.from(real?.options || []).forEach(option => input.add(new Option(option.text, option.value)));
        if (real) input.value = real.value;
        input.addEventListener('change', () => { setOverlayFieldValue(f.id, input.value); maybeSyncOverlayStyle(def); });
    }

    if (input) wrap.appendChild(input);
    return wrap;
}

function closeOverlayPopover() {
    const popover = document.getElementById('overlayPropertiesPopover');
    if (popover) popover.style.display = 'none';
}

function openOverlayPopover(def, chip) {
    const popover = document.getElementById('overlayPropertiesPopover');
    const title = document.getElementById('overlayPopoverTitle');
    const body = document.getElementById('overlayPopoverBody');
    if (!popover || !title || !body || !def.popoverFields) return;

    title.textContent = t(def.popoverTitleKey);
    body.innerHTML = '';

    if (def.requiresChatlog && !document.getElementById('chatlogEnabled')?.checked) {
        const gateNotice = document.createElement('div');
        gateNotice.className = 'gate-notice show';
        const message = document.createElement('span');
        message.className = 'label-body';
        message.textContent = t('dynamic.overlay.chatlogGateMessage');
        gateNotice.appendChild(message);
        body.appendChild(gateNotice);
    }

    def.popoverFields.forEach(f => body.appendChild(buildOverlayPopoverField(f, def)));
    def.popoverFields.forEach(f => {
        if (f.type === 'checkbox' && f.disables) {
            applyPopoverInverseDisable(f.disables, !!document.getElementById(f.id)?.checked);
        }
    });

    popover.style.display = 'block';
    const chipRect = chip.getBoundingClientRect();
    const popRect = popover.getBoundingClientRect();
    let left = chipRect.right + 8;
    let top = chipRect.top;
    if (left + popRect.width > window.innerWidth) left = chipRect.left - popRect.width - 8;
    if (top + popRect.height > window.innerHeight) top = window.innerHeight - popRect.height - 8;
    popover.style.left = Math.max(8, left) + 'px';
    popover.style.top = Math.max(8, top) + 'px';
}

function setupOverlayChipDrag(def) {
    const chip = document.getElementById(def.chipId);
    if (!chip) return;

    let dragging = false;
    let moved = false;
    let startX = 0, startY = 0, originLeft = 0, originTop = 0;
    // endDrag reads this instead of offsetLeft/offsetTop, which would round off pointermove's fractional position.
    let lastX = 0, lastY = 0;

    chip.addEventListener('pointerdown', (e) => {
        dragging = true;
        moved = false;
        chip.classList.add('dragging');
        chip.classList.remove('settling');
        chip.setPointerCapture(e.pointerId);
        startX = e.clientX;
        startY = e.clientY;
        const stage = document.getElementById('overlayLayoutStage');
        const { left, top } = overlayChipStagePos(stage, chip);
        originLeft = left;
        originTop = top;
        lastX = left;
        lastY = top;
        e.preventDefault();
    });

    chip.addEventListener('pointermove', (e) => {
        if (!dragging) return;
        if (Math.hypot(e.clientX - startX, e.clientY - startY) > 4) moved = true;

        const stage = document.getElementById('overlayLayoutStage');
        const { width: W, height: H } = overlayStageContentSize(stage);
        const chipRect = chip.getBoundingClientRect();
        const w = chipRect.width, h = chipRect.height;
        const scale = overlayStageScale(stage);
        const rangeX = overlayOffsetRange(def.offsetXId);
        const rangeY = overlayOffsetRange(def.offsetYId);

        const rawX = overlayClamp(originLeft + (e.clientX - startX), 0, Math.max(0, W - w));
        const rawY = overlayClamp(originTop + (e.clientY - startY), 0, Math.max(0, H - h));
        const anchor = overlayZoneForPoint(rawX + w / 2, rawY + h / 2, W, H);
        const anchorPos = overlayAnchorBoxPos(anchor, w, h, W, H);

        // Anchor snap takes priority over chip-to-chip alignment.
        const snappedToAnchor = Math.hypot(rawX - anchorPos.x, rawY - anchorPos.y) < OVERLAY_SNAP_THRESHOLD_PX;
        const align = snappedToAnchor ? { x: null, y: null, guideX: null, guideY: null } : overlayFindAlignmentSnap(chip.id, rawX, rawY, w, h);
        const alignedToOther = align.x !== null || align.y !== null;
        const targetX = snappedToAnchor ? anchorPos.x : (align.x !== null ? align.x : rawX);
        const targetY = snappedToAnchor ? anchorPos.y : (align.y !== null ? align.y : rawY);

        // Clamped live, not just at drop, or the chip would jump back once released.
        const x = overlayClamp(targetX, Math.max(0, anchorPos.x + rangeX.min * scale), Math.min(W - w, anchorPos.x + rangeX.max * scale));
        const y = overlayClamp(targetY, Math.max(0, anchorPos.y + rangeY.min * scale), Math.min(H - h, anchorPos.y + rangeY.max * scale));

        chip.style.left = x + 'px';
        chip.style.top = y + 'px';
        lastX = x;
        lastY = y;
        chip.classList.toggle('snapped', snappedToAnchor || alignedToOther);
        chip.classList.toggle('clamped', x !== targetX || y !== targetY);
        overlayShowAlignmentGuides(snappedToAnchor ? null : align.guideX, snappedToAnchor ? null : align.guideY);
    });

    function endDrag() {
        if (!dragging) return;
        dragging = false;
        chip.classList.remove('dragging', 'clamped', 'snapped');
        chip.classList.add('settling');
        overlayShowAlignmentGuides(null, null);

        const stage = document.getElementById('overlayLayoutStage');
        const { width: W, height: H } = overlayStageContentSize(stage);
        const chipRect = chip.getBoundingClientRect();
        const w = chipRect.width, h = chipRect.height;
        const scale = overlayStageScale(stage);
        const x = lastX, y = lastY;
        const anchor = overlayZoneForPoint(x + w / 2, y + h / 2, W, H);
        const anchorPos = overlayAnchorBoxPos(anchor, w, h, W, H);
        const rangeX = overlayOffsetRange(def.offsetXId);
        const rangeY = overlayOffsetRange(def.offsetYId);
        const ox = overlayClamp((x - anchorPos.x) / scale, rangeX.min, rangeX.max);
        const oy = overlayClamp((y - anchorPos.y) / scale, rangeY.min, rangeY.max);

        setOverlayFieldValue(def.positionId, anchor);
        setOverlayFieldValue(def.offsetXId, Math.round(ox));
        setOverlayFieldValue(def.offsetYId, Math.round(oy));
        placeOverlayChip(def);

        // A click (no real movement) opens this element's properties popover instead of just re-placing it.
        if (!moved && def.popoverFields) openOverlayPopover(def, chip);
    }

    chip.addEventListener('pointerup', endDrag);
    chip.addEventListener('pointercancel', endDrag);
}

export function initOverlayLayoutPreview() {
    if (!document.getElementById('overlayLayoutStage')) return;

    OVERLAY_LAYOUT_ELEMENTS.forEach(def => {
        setupOverlayChipDrag(def);

        // Refreshes live however the field gets edited - this tab, the popover, or the real tab.
        const liveFieldIds = new Set([
            def.positionId, def.showId, ...(def.alsoRequiresIds || []), def.colorId,
            def.fontNameId, def.fontWeightId, def.uniqueColorsId,
            def.bgColorId, def.bgOpacityId,
            ...(def.popoverFields || []).map(f => f.id),
        ].filter(Boolean));

        liveFieldIds.forEach(id => {
            const field = document.getElementById(id);
            if (!field) return;
            field.addEventListener(isChangeEventType(field) ? 'change' : 'input', refreshOverlayLayoutPreview);
        });
    });

    document.getElementById('thumbWidth')?.addEventListener('input', refreshOverlayLayoutPreview);
    document.getElementById('thumbHeight')?.addEventListener('input', refreshOverlayLayoutPreview);
    document.getElementById('thumbSizeSlider')?.addEventListener('input', refreshOverlayLayoutPreview);
    window.addEventListener('resize', refreshOverlayLayoutPreview);
    window.addEventListener('resize', () => fitHotkeyGroupCharsList(selectedHotkeyGroupIndex));
    window.addEventListener('resize', updateHotkeyPlaceholders);
    // Startup size is a DPI guess corrected post-load (targetSize/WM_DPICHANGED in dialog/host.zig) - redo every registered label-column measurement once it lands.
    window.addEventListener('resize', () => labelColumnRealignJobs.forEach(job => job()));

    // Turning sync on (or loading a profile while it's already on) unifies every element to Character Name's current styling.
    document.getElementById('syncOverlayStyling')?.addEventListener('change', function () {
        if (this.checked) syncOverlayStyleFromCharacterName();
    });

    document.getElementById('overlayPopoverClose')?.addEventListener('click', closeOverlayPopover);
    document.addEventListener('pointerdown', (e) => {
        const popover = document.getElementById('overlayPropertiesPopover');
        if (!popover || popover.style.display === 'none') return;
        if (popover.contains(e.target)) return;
        if (e.target.closest && e.target.closest('.overlay-chip')) return;
        // Color picker popup lives outside this popover (appended to document.body) - don't treat it as "clicked outside".
        if (e.target.closest && e.target.closest('#custom-color-picker')) return;
        closeOverlayPopover();
    });
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') closeOverlayPopover();
    });
}
