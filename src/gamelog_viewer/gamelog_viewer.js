// Forwards console.error/warn to Zig's log.zig since this webview's devtools console is normally hidden.
function formatLogArgs(args) {
    return args.map((a) => {
        if (a instanceof Error) return a.stack || a.message;
        if (typeof a === 'object' && a !== null) {
            try { return JSON.stringify(a); } catch (_) { return String(a); }
        }
        return String(a);
    }).join(' ');
}

function sendClientLog(level, message) {
    if (typeof webui !== 'undefined') {
        webui.call('logClientMessage', level, message).catch(() => {});
    }
}

function logError(...args) {
    console.error(...args);
    sendClientLog('error', formatLogArgs(args));
}

function logWarn(...args) {
    console.warn(...args);
    sendClientLog('warn', formatLogArgs(args));
}

window.addEventListener('error', (event) => {
    const detail = event.error ? (event.error.stack || event.error.message) : event.message;
    logError('Uncaught error:', detail, `(${event.filename}:${event.lineno}:${event.colno})`);
});

window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason instanceof Error ? (event.reason.stack || event.reason.message) : event.reason;
    logError('Unhandled promise rejection:', reason);
});

let events = [];
let filter = 'all';
let excludeDroneTargets = false;

const log = document.getElementById('log'), search = document.getElementById('search'), empty = document.getElementById('empty'), visibleCount = document.getElementById('visibleCount');
const fileInput = document.getElementById('fileInput'), filtersEl = document.getElementById('filters'), excludeDroneTargetsEl = document.getElementById('excludeDroneTargets');
const characterSelect = document.getElementById('characterSelect'), loadStatus = document.getElementById('loadStatus');

function showStatus(message, type) {
    loadStatus.textContent = message;
    loadStatus.className = 'status-message show ' + (type || 'info');
}

function clearStatus() {
    loadStatus.className = 'status-message';
}

async function populateCharacters() {
    const previous = characterSelect.value;
    try {
        const result = await webui.call('listOpenCharacters');
        const names = JSON.parse(result);
        characterSelect.innerHTML = names.length
            ? names.map(name => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`).join('')
            : '<option value="">No clients detected</option>';
        if (names.includes(previous)) characterSelect.value = previous;
    } catch (error) {
        logError('Failed to list open EVE clients:', error);
        characterSelect.innerHTML = '<option value="">No clients detected</option>';
    }
}

async function loadCharacterGamelog() {
    const name = characterSelect.value;
    if (!name) {
        showStatus('Select a character first.', 'error');
        return;
    }
    clearStatus();
    try {
        const text = await webui.call('loadGamelogForCharacter', name);
        if (!text) {
            showStatus(`No gamelog file found for ${name}.`, 'error');
            return;
        }
        loadText(text, `${name} — gamelog.txt`);
    } catch (error) {
        logError('Failed to load gamelog for character:', name, error);
        showStatus(`Failed to load gamelog for ${name}.`, 'error');
    }
}

function decodeEntities(s) { const t = document.createElement('textarea'); t.innerHTML = s; return t.value }
function escapeHtml(s) { return s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])) }
function plainMessage(raw) {
    let s = raw.replace(/<br\s*\/?\s*>/gi, '\n');
    s = s.replace(/<\/?(?:color|font|b|a)\b[^>]*>/gi, '');
    return decodeEntities(s).replace(/\n{3,}/g, '\n\n').trim();
}

// Current EVE combat-drone families plus special combat/EWAR hybrids found in the 2026 SDE/EVE Ref data.
// Family matching intentionally catches Tech I/II, Navy, Integrated and Augmented variants.
const DRONE_FAMILIES = [
    'Acolyte', 'Hornet', 'Hobgoblin', 'Warrior',
    'Infiltrator', 'Vespa', 'Hammerhead', 'Valkyrie',
    'Praetor', 'Wasp', 'Ogre', 'Berserker',
    'Curator', 'Warden', 'Garde', 'Bouncer', 'Gecko'
];
const SPECIAL_COMBAT_DRONES = [
    'Inshore EC-300-I', 'Orbweaver SW-300-I', 'Skimmer TP-300-I', 'Stellate TD-300-I', 'Stigmella SD-300-I', 'Tick EV-300-I',
    "'Subverted' JVN-UC49", 'Subverted JVN-UC49', 'Aralez', 'Darter TP-600-I', 'Huntsman SW-600-I', 'Immaculate TD-600-I', 'Luna SD-600-I', 'Mosquito EV-600-I', 'Nertic EC-600-I',
    'Arabellata SW-900-I', 'Atlas SD-900-I', 'Humboldt EC-900-I', 'Meganeura TP-900-I', 'Tabanida EV-900-I', 'Torafugu TD-900-I'
];
const SPECIAL_COMBAT_DRONE_SET = new Set(SPECIAL_COMBAT_DRONES.map(x => x.toLowerCase()));
function cleanWeaponName(name) { return (name || '').replace(/^Your\s+/i, '').replace(/\s*\*+\s*$/, '').trim() }
function isCombatDroneName(name) {
    const clean = cleanWeaponName(name), lower = clean.toLowerCase();
    if (!clean) return false;
    if (SPECIAL_COMBAT_DRONE_SET.has(lower)) return true;
    if (/\b(?:light|medium|heavy|sentry) mutated drone\b/i.test(clean)) return true;
    if (/\b(?:EC|SW|TP|TD|SD|EV)-(?:300|600|900)(?:-I)?\b/i.test(clean)) return true;
    return DRONE_FAMILIES.some(base => new RegExp(`\\b${base}\\b`, 'i').test(clean));
}
function extractDroneTypeFromTarget(target) {
    const t = (target || '').trim(); if (!t) return '';
    // Current combat lines commonly put the target hull/object type in parentheses, e.g. Pilot[CORP](Moros).
    // When that parenthesized object is a drone, this is the strongest signal and avoids character-name false positives.
    const paren = [...t.matchAll(/\(([^()]*)\)/g)].map(m => m[1].trim()).reverse();
    for (const p of paren) if (isCombatDroneName(p)) return p;
    const lower = t.toLowerCase();
    for (const special of SPECIAL_COMBAT_DRONES) { if (lower.includes(special.toLowerCase())) return special }
    const mutated = t.match(/\b(?:light|medium|heavy|sentry) mutated drone\b/i); if (mutated) return mutated[0];
    const hybrid = t.match(/\b(?:EC|SW|TP|TD|SD|EV)-(?:300|600|900)(?:-I)?\b/i); if (hybrid) return hybrid[0];
    // Direct drone-object labels (including faction / Integrated / Augmented variants). Require either a recognized
    // variant prefix, an I/II suffix, or the descriptor to be just the drone family to avoid names like "Warrior Poet".
    const families = DRONE_FAMILIES.map(x => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|');
    const re = new RegExp(`(?:^|\\b)((?:(?:Imperial Navy|Caldari Navy|Federation Navy|Republic Fleet|'Augmented'|'Integrated')\\s+)?(?:${families})(?:\\s+(?:I|II))?)(?=\\b|$)`, 'i');
    const m = t.match(re);
    if (m) {
        const candidate = m[1].trim();
        if (/(?:Navy|'Augmented'|'Integrated')/i.test(candidate) || /\s(?:I|II)$/i.test(candidate) || candidate.toLowerCase() === 'gecko' || t.toLowerCase() === candidate.toLowerCase()) return candidate;
    }
    return '';
}
function analyzeDamage(e) {
    if (!e || e.type !== 'combat') return null;
    const m = e.message.match(/^(\d[\d,]*)\s+(to|from)\b/i); if (!m) return null;
    const direction = m[2].toLowerCase();
    const parts = e.message.split(/\s+-\s+/);
    const weapon = cleanWeaponName(parts.length >= 3 ? parts[parts.length - 2] : '');
    let target = '', targetDroneName = '';
    if (direction === 'to') {
        const tm = e.message.match(/^\d[\d,]*\s+to\s+(.+?)(?=\s+-\s+)/i);
        target = tm ? tm[1].trim() : '';
        targetDroneName = extractDroneTypeFromTarget(target);
    }
    const sourceIsDrone = isCombatDroneName(weapon);
    return { amount: Number(m[1].replace(/,/g, '')), direction, weapon, target, isDrone: sourceIsDrone, droneName: sourceIsDrone ? weapon : '', targetIsDrone: !!targetDroneName, targetDroneName };
}

function parseLog(text) {
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
    const lines = text.replace(/\r/g, '').split('\n');
    let listener = 'Unknown pilot', session = 'Unknown session', current = null;
    const parsed = [];
    for (const line of lines) {
        let m = line.match(/^\s*Listener:\s*(.+?)\s*$/i); if (m) { listener = m[1]; continue }
        m = line.match(/^\s*Session Started:\s*(.+?)\s*$/i); if (m) { session = m[1]; continue }
        m = line.match(/^\[\s*(\d{4}\.\d{2}\.\d{2}\s+\d{2}:\d{2}:\d{2})\s*\]\s*\(([^)]+)\)\s*(.*)$/);
        if (m) {
            if (current) parsed.push(current);
            current = { ts: m[1], time: m[1].slice(-8), type: m[2].trim().toLowerCase(), sourceType: m[2].trim(), raw: m[3] };
        } else if (current && line.trim() && !/^[-]{5,}$/.test(line.trim())) {
            current.raw += '\n' + line.trim();
        }
    }
    if (current) parsed.push(current);
    parsed.forEach(e => { e.message = plainMessage(e.raw); e.damage = analyzeDamage(e) });
    return { listener, session, events: parsed };
}
function formatMessage(e) {
    let text = e.message;
    let html = escapeHtml(text).replace(/\n/g, '<br>');
    if (e.type === 'combat') {
        const out = text.match(/^(\d[\d,]*)\s+to\b/i), incoming = text.match(/^(\d[\d,]*)\s+from\b/i);
        if (out) html = html.replace(escapeHtml(out[1]), `<strong class="damage-out">${escapeHtml(out[1])}</strong>`);
        else if (incoming) html = html.replace(escapeHtml(incoming[1]), `<strong class="damage-in">${escapeHtml(incoming[1])}</strong>`);
        else if (/^Warp (?:scramble|disruption) attempt/i.test(text)) html = html.replace(/^(Warp (?:scramble|disruption) attempt)/i, '<strong class="tackle">$1</strong>');
    }
    if (e.type === 'bounty') html = html.replace(/([\d,]+\s+ISK)/i, '<strong class="isk">$1</strong>');
    if (e.damage && e.damage.isDrone && e.damage.weapon) { const w = escapeHtml(e.damage.weapon); html = html.replace(w, `<span class="drone-name">${w}</span>`) }
    if (e.damage && e.damage.targetIsDrone && e.damage.targetDroneName) { const t = escapeHtml(e.damage.targetDroneName); html = html.replace(t, `<span class="drone-target-name">${t}</span>`) }
    html = html.replace(/\b(from|to)\b/gi, '<span class="connector">$1</span>');
    html = html.replace(/CONCORD/g, '<span class="concord">CONCORD</span>');
    return html;
}
function render() {
    log.innerHTML = ''; const frag = document.createDocumentFragment();
    events.forEach(e => { const isDrone = !!(e.damage && e.damage.isDrone), targetIsDrone = !!(e.damage && e.damage.targetIsDrone); const row = document.createElement('div'); row.className = `row ${e.type}${isDrone ? ' drone-hit' : ''}${targetIsDrone ? ' drone-target-hit' : ''}`; row.dataset.type = e.type; row.dataset.drone = isDrone ? '1' : '0'; row.dataset.droneTarget = targetIsDrone ? '1' : '0'; row.dataset.search = (e.ts + ' ' + e.sourceType + ' ' + e.message).toLowerCase(); const kind = targetIsDrone ? 'to drone' : (isDrone ? 'drone' : e.sourceType); row.innerHTML = `<div class="time">${escapeHtml(e.time)}</div><div class="kind">${escapeHtml(kind)}</div><div class="msg">${formatMessage(e)}</div>`; frag.appendChild(row) });
    log.appendChild(frag); apply();
}
function labelForType(type) { return ({ combat: 'Combat', notify: 'Notify', bounty: 'Bounty', question: 'Fleet prompt', hint: 'Hints' })[type] || type.charAt(0).toUpperCase() + type.slice(1) }
function rebuildFilters() {
    const counts = {}; events.forEach(e => counts[e.type] = (counts[e.type] || 0) + 1);
    const preferred = ['combat', 'notify', 'bounty', 'question', 'hint'];
    const types = Object.keys(counts).sort((a, b) => { const ai = preferred.indexOf(a), bi = preferred.indexOf(b); if (ai < 0 && bi < 0) return a.localeCompare(b); if (ai < 0) return 1; if (bi < 0) return -1; return ai - bi });
    filtersEl.innerHTML = '';
    const add = (type, label, count) => { const b = document.createElement('button'); b.className = 'filter' + (type === filter ? ' active' : ''); b.dataset.filter = type; b.innerHTML = `<span class="dot"></span>${escapeHtml(label)} <span class="count">${count}</span>`; b.addEventListener('click', () => { filter = type; [...filtersEl.children].forEach(x => x.classList.toggle('active', x === b)); apply() }); filtersEl.appendChild(b) };
    add('all', 'All events', events.length); const droneEvents = events.filter(e => e.damage && e.damage.isDrone).length; if (droneEvents) add('drone', 'Damage from drones', droneEvents); const droneTargetEvents = events.filter(e => e.damage && e.damage.targetIsDrone).length; if (droneTargetEvents) add('drone-target', 'Damage to drones', droneTargetEvents); types.forEach(t => add(t, labelForType(t), counts[t]));
}
function parseLocalTimestamp(ts) { const m = ts.match(/^(\d{4})\.(\d{2})\.(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/); return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : null }
function formatSpan(ms) { let s = Math.max(0, Math.round(ms / 1000)); const h = Math.floor(s / 3600); s %= 3600; const m = Math.floor(s / 60); s %= 60; return h ? `${h}h ${m}m ${s}s` : m ? `${m}m ${s}s` : `${s}s` }
function renderDroneBreakdown(byDrone, totalDroneOut) {
    const el = document.getElementById('droneBreakdown');
    const rows = Object.values(byDrone).sort((a, b) => b.damage - a.damage);
    if (!rows.length) { el.innerHTML = '<div class="damage-empty">No outgoing drone damage detected.</div>'; return }
    el.innerHTML = '<div class="drone-heading">Outgoing by drone type</div>' + rows.map(d => { const pct = totalDroneOut ? ((d.damage / totalDroneOut) * 100).toFixed(1) : '0.0'; return `<div class="drone-item"><div class="name" title="${escapeHtml(d.name)}">${escapeHtml(d.name)}</div><div class="amount">${d.damage.toLocaleString()}</div><div class="meta">${d.hits.toLocaleString()} hit${d.hits === 1 ? '' : 's'} · ${pct}% of drone damage</div></div>` }).join('');
}
function updateStats() {
    let out = 0, inc = 0, shipOut = 0, droneOut = 0, droneIn = 0, damageToDrones = 0; const byDrone = {};
    events.forEach(e => {
        const d = e.damage || analyzeDamage(e); if (!d) return;
        if (d.direction === 'to') {
            if (d.targetIsDrone) damageToDrones += d.amount;
            if (excludeDroneTargets && d.targetIsDrone) return;
            out += d.amount;
            if (d.isDrone) {
                droneOut += d.amount; const key = (d.droneName || d.weapon || 'Unknown drone').toLowerCase();
                if (!byDrone[key]) byDrone[key] = { name: d.droneName || d.weapon || 'Unknown drone', damage: 0, hits: 0 };
                byDrone[key].damage += d.amount; byDrone[key].hits++;
            } else shipOut += d.amount;
        } else {
            inc += d.amount; if (d.isDrone) droneIn += d.amount;
        }
    });
    document.getElementById('damageOut').textContent = out.toLocaleString(); document.getElementById('damageIn').textContent = inc.toLocaleString(); document.getElementById('eventCount').textContent = events.length.toLocaleString();
    document.getElementById('shipDamageOut').textContent = shipOut.toLocaleString(); document.getElementById('droneDamageOut').textContent = droneOut.toLocaleString(); document.getElementById('droneDamageIn').textContent = droneIn.toLocaleString(); document.getElementById('damageToDrones').textContent = damageToDrones.toLocaleString(); renderDroneBreakdown(byDrone, droneOut);
    let span = '0s'; if (events.length > 1) { const a = parseLocalTimestamp(events[0].ts), b = parseLocalTimestamp(events[events.length - 1].ts); if (a && b) span = formatSpan(b - a) } document.getElementById('logSpan').textContent = span;
}
function loadText(text, name) {
    const data = parseLog(text); events = data.events; filter = 'all'; search.value = '';
    document.getElementById('listener').textContent = data.listener; document.getElementById('sessionTime').textContent = data.session; document.getElementById('filename').textContent = name || 'Loaded log'; document.title = `EVE Gamelog — ${data.listener}`;
    rebuildFilters(); updateStats(); render(); document.getElementById('logWrap').scrollTop = 0;
}
function apply() {
    const q = search.value.trim().toLowerCase(); let shown = 0; [...log.children].forEach(row => { const okType = filter === 'all' || (filter === 'drone' ? row.dataset.drone === '1' : filter === 'drone-target' ? row.dataset.droneTarget === '1' : row.dataset.type === filter), okSearch = !q || row.dataset.search.includes(q), okDroneTarget = !(excludeDroneTargets && row.dataset.droneTarget === '1'), show = okType && okSearch && okDroneTarget; row.classList.toggle('hidden', !show); if (show) shown++ }); visibleCount.textContent = events.length ? `${shown} / ${events.length} visible` : ''; empty.classList.toggle('show', shown === 0);
}
async function openFile(file) { if (!file) return; try { const text = await file.text(); loadText(text, file.name); clearStatus(); } catch (err) { logError('Failed to read dropped/opened gamelog file:', err); showStatus('Unable to read that file. Please choose a plain-text EVE gamelog.', 'error'); } }

document.getElementById('openFileBtn').addEventListener('click', () => fileInput.click());
fileInput.addEventListener('change', () => { openFile(fileInput.files[0]); fileInput.value = ''; });
document.getElementById('loadCharacterBtn').addEventListener('click', loadCharacterGamelog);
document.getElementById('refreshCharactersBtn').addEventListener('click', populateCharacters);
excludeDroneTargetsEl.addEventListener('change', () => { excludeDroneTargets = excludeDroneTargetsEl.checked; updateStats(); apply() });
search.addEventListener('input', apply);
document.getElementById('resetBtn').addEventListener('click', () => { search.value = ''; filter = 'all'; excludeDroneTargets = false; excludeDroneTargetsEl.checked = false; [...filtersEl.children].forEach(b => b.classList.toggle('active', b.dataset.filter === 'all')); updateStats(); apply() });
document.getElementById('copyBtn').addEventListener('click', async () => { const rows = [...log.children].filter(r => !r.classList.contains('hidden')); const text = rows.map(r => `[ ${r.querySelector('.time').textContent} ] (${r.querySelector('.kind').textContent}) ${r.querySelector('.msg').innerText}`).join('\n'); try { await navigator.clipboard.writeText(text); const b = document.getElementById('copyBtn'), old = b.textContent; b.textContent = 'Copied'; setTimeout(() => b.textContent = old, 900) } catch (e) { logWarn('Clipboard write failed:', e) } });

const main = document.getElementById('main'), dropOverlay = document.getElementById('dropOverlay'); let dragDepth = 0;
['dragenter', 'dragover'].forEach(type => main.addEventListener(type, e => { e.preventDefault(); dragDepth++; dropOverlay.classList.add('show') }));
main.addEventListener('dragleave', e => { e.preventDefault(); dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) dropOverlay.classList.remove('show') });
main.addEventListener('drop', e => { e.preventDefault(); dragDepth = 0; dropOverlay.classList.remove('show'); openFile(e.dataTransfer.files && e.dataTransfer.files[0]) });

populateCharacters();
apply();
