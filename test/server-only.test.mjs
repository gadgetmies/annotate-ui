// Integration test: `serve --server-only` starts the /__annotate/* callback
// server with NO reverse proxy — the transport a non-web (e.g. QML) overlay uses.
// Asserts the submit→poll→reply round-trip works and non-callback paths 404.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "cli.mjs");

let proc, url, stateDir;

function waitForUrl(p) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const onData = (d) => {
      buf += d.toString();
      const m = buf.match(/server-only\s*→\s*(http:\/\/[\d.]+:\d+)/);
      if (m) {
        p.stdout.off("data", onData);
        resolve(m[1]);
      }
    };
    p.stdout.on("data", onData);
    p.on("exit", (c) => reject(new Error("serve exited early: " + c + "\n" + buf)));
    setTimeout(() => reject(new Error("timeout waiting for server-only URL\n" + buf)), 8000);
  });
}

before(async () => {
  stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "annotate-server-only-"));
  proc = spawn(process.execPath, [CLI, "serve", "--server-only", "--port", "0"], {
    env: { ...process.env, ANNOTATE_STATE_DIR: stateDir },
    stdio: ["ignore", "pipe", "pipe"],
  });
  proc.stderr.on("data", () => {});
  url = await waitForUrl(proc);
});

after(() => {
  try {
    proc.kill("SIGTERM");
  } catch {}
  fs.rmSync(stateDir, { recursive: true, force: true });
});

test("session file records server-only mode with a null target", () => {
  const session = JSON.parse(fs.readFileSync(path.join(stateDir, "session.json"), "utf8"));
  assert.equal(session.mode, "server-only");
  assert.equal(session.target, null);
  assert.equal(session.url, url);
});

test("non-callback paths 404 (no proxy in server-only mode)", async () => {
  const res = await fetch(url + "/");
  assert.equal(res.status, 404);
  const body = await res.json();
  assert.match(body.error, /server-only/);
});

test("submit → blocked poll round-trip works with no target", async () => {
  // A long poll started BEFORE submit must be unblocked by the submit.
  const pollP = fetch(url + "/__annotate/poll?timeout=10").then((r) => r.json());
  await new Promise((r) => setTimeout(r, 150));
  const submit = await (
    await fetch(url + "/__annotate/submit", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        annotations: [{ comment: "fix this row", surface: "qml", objectName: "cacheButton" }],
      }),
    })
  ).json();
  assert.equal(submit.ok, true);

  const delivered = await pollP;
  assert.equal(delivered.annotations[0].comment, "fix this row");
  assert.equal(delivered.annotations[0].surface, "qml");
});

test("agent reply reaches /__annotate/messages", async () => {
  await fetch(url + "/__annotate/reply", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message: "looking now" }),
  });
  const msgs = await (await fetch(url + "/__annotate/messages?since=0")).json();
  assert.equal(msgs.messages.at(-1).message, "looking now");
});
