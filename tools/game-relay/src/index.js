// Gathers up to six anonymous players on a join code and relays their messages; nothing is kept once a match ends.
import { DurableObject } from "cloudflare:workers";

// Must match CODE_ALPHABET in src/multiplayer/wire.zig.
const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 6;
const CODE_PATTERN = /^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{6}$/;
const UNSTARTED_EXPIRY_MS = 10 * 60 * 1000;
// Must match MAX_SEATS in src/multiplayer/wire.zig; the host is seat 0.
const MAX_SEATS = 6;
// Must match MAX_MESSAGE_BYTES in src/multiplayer/wire.zig; anything bigger is dropped, and what's passed on gains a seat byte.
const MAX_MESSAGE_BYTES = 64;
const MAX_MESSAGES_PER_SECOND = 60;
const HOST_ATTEMPTS = 5;

export default {
  async fetch(request, env) {
    if (request.headers.get("Upgrade") !== "websocket") return new Response("Expected a WebSocket", { status: 426 });
    const url = new URL(request.url);
    const version = url.searchParams.get("v") ?? "";
    // Held only for the limiter's window; never logged or stored.
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";

    if (url.pathname === "/host") {
      if (!(await env.LIMITER.limit({ key: `host:${ip}` })).success) return refuse("rate_limited");
      for (let attempt = 0; attempt < HOST_ATTEMPTS; attempt++) {
        const code = randomCode();
        const response = await room(env, code).fetch(roomRequest(request, "host", code, version));
        // 409: that code is in use, so try another.
        if (response.status !== 409) return response;
      }
      return refuse("unknown");
    }

    const join = url.pathname.match(/^\/join\/([^/]+)$/);
    if (join) {
      if (!(await env.LIMITER.limit({ key: `join:${ip}` })).success) return refuse("rate_limited");
      const code = join[1].toUpperCase();
      if (!CODE_PATTERN.test(code)) return refuse("not_found");
      return room(env, code).fetch(roomRequest(request, "guest", code, version));
    }
    return new Response("Not found", { status: 404 });
  },
};

// One match: the host's lobby on its code, then up to MAX_SEATS players once the host locks it.
export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    // Per socket: [window start ms, messages in it]; lost on hibernation, which is harmless.
    this.rates = new Map();
  }

  async fetch(request) {
    const url = new URL(request.url);
    const role = url.pathname.slice(1);
    const version = url.searchParams.get("v");
    const sockets = this.ctx.getWebSockets();

    if (role === "host") {
      if (sockets.length > 0) return new Response(null, { status: 409 });
      const [client, socket] = this.accept("host", version, 0);
      socket.send(JSON.stringify({ type: "code", code: url.searchParams.get("code") }));
      await this.ctx.storage.setAlarm(Date.now() + UNSTARTED_EXPIRY_MS);
      return new Response(null, { status: 101, webSocket: client });
    }

    const host = this.ctx.getWebSockets("host")[0];
    if (!host) return refuse("not_found");
    if (host.deserializeAttachment().version !== version) return refuse("version");
    if (await this.ctx.storage.get("locked")) return refuse("started");
    const taken = new Set(sockets.map((socket) => socket.deserializeAttachment().seat));
    let seat = 1;
    while (seat < MAX_SEATS && taken.has(seat)) seat++;
    if (seat === MAX_SEATS) return refuse("full");
    const [client, guest] = this.accept("guest", version, seat);
    guest.send(JSON.stringify({ type: "welcome", seat }));
    for (const socket of sockets) trySend(socket, JSON.stringify({ type: "joined", seat }));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket, message) {
    if (typeof message === "string") {
      await this.control(socket, message);
      return;
    }
    if (message.byteLength > MAX_MESSAGE_BYTES) return;
    if (this.isFlooding(socket)) {
      await this.leave(socket);
      return;
    }
    const others = this.ctx.getWebSockets().filter((other) => other !== socket);
    // A keepalive while no one else is in, answered so the sender's receive doesn't time out.
    if (others.length === 0) {
      socket.send(JSON.stringify({ type: "waiting" }));
      return;
    }
    const framed = new Uint8Array(message.byteLength + 1);
    framed[0] = socket.deserializeAttachment().seat;
    framed.set(new Uint8Array(message), 1);
    for (const other of others) trySend(other, framed);
  }

  async webSocketClose(socket) {
    await this.leave(socket);
  }

  async webSocketError(socket) {
    await this.leave(socket);
  }

  async alarm() {
    if (await this.ctx.storage.get("locked")) return;
    for (const socket of this.ctx.getWebSockets()) {
      trySend(socket, JSON.stringify({ type: "refused", reason: "expired" }));
      tryClose(socket, "expired");
    }
    await this.ctx.storage.deleteAll();
  }

  accept(role, version, seat) {
    const [client, socket] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(socket, [role]);
    socket.serializeAttachment({ version, seat });
    return [client, socket];
  }

  // Only the host's {"type":"lock"}, which starts the match and turns later joiners away.
  async control(socket, text) {
    if (this.ctx.getTags(socket)[0] !== "host") return;
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      return;
    }
    if (parsed?.type !== "lock") return;
    await this.ctx.storage.put("locked", true);
    await this.ctx.storage.deleteAlarm();
  }

  isFlooding(socket) {
    const now = Date.now();
    const rate = this.rates.get(socket);
    if (!rate || now - rate[0] >= 1000) {
      this.rates.set(socket, [now, 1]);
      return false;
    }
    rate[1] += 1;
    return rate[1] > MAX_MESSAGES_PER_SECOND;
  }

  // The host leaving ends the room for everyone, so a code is never reused; a guest leaving only frees its seat.
  async leave(leaving) {
    const seat = leaving.deserializeAttachment().seat;
    this.rates.delete(leaving);
    tryClose(leaving, "left");
    const rest = this.ctx.getWebSockets().filter((socket) => socket !== leaving);
    if (seat !== 0) {
      for (const socket of rest) trySend(socket, JSON.stringify({ type: "left", seat }));
      return;
    }
    for (const socket of rest) {
      trySend(socket, JSON.stringify({ type: "host_left" }));
      tryClose(socket, "ended");
      this.rates.delete(socket);
    }
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }
}

function room(env, code) {
  return env.ROOMS.get(env.ROOMS.idFromName(code));
}

function roomRequest(request, role, code, version) {
  const url = `https://room/${role}?code=${code}&v=${encodeURIComponent(version)}`;
  return new Request(url, request);
}

function randomCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
  // 256 isn't a multiple of 31, so this leans very slightly toward early letters; fine for a join code.
  return Array.from(bytes, (byte) => ALPHABET[byte % ALPHABET.length]).join("");
}

// Accepts the WebSocket only to say why, then closes it, so the client reads one kind of answer.
function refuse(reason) {
  const [client, socket] = Object.values(new WebSocketPair());
  socket.accept();
  socket.send(JSON.stringify({ type: "refused", reason }));
  socket.close(1000, reason);
  return new Response(null, { status: 101, webSocket: client });
}

function trySend(socket, text) {
  try {
    socket.send(text);
  } catch {
    // Already closed.
  }
}

function tryClose(socket, reason) {
  try {
    socket.close(1000, reason);
  } catch {
    // Already closed.
  }
}
