// The backend bridge (rpc, app events), logging forwarded to eve-maj.log, and small shared helpers.
import { app } from './state.js';

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

// The backend's one entry point (dialog/rpc.zig): resolves with the call's data, or rejects with an Error whose `code` is the Zig error name.
export async function rpc(method, args = {}) {
    const reply = JSON.parse(await webui.call('rpc', method, JSON.stringify(args)));
    if (reply.ok) return reply.data;
    const error = new Error(reply.error.message);
    error.code = reply.error.code;
    throw error;
}

// Pushed by dialog/events.zig as window.onAppEvent(name, payload).
const appEventHandlers = {};
export function listenForAppEvent(name, handler) {
    (appEventHandlers[name] ||= []).push(handler);
}
window.onAppEvent = (name, payload) => {
    for (const handler of appEventHandlers[name] || []) {
        try {
            handler(payload);
        } catch (error) {
            logError(`Handler for app event ${name} failed:`, error);
        }
    }
};

function sendClientLog(level, message) {
    if (typeof webui !== 'undefined') {
        rpc('logClientMessage', { level, message }).catch(() => {});
    }
}

export function logError(...args) {
    console.error(...args);
    sendClientLog('error', formatLogArgs(args));
}

export function logWarn(...args) {
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

export async function waitForWebUI() {
    let attempts = 0;
    const maxAttempts = 50;

    while (attempts < maxAttempts) {
        if (typeof webui !== 'undefined' && webui.call) {
            try {
                await rpc('getAppVersion');
                app.webuiReady = true;
                return true;
            } catch (error) {
                // Not ready yet; retry below.
            }
        }
        await new Promise(resolve => setTimeout(resolve, 100));
        attempts++;
    }
    
    logError('WebUI failed to initialize after', maxAttempts * 100, 'ms');
    return false;
}

export function escapeHtml(str) {
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}
