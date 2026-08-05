# annotate-ui

Point-and-click annotation for any running web dev build, streamed back to a coding agent.

Click an element in your **live** app, type what needs fixing, hit **Send** — your coding agent
receives the annotation with a CSS selector, the page route, the element's `outerHTML`, and (for
React dev builds) the **source file:line**. Modeled on the [`lavish`](https://skills.sh) loop, but
it annotates your real dev server instead of a static HTML artifact.

It works by running a transparent reverse proxy in front of your dev server: it injects a small
overlay `<script>` into HTML responses, tunnels the HMR websocket so hot-reload keeps working, and
serves callback routes under `/__annotate/*`. **No changes to your app or its build.**

## Requirements

- Node **≥ 18**. That's it — **zero runtime dependencies** (Node built-ins only).

## Install

As a Claude skill (user-level):

```bash
# copy or clone into your skills dir
git clone <this-repo> ~/.claude/skills/annotate-ui
# or, if published to the skills ecosystem:
npx skills add <owner/repo@annotate-ui>
```

Or use it as a plain CLI from anywhere:

```bash
node /path/to/annotate-ui/cli.mjs --help
```

## Usage

```bash
CLI="node ~/.claude/skills/annotate-ui/cli.mjs"

# 1. find your running dev server
$CLI detect

# 2. start the proxy (read the printed URL — may differ from 6100)
$CLI serve --target http://localhost:5173 --open

# 3. block until the user sends annotations
$CLI poll

# 4. reply into the browser and wait for the next round
$CLI poll --agent-reply "fixed the header spacing — please re-check"

# 5. stop
$CLI stop
```

Open the **proxy** URL (default `http://127.0.0.1:6100`) in your browser, click **✎ Annotate**,
click any element, type a note, and **Send to agent**.

## Editing & revealing pins

Each pending annotation in the panel has three controls before you send:

- **✎ edit** — revise the comment inline (⌘/Ctrl+Enter to save, Esc to cancel). The pinned
  element stays the same; only your note changes.
- **⌖ reveal** — jump back to that annotation and flash-highlight the element. If the pin is on the
  page you're already viewing, it scrolls to it instantly. If it's on a different route, the panel
  navigates there (a real page load — your pending pins survive it) and highlights the element once
  the view mounts.
- **✕ delete** — drop the pin.

Reveal is reliable for elements that are still on the page and for views addressable by their URL.
Because a cross-route reveal is a genuine reload, transient in-app state (open modals, unsaved form
input) is reset, and a view that isn't encoded in the URL won't reconstruct — in those cases reveal
flashes "couldn't find that element" rather than leaving you somewhere broken.

### Freeform notes

Not every comment is about a specific element. The composer at the bottom of the panel (a small
textarea that grows as you type) adds a **freeform note** — general feedback not pinned to anything.
Type it and press **⌘/Ctrl+Enter**; it drops into the same list, editable and deletable like any
other entry (it just has no **⌖ reveal**, since there's nothing to point at). Notes are delivered in
the same batch tagged `kind: "note"` with no element context.

## Ports & env

Port precedence: `--port` → `ANNOTATE_PORT` → `6100`. A busy **default** auto-picks the next free
port (the real URL is printed). A busy **explicit** port exits with a remedy.

| Env | Meaning |
|---|---|
| `ANNOTATE_TARGET` | default `--target` dev-server URL |
| `ANNOTATE_PORT` | pin the proxy port |
| `ANNOTATE_STATE_DIR` | where `session.json` lives (default `~/.annotate/`) |
| `ANNOTATE_IDLE_SECONDS` | auto-stop after this much inactivity (default `1800`, `0` = never) |

## Annotation shape

```jsonc
{
  "comment": "star fill is too dim here",
  "selector": "main > section.feed > article:nth-of-type(2) button.star-btn",
  "rect": { "x": 812, "y": 344, "w": 28, "h": 28 },
  "route": "/feed",
  "viewport": { "w": 1440, "h": 900, "dpr": 2 },
  "text": "★",
  "outerHTML": "<button class=\"star-btn is-active\">…</button>",
  "ancestors": ["main", "section.feed", "article.mix-card"],
  "role": "button", "a11yName": "Rate 3 stars",
  "source": { "file": "src/components/MixRow.tsx", "line": 42, "column": 6, "component": "MixRow" }
}
```

`source` is `null` for production builds or non-React apps; every other field is always present.

Freeform notes are the exception: they carry only `{ "kind": "note", "comment": "…" }` with no
element-context fields, since they aren't tied to anything on the page.

## Native / QML apps

The same point-and-click-then-poll loop works for a native **Qt Quick / QML** app — no web, no
proxy. Run the callback server on its own (`annotate-ui serve --server-only`) and drop the shipped,
**self-contained** [`qml/AnnotateOverlay.qml`](./qml/AnnotateOverlay.qml) into your running app: it
does its own HTTP transport, hit-testing, type introspection, and pending-pin state in pure QML.
A host (C++ **or** Python) only injects an `annotateServerUrl` string and an optional `annotateHost`
object, then parents the overlay into the window — full wiring, payload shape, and C++/PySide6 shim
sketches are in [`qml/HOST-CONTRACT.md`](./qml/HOST-CONTRACT.md). Pins arrive through the same
`annotate-ui poll`, tagged `surface: "qml"`.

## How it works

- **Framework-agnostic:** it proxies whatever dev server you point it at (Vite, CRA, Next, Vue,
  Svelte, plain static). React source location is a bonus when available, not a requirement.
- **HMR-safe:** websocket `upgrade` requests are raw-tunneled to the target.
- **Dev-only & local:** binds `127.0.0.1`; the overlay only exists while the proxy runs.

## License

MIT — see [LICENSE](./LICENSE).
