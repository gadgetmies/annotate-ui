## 1. Skill scaffold & packaging

- [x] 1.1 Create the skill directory `annotate-ui/` with files `SKILL.md`, `cli.mjs`, `overlay.js`, `README.md`, `LICENSE` (MIT); intended install path `~/.claude/skills/annotate-ui/`, no reference to this repo
- [x] 1.2 Add SKILL.md frontmatter (`name`, `description`, `metadata.tags`) and a "Startup / ports" note documenting the `--port` → `ANNOTATE_PORT` → `6100` precedence and the auto-probe-upward fallback so the agent never debugs `EADDRINUSE`
- [x] 1.3 Confirm zero runtime dependencies (Node ≥18 built-ins only) — no `package.json` deps required to run

## 2. CLI foundation (`cli.mjs`)

- [x] 2.1 Argument parser + command dispatch for `detect | serve | poll | stop`; `--help` for each
- [x] 2.2 Port resolution helper: precedence `--port` → `ANNOTATE_PORT` → `6100`; free-port probe (bounded upward scan); explicit-busy → exit non-zero with one-line remedy
- [x] 2.3 Session file read/write at `~/.annotate/session.json` (override `$ANNOTATE_STATE_DIR`) storing `{port, target, pid, url}`

## 3. Reverse proxy + callback server (`serve`)

- [x] 3.1 HTTP proxy: re-issue each request upstream to `--target`/`ANNOTATE_TARGET` with `Accept-Encoding: identity`; stream non-HTML responses byte-for-byte
- [x] 3.2 HTML injection: buffer `text/html` responses, insert one `<script src="/__annotate/overlay.js">` before `</head>` (fallbacks `</body>`, append), recompute `Content-Length`
- [x] 3.3 Websocket `upgrade` raw-tunnel via `net` so HMR/live-reload round-trips
- [x] 3.4 Bind `127.0.0.1` only; `--open` opens the resolved proxy URL; print the actual bound URL
- [x] 3.5 `/__annotate/*` router served locally (never forwarded): `overlay.js`, `submit`, `poll`, `reply`, `messages`, `shutdown`; idle self-stop grace timer

## 4. Callback queue & long-poll (`poll`, server side)

- [x] 4.1 In-memory batch queue with monotonic `batchId`; `POST /submit` enqueues + unblocks a waiting `poll`; drained ids not re-emitted
- [x] 4.2 `GET /poll` long-poll held open ~25s then empty; `poll` CLI reads session, optionally `POST /reply` first, then blocks; prints JSON + markdown summary
- [x] 4.3 Agent→browser reply channel: `POST /reply` stored; `GET /messages?since=` returned to the overlay
- [x] 4.4 `stop` → `POST /shutdown` graceful close

## 5. Target detection (`detect`)

- [x] 5.1 Probe common dev ports (`3000 3001 4200 5173 5174 8080 8000 1234 4321 5000`) + best-effort local listeners (`lsof`/`ss`); `GET /` and classify `text/html`
- [x] 5.2 Output: exactly one HTML candidate → recommend it; zero/many → print full candidate list (JSON) for the agent to ask the user; never start a dev server

## 6. Overlay client (`overlay.js`)

- [x] 6.1 Shadow-DOM-isolated UI: floating Annotate toggle, hover highlight, click-to-pin comment popover, pending-list panel with edit/delete, Send button; exclude overlay's own DOM from targeting
- [x] 6.2 Capture-phase click handling (`preventDefault`/`stopPropagation`) in annotate mode; persist pending pins in `sessionStorage` to survive HMR reload
- [x] 6.3 Context extraction: unique CSS `selector` (widen until `querySelectorAll` length 1), `rect`, `route`, `viewport`, `text`, capped `outerHTML`, `ancestors`, `role`, `a11yName`
- [x] 6.4 React source: read `__reactFiber$*`/`__reactInternalInstance$*`, walk `return`/`_debugOwner` to `_debugSource` → `{file,line,column,component}`; `null` if absent (never throw)
- [x] 6.5 Send → `POST /__annotate/submit`; poll `GET /__annotate/messages` to display agent replies

## 7. SKILL.md agent workflow

- [x] 7.1 Document the loop: `detect` → (one match use it / else ask) → `serve --target <url> --open` → read printed URL → `poll` foreground → apply fixes → `poll --agent-reply` → `stop`
- [x] 7.2 Foreground/verified-wake discipline for `poll` (mirroring lavish); security note treating `outerHTML`/`text`/`comment` as untrusted data, dev-only, loopback

## 8. Tests

- [x] 8.1 CLI unit: port precedence + self-healing (default vs explicit); session.json round-trip; `detect` HTML-vs-non-HTML classification against a stub server
- [x] 8.2 Proxy integration: fake upstream serving HTML + a non-HTML asset + a ws echo — assert single overlay injection, byte-identical asset passthrough, ws upgrade round-trip
- [x] 8.3 Callback loop: `submit` → blocked `poll` returns the batch; `reply` delivered via `messages`; drained `batchId` not re-emitted
- [x] 8.4 Overlay (light, jsdom/headless): selector uniqueness + React `_debugSource` extraction on a fixture DOM; `null` when absent

## 9. Publish readiness

- [x] 9.1 README.md: install (`~/.claude/skills/` copy + `npx skills add`), usage, port/env docs, framework-agnostic note
- [x] 9.2 Verify self-contained standalone run from a temp dir against a throwaway dev server (no repo dependency)
