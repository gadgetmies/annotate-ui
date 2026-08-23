// Integration tests for the changelog-verification wire loop: spawn the real
// `serve --server-only` callback server and drive the real `poll --changelog`
// CLI against it, asserting the typed message is delivered, malformed input is
// rejected, --changelog composes with --agent-reply, a kind:"verification" submit
// item is delivered + rendered by poll, and plain replies still work unchanged.
// Zero dependencies.

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

// Run the CLI as a child (so `poll` uses the same session file) and capture it.
function runCli(args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CLI, ...args], {
      env: { ...process.env, ANNOTATE_STATE_DIR: stateDir },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

before(async () => {
  stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "annotate-changelog-"));
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

test("poll --changelog (inline JSON) posts a type:changelog message readable via /messages", async () => {
  const changelog = JSON.stringify([
    { id: "c1", title: "Star now gold", description: "changed fill", context: { selector: ".rating > svg" } },
    { id: "c2", title: "Debounced search" },
  ]);
  const { code } = await runCli(["poll", "--changelog", changelog, "--timeout", "1"]);
  assert.equal(code, 0);
  const { messages } = await (await fetch(url + "/__annotate/messages?since=0")).json();
  const cl = messages.find((m) => m.type === "changelog");
  assert.ok(cl, "a changelog message was delivered");
  assert.equal(cl.changelog.length, 2);
  assert.equal(cl.changelog[0].id, "c1");
  assert.equal(cl.changelog[0].context.selector, ".rating > svg");
});

test("poll --changelog (file path) also posts the typed message", async () => {
  const file = path.join(stateDir, "cl.json");
  fs.writeFileSync(file, JSON.stringify([{ id: "f1", title: "From a file" }]));
  const { code } = await runCli(["poll", "--changelog", file, "--timeout", "1"]);
  assert.equal(code, 0);
  const { messages } = await (await fetch(url + "/__annotate/messages?since=0")).json();
  assert.ok(messages.some((m) => m.type === "changelog" && m.changelog.some((e) => e.id === "f1")));
});

test("poll --changelog rejects a malformed changelog with a clear error (non-zero exit)", async () => {
  const { code, stderr } = await runCli(["poll", "--changelog", '[{"title":"no id"}]', "--timeout", "1"]);
  assert.notEqual(code, 0);
  assert.match(stderr, /id/);
});

test("--changelog composes with --agent-reply (both messages delivered)", async () => {
  const before = await (await fetch(url + "/__annotate/messages?since=0")).json();
  const since = before.messages.at(-1)?.id ?? 0;
  const { code } = await runCli([
    "poll",
    "--agent-reply",
    "please re-check",
    "--changelog",
    '[{"id":"x1","title":"An entry"}]',
    "--timeout",
    "1",
  ]);
  assert.equal(code, 0);
  const { messages } = await (await fetch(url + "/__annotate/messages?since=" + since)).json();
  assert.ok(messages.some((m) => m.message === "please re-check"), "plain reply delivered");
  assert.ok(messages.some((m) => m.type === "changelog"), "changelog delivered");
});

test("a plain --agent-reply carries no changelog fields (backward compatible)", async () => {
  const before = await (await fetch(url + "/__annotate/messages?since=0")).json();
  const since = before.messages.at(-1)?.id ?? 0;
  await runCli(["poll", "--agent-reply", "just text", "--timeout", "1"]);
  const { messages } = await (await fetch(url + "/__annotate/messages?since=" + since)).json();
  const m = messages.find((x) => x.message === "just text");
  assert.ok(m);
  assert.equal(m.type, undefined);
  assert.equal(m.changelog, undefined);
});

test("a kind:verification submit item is delivered by poll and rendered distinct from pins/notes", async () => {
  // Submit a mixed batch: a pin, a note, and a verification issue.
  await fetch(url + "/__annotate/submit", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      annotations: [
        { comment: "too dim", selector: "button.x", source: { file: "src/A.tsx", line: 5 } },
        { kind: "note", comment: "spacing feels cramped" },
        {
          kind: "verification",
          changelogId: "c1",
          comment: "still orange on the detail page",
          selector: ".rating > svg",
          route: "/movie/42",
        },
      ],
    }),
  });
  // A queued batch makes poll return immediately; capture its JSON + markdown.
  const { code, stdout } = await runCli(["poll", "--timeout", "3"]);
  assert.equal(code, 0);
  const jsonLine = stdout.split("\n").find((l) => l.trim().startsWith("{"));
  const batch = JSON.parse(jsonLine);
  const v = batch.annotations.find((a) => a.kind === "verification");
  assert.ok(v, "verification item delivered in the batch");
  assert.equal(v.changelogId, "c1");
  // Markdown renders it as a verification issue, distinct from the note/pin.
  assert.match(stdout, /verification issue — answers changelog `c1`/);
  assert.match(stdout, /still orange on the detail page/);
  assert.match(stdout, /freeform note \(not tied to a specific element\)/);
});
