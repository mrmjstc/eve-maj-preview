// Drawing and editing the Thumbnail Space regions through the app's overlay.
import { app } from './state.js';
import { markAsChanged } from './changes.js';
import { listenForAppEvent, logWarn, rpc } from './core.js';
import { setFieldValue } from './form.js';
import { t } from './i18n.js';
import { showStatus } from './layout.js';
import { scheduleThumbnailPreview } from './preview.js';

// The app draws the drag overlay; the result comes back as a regionSelected event, routed to whichever fields started it.
let regionSelectTarget = null;

listenForAppEvent('regionSelected', (result) => {
    const fieldIds = regionSelectTarget;
    regionSelectTarget = null;
    if (!fieldIds) return;
    if (result.tooSmall) showStatus(t('status.regionSelectTooSmall'), 'info');
    if (result.cancelled) return;

    setFieldValue(fieldIds.x, result.x);
    setFieldValue(fieldIds.y, result.y);
    setFieldValue(fieldIds.width, result.width);
    setFieldValue(fieldIds.height, result.height);
    app.currentConfig.display[fieldIds.x] = result.x;
    app.currentConfig.display[fieldIds.y] = result.y;
    app.currentConfig.display[fieldIds.width] = result.width;
    app.currentConfig.display[fieldIds.height] = result.height;
    refreshRegionButtons();
    markAsChanged();
    scheduleThumbnailPreview();
    showStatus(t('status.regionSet'), 'success');
});

export const REGION_FIELD_IDS = { x: 'regionX', y: 'regionY', width: 'regionWidth', height: 'regionHeight', hideThumbnails: 'hideThumbnailsDuringRegionSelect' };
export const NOT_LOGGED_IN_FIELD_IDS = { x: 'notLoggedInSpaceX', y: 'notLoggedInSpaceY', width: 'notLoggedInSpaceWidth', height: 'notLoggedInSpaceHeight', hideThumbnails: 'notLoggedInSpaceHideThumbnailsDuringRegionSelect' };

function currentRegionValues(fieldIds) {
    const values = [fieldIds.x, fieldIds.y, fieldIds.width, fieldIds.height].map(id => app.currentConfig?.display?.[id]);
    return values.every(Number.isInteger) && values[2] > 0 && values[3] > 0 ? values : null;
}

// Edit and clear need an existing region to act on, so they're greyed out until one is set.
export function refreshRegionButtons() {
    const rows = [
        [['editRegionButton', 'clearRegionButton'], REGION_FIELD_IDS],
        [['editNotLoggedInSpaceButton', 'clearNotLoggedInSpaceButton'], NOT_LOGGED_IN_FIELD_IDS],
    ];
    for (const [buttonIds, fieldIds] of rows) {
        const disabled = !currentRegionValues(fieldIds);
        for (const buttonId of buttonIds) {
            const button = document.getElementById(buttonId);
            if (button) button.disabled = disabled;
        }
    }
}

export function clearRegion(fieldIds) {
    for (const id of [fieldIds.x, fieldIds.y, fieldIds.width, fieldIds.height]) {
        setFieldValue(id, null);
        app.currentConfig.display[id] = null;
    }
    refreshRegionButtons();
    markAsChanged();
    scheduleThumbnailPreview();
}

// fieldIds let the same overlay feed either RegionFit or notLoggedInSpace; edit adjusts the existing region's borders instead of dragging a new one.
export async function startRegionSelectFlow(fieldIds, edit = false) {
    if (typeof webui === 'undefined') return;

    const regionToEdit = edit ? currentRegionValues(fieldIds) : null;
    if (edit && !regionToEdit) return;
    try {
        await rpc('startRegionSelect', {
            hide: !!document.getElementById(fieldIds.hideThumbnails)?.checked,
            region: regionToEdit,
            // The overlay is drawn by the app, which has no language files, so it gets its text from here.
            labels: {
                save: t('button.save-configuration.label'),
                cancel: t('common.cancel'),
                hintNew: t('overlay.regionHintNew'),
                hintEdit: t('overlay.regionHintEdit'),
                hintConfirm: t('overlay.regionHintConfirm'),
            },
        });
        regionSelectTarget = fieldIds;
    } catch (err) {
        logWarn('Failed to start region select:', err);
        showStatus(t('status.regionSelectFailedPrefix') + err.message, 'error');
    }
}
