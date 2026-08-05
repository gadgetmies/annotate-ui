// Integration tests: spawn the real `serve` process against a fake upstream and
// assert overlay injection, byte-identical asset passthrough, ws upgrade
// tunneling, and the submit/poll/reply callback loop. Zero dependencies.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "cli.mjs");
const ASSET = Buffer.from([0, 1, 2, 3, 255, 254, 200, 42]); // non-UTF8 bytes

let upstream, proxyProc, upstreamPort, proxyUrl, stateDir;

function startUpstream() {
  return new Promise((resolve) => {
    upstream = http.createServer((req, res) => {
      if (req.url === "/asset.bin") {
        res.writeHead(200, { "content-type": "application/octet-stream", "content-length": ASSET.length });
        return res.end(ASSET);
      }
      const body = "<html><head><title>t</title></head><body>hello</body></html>";
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(body);
    });
    // Echo websocket-ish upgrade: complete the handshake and echo one frame of bytes.
    upstream.on("upgrade", (req, socket) => {
      socket.write(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
      );
      socket.on("data", (d) => socket.write(d)); // echo
    });
    upstream.listen(0, "127.0.0.1", () => {
      upstreamPort = upstream.address().port;
      resolve();
    });
  });
}

function waitForUrl(proc) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const onData = (d) => {
      buf += d.toString();
      const m = buf.match(/browser:\s*(http:\/\/[\d.]+:\d+)/);
      if (m) {
        proc.stdout.off("data", onData);
        resolve(m[1]);
      }
    };
    proc.stdout.on("data", onData);
    proc.on("exit", (c) => reject(new Error("serve exited early: " + c + "\n" + buf)));
    setTimeout(() => reject(new Error("timeout waiting for serve URL\n" + buf)), 8000);
  });
}

before(async () => {
  await startUpstream();
  stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "annotate-proxy-"));
  proxyProc = spawn(
    process.execPath,
    [CLI, "serve", "--target", `http://127.0.0.1:${upstreamPort}`, "--port", "0"],
    { env: { ...process.env, ANNOTATE_STATE_DIR: stateDir }, stdio: ["ignore", "pipe", "pipe"] },
  );
  proxyProc.stderr.on("data", () => {});
  // --port 0 asks the OS for a free port; the process prints the bound URL.
  proxyUrl = await waitForUrl(proxyProc);
});

after(() => {
  try {
    proxyProc.kill("SIGTERM");
  } catch {}
  upstream.close();
  fs.rmSync(stateDir, { recursive: true, force: true });
});

test("HTML response gets exactly one overlay script injected", async () => {
  const res = await fetch(proxyUrl + "/");
  const text = await res.text();
  const count = (text.match(/__annotate\/overlay\.js/g) || []).length;
  assert.equal(count, 1);
  assert.match(text, /hello/); // original content preserved
});

test("non-HTML asset passes through byte-for-byte", async () => {
  const res = await fetch(proxyUrl + "/asset.bin");
  const got = Buffer.from(await res.arrayBuffer());
  assert.deepEqual(got, ASSET);
});

test("overlay.js is served from the callback route", async () => {
  const res = await fetch(proxyUrl + "/__annotate/overlay.js");
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type") || "", /javascript/);
  const src = await res.text();
  assert.match(src, /findReactSource/);
});

test("websocket upgrade is tunneled and echoes", async () => {
  const u = new URL(proxyUrl);
  await new Promise((resolve, reject) => {
    const sock = net.connect(Number(u.port), u.hostname, () => {
      sock.write(
        `GET / HTTP/1.1\r\nHost: ${u.host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
          `Sec-WebSocket-Key: x\r\nSec-WebSocket-Version: 13\r\n\r\n`,
      );
    });
    let stage = 0;
    sock.on("data", (d) => {
      if (stage === 0) {
        assert.match(d.toString(), /101 Switching Protocols/);
        stage = 1;
        sock.write(Buffer.from("ping-bytes"));
      } else {
        assert.match(d.toString(), /ping-bytes/);
        sock.destroy();
        resolve();
      }
    });
    sock.on("error", reject);
    setTimeout(() => reject(new Error("ws timeout")), 4000);
  });
});

test("callback loop: submit unblocks a waiting poll; reply reaches messages; drained id not re-emitted", async () => {
  // Start a poll (long) BEFORE submitting, so submit must unblock it.
  const pollP = fetch(proxyUrl + "/__annotate/poll?timeout=10").then((r) => r.json());
  await new Promise((r) => setTimeout(r, 150));
  const submit = await (
    await fetch(proxyUrl + "/__annotate/submit", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ annotations: [{ comment: "fix me", selector: "button" }] }),
    })
  ).json();
  assert.equal(submit.ok, true);
  assert.equal(submit.batchId, 1);

  const delivered = await pollP;
  assert.equal(delivered.batchId, 1);
  assert.equal(delivered.annotations[0].comment, "fix me");

  // A subsequent short poll must NOT re-emit the drained batch.
  const empty = await fetch(proxyUrl + "/__annotate/poll?timeout=1");
  assert.equal(empty.status, 204);

  // Reply → messages
  await fetch(proxyUrl + "/__annotate/reply", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message: "on it" }),
  });
  const msgs = await (await fetch(proxyUrl + "/__annotate/messages?since=0")).json();
  assert.equal(msgs.messages.at(-1).message, "on it");
});
