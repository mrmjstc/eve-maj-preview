// Shared list widgets: confirm buttons, drag reordering, accordions and roster search.
import { markAsChanged } from './changes.js';
import { alignBindingLabelColumns, labelColumnRealignJobs, remVarToPx, updateHotkeyPlaceholders } from './hotkeys.js';
import { t } from './i18n.js';

// Shared by setupCharacterDragAndDrop and setupHotkeyGroupCharDragAndDrop, which were previously near-identical ~60-line blocks differing only in selectors and the reorder callback.
// Nearest ancestor that actually scrolls - not always the element holding the rows, since #charactersList wraps the .roster that carries the overflow.
function nearestScrollableAncestor(el) {
    for (let node = el.parentElement; node; node = node.parentElement) {
        const overflowY = getComputedStyle(node).overflowY;
        if (overflowY === 'auto' || overflowY === 'scroll') return node;
    }
    return null;
}

// Drag-to-reorder for a list or grid of rows. The insertion point is measured against every row at once rather than
// whichever one the pointer happens to be over, so the gaps between rows and the empty space past the last one drop
// as sensibly as the rows do. options: wholeRow (drag from anywhere on the row), grid (rows sit side by side).
export function setupDragReorder(container, itemSelector, handleSelector, getIndex, onReorder, options = {}) {
    if (!container) return;
    // A container that outlives its rows (the member list re-renders in place) would otherwise stack a second set of handlers on every call, and keep the last set alive after its rows are gone.
    container.dragReorderAbort?.abort();

    const items = Array.from(container.querySelectorAll(itemSelector));
    if (items.length === 0) return;

    const abort = new AbortController();
    container.dragReorderAbort = abort;
    const signal = abort.signal;

    const scroller = nearestScrollableAncestor(items[0]);
    let draggedIndex = null;

    // Rows sitting side by side need the pointer's x to tell which side of one it's on; a single column only cares about y.
    const insertionIndexAt = (x, y) => {
        let index = 0;
        for (const item of items) {
            const rect = item.getBoundingClientRect();
            const isPast = options.grid
                ? (y > rect.bottom || (y >= rect.top && x > rect.left + rect.width / 2))
                : (y > rect.top + rect.height / 2);
            if (!isPast) break;
            index++;
        }
        return index;
    };

    const clearMarkers = () => items.forEach(i => i.classList.remove('drag-over-top', 'drag-over-bottom'));

    const markInsertion = (index) => {
        clearMarkers();
        // Dropping on either side of where it started changes nothing, so neither position is marked.
        if (index === draggedIndex || index === draggedIndex + 1) return;
        if (index < items.length) items[index].classList.add('drag-over-top');
        else items[items.length - 1].classList.add('drag-over-bottom');
    };

    // A row can only be dragged past the end of a scrolled-off list if the drag itself scrolls.
    const autoScroll = (y) => {
        if (!scroller || scroller.scrollHeight <= scroller.clientHeight) return;
        const rect = scroller.getBoundingClientRect();
        const EDGE = 36;
        const fromTop = y - rect.top;
        const fromBottom = rect.bottom - y;
        if (fromTop < EDGE) scroller.scrollTop -= (EDGE - fromTop) / 3;
        else if (fromBottom < EDGE) scroller.scrollTop += (EDGE - fromBottom) / 3;
    };

    items.forEach(item => {
        // Rows carrying a text input keep the index chip as their handle, so dragging can't fight with selecting text in the input.
        const handle = options.wholeRow ? item : (handleSelector ? item.querySelector(handleSelector) : item);
        if (!handle) return;
        if (options.wholeRow) item.draggable = true;

        handle.addEventListener('dragstart', (e) => {
            draggedIndex = getIndex(item);
            item.classList.add('dragging');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/plain', String(draggedIndex));
            // Drag the whole item, not just the small handle glyph
            e.dataTransfer.setDragImage(item, 10, 10);
        }, { signal });

        handle.addEventListener('dragend', () => {
            item.classList.remove('dragging');
            clearMarkers();
            draggedIndex = null;
        }, { signal });
    });

    container.addEventListener('dragover', (e) => {
        if (draggedIndex === null) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        autoScroll(e.clientY);
        markInsertion(insertionIndexAt(e.clientX, e.clientY));
    }, { signal });

    container.addEventListener('dragleave', (e) => {
        if (!container.contains(e.relatedTarget)) clearMarkers();
    }, { signal });

    container.addEventListener('drop', (e) => {
        e.preventDefault();
        clearMarkers();
        if (draggedIndex === null) return;

        const index = insertionIndexAt(e.clientX, e.clientY);
        if (index === draggedIndex || index === draggedIndex + 1) return;
        onReorder(draggedIndex, index);
        markAsChanged();
    }, { signal });
}

// Moves arr[fromIndex] to just before insertBeforeIndex (both measured before the move), matching setupDragReorder's insertion semantics. Returns the moved element.
export function moveArrayItem(arr, fromIndex, insertBeforeIndex) {
    const [moved] = arr.splice(fromIndex, 1);
    const insertAt = fromIndex < insertBeforeIndex ? insertBeforeIndex - 1 : insertBeforeIndex;
    arr.splice(insertAt, 0, moved);
    return moved;
}

// Filters .roster-row elements in containerId by a case-insensitive substring match against each row's .roster-name text.
export function makeRosterSearchFilter(containerId) {
    let query = '';
    function apply() {
        const container = document.getElementById(containerId);
        if (!container) return;
        container.querySelectorAll('.roster-row').forEach(row => {
            const name = (row.querySelector('.roster-name')?.textContent || '').toLowerCase();
            row.style.display = !query || name.includes(query) ? '' : 'none';
        });
    }
    return {
        apply,
        onInput(value) {
            query = value.toLowerCase().trim();
            apply();
        },
        clear(inputId) {
            const input = document.getElementById(inputId);
            if (input) input.value = '';
            query = '';
            apply();
        },
    };
}

// The .expanded class is what CSS reads and aria-expanded is what screen readers
// read, so both are set in one place to stop them drifting apart.
function setAccordionExpanded(accordion, expanded) {
    accordion.classList.toggle('expanded', expanded);
    accordion.querySelector('.accordion-header')?.setAttribute('aria-expanded', expanded ? 'true' : 'false');
    // .accordion-content is display:none while collapsed, so its .binding-lists could only be measured now that expanding makes them visible.
    if (expanded) {
        alignBindingLabelColumns('.panel-content[data-panel="advanced"]');
        updateHotkeyPlaceholders();
    }
}

export function toggleAccordionEl(header) {
    const accordion = header.parentElement;
    setAccordionExpanded(accordion, !accordion.classList.contains('expanded'));
}

export function syncAccordionHeaderName(nameFieldId, headerFieldId, fallbackPrefix, index) {
    const nameInput = document.getElementById(nameFieldId);
    const headerName = document.getElementById(headerFieldId);

    if (nameInput && headerName) {
        const newName = nameInput.value.trim();
        headerName.textContent = newName || `${fallbackPrefix} ${index + 1}`;
    }
}

export function scrollContentPanelToBottom() {
    const contentPanel = document.getElementById('content-panel');
    if (contentPanel) {
        setTimeout(() => {
            contentPanel.scrollTop = contentPanel.scrollHeight;
        }, 100);
    }
}

// Every character's fields stay mounted (just hidden) so hotkey-conflict detection, which scans all input.hotkey-input elements at once, keeps seeing every character.
export function selectMasterDetailRow(containerId, index) {
    document.querySelectorAll(`#${containerId} .roster-row`).forEach(row => {
        const isSelected = parseInt(row.dataset.index, 10) === index;
        row.classList.toggle('selected', isSelected);
        row.setAttribute('aria-selected', isSelected ? 'true' : 'false');
    });
    document.querySelectorAll(`#${containerId} .detail-panel`).forEach(panel => {
        const isActive = parseInt(panel.dataset.index, 10) === index;
        panel.classList.toggle('active', isActive);
        panel.classList.toggle('fade-in', isActive);
    });
}

export function confirmRemove(buttonId, removeCallback, confirmText = t('common.confirm')) {
    const btn = document.getElementById(buttonId);
    if (!btn) return;

    if (btn.classList.contains('confirm-delete')) {
        // Second click - revert to normal appearance, then perform the action
        btn.classList.remove('confirm-delete');
        btn.textContent = btn.dataset.originalText || btn.textContent;
        removeCallback();
    } else {
        // First click - set confirm state. Width is reserved ahead of time by
        // reserveConfirmButtonWidth(), so this swap itself never resizes the button.
        const originalText = btn.textContent;
        btn.classList.add('confirm-delete');
        btn.textContent = confirmText;
        btn.dataset.originalText = originalText;

        // Reset after 2 seconds if not clicked
        setTimeout(() => {
            if (btn && btn.classList.contains('confirm-delete')) {
                btn.classList.remove('confirm-delete');
                btn.textContent = btn.dataset.originalText || 'Remove';
            }
        }, 2000);
    }
}

// Buttons confirmRemove() swaps to a wider "Confirm" label are pre-sized to fit that label the
// instant they're created, so the very first click can't resize them - locking the width inside
// confirmRemove itself is one transition too late, since the button has already rendered and been
// seen at its narrower natural size by then. Measures an offscreen clone rather than the button
// itself, since these buttons are routinely created while their tab or detail panel is
// display:none (getBoundingClientRect would read zero) - a clone appended straight to <body>
// keeps the original's classes and font but sidesteps that hidden ancestor entirely.
const CONFIRM_BUTTON_SELECTOR = '[id$="_removeBtn"], #clearAllWindowPositionsBtn';

function reserveConfirmButtonWidth(btn) {
    if (!btn || btn.dataset.confirmWidthReserved) return;
    btn.dataset.confirmWidthReserved = '1';

    const clone = btn.cloneNode(true);
    clone.removeAttribute('id');
    clone.style.cssText = 'position:fixed; visibility:hidden; left:-9999px; top:-9999px;';
    document.body.appendChild(clone);
    const originalWidth = clone.getBoundingClientRect().width;
    clone.textContent = t('common.confirm');
    const confirmWidth = clone.getBoundingClientRect().width;
    document.body.removeChild(clone);

    btn.style.minWidth = `${Math.max(originalWidth, confirmWidth)}px`;
}

export function initConfirmButtonWidthReservation() {
    document.querySelectorAll(CONFIRM_BUTTON_SELECTOR).forEach(reserveConfirmButtonWidth);

    // Dynamic lists (characters, hotkey groups, window filters, ...) rebuild their rows via
    // innerHTML on every add/remove/re-render, so new buttons keep appearing after this first pass.
    new MutationObserver(mutations => {
        for (const mutation of mutations) {
            mutation.addedNodes.forEach(node => {
                if (node.nodeType !== Node.ELEMENT_NODE) return;
                if (node.matches?.(CONFIRM_BUTTON_SELECTOR)) reserveConfirmButtonWidth(node);
                node.querySelectorAll?.(CONFIRM_BUTTON_SELECTOR).forEach(reserveConfirmButtonWidth);
            });
        }
    }).observe(document.body, { childList: true, subtree: true });
}

// The title row sits outside .detail-form's grid, so no CSS rule can size its column to match the label rail below - or the other way around, if the header text (e.g. "Group Name") is the wider of the two. A paired binding row (see .binding-paired) also hangs its control back into the gutter by --binding-dir-offset, so its label needs that much extra room - same technique alignBindingLabelColumns uses for the Hotkeys tab. Every panel in the list shares one field set and header label, so the active one's measurements size all of them.
export function alignDetailPanelNameLabel(containerId) {
    const activePanel = document.querySelector(`#${containerId} .detail-panel.active`);
    if (!activePanel) return;

    const form = activePanel.querySelector('.detail-form');
    const nameLabel = activePanel.querySelector('.detail-panel-name-label');
    if (!form || !nameLabel) return;
    labelColumnRealignJobs.set(`detail:${containerId}`, () => alignDetailPanelNameLabel(containerId));

    // Skip silently while hidden instead of resetting - a late async populate landing after a tab switch shouldn't clobber a good width with an unmeasurable one.
    if (form.getClientRects().length === 0) return;

    // max-content/0 first, so each label reports its own text width rather than a stretched or stale one.
    form.style.gridTemplateColumns = 'max-content minmax(8.75rem, 1fr)';
    nameLabel.style.minWidth = '0';

    const dirOffset = remVarToPx('--binding-dir-offset');
    const fieldWidths = Array.from(form.querySelectorAll(':scope > .detail-field > label'))
        .map(label => label.getBoundingClientRect().width + (label.parentElement.classList.contains('binding-paired') ? dirOffset : 0));

    const widest = Math.max(nameLabel.getBoundingClientRect().width, ...fieldWidths);
    if (!widest) return;

    const widthPx = `${Math.ceil(widest)}px`;
    document.querySelectorAll(`#${containerId} .detail-form`).forEach(f => { f.style.gridTemplateColumns = `${widthPx} minmax(8.75rem, 1fr)`; });
    document.querySelectorAll(`#${containerId} .detail-panel-name-label`).forEach(label => { label.style.minWidth = widthPx; });
}
