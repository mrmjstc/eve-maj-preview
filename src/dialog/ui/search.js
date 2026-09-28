// Settings search.
import { t } from './i18n.js';
import { switchTab } from './layout.js';

export let searchState = {
    currentQuery: '',
    matchedElements: [],
    highlightedTab: null,
    initiallyHiddenTabs: []
};

// filterSettings() rescans every panel/section/label in the document, so it's debounced here; clearing the box runs immediately since there's no scan cost to an empty query.
let searchDebounceTimer = null;

export function onSearchInput(query) {
    if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
    if (!query) {
        filterSettings(query);
        return;
    }
    searchDebounceTimer = setTimeout(() => filterSettings(query), 150);
}

function filterSettings(query) {
    searchState.currentQuery = query.toLowerCase().trim();
    
    if (!searchState.currentQuery) {
        document.querySelectorAll('.section').forEach(el => {
            el.style.display = '';
        });
        document.querySelectorAll('.tab-item').forEach(el => {
            const tabId = el.getAttribute('data-tab');
            if (!searchState.initiallyHiddenTabs.includes(tabId)) {
                el.style.display = '';
            }
        });
        updateSearchCount(0, 0);
        searchState.matchedElements = [];
        return;
    }
    
    const matches = [];

    document.querySelectorAll('.panel-content').forEach(panel => {
        const panelTab = panel.getAttribute('data-panel');

        if (searchState.initiallyHiddenTabs.includes(panelTab)) {
            return;
        }

        // Skip whole tabs gated behind Advanced Mode (like General) while it's off
        if (panel.classList.contains('advanced-tab-panel') && !document.body.classList.contains('advanced-mode')) {
            return;
        }

        const tab = document.querySelector(`.tab-item[data-tab="${panelTab}"]`);
        const sections = panel.querySelectorAll('.section');
        let panelHasMatches = false;
        
        sections.forEach(section => {
            // Advanced-only sections stay hidden while Advanced Mode is off, even if their contents would otherwise match.
            if (section.classList.contains('advanced-section') && !document.body.classList.contains('advanced-mode')) {
                section.style.display = 'none';
                return;
            }

            const sectionText = section.textContent.toLowerCase();
            const labels = section.querySelectorAll('label, h3, h4, p.hint, .accordion-name');
            const inputs = section.querySelectorAll('input[id], select[id], textarea[id]');

            let sectionHasMatches = false;

            const heading = section.querySelector('h3');
            if (heading && heading.textContent.toLowerCase().includes(searchState.currentQuery)) {
                sectionHasMatches = true;
            }

            labels.forEach(label => {
                const text = label.textContent.toLowerCase();
                if (text.includes(searchState.currentQuery)) {
                    sectionHasMatches = true;
                }
            });

            inputs.forEach(input => {
                const id = input.id.toLowerCase();
                const value = (input.value || '').toLowerCase();
                const placeholder = (input.placeholder || '').toLowerCase();
                
                if (id.includes(searchState.currentQuery) || 
                    value.includes(searchState.currentQuery) || 
                    placeholder.includes(searchState.currentQuery)) {
                    sectionHasMatches = true;
                }
            });

            if (sectionHasMatches) {
                section.style.display = '';
                matches.push({ panel: panelTab, section: section });
                panelHasMatches = true;
            } else {
                section.style.display = 'none';
            }
        });
        
        // Show/hide tabs based on matches (but never show initially hidden tabs)
        if (tab) {
            if (panelHasMatches) {
                tab.style.display = '';
            } else {
                tab.style.display = 'none';
            }
        }
    });
    
    searchState.matchedElements = matches;
    updateSearchCount(matches.length, matches.length);

    // Auto-switch to first tab with results if current tab has no matches
    const activePanel = document.querySelector('.panel-content.active');
    const activePanelHasMatches = activePanel && activePanel.querySelector('.section:not([style*="display: none"])');

    if (!activePanelHasMatches && matches.length > 0) {
        switchTab(matches[0].panel);
    }
}

function updateSearchCount(sections, elements) {
    const countEl = document.getElementById('search-results-count');
    if (!countEl) return;
    
    if (sections === 0 && !searchState.currentQuery) {
        countEl.textContent = '';
        countEl.classList.remove('search-count-none', 'search-count-some');
    } else if (sections === 0) {
        countEl.textContent = t('status.noMatches');
        countEl.classList.add('search-count-none');
        countEl.classList.remove('search-count-some');
    } else {
        countEl.textContent = `${sections} ${sections !== 1 ? t('status.sectionPlural') : t('status.sectionSingular')}`;
        countEl.classList.add('search-count-some');
        countEl.classList.remove('search-count-none');
    }
}

export function clearSearch() {
    const searchInput = document.getElementById('search-filter');
    if (searchInput) {
        searchInput.value = '';
        filterSettings('');
        searchInput.focus();
    }
}
