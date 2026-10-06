// Drawing and editing a thumbnail space's region through the app's overlay.
import { app } from './state.js';
import { markAsChanged } from './changes.js';
import { listenForAppEvent, logWarn, rpc } from './core.js';
import { t } from './i18n.js';
import { showStatus } from './layout.js';
import { populateThumbnailSpaces, saveThumbnailSpaces, spaceRect } from './thumbnail_spaces.js';

// The app draws the drag overlay; the result comes back as a regionSelected event, for the space that started it.
let regionSelectTarget = null;

// The list may have been reloaded while the overlay was up, replacing its objects, so the space is found again by id.
function findSpace(space) {
    const list = app.currentConfig?.thumbnailSpaces || [];
    if (list.includes(space)) return space;
    return space.id == null ? null : list.find(other => other.id === space.id) || null;
}

listenForAppEvent('regionSelected', (result) => {
    const target = regionSelectTarget;
    regionSelectTarget = null;
    if (!target) return;
    if (result.tooSmall) showStatus(t('status.regionSelectTooSmall'), 'info');
    if (result.cancelled) return;

    const space = findSpace(target);
    if (!space) return;
    saveThumbnailSpaces();
    Object.assign(space, { x: result.x, y: result.y, width: result.width, height: result.height });
    markAsChanged();
    populateThumbnailSpaces();
    showStatus(t('status.regionSet'), 'success');
});

export function clearSpaceRegion(index) {
    const space = app.currentConfig?.thumbnailSpaces?.[index];
    if (!space) return;
    saveThumbnailSpaces();
    Object.assign(space, { x: null, y: null, width: null, height: null });
    markAsChanged();
    populateThumbnailSpaces();
}

// `edit` adjusts the space's current region's borders instead of dragging a new one.
export async function startSpaceRegionSelect(index, edit = false) {
    if (typeof eveRpc === 'undefined') return;
    const space = app.currentConfig?.thumbnailSpaces?.[index];
    if (!space) return;

    const regionToEdit = edit ? spaceRect(space) : null;
    if (edit && !regionToEdit) return;
    try {
        await rpc('startRegionSelect', {
            hide: !!document.getElementById('hideThumbnailsDuringRegionSelect')?.checked,
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
        regionSelectTarget = space;
    } catch (err) {
        logWarn('Failed to start region select:', err);
        showStatus(t('status.regionSelectFailedPrefix') + err.message, 'error');
    }
}
