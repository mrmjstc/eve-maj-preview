// Unsaved-change tracking: every edit is flushed to the app (see session.js), which says whether it differs from what's saved.
import { app } from './state.js';
import { hasPendingEdits, scheduleFlush } from './session.js';

export function markAsChanged() {
    scheduleFlush();
}

export function setDirty(dirty) {
    app.dirty = dirty;
    const indicator = document.getElementById('changes-indicator');
    if (indicator) indicator.style.display = hasUnsavedChanges() ? 'flex' : 'none';
}

// Counts edits not yet flushed too; callers that need an exact answer await flushEdits() first.
export function hasUnsavedChanges() {
    return app.dirty.profile || app.dirty.global || hasPendingEdits();
}

// Delegated (not per-element) so rows added later at runtime are covered without needing to re-run this after every dynamic list rebuild.
function isTrackedFormElement(element) {
    if (!element.matches || !element.matches('input, select, textarea')) return false;
    return element.id !== 'search-filter' && element.id !== 'profile-select' && element.id !== 'ultraPotatoProfileSelect' &&
        element.id !== 'dialogScaleSelect';
}

export function isChangeEventType(element) {
    return element.type === 'checkbox' || element.type === 'radio' ||
        element.type === 'color' || element.tagName === 'SELECT';
}

export function setupChangeDetection() {
    document.addEventListener('input', (e) => {
        if (isTrackedFormElement(e.target) && !isChangeEventType(e.target)) markAsChanged();
    });
    document.addEventListener('change', (e) => {
        if (isTrackedFormElement(e.target) && isChangeEventType(e.target)) markAsChanged();
    });
}
