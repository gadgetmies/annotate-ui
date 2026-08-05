// annotate-ui overlay — injected into the live dev build by the proxy.
// Served as an ES module. Pure context-extraction helpers are exported for
// unit testing; the interactive UI only boots when a real `document` exists.

const PREFIX = "/__annotate/";
const OUTER_HTML_CAP = 500;

// Use the browser's CSS.escape when present; fall back to a minimal escape so
// the selector helpers also run under Node (tests) with no DOM globals.
function cssEscape(v) {
  if (typeof CSS !== "undefined" && CSS.escape) return CSS.escape(v);
  return String(v).replace(/[^a-zA-Z0-9_-]/g, (c) => "\\" + c);
}

// --- pure helpers (exported, testable without a browser) -------------------

// Trim + collapse an element's outerHTML so a coding agent gets a greppable
// anchor without a wall of nested markup.
export function cappedOuterHTML(el, cap = OUTER_HTML_CAP) {
  let html = "";
  try {
    const clone = el.cloneNode(false); // no children
    // Represent children compactly as a single ellipsis text node.
    if (el.childNodes && el.childNodes.length) clone.textContent = "…";
    html = clone.outerHTML || "";
  } catch {
    html = "";
  }
  if (html.length > cap) html = html.slice(0, cap - 1) + "…";
  return html;
}

// Build a CSS selector that resolves to exactly one node, widening from the
// element up its ancestors until unique (or the document root is reached).
export function buildSelector(el, doc = globalThis.document) {
  if (!el || el.nodeType !== 1) return "";
  const seg = (node) => {
    if (node.id) return `#${cssEscape(node.id)}`;
    // Prefer stable test ids.
    for (const attr of ["data-testid", "data-test", "data-cy"]) {
      const v = node.getAttribute && node.getAttribute(attr);
      if (v) return `${node.tagName.toLowerCase()}[${attr}="${cssAttr(v)}"]`;
    }
    let s = node.tagName.toLowerCase();
    const cls = (node.getAttribute && node.getAttribute("class") ? node.className : "")
      .toString()
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((c) => `.${cssEscape(c)}`)
      .join("");
    s += cls;
    // nth-of-type disambiguation among siblings of the same tag.
    const parent = node.parentElement;
    if (parent) {
      const sameTag = [...parent.children].filter((c) => c.tagName === node.tagName);
      if (sameTag.length > 1) s += `:nth-of-type(${sameTag.indexOf(node) + 1})`;
    }
    return s;
  };

  const parts = [];
  let node = el;
  while (node && node.nodeType === 1 && node.tagName.toLowerCase() !== "html") {
    parts.unshift(seg(node));
    const candidate = parts.join(" > ");
    try {
      if (doc && doc.querySelectorAll(candidate).length === 1) return candidate;
    } catch {
      /* invalid selector while widening — keep going */
    }
    node = node.parentElement;
  }
  return parts.join(" > ");
}

function cssAttr(v) {
  return String(v).replace(/"/g, '\\"');
}

// Walk the React fiber from a DOM node to the nearest _debugSource.
// Returns { file, line, column, component } or null. Never throws.
export function findReactSource(el) {
  try {
    const key = Object.keys(el).find(
      (k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$"),
    );
    if (!key) return null;
    let fiber = el[key];
    let depth = 0;
    while (fiber && depth < 60) {
      const src = fiber._debugSource;
      if (src && src.fileName) {
        let component = null;
        const owner = fiber._debugOwner || fiber;
        const t = owner && owner.type;
        if (typeof t === "function") component = t.displayName || t.name || null;
        else if (t && typeof t === "object") component = t.displayName || null;
        return {
          file: src.fileName,
          line: src.lineNumber ?? null,
          column: src.columnNumber ?? null,
          component,
        };
      }
      fiber = fiber.return || fiber._debugOwner;
      depth++;
    }
  } catch {
    /* ignore */
  }
  return null;
}

// Accessible name (cheap): aria-label → aria-labelledby text → alt → trimmed text.
export function a11yName(el, doc = globalThis.document) {
  try {
    const aria = el.getAttribute && el.getAttribute("aria-label");
    if (aria) return aria.trim();
    const labelledby = el.getAttribute && el.getAttribute("aria-labelledby");
    if (labelledby && doc) {
      const txt = labelledby
        .split(/\s+/)
        .map((id) => doc.getElementById(id)?.textContent || "")
        .join(" ")
        .trim();
      if (txt) return txt;
    }
    const alt = el.getAttribute && el.getAttribute("alt");
    if (alt) return alt.trim();
    const t = (el.textContent || "").trim().replace(/\s+/g, " ");
    return t.slice(0, 80);
  } catch {
    return "";
  }
}

export function ancestorChain(el, max = 4) {
  const chain = [];
  let node = el.parentElement;
  while (node && node.tagName && node.tagName.toLowerCase() !== "html" && chain.length < max) {
    let seg = node.tagName.toLowerCase();
    const first = (node.getAttribute && node.getAttribute("class") ? node.className : "")
      .toString()
      .trim()
      .split(/\s+/)
      .filter(Boolean)[0];
    if (first) seg += `.${first}`;
    chain.unshift(seg);
    node = node.parentElement;
  }
  return chain;
}

// Assemble the full annotation context for one pinned element.
export function extractContext(el, comment, win = globalThis) {
  const doc = win.document;
  const rect = el.getBoundingClientRect
    ? el.getBoundingClientRect()
    : { x: 0, y: 0, width: 0, height: 0 };
  const loc = win.location || { pathname: "", search: "", hash: "" };
  return {
    comment: String(comment || "").trim(),
    selector: buildSelector(el, doc),
    rect: {
      x: Math.round(rect.x ?? rect.left ?? 0),
      y: Math.round(rect.y ?? rect.top ?? 0),
      w: Math.round(rect.width ?? 0),
      h: Math.round(rect.height ?? 0),
    },
    route: `${loc.pathname || ""}${loc.search || ""}${loc.hash || ""}`,
    viewport: {
      w: win.innerWidth || 0,
      h: win.innerHeight || 0,
      dpr: win.devicePixelRatio || 1,
    },
    text: (el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 120),
    outerHTML: cappedOuterHTML(el),
    ancestors: ancestorChain(el),
    role: (el.getAttribute && el.getAttribute("role")) || el.tagName?.toLowerCase() || null,
    a11yName: a11yName(el, doc),
    source: findReactSource(el),
  };
}

// Decide how to reveal a pinned annotation: if its route matches the route the
// page is currently showing, reveal in place; otherwise a real navigation is
// needed. Kept pure (no DOM) so it can be unit-tested. `route` is the annotation's
// `pathname+search+hash`; an empty/missing route has nowhere to navigate, so it
// resolves in place.
export function revealPlan(annotationRoute, currentRoute) {
  const route = String(annotationRoute || "");
  return { mode: route && route !== currentRoute ? "navigate" : "inline", route };
}

// --- interactive UI (browser only) -----------------------------------------

function boot() {
  if (window.__ANNOTATE_UI_BOOTED__) return;
  window.__ANNOTATE_UI_BOOTED__ = true;

  const STORE_KEY = "annotate-ui.pending";
  const MIN_KEY = "annotate-ui.minimized"; // panel-minimised state, survives a reveal reload
  const REVEAL_KEY = "annotate-ui.reveal"; // survives a reload so a cross-route reveal can finish after boot
  const REVEAL_BOOT_TRIES = 14; // ~2s of 150ms retries — SPA views often mount after the overlay boots
  const state = {
    active: false,
    pending: loadPending(),
    minimized: loadMinimized(),
    lastMessageId: 0,
    hovered: null,
    editing: null, // index of the pending row currently being edited (or null)
  };
  let revealHideTimer = null;

  function loadPending() {
    try {
      return JSON.parse(sessionStorage.getItem(STORE_KEY) || "[]");
    } catch {
      return [];
    }
  }
  function savePending() {
    try {
      sessionStorage.setItem(STORE_KEY, JSON.stringify(state.pending));
    } catch {
      /* ignore */
    }
  }
  function loadMinimized() {
    try {
      return sessionStorage.getItem(MIN_KEY) === "1";
    } catch {
      return false;
    }
  }
  // Minimise the panel to just the bottom-right pill so the corner it occupies
  // is free to click-annotate; independent of annotate on/off. A ⤢ button on the
  // pill restores it. Persisted so a reveal-navigation reload keeps the state.
  function setMinimized(on) {
    state.minimized = on;
    try {
      sessionStorage.setItem(MIN_KEY, on ? "1" : "0");
    } catch {
      /* ignore */
    }
    applyPanelVisibility();
  }
  function applyPanelVisibility() {
    panel.style.display = state.minimized ? "none" : "block";
    restore.style.display = state.minimized ? "inline-flex" : "none";
  }

  // Shadow-DOM host so the app's CSS can never touch our UI (and vice-versa).
  const host = document.createElement("div");
  host.id = "annotate-ui-root";
  host.style.cssText = "all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647";
  document.documentElement.appendChild(host);
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = TEMPLATE;

  const isOurs = (node) => host.contains(node) || (node && node.getRootNode?.() === root);

  const highlight = root.getElementById("hl");
  const revealHl = root.getElementById("reveal-hl");
  const panel = root.getElementById("panel");
  const listEl = root.getElementById("list");
  const msgsEl = root.getElementById("msgs");
  const toggle = root.getElementById("toggle");
  const toggleLabel = root.getElementById("toggle-label");
  const restore = root.getElementById("restore");

  function setActive(on) {
    state.active = on;
    toggleLabel.textContent = on ? "● Annotating — Esc to stop" : "✎ Annotate";
    toggle.dataset.on = on ? "1" : "0";
    highlight.style.display = "none";
    document.body.style.cursor = on ? "crosshair" : "";
  }

  toggle.addEventListener("click", (e) => {
    e.stopPropagation();
    setActive(!state.active);
  });

  // "–" in the panel header minimises to the pill; "⤢" on the pill restores.
  // The restore click must not bubble to the toggle (which would flip annotate mode).
  root.getElementById("min").addEventListener("click", (e) => {
    e.stopPropagation();
    setMinimized(true);
  });
  restore.addEventListener("click", (e) => {
    e.stopPropagation();
    setMinimized(false);
  });

  window.addEventListener(
    "mousemove",
    (e) => {
      if (!state.active) return;
      // Alt/⌥ held → the next click drives the APP (pass-through), it won't
      // annotate. Drop the highlight + crosshair so that intent is visible.
      if (e.altKey) {
        highlight.style.display = "none";
        state.hovered = null;
        document.body.style.cursor = "";
        return;
      }
      document.body.style.cursor = "crosshair";
      const el = document.elementFromPoint(e.clientX, e.clientY);
      if (!el || isOurs(el)) {
        highlight.style.display = "none";
        state.hovered = null;
        return;
      }
      state.hovered = el;
      const r = el.getBoundingClientRect();
      Object.assign(highlight.style, {
        display: "block",
        left: r.left + "px",
        top: r.top + "px",
        width: r.width + "px",
        height: r.height + "px",
      });
    },
    true,
  );

  window.addEventListener(
    "click",
    (e) => {
      if (!state.active) return;
      // Alt/⌥+click passes straight through to the app, so you can operate it
      // (open a menu/popup, toggle a control) WITHOUT leaving annotate mode.
      // Then a plain click on the now-open UI annotates its contents.
      if (e.altKey) return;
      const el = document.elementFromPoint(e.clientX, e.clientY);
      if (!el || isOurs(el)) return;
      e.preventDefault();
      e.stopPropagation();
      // Snapshot the element's full context NOW — before the app (or opening our
      // own input) can dismiss a popup and detach the element. The typed comment
      // is folded into this snapshot on save.
      openPopover(extractContext(el, "", window), e.clientX, e.clientY);
    },
    true,
  );

  // Our own UI must never read as an "outside click" to the app: many popups
  // (e.g. the cache-control popover) close on an outside `mousedown`, which is
  // why clicking our toggle or comment input used to dismiss them. Stop any
  // mousedown that originates on the overlay from reaching the app, so an open
  // popup stays put while you annotate it. Scoped to our own targets only — the
  // app's own mousedowns are untouched (and Alt+click pass-through still works,
  // since its target is an app element, not ours).
  window.addEventListener(
    "mousedown",
    (e) => {
      if (isOurs(e.target)) e.stopPropagation();
    },
    true,
  );

  // Keep the crosshair/highlight in sync when Alt is pressed/released without
  // moving the mouse (mousemove handles the moving case).
  const syncAlt = (altHeld) => {
    if (!state.active) return;
    if (altHeld) {
      highlight.style.display = "none";
      document.body.style.cursor = "";
    } else {
      document.body.style.cursor = "crosshair";
    }
  };
  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && state.active) setActive(false);
    else if (e.key === "Alt") syncAlt(true);
  });
  window.addEventListener("keyup", (e) => {
    if (e.key === "Alt") syncAlt(false);
  });

  function openPopover(snapshot, x, y) {
    const pop = root.getElementById("popover");
    const input = root.getElementById("comment");
    pop.style.display = "block";
    pop.style.left = Math.min(x, window.innerWidth - 320) + "px";
    pop.style.top = Math.min(y, window.innerHeight - 160) + "px";
    input.value = "";
    setTimeout(() => input.focus(), 0);
    const save = () => {
      const comment = input.value.trim();
      if (comment) {
        // The context was snapshotted at pick time; just attach the comment.
        snapshot.comment = comment;
        state.pending.push(snapshot);
        savePending();
        renderList();
      }
      pop.style.display = "none";
    };
    root.getElementById("pop-save").onclick = save;
    root.getElementById("pop-cancel").onclick = () => (pop.style.display = "none");
    input.onkeydown = (ev) => {
      if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) save();
    };
  }

  function renderList() {
    applyPanelVisibility();
    listEl.innerHTML = "";
    state.pending.forEach((a, i) => {
      const row = document.createElement("div");
      row.className = "row";
      if (state.editing === i) {
        row.classList.add("editing");
        renderEditRow(row, a);
      } else {
        renderDisplayRow(row, a, i);
      }
      listEl.appendChild(row);
    });
    root.getElementById("count").textContent = String(state.pending.length);
    root.getElementById("send").disabled = state.pending.length === 0;
  }

  function renderDisplayRow(row, a, i) {
    const isNote = a.kind === "note";
    const cmt = document.createElement("div");
    cmt.className = "cmt";
    cmt.textContent = a.comment;
    const meta = document.createElement("div");
    meta.className = "meta";
    // Notes aren't tied to an element — label them instead of showing a selector.
    meta.textContent = isNote
      ? "note"
      : (a.source?.file ? a.source.file.split("/").pop() + ":" + a.source.line : a.selector) || "";

    const acts = document.createElement("div");
    acts.className = "acts";
    // Reveal only makes sense for element-pinned annotations, not freeform notes.
    if (!isNote) acts.append(mkActBtn("⌖", "Reveal in the app", () => revealAnnotation(a)));
    acts.append(
      mkActBtn("✎", "Edit comment", () => {
        state.editing = i;
        renderList();
      }),
      mkActBtn("✕", "Delete", () => {
        state.pending.splice(i, 1);
        if (state.editing === i) state.editing = null;
        savePending();
        renderList();
      }),
    );
    row.append(cmt, meta, acts);
  }

  function renderEditRow(row, a) {
    const ta = document.createElement("textarea");
    ta.className = "edit-input";
    ta.value = a.comment;
    const commit = () => {
      const v = ta.value.trim();
      if (v) a.comment = v; // empty edit keeps the original — use ✕ to remove
      state.editing = null;
      savePending();
      renderList();
    };
    const abort = () => {
      state.editing = null;
      renderList();
    };
    ta.onkeydown = (ev) => {
      if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) commit();
      else if (ev.key === "Escape") {
        ev.stopPropagation(); // don't let Escape also toggle annotate-mode off
        abort();
      }
    };
    const btns = document.createElement("div");
    btns.className = "ebtns";
    const cancel = document.createElement("button");
    cancel.className = "ecancel";
    cancel.textContent = "Cancel";
    cancel.onclick = abort;
    const save = document.createElement("button");
    save.className = "esave";
    save.textContent = "Save";
    save.onclick = commit;
    btns.append(cancel, save);
    row.append(ta, btns);
    setTimeout(() => ta.focus(), 0);
  }

  function mkActBtn(glyph, title, onClick) {
    const b = document.createElement("button");
    b.textContent = glyph;
    b.title = title;
    b.onclick = onClick;
    return b;
  }

  // Freeform-note composer: a small textarea at the panel bottom that grows with
  // its content. ⌘/Ctrl+Enter adds the typed text as a note (kind:"note", no
  // element binding) into the same list, then resets the box.
  const composer = root.getElementById("composer");
  function growComposer() {
    composer.style.height = "auto";
    composer.style.height = Math.min(composer.scrollHeight, 160) + "px";
  }
  function resetComposer() {
    composer.value = "";
    composer.style.height = "";
  }
  function addNote() {
    const text = composer.value.trim();
    if (!text) return;
    state.pending.push({ kind: "note", comment: text });
    savePending();
    resetComposer();
    renderList();
  }
  composer.addEventListener("input", growComposer);
  composer.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
      ev.preventDefault();
      addNote();
    }
  });

  // Reveal a pinned element: highlight it in place when it's on the current
  // route, otherwise navigate to its route (a real reload — pending annotations
  // survive it) and finish the reveal on the next boot via REVEAL_KEY.
  function revealAnnotation(a) {
    const currentRoute = `${location.pathname}${location.search}${location.hash}`;
    const plan = revealPlan(a.route, currentRoute);
    if (plan.mode === "navigate") {
      try {
        sessionStorage.setItem(REVEAL_KEY, JSON.stringify({ route: plan.route, selector: a.selector }));
      } catch {
        /* ignore */
      }
      location.assign(plan.route);
      return;
    }
    revealBySelector(a.selector, 1);
  }

  // Find `selector`, scroll it to center, and flash the reveal highlight over it.
  // Retries a few times (150ms apart) so a freshly-reloaded SPA view has time to
  // mount; flashes a message if it never resolves.
  function revealBySelector(selector, tries) {
    let attempt = 0;
    const tick = () => {
      let el = null;
      try {
        el = selector ? document.querySelector(selector) : null;
      } catch {
        el = null; // stale/invalid selector — treat as not found
      }
      if (el && !isOurs(el)) {
        highlight.style.display = "none";
        el.scrollIntoView({ behavior: "auto", block: "center", inline: "center" });
        const r = el.getBoundingClientRect();
        Object.assign(revealHl.style, {
          display: "block",
          left: r.left + "px",
          top: r.top + "px",
          width: r.width + "px",
          height: r.height + "px",
        });
        // Restart the fade animation even if the box is reused for a second reveal.
        revealHl.style.animation = "none";
        void revealHl.offsetWidth; // force reflow
        revealHl.style.animation = "";
        clearTimeout(revealHideTimer);
        revealHideTimer = setTimeout(() => (revealHl.style.display = "none"), 2000);
        return;
      }
      if (++attempt < tries) {
        setTimeout(tick, 150);
      } else {
        flash("Couldn't find that element on this page", true);
      }
    };
    tick();
  }

  // After a cross-route reveal reloads the page, finish the reveal here.
  function consumeRevealTarget() {
    let target = null;
    try {
      const raw = sessionStorage.getItem(REVEAL_KEY);
      if (raw) target = JSON.parse(raw);
      sessionStorage.removeItem(REVEAL_KEY);
    } catch {
      target = null;
    }
    if (!target || !target.selector) return;
    const currentRoute = `${location.pathname}${location.search}${location.hash}`;
    if (target.route && target.route !== currentRoute) return; // landed somewhere else — don't guess
    revealBySelector(target.selector, REVEAL_BOOT_TRIES);
  }

  root.getElementById("send").addEventListener("click", async () => {
    if (!state.pending.length) return;
    const batch = state.pending;
    try {
      const res = await fetch(PREFIX + "submit", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ annotations: batch }),
      });
      if (res.ok) {
        state.pending = [];
        savePending();
        renderList();
        flash("Sent to agent ✓");
      } else {
        flash("Send failed", true);
      }
    } catch {
      flash("Send failed (proxy down?)", true);
    }
  });

  function flash(text, bad) {
    const f = root.getElementById("flash");
    f.textContent = text;
    f.style.color = bad ? "#ff9d9d" : "#9dffb0";
    f.style.opacity = "1";
    setTimeout(() => (f.style.opacity = "0"), 2200);
  }

  // Poll agent replies and show them in the panel.
  async function pollMessages() {
    try {
      const res = await fetch(PREFIX + "messages?since=" + state.lastMessageId);
      if (res.ok) {
        const { messages } = await res.json();
        for (const m of messages) {
          state.lastMessageId = Math.max(state.lastMessageId, m.id);
          const div = document.createElement("div");
          div.className = "msg";
          div.textContent = "🤖 " + m.message;
          msgsEl.appendChild(div);
          msgsEl.scrollTop = msgsEl.scrollHeight;
        }
      }
    } catch {
      /* ignore */
    }
    setTimeout(pollMessages, 3000);
  }

  setActive(false);
  renderList();
  pollMessages();
  consumeRevealTarget();
}

const TEMPLATE = `
<style>
  :host { all: initial; }
  * { box-sizing: border-box; font-family: ui-sans-serif, system-ui, sans-serif; }
  #hl { position: fixed; display:none; pointer-events:none; border:2px solid #6ea8fe;
        background:rgba(110,168,254,.15); border-radius:3px; z-index:2 }
  #reveal-hl { position: fixed; display:none; pointer-events:none; border:2px solid #ffc15e;
        border-radius:3px; z-index:3; animation: reveal-pulse 2s ease-out forwards }
  @keyframes reveal-pulse {
    0%   { box-shadow:0 0 0 3px rgba(255,193,94,.9); background:rgba(255,193,94,.28) }
    70%  { box-shadow:0 0 0 3px rgba(255,193,94,.7); background:rgba(255,193,94,.18) }
    100% { box-shadow:0 0 0 3px rgba(255,193,94,0);  background:rgba(255,193,94,0) }
  }
  #toggle { position: fixed; right:16px; bottom:16px; pointer-events:auto; z-index:5;
        display:inline-flex; align-items:center; gap:8px;
        background:#1b1e24; color:#e8eaed; border:1px solid #3a3f47; border-radius:20px;
        padding:8px 14px; font-size:13px; cursor:pointer; box-shadow:0 4px 14px rgba(0,0,0,.4) }
  #toggle[data-on="1"] { background:#2b5fd0; border-color:#2b5fd0; color:#fff }
  #restore { display:none; align-items:center; justify-content:center; font-size:15px; line-height:1;
        padding-left:8px; margin-left:2px; border-left:1px solid rgba(255,255,255,.25); cursor:pointer }
  #panel { position: fixed; right:16px; bottom:60px; width:320px; max-height:60vh; overflow:auto;
        pointer-events:auto; z-index:5; background:#14161b; color:#e8eaed; border:1px solid #3a3f47;
        border-radius:10px; padding:10px; box-shadow:0 8px 28px rgba(0,0,0,.5); font-size:13px }
  #phead { display:flex; align-items:center; justify-content:space-between; margin-bottom:6px }
  #panel h4 { margin:0; font-size:12px; color:#9aa0a6; font-weight:600 }
  #min { background:none; border:none; color:#8b9199; cursor:pointer; font-size:18px; line-height:1;
        padding:0 4px; border-radius:4px }
  #min:hover { color:#e8eaed; background:#24272e }
  #hint { margin:-2px 0 8px; font-size:11px; line-height:1.35; color:#6b7178 }
  #hint b { color:#9aa0a6; font-weight:600 }
  .row { display:grid; grid-template-columns:1fr auto; gap:2px 8px; padding:6px 0;
        border-top:1px solid #24272e; align-items:center }
  .row .cmt { grid-column:1; }
  .row .meta { grid-column:1; color:#8b9199; font-size:11px; font-family:ui-monospace,monospace;
        overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
  .row .acts { grid-column:2; grid-row:1/3; display:flex; gap:2px; align-items:center }
  .row .acts button { background:none; border:none; color:#8b9199; cursor:pointer; font-size:13px;
        padding:2px 3px; line-height:1; border-radius:4px }
  .row .acts button:hover { color:#e8eaed; background:#24272e }
  .row.editing { grid-template-columns:1fr }
  .edit-input { grid-column:1; width:100%; height:52px; resize:vertical; background:#0e1013;
        color:#e8eaed; border:1px solid #3a3f47; border-radius:6px; padding:6px; font-size:13px }
  .ebtns { grid-column:1; display:flex; justify-content:flex-end; gap:8px; margin-top:6px }
  .ebtns button { border:none; border-radius:6px; padding:5px 10px; cursor:pointer }
  .esave { background:#2b5fd0; color:#fff }
  .ecancel { background:#2a2d33; color:#e8eaed }
  #composer { width:100%; min-height:34px; max-height:160px; resize:none; overflow:auto;
        margin-top:8px; background:#0e1013; color:#e8eaed; border:1px solid #3a3f47;
        border-radius:6px; padding:7px 8px; font-size:13px; font-family:inherit; line-height:1.4 }
  #composer::placeholder { color:#6b7178 }
  #actions { display:flex; align-items:center; gap:8px; margin-top:8px }
  #send { background:#2b5fd0;color:#fff;border:none;border-radius:6px;padding:7px 12px;cursor:pointer }
  #send:disabled { background:#2a2d33; color:#6b7178; cursor:default }
  #flash { font-size:12px; opacity:0; transition:opacity .2s }
  #msgs { margin-top:8px; max-height:120px; overflow:auto }
  .msg { background:#10233a; border:1px solid #1d3a5c; border-radius:6px; padding:5px 8px;
        margin-top:4px; font-size:12px }
  #popover { position:fixed; display:none; width:300px; pointer-events:auto; z-index:6;
        background:#14161b; color:#e8eaed; border:1px solid #3a3f47; border-radius:8px; padding:10px;
        box-shadow:0 8px 28px rgba(0,0,0,.5) }
  #comment { width:100%; height:64px; resize:vertical; background:#0e1013; color:#e8eaed;
        border:1px solid #3a3f47; border-radius:6px; padding:6px; font-size:13px }
  #popover .pbtns { display:flex; justify-content:flex-end; gap:8px; margin-top:8px }
  #popover button { border:none; border-radius:6px; padding:6px 10px; cursor:pointer }
  #pop-save { background:#2b5fd0; color:#fff }
  #pop-cancel { background:#2a2d33; color:#e8eaed }
</style>
<div id="hl"></div>
<div id="reveal-hl"></div>
<button id="toggle"><span id="toggle-label">✎ Annotate</span><span id="restore" title="Restore panel">⤢</span></button>
<div id="panel">
  <div id="phead">
    <h4>Annotations (<span id="count">0</span>)</h4>
    <button id="min" title="Minimise">–</button>
  </div>
  <div id="hint"><b>Alt/⌥-click</b> to use the app (open menus &amp; popups), then click inside to annotate.</div>
  <div id="list"></div>
  <textarea id="composer" rows="1" placeholder="Add a note… (⌘/Ctrl+Enter)"></textarea>
  <div id="actions"><button id="send" disabled>Send to agent</button><span id="flash"></span></div>
  <div id="msgs"></div>
</div>
<div id="popover">
  <textarea id="comment" placeholder="What needs fixing here? (⌘/Ctrl+Enter to save)"></textarea>
  <div class="pbtns"><button id="pop-cancel">Cancel</button><button id="pop-save">Add</button></div>
</div>
`;

if (typeof document !== "undefined" && typeof window !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
}
