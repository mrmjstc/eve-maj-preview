// Unsaved-change tracking for the whole form.
import { app } from './state.js';

export function markAsChanged() {
    if (!app.hasUnsavedChanges) {
        app.hasUnsavedChanges = true;
        const indicator = document.getElementById('changes-indicator');
        if (indicator) {
            indicator.style.display = 'flex';
        }
    }
}

export function markAsSaved() {
    app.hasUnsavedChanges = false;
    const indicator = document.getElementById('changes-indicator');
    if (indicator) {
        indicator.style.display = 'none';
    }
    app.savedFormFingerprint = computeFormFingerprint();
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

// Value-based snapshot of every tracked field. Unlike hasUnsavedChanges (a one-way latch set by any input/change event),
// this tells a real edit apart from a value that got toggled back to what it was - e.g. a checkbox clicked on then off.
function computeFormFingerprint() {
    const parts = [];
    document.querySelectorAll('input, select, textarea').forEach((el) => {
        if (!isTrackedFormElement(el)) return;
        const value = (el.type === 'checkbox' || el.type === 'radio') ? el.checked : el.value;
        parts.push(el.id + '=' + value);
    });
    return parts.join('\n');
}

// null savedFormFingerprint means the initial load hasn't finished yet, so nothing can be "unsaved" yet either.
export function hasRealUnsavedChanges() {
    return app.savedFormFingerprint !== null && computeFormFingerprint() !== app.savedFormFingerprint;
}

export function setupChangeDetection() {
    document.addEventListener('input', (e) => {
        if (isTrackedFormElement(e.target) && !isChangeEventType(e.target)) markAsChanged();
    });
    document.addEventListener('change', (e) => {
        if (isTrackedFormElement(e.target) && isChangeEventType(e.target)) markAsChanged();
    });
}
