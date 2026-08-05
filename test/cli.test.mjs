// Unit tests for the CLI helpers — port precedence, self-healing, session I/O,
// overlay HTML injection, and the poll markdown formatter. Zero dependencies.

import { test } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  parseFlags,
  resolvePort,
  pickPort,
  injectOverlay,
  formatBatchMarkdown,
  rewriteResponseHeaders,
  writeSession,
  readSession,
  DEFAULT_PORT,
} from "../cli.mjs";

test("parseFlags handles --k v, --k=v, and booleans", () => {
  const { flags, positional } = parseFlags(["serve", "--target", "http://x", "--open", "--port=6200"]);
  assert.equal(flags.target, "http://x");
  assert.equal(flags.open, true);
  assert.equal(flags.port, "6200");
  assert.deepEqual(positional, ["serve"]);
});

test("resolvePort precedence: flag > env > default", () => {
  assert.deepEqual(resolvePort({ port: "7000" }, {}), { port: 7000, explicit: true });
  assert.deepEqual(resolvePort({}, { ANNOTATE_PORT: "7100" }), { port: 7100, explicit: true });
  assert.deepEqual(resolvePort({}, {}), { port: DEFAULT_PORT, explicit: false });
});

test("pickPort auto-heals a busy DEFAULT port upward", async () => {
  const blocker = net.createServer();
  await new Promise((r) => blocker.listen(0, "127.0.0.1", r));
  const busy = blocker.address().port;
  const chosen = await pickPort({ port: busy, explicit: false });
  assert.notEqual(chosen, busy);
  assert.ok(chosen > busy && chosen <= busy + 20);
  blocker.close();
});

test("pickPort throws with a remedy on a busy EXPLICIT port", async () => {
  const blocker = net.createServer();
  await new Promise((r) => blocker.listen(0, "127.0.0.1", r));
  const busy = blocker.address().port;
  await assert.rejects(() => pickPort({ port: busy, explicit: true }), /in use.*--port/);
  blocker.close();
});

test("injectOverlay inserts exactly one module script before </head>", () => {
  const html = Buffer.from("<html><head><title>x</title></head><body>hi</body></html>");
  const out = injectOverlay(html).toString();
  const count = (out.match(/__annotate\/overlay\.js/g) || []).length;
  assert.equal(count, 1);
  assert.ok(out.indexOf("overlay.js") < out.indexOf("</head>"));
  assert.match(out, /<script type="module"/);
});

test("injectOverlay falls back to </body>, then append", () => {
  const noHead = injectOverlay(Buffer.from("<body>hi</body>")).toString();
  assert.ok(noHead.indexOf("overlay.js") < noHead.indexOf("</body>"));
  const bare = injectOverlay(Buffer.from("<div>hi</div>")).toString();
  assert.match(bare, /<div>hi<\/div><script/);
});

test("session round-trips through ANNOTATE_STATE_DIR", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "annotate-state-"));
  const prev = process.env.ANNOTATE_STATE_DIR;
  process.env.ANNOTATE_STATE_DIR = dir;
  try {
    const s = { port: 6100, target: "http://localhost:5173", url: "http://127.0.0.1:6100", pid: 1 };
    writeSession(s);
    assert.deepEqual(readSession(), s);
  } finally {
    if (prev === undefined) delete process.env.ANNOTATE_STATE_DIR;
    else process.env.ANNOTATE_STATE_DIR = prev;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("rewriteResponseHeaders rewrites target-origin redirects to the proxy origin", () => {
  const t = "http://localhost:5173";
  const p = "http://127.0.0.1:6100";
  // absolute redirect to the target origin (localhost) -> proxy origin
  let h = rewriteResponseHeaders({ location: "http://localhost:5173/auth/mock/callback?x=1" }, t, p, true);
  assert.equal(h.location, "http://127.0.0.1:6100/auth/mock/callback?x=1");
  // loopback alias (127.0.0.1) of the target is also rewritten
  h = rewriteResponseHeaders({ location: "http://127.0.0.1:5173/feed" }, t, p, true);
  assert.equal(h.location, "http://127.0.0.1:6100/feed");
  // an EXTERNAL redirect (e.g. real OAuth) is left untouched
  h = rewriteResponseHeaders({ location: "https://accounts.google.com/o/oauth2/v2/auth" }, t, p, true);
  assert.equal(h.location, "https://accounts.google.com/o/oauth2/v2/auth");
});

test("rewriteResponseHeaders makes cookies apply to the proxy (strip Domain/Secure over http)", () => {
  const t = "http://localhost:5173";
  const p = "http://127.0.0.1:6100";
  const h = rewriteResponseHeaders(
    { "set-cookie": ["tp_session=abc; Path=/; Domain=localhost; Secure; HttpOnly; SameSite=None"] },
    t,
    p,
    true,
  );
  const c = h["set-cookie"][0];
  assert.ok(!/Domain=/i.test(c), "Domain stripped");
  assert.ok(!/Secure/i.test(c), "Secure stripped over http");
  assert.match(c, /SameSite=Lax/); // downgraded from None (which needs Secure)
  assert.match(c, /HttpOnly/); // untouched attrs preserved
});

test("formatBatchMarkdown surfaces source and selector", () => {
  const md = formatBatchMarkdown({
    batchId: 2,
    annotations: [
      { comment: "too dim", source: { file: "src/A.tsx", line: 5, component: "A" }, route: "/f", selector: "button.x" },
    ],
  });
  assert.match(md, /batch #2/);
  assert.match(md, /too dim/);
  assert.match(md, /src\/A\.tsx:5/);
  assert.match(md, /button\.x/);
});

test("formatBatchMarkdown labels a freeform note and omits element fields", () => {
  const md = formatBatchMarkdown({
    batchId: 7,
    annotations: [{ kind: "note", comment: "overall the spacing feels cramped" }],
  });
  assert.match(md, /overall the spacing feels cramped/);
  assert.match(md, /freeform note \(not tied to a specific element\)/);
  assert.doesNotMatch(md, /selector:/); // notes carry no element context
  assert.doesNotMatch(md, /route:/);
});
