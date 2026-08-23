#!/usr/bin/env node
// annotate-ui — a standalone, framework-agnostic reverse proxy that injects a
// point-and-click annotation overlay into any running web dev build and streams
// annotations back to a coding agent via a long-poll CLI.
//
// Runtime: Node >= 18 built-ins ONLY (no npm dependencies).
// Commands: detect | serve | poll | stop

import http from "node:http";
import https from "node:https";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, execFile } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Constants & shared helpers
// ---------------------------------------------------------------------------

export const DEFAULT_PORT = 6100;
export const PREFIX = "/__annotate/";
const PORT_PROBE_LIMIT = 20; // how far the default port auto-heals upward
const OVERLAY_FILE = path.join(__dirname, "overlay.js");

const COMMON_DEV_PORTS = [
  3000, 3001, 5173, 5174, 4200, 8080, 8000, 1234, 4321, 5000, 3333, 9000,
];

function stateDir() {
  return process.env.ANNOTATE_STATE_DIR || path.join(os.homedir(), ".annotate");
}
function sessionPath() {
  return path.join(stateDir(), "session.json");
}

export function writeSession(session) {
  fs.mkdirSync(stateDir(), { recursive: true });
  fs.writeFileSync(sessionPath(), JSON.stringify(session, null, 2));
}
export function readSession() {
  try {
    return JSON.parse(fs.readFileSync(sessionPath(), "utf8"));
  } catch {
    return null;
  }
}
function clearSession() {
  try {
    fs.unlinkSync(sessionPath());
  } catch {
    /* ignore */
  }
}

// Minimal flag parser: --key value, --key=value, --flag (boolean).
export function parseFlags(argv) {
  const flags = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const eq = a.indexOf("=");
      if (eq !== -1) {
        flags[a.slice(2, eq)] = a.slice(eq + 1);
      } else {
        const key = a.slice(2);
        const next = argv[i + 1];
        if (next === undefined || next.startsWith("--")) {
          flags[key] = true;
        } else {
          flags[key] = next;
          i++;
        }
      }
    } else {
      positional.push(a);
    }
  }
  return { flags, positional };
}

// Port precedence: --port flag → ANNOTATE_PORT env → default. Returns
// { port, explicit } — explicit=true when the caller pinned a specific port.
export function resolvePort(flags, env = process.env) {
  if (flags.port !== undefined) {
    return { port: Number(flags.port), explicit: true };
  }
  if (env.ANNOTATE_PORT) {
    return { port: Number(env.ANNOTATE_PORT), explicit: true };
  }
  return { port: DEFAULT_PORT, explicit: false };
}

function isPortFree(port, host = "127.0.0.1") {
  return new Promise((resolve) => {
    const tester = net
      .createServer()
      .once("error", () => resolve(false))
      .once("listening", () => tester.close(() => resolve(true)))
      .listen(port, host);
  });
}

// Given the resolved { port, explicit }, return a usable port. A busy DEFAULT
// port auto-probes upward; a busy EXPLICIT port throws with a one-line remedy.
export async function pickPort({ port, explicit }, probeLimit = PORT_PROBE_LIMIT) {
  if (await isPortFree(port)) return port;
  if (explicit) {
    const err = new Error(
      `port ${port} in use — re-run with --port <free-port> (or unset ANNOTATE_PORT)`,
    );
    err.code = "EPORTINUSE";
    throw err;
  }
  for (let p = port + 1; p <= port + probeLimit; p++) {
    if (await isPortFree(p)) return p;
  }
  const err = new Error(
    `no free port between ${port} and ${port + probeLimit} — pass --port <free-port>`,
  );
  err.code = "EPORTINUSE";
  throw err;
}

function httpModuleFor(u) {
  return u.protocol === "https:" ? https : http;
}

function openBrowser(url) {
  const cmd =
    process.platform === "darwin"
      ? ["open", [url]]
      : process.platform === "win32"
        ? ["cmd", ["/c", "start", "", url]]
        : ["xdg-open", [url]];
  try {
    const child = spawn(cmd[0], cmd[1], { stdio: "ignore", detached: true });
    child.unref();
  } catch {
    /* best-effort */
  }
}

// ---------------------------------------------------------------------------
// detect — report candidate running frontend dev URLs
// ---------------------------------------------------------------------------

function probeUrl(url, timeoutMs = 700) {
  return new Promise((resolve) => {
    let u;
    try {
      u = new URL(url);
    } catch {
      return resolve(null);
    }
    const req = httpModuleFor(u).request(
      url,
      { method: "GET", headers: { "user-agent": "annotate-ui/detect" } },
      (res) => {
        const ct = String(res.headers["content-type"] || "");
        res.resume(); // drain
        resolve({ url, status: res.statusCode, contentType: ct, html: ct.includes("text/html") });
      },
    );
    req.setTimeout(timeoutMs, () => req.destroy());
    req.on("error", () => resolve(null));
    req.end();
  });
}

function listeningPorts() {
  return new Promise((resolve) => {
    const done = (out) => {
      const ports = new Set();
      for (const m of out.matchAll(/[.:](\d{2,5})\b/g)) {
        const p = Number(m[1]);
        if (p > 0 && p < 65536) ports.add(p);
      }
      resolve([...ports]);
    };
    // macOS/Linux: lsof; fall back to ss (Linux) — both best-effort.
    execFile(
      "lsof",
      ["-iTCP", "-sTCP:LISTEN", "-P", "-n"],
      { timeout: 1500 },
      (err, stdout) => {
        if (!err && stdout) return done(stdout);
        execFile("ss", ["-ltn"], { timeout: 1500 }, (e2, out2) => {
          done(!e2 && out2 ? out2 : "");
        });
      },
    );
  });
}

async function cmdDetect() {
  const listeners = await listeningPorts();
  const ports = [...new Set([...COMMON_DEV_PORTS, ...listeners])].filter(
    (p) => p !== readSession()?.port, // don't report our own proxy
  );
  const results = (await Promise.all(ports.map((p) => probeUrl(`http://127.0.0.1:${p}/`)))).filter(
    Boolean,
  );
  const candidates = results.filter((r) => r.html);
  const recommended = candidates.length === 1 ? candidates[0].url : null;
  const payload = {
    recommended,
    candidates: candidates.map((c) => ({ url: c.url, status: c.status })),
    otherListeners: results.filter((r) => !r.html).map((r) => ({ url: r.url, status: r.status })),
  };
  process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
  if (recommended) {
    process.stderr.write(`\nRecommended target: ${recommended}\n`);
  } else if (candidates.length === 0) {
    process.stderr.write(
      "\nNo HTML dev server found. Start your dev server, or pass its URL to `serve --target`.\n",
    );
  } else {
    process.stderr.write(
      `\n${candidates.length} candidates — ask the user which URL to target, then pass it to \`serve --target\`.\n`,
    );
  }
}

// ---------------------------------------------------------------------------
// serve — reverse proxy + overlay injection + callback server
// ---------------------------------------------------------------------------

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}
function sendJson(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": body.length,
    "cache-control": "no-store",
  });
  res.end(body);
}

// Insert exactly one overlay <script> into an HTML document buffer.
export function injectOverlay(htmlBuffer, scriptSrc = PREFIX + "overlay.js") {
  const html = htmlBuffer.toString("utf8");
  const tag = `<script type="module" src="${scriptSrc}"></script>`;
  const lower = html.toLowerCase();
  let idx = lower.lastIndexOf("</head>");
  if (idx === -1) idx = lower.lastIndexOf("</body>");
  const injected = idx === -1 ? html + tag : html.slice(0, idx) + tag + html.slice(idx);
  return Buffer.from(injected, "utf8");
}

function createCallbackState() {
  return {
    queue: [], // pending annotation batches (FIFO, drained on delivery)
    nextBatchId: 1,
    waiters: [], // pending long-poll responses
    messages: [], // agent -> browser replies
    nextMessageId: 1,
    lastActivity: Date.now(),
  };
}

function deliverBatch(state) {
  // Hand the oldest queued batch to the oldest waiting poll, if both exist.
  while (state.queue.length && state.waiters.length) {
    const batch = state.queue.shift();
    const waiter = state.waiters.shift();
    clearTimeout(waiter.timer);
    sendJson(waiter.res, 200, batch);
  }
}

function handleCallback(req, res, url, state) {
  state.lastActivity = Date.now();
  const route = url.pathname.slice(PREFIX.length);

  if (req.method === "GET" && route === "overlay.js") {
    fs.readFile(OVERLAY_FILE, (err, data) => {
      if (err) {
        res.writeHead(500);
        return res.end("overlay.js missing");
      }
      res.writeHead(200, {
        "content-type": "text/javascript; charset=utf-8",
        "content-length": data.length,
        "cache-control": "no-store",
      });
      res.end(data);
    });
    return;
  }

  if (req.method === "POST" && route === "submit") {
    readBody(req).then((buf) => {
      let parsed;
      try {
        parsed = JSON.parse(buf.toString("utf8") || "{}");
      } catch {
        return sendJson(res, 400, { ok: false, error: "invalid JSON" });
      }
      const annotations = Array.isArray(parsed.annotations) ? parsed.annotations : [];
      if (!annotations.length) return sendJson(res, 400, { ok: false, error: "no annotations" });
      const batch = {
        batchId: state.nextBatchId++,
        sentAt: new Date().toISOString(),
        annotations,
      };
      state.queue.push(batch);
      sendJson(res, 200, { ok: true, batchId: batch.batchId });
      deliverBatch(state);
    });
    return;
  }

  if (req.method === "GET" && route === "poll") {
    if (state.queue.length) {
      return sendJson(res, 200, state.queue.shift());
    }
    const timeoutMs = Math.max(1000, Number(url.searchParams.get("timeout") || 25) * 1000);
    const waiter = { res, timer: null };
    waiter.timer = setTimeout(() => {
      const i = state.waiters.indexOf(waiter);
      if (i !== -1) state.waiters.splice(i, 1);
      sendJson(res, 204, { batchId: null, annotations: [] });
    }, timeoutMs);
    state.waiters.push(waiter);
    req.on("close", () => {
      const i = state.waiters.indexOf(waiter);
      if (i !== -1) {
        state.waiters.splice(i, 1);
        clearTimeout(waiter.timer);
      }
    });
    return;
  }

  if (req.method === "POST" && route === "reply") {
    readBody(req).then((buf) => {
      let parsed;
      try {
        parsed = JSON.parse(buf.toString("utf8") || "{}");
      } catch {
        return sendJson(res, 400, { ok: false });
      }
      // A typed changelog message rides the same channel as a plain reply; it is
      // stored verbatim (type + changelog carried through unchanged) so overlays
      // can branch on `type`. Plain replies keep their { id, message } shape.
      if (parsed.type === "changelog" && Array.isArray(parsed.changelog)) {
        state.messages.push({
          id: state.nextMessageId++,
          at: new Date().toISOString(),
          type: "changelog",
          changelog: parsed.changelog,
        });
      } else {
        const message = String(parsed.message || "").trim();
        if (message) {
          state.messages.push({
            id: state.nextMessageId++,
            at: new Date().toISOString(),
            message,
          });
        }
      }
      sendJson(res, 200, { ok: true });
    });
    return;
  }

  if (req.method === "GET" && route === "messages") {
    const since = Number(url.searchParams.get("since") || 0);
    sendJson(res, 200, { messages: state.messages.filter((m) => m.id > since) });
    return;
  }

  if (req.method === "POST" && route === "shutdown") {
    sendJson(res, 200, { ok: true });
    setTimeout(() => process.emit("annotate:shutdown"), 50);
    return;
  }

  sendJson(res, 404, { ok: false, error: "unknown route" });
}

// Loopback host aliases: localhost <-> 127.0.0.1 on the same port, so a redirect
// to either spelling of the target origin is rewritten to the proxy origin.
function originVariants(origin) {
  const u = new URL(origin);
  const out = new Set([`${u.protocol}//${u.host}`]);
  if (u.hostname === "localhost") out.add(`${u.protocol}//127.0.0.1:${u.port}`);
  if (u.hostname === "127.0.0.1") out.add(`${u.protocol}//localhost:${u.port}`);
  return [...out];
}

// Rewrite response headers so an app that redirects to / sets cookies for its OWN
// origin (e.g. an auth callback -> http://localhost:5173/) works transparently
// through the proxy, with NO app or backend config change. Only the TARGET origin
// is rewritten — external redirects (e.g. a real OAuth provider) are left intact.
export function rewriteResponseHeaders(headers, targetOrigin, proxyOrigin, proxyIsHttp) {
  const variants = originVariants(targetOrigin);
  // Absolute Location redirects pointing at the target origin -> proxy origin.
  const loc = headers.location;
  if (loc && typeof loc === "string") {
    for (const v of variants) {
      if (loc.startsWith(v)) {
        headers.location = proxyOrigin + loc.slice(v.length);
        break;
      }
    }
  }
  // Cookies must apply to the proxy origin: strip Domain (=> host-only on the
  // proxy host) and, over a plaintext loopback proxy, strip Secure so the browser
  // stores the dev session cookie (downgrading SameSite=None, which needs Secure).
  let sc = headers["set-cookie"];
  if (sc) {
    if (!Array.isArray(sc)) sc = [sc];
    headers["set-cookie"] = sc.map((c) => {
      let out = c.replace(/;\s*Domain=[^;]*/gi, "");
      if (proxyIsHttp) {
        out = out.replace(/;\s*Secure\b/gi, "");
        out = out.replace(/;\s*SameSite=None/gi, "; SameSite=Lax");
      }
      return out;
    });
  }
  return headers;
}

// Proxy a normal request upstream, injecting the overlay into HTML responses.
function proxyRequest(req, res, target, state) {
  if (state) state.lastActivity = Date.now();
  const upstreamUrl = new URL(req.url, target);
  const headers = { ...req.headers };
  headers.host = upstreamUrl.host;
  // Force full, uncompressed responses so we can reliably inject into HTML.
  headers["accept-encoding"] = "identity";
  delete headers["if-none-match"];
  delete headers["if-modified-since"];

  const mod = httpModuleFor(upstreamUrl);
  const upstream = mod.request(
    upstreamUrl,
    { method: req.method, headers },
    (uRes) => {
      const ct = String(uRes.headers["content-type"] || "");
      const isHtml = ct.includes("text/html");
      const outHeaders = { ...uRes.headers };
      delete outHeaders["content-encoding"];
      if (state && state.proxyOrigin) {
        rewriteResponseHeaders(outHeaders, state.targetOrigin, state.proxyOrigin, state.proxyIsHttp);
      }

      if (!isHtml) {
        res.writeHead(uRes.statusCode || 502, outHeaders);
        uRes.pipe(res);
        return;
      }
      // Buffer HTML, inject, recompute content-length.
      const chunks = [];
      uRes.on("data", (c) => chunks.push(c));
      uRes.on("end", () => {
        const injected = injectOverlay(Buffer.concat(chunks));
        outHeaders["content-length"] = injected.length;
        delete outHeaders["transfer-encoding"];
        res.writeHead(uRes.statusCode || 200, outHeaders);
        res.end(injected);
      });
      uRes.on("error", () => res.destroy());
    },
  );
  upstream.on("error", (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { "content-type": "text/plain" });
    }
    res.end(`annotate-ui proxy error: ${err.message}\nis the dev server at ${target} running?`);
  });
  req.pipe(upstream);
}

// Raw-tunnel a websocket upgrade (Vite HMR / live reload) to the target.
function tunnelUpgrade(req, clientSocket, head, target) {
  const t = new URL(target);
  const upstream = net.connect(Number(t.port) || 80, t.hostname, () => {
    const headerLines = [`${req.method} ${req.url} HTTP/1.1`];
    const h = { ...req.headers, host: t.host };
    for (const [k, v] of Object.entries(h)) {
      if (Array.isArray(v)) for (const vv of v) headerLines.push(`${k}: ${vv}`);
      else headerLines.push(`${k}: ${v}`);
    }
    upstream.write(headerLines.join("\r\n") + "\r\n\r\n");
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  const kill = () => {
    upstream.destroy();
    clientSocket.destroy();
  };
  upstream.on("error", kill);
  clientSocket.on("error", kill);
}

async function cmdServe(flags) {
  // Server-only mode runs just the `/__annotate/*` callback server with NO reverse
  // proxy — for non-web surfaces (e.g. the in-process QML overlay) that inject
  // their own overlay and only need the submit/poll/reply endpoints + session file.
  const serverOnly = Boolean(flags["server-only"]);
  const target = flags.target || process.env.ANNOTATE_TARGET;
  if (!serverOnly) {
    if (!target) {
      process.stderr.write(
        "error: --target <url> is required (or set ANNOTATE_TARGET), " +
          "or pass --server-only for a proxy-less callback server.\n" +
          "Tip: run `annotate-ui detect` to find your running dev server.\n",
      );
      process.exit(2);
    }
    try {
      new URL(target);
    } catch {
      process.stderr.write(`error: invalid --target URL: ${target}\n`);
      process.exit(2);
    }
  }

  let port;
  try {
    port = await pickPort(resolvePort(flags));
  } catch (err) {
    process.stderr.write(`error: ${err.message}\n`);
    process.exit(1);
  }

  const state = createCallbackState();
  if (!serverOnly) state.targetOrigin = new URL(target).origin;
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    if (url.pathname.startsWith(PREFIX)) return handleCallback(req, res, url, state);
    if (serverOnly) {
      // No proxy target in server-only mode — only the callback surface exists.
      return sendJson(res, 404, {
        ok: false,
        error: "server-only mode: only /__annotate/* is served",
      });
    }
    proxyRequest(req, res, target, state);
  });
  if (!serverOnly) {
    server.on("upgrade", (req, socket, head) => tunnelUpgrade(req, socket, head, target));
  }

  // Idle self-stop: shut down if nothing touches the proxy for a while.
  const idleMs = Number(process.env.ANNOTATE_IDLE_SECONDS || 1800) * 1000;
  const idleTimer = setInterval(() => {
    if (idleMs > 0 && Date.now() - state.lastActivity > idleMs) shutdown("idle");
  }, 30_000);
  idleTimer.unref();

  let shuttingDown = false;
  function shutdown(reason) {
    if (shuttingDown) return;
    shuttingDown = true;
    clearInterval(idleTimer);
    clearSession();
    for (const w of state.waiters) {
      clearTimeout(w.timer);
      try {
        w.res.end();
      } catch {
        /* ignore */
      }
    }
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 500).unref();
    if (reason) process.stderr.write(`\nannotate-ui: shutting down (${reason}).\n`);
  }
  process.on("annotate:shutdown", () => shutdown("stop requested"));
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));

  server.listen(port, "127.0.0.1", () => {
    const actualPort = server.address().port; // may differ when the OS assigns (e.g. --port 0)
    const url = `http://127.0.0.1:${actualPort}`;
    if (!serverOnly) {
      state.proxyOrigin = url;
      state.proxyIsHttp = url.startsWith("http://");
    }
    writeSession({
      port: actualPort,
      target: serverOnly ? null : target,
      url,
      mode: serverOnly ? "server-only" : "proxy",
      pid: process.pid,
      startedAt: new Date().toISOString(),
    });
    if (serverOnly) {
      process.stdout.write(
        `annotate-ui server-only → ${url}\n` +
          `(callback server at ${PREFIX}; no proxy. Point an in-app overlay at this URL, ` +
          `then run \`annotate-ui poll\`.)\n`,
      );
    } else {
      process.stdout.write(
        `annotate-ui proxy → ${target}\n` +
          `Open this URL in your browser: ${url}\n` +
          `(annotation overlay injected; HMR tunneled; callbacks at ${PREFIX})\n`,
      );
      if (flags.open) openBrowser(url);
    }
  });
}

// ---------------------------------------------------------------------------
// poll — long-poll for annotations; optionally reply to the browser first
// ---------------------------------------------------------------------------

function httpJson(method, url, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const data = body ? Buffer.from(JSON.stringify(body)) : null;
    const req = httpModuleFor(u).request(
      u,
      {
        method,
        headers: data
          ? { "content-type": "application/json", "content-length": data.length }
          : {},
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let parsed = null;
          try {
            parsed = text ? JSON.parse(text) : null;
          } catch {
            /* leave null */
          }
          resolve({ status: res.statusCode, body: parsed });
        });
      },
    );
    req.on("error", reject);
    if (data) req.write(data);
    req.end();
  });
}

export function formatBatchMarkdown(batch) {
  if (!batch || !batch.annotations || !batch.annotations.length) return "";
  const lines = [`### ${batch.annotations.length} annotation(s) — batch #${batch.batchId}`, ""];
  batch.annotations.forEach((a, i) => {
    lines.push(`**${i + 1}. ${a.comment || "(no comment)"}**`);
    if (a.kind === "note") {
      lines.push(`- freeform note (not tied to a specific element)`);
      lines.push("");
      return;
    }
    // A verification issue answers a changelog entry; render its changelogId so
    // it reads as sign-off feedback, distinct from a fresh pin, then fall through
    // to its (auto-linked or re-pinned) element context below.
    if (a.kind === "verification") {
      lines.push(`- verification issue — answers changelog \`${a.changelogId ?? "?"}\``);
    }
    if (a.source && a.source.file) {
      lines.push(`- source: \`${a.source.file}:${a.source.line}\`${a.source.component ? ` (<${a.source.component}>)` : ""}`);
    }
    if (a.route) lines.push(`- route: \`${a.route}\``);
    if (a.selector) lines.push(`- selector: \`${a.selector}\``);
    if (a.a11yName) lines.push(`- a11y: ${a.role || "?"} "${a.a11yName}"`);
    // QML identity (present on `surface:"qml"` pins/verifications) — no exact line.
    if (a.objectName) lines.push(`- objectName: \`${a.objectName}\``);
    if (a.qmlType) lines.push(`- qmlType: \`${a.qmlType}\``);
    if (a.qmlFile) lines.push(`- qmlFile: \`${a.qmlFile}\``);
    if (a.outerHTML) lines.push(`- html: \`${a.outerHTML}\``);
    lines.push("");
  });
  return lines.join("\n");
}

// Validate a parsed changelog: an array of { id, title, description?, context? }
// entries. Returns a normalised copy (only known fields). Throws Error with a
// clear, user-facing message on any problem.
export function validateChangelog(parsed) {
  if (!Array.isArray(parsed)) {
    throw new Error("changelog must be a JSON array of entries");
  }
  return parsed.map((e, i) => {
    if (!e || typeof e !== "object" || Array.isArray(e)) {
      throw new Error(`changelog entry #${i + 1} must be an object`);
    }
    if (typeof e.id !== "string" || e.id.trim() === "") {
      throw new Error(`changelog entry #${i + 1} needs a non-empty string "id"`);
    }
    if (typeof e.title !== "string" || e.title.trim() === "") {
      throw new Error(`changelog entry #${i + 1} (${e.id}) needs a non-empty string "title"`);
    }
    if (e.description !== undefined && typeof e.description !== "string") {
      throw new Error(`changelog entry ${e.id}: "description" must be a string`);
    }
    if (
      e.context !== undefined &&
      (typeof e.context !== "object" || e.context === null || Array.isArray(e.context))
    ) {
      throw new Error(`changelog entry ${e.id}: "context" must be an object`);
    }
    const out = { id: e.id, title: e.title };
    if (e.description !== undefined) out.description = e.description;
    if (e.context !== undefined) out.context = e.context;
    return out;
  });
}

// Resolve a `--changelog <file|json>` argument to a validated changelog array.
// The argument is read as a file when it names an existing one, otherwise parsed
// as inline JSON. Throws Error with a clear message on any problem.
export function readChangelog(input) {
  if (typeof input !== "string" || input.trim() === "") {
    throw new Error("--changelog requires a file path or inline JSON");
  }
  let text = input;
  try {
    if (fs.existsSync(input) && fs.statSync(input).isFile()) {
      text = fs.readFileSync(input, "utf8");
    }
  } catch {
    /* not a readable file — fall through to inline JSON parse */
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    throw new Error(`--changelog is neither a readable file nor valid JSON: ${e.message}`);
  }
  return validateChangelog(parsed);
}

async function cmdPoll(flags) {
  const session = readSession();
  if (!session) {
    process.stderr.write("error: no active session — run `annotate-ui serve --target <url>` first.\n");
    process.exit(2);
  }
  const base = session.url;
  const reply = flags["agent-reply"];
  if (reply && typeof reply === "string") {
    try {
      await httpJson("POST", base + PREFIX + "reply", { message: reply });
      process.stderr.write("annotate-ui: reply sent to browser.\n");
    } catch (e) {
      process.stderr.write(`annotate-ui: could not send reply (${e.message}).\n`);
    }
  }
  // Deliver a structured changelog (composes with --agent-reply — both are sent).
  if (flags.changelog !== undefined) {
    let changelog;
    try {
      changelog = readChangelog(typeof flags.changelog === "string" ? flags.changelog : "");
    } catch (e) {
      process.stderr.write(`error: ${e.message}\n`);
      process.exit(2);
    }
    try {
      await httpJson("POST", base + PREFIX + "reply", { type: "changelog", changelog });
      process.stderr.write(`annotate-ui: changelog (${changelog.length} item(s)) sent to overlay.\n`);
    } catch (e) {
      process.stderr.write(`annotate-ui: could not send changelog (${e.message}).\n`);
    }
  }
  const timeout = Number(flags.timeout || 25);
  try {
    const { status, body } = await httpJson("GET", `${base}${PREFIX}poll?timeout=${timeout}`);
    if (status === 200 && body && body.annotations && body.annotations.length) {
      // Machine-readable first, then a human summary.
      process.stdout.write(JSON.stringify(body) + "\n");
      process.stdout.write("\n" + formatBatchMarkdown(body) + "\n");
    } else {
      process.stderr.write(
        "annotate-ui: no annotations before timeout — re-run `poll` to keep waiting (nothing is lost).\n",
      );
    }
  } catch (e) {
    process.stderr.write(`error: poll failed (${e.message}) — is the serve session still running?\n`);
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// stop
// ---------------------------------------------------------------------------

async function cmdStop() {
  const session = readSession();
  if (!session) {
    process.stderr.write("annotate-ui: no active session.\n");
    return;
  }
  try {
    await httpJson("POST", session.url + PREFIX + "shutdown");
    process.stderr.write("annotate-ui: stop requested.\n");
  } catch {
    process.stderr.write("annotate-ui: server not reachable; clearing session file.\n");
  }
  clearSession();
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

const HELP = `annotate-ui — point-and-click UI annotation for a coding agent

Usage:
  annotate-ui detect
      Probe common dev ports + local listeners; print candidate frontend URLs.

  annotate-ui serve --target <url> [--port <n>] [--open]
      Start the reverse proxy + overlay + callback server.
      Port precedence: --port  →  ANNOTATE_PORT  →  6100.
      A busy DEFAULT port auto-picks the next free one (read the printed URL).
      A busy EXPLICIT port exits with a remedy.

  annotate-ui serve --server-only [--port <n>]
      Start ONLY the /__annotate/* callback server (no reverse proxy) for a
      non-web surface that injects its own overlay (e.g. an in-process QML
      overlay). It POSTs to /__annotate/submit and reads /__annotate/messages;
      you receive pins with the same 'poll' command.

  annotate-ui poll [--agent-reply "<msg>"] [--changelog <file|json>] [--timeout <secs=25>]
      Block until the user sends annotations; print them as JSON + markdown.
      --agent-reply posts a message into the browser panel first.
      --changelog delivers a structured changelog — a JSON array (file path or
        inline) of { id, title, description?, context? } entries — that the
        overlay renders as a Verified/Rejected checklist. Rejections come back
        through this same poll as kind:"verification" items tied to changelogId.
        Composes with --agent-reply.

  annotate-ui stop
      Shut down the running serve session.

Env: ANNOTATE_TARGET, ANNOTATE_PORT, ANNOTATE_STATE_DIR, ANNOTATE_IDLE_SECONDS
`;

async function main() {
  const { flags, positional } = parseFlags(process.argv.slice(2));
  const cmd = positional[0];
  if (flags.help || cmd === "help" || !cmd) {
    process.stdout.write(HELP);
    return;
  }
  switch (cmd) {
    case "detect":
      return cmdDetect();
    case "serve":
      return cmdServe(flags);
    case "poll":
      return cmdPoll(flags);
    case "stop":
      return cmdStop();
    default:
      process.stderr.write(`unknown command: ${cmd}\n\n${HELP}`);
      process.exit(2);
  }
}

// Only run the CLI when executed directly (so tests can import helpers).
// Compare realpaths so invocation via a symlink (e.g. ~/.claude/skills/...)
// still matches the module's resolved path.
function isMain() {
  if (!process.argv[1]) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return fs.realpathSync(process.argv[1]) === fs.realpathSync(self);
  } catch {
    return path.resolve(process.argv[1]) === self;
  }
}
if (isMain()) {
  main();
}
