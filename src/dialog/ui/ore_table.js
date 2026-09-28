// The ore price table and fetching Jita prices.
import { app } from './state.js';
import { markAsChanged } from './changes.js';
import { escapeHtml, logError, rpc } from './core.js';
import { applySchemaToInputs } from './binding.js';
import { t } from './i18n.js';
import { showStatus } from './layout.js';

const ORE_CATEGORIES = ['Ore', 'Ice', 'Moons', 'Gas'];

function oreCategoryRank(category) {
    const i = ORE_CATEGORIES.indexOf(category);
    return i === -1 ? ORE_CATEGORIES.length : i;
}

// Price is the only user-editable field shown - name, category, and m3/unit are still tracked internally (see OreEntry in config.zig) and fixed, but category still drives the grouped/sorted display below (same rowspan'd-label + separator-border technique as the Event Alerts table's populateNotificationTypes).
// Name is deliberately not editable: chatlog.zig matches mined-ore log lines against this exact string, so renaming a row would silently break that ore's lookup.
export function populateOreTable() {
    const tbody = document.getElementById('oreTableBody');
    if (!tbody) return;

    const entries = app.oreCatalog.map(entry => ({ ...entry, price: orePrice(entry) }));

    const displayOrder = entries.map((entry, index) => ({ entry, index }));
    displayOrder.sort((a, b) => {
        const rankDiff = oreCategoryRank(a.entry.category) - oreCategoryRank(b.entry.category);
        return rankDiff !== 0 ? rankDiff : a.index - b.index;
    });

    const categoryRowCounts = {};
    displayOrder.forEach(({ entry }) => {
        const category = entry.category || 'Ore';
        categoryRowCounts[category] = (categoryRowCounts[category] || 0) + 1;
    });

    tbody.innerHTML = '';
    let lastCategory = null;
    displayOrder.forEach(({ entry, index }) => {
        const category = entry.category || 'Ore';
        const isFirstInCategory = category !== lastCategory;
        const isFirstCategoryOverall = lastCategory === null;
        lastCategory = category;

        const row = document.createElement('tr');
        if (isFirstInCategory && !isFirstCategoryOverall) row.className = 'category-separator';

        row.innerHTML = `
            ${isFirstInCategory ? `<td rowspan="${categoryRowCounts[category]}" class="category-cell"><span class="category-cell-label">${escapeHtml(category)}</span></td>` : ''}
            <td class="event-name-cell">${escapeHtml(entry.name || '')}</td>
            <td><input type="number" class="ore-price-input" id="ore_${index}_price" value="${entry.price ?? 0}" data-range="global.oreTable.*.price" step="0.01"></td>
        `;
        tbody.appendChild(row);
    });
    applySchemaToInputs(tbody);
}

// The global settings only hold the prices that differ from the catalog's.
function orePrice(entry) {
    const override = app.currentGlobalSettings?.oreTable?.find(o => o.name === entry.name);
    return override ? override.price : entry.price;
}

// Keeps existing overrides in their saved order, so reading back an untouched table changes nothing.
export function saveOreTable() {
    const settings = app.currentGlobalSettings;
    if (!settings?.oreTable || !document.getElementById('oreTableBody')?.children.length) return;

    const prices = new Map();
    app.oreCatalog.forEach((entry, index) => {
        const field = document.getElementById(`ore_${index}_price`);
        if (field) prices.set(entry.name, parseFloat(field.value) || 0);
    });
    const table = settings.oreTable.map(o => prices.has(o.name) ? { ...o, price: prices.get(o.name) } : o);
    for (const entry of app.oreCatalog) {
        const price = prices.get(entry.name);
        if (price !== undefined && price !== entry.price && !table.some(o => o.name === entry.name)) table.push({ name: entry.name, price });
    }
    settings.oreTable = table;
}

let isFetchingOrePrices = false;

// Looks up each row's Jita buy price via ESI (public, no key needed) - see dialog/tools/esi_prices.zig for the actual request.
export async function fetchOrePrices() {
    if (isFetchingOrePrices) return;
    const names = app.oreCatalog.map(e => e.name).filter(n => n);
    if (names.length === 0) return;

    isFetchingOrePrices = true;
    const btn = document.getElementById('fetchOrePricesBtn');
    if (btn) btn.disabled = true;
    showStatus(t('status.fetchingOrePrices').replace('{n}', names.length), 'info');

    try {
        const prices = await rpc('fetchOrePrices', { names });

        let updated = 0;
        app.oreCatalog.forEach((entry, index) => {
            const field = document.getElementById(`ore_${index}_price`);
            if (field && Object.prototype.hasOwnProperty.call(prices, entry.name)) {
                field.value = prices[entry.name];
                updated++;
            }
        });

        markAsChanged();
        showStatus(t('status.orePricesUpdated').replace('{updated}', updated).replace('{total}', names.length), updated > 0 ? 'success' : 'error');
    } catch (error) {
        logError('Failed to fetch ore prices:', error);
        showStatus(t('status.orePricesFetchFailed'), 'error');
    } finally {
        isFetchingOrePrices = false;
        if (btn) btn.disabled = false;
    }
}
