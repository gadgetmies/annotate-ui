// Tests for the overlay's pure context-extraction helpers, using a tiny fake
// DOM (no jsdom — zero dependencies). Importing overlay.js must NOT boot the UI
// because there is no global `document`.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  findReactSource,
  buildSelector,
  extractContext,
  cappedOuterHTML,
  revealPlan,
  mergeChangelog,
  buildVerificationItem,
  applyRowState,
} from "../overlay.js";

// --- minimal fake element ---------------------------------------------------

function makeEl(opts = {}) {
  const el = {
    nodeType: 1,
    tagName: (opts.tag || "div").toUpperCase(),
    attrs: opts.attrs || {},
    className: opts.className || "",
    id: opts.id || "",
    childNodes: opts.childNodes || [],
    parentElement: null,
    children: [],
    textContent: opts.text || "",
    getAttribute(name) {
      if (name === "class") return this.className || null;
      return name in this.attrs ? this.attrs[name] : null;
    },
    getBoundingClientRect() {
      return opts.rect || { x: 10, y: 20, width: 30, height: 40 };
    },
    cloneNode() {
      return {
        outerHTML: `<${(opts.tag || "div")}${opts.className ? ` class="${opts.className}"` : ""}></${opts.tag || "div"}>`,
        set textContent(v) {
          this.outerHTML = this.outerHTML.replace(/><\//, `>${v}</`);
        },
      };
    },
  };
  return el;
}

test("findReactSource walks the fiber to _debugSource", () => {
  const el = makeEl({ tag: "button" });
  const leaf = { _debugSource: null, return: null };
  const parent = {
    _debugSource: { fileName: "src/components/MixRow.tsx", lineNumber: 42, columnNumber: 6 },
    _debugOwner: { type: function MixRow() {} },
    return: null,
  };
  leaf.return = parent;
  el["__reactFiber$abc"] = leaf;

  const src = findReactSource(el);
  assert.equal(src.file, "src/components/MixRow.tsx");
  assert.equal(src.line, 42);
  assert.equal(src.column, 6);
  assert.equal(src.component, "MixRow");
});

test("findReactSource returns null for a non-React element (never throws)", () => {
  assert.equal(findReactSource(makeEl()), null);
  assert.equal(findReactSource({}), null);
});

test("buildSelector widens until unique against the doc", () => {
  const btn = makeEl({ tag: "button", className: "star-btn" });
  // Fake document: the tag-only selector matches 3, the id selector matches 1.
  const doc = {
    querySelectorAll(sel) {
      if (sel.includes("#")) return [1];
      return [1, 2, 3];
    },
  };
  const parent = makeEl({ tag: "section", id: "feed" });
  parent.children = [btn];
  btn.parentElement = parent;
  const sel = buildSelector(btn, doc);
  assert.match(sel, /#feed/); // widened up to the unique ancestor id
});

test("cappedOuterHTML collapses children and caps length", () => {
  const el = makeEl({ tag: "button", className: "x", childNodes: [{}, {}] });
  const html = cappedOuterHTML(el, 500);
  assert.match(html, /^<button/);
  assert.ok(html.length <= 500);
});

test("revealPlan returns inline when the annotation route matches the current route", () => {
  assert.deepEqual(revealPlan("/feed?tab=hot", "/feed?tab=hot"), { mode: "inline", route: "/feed?tab=hot" });
});

test("revealPlan returns navigate when the routes differ", () => {
  assert.deepEqual(revealPlan("/settings", "/feed"), { mode: "navigate", route: "/settings" });
});

test("revealPlan treats a missing annotation route as inline (nothing to navigate to)", () => {
  assert.deepEqual(revealPlan("", "/feed"), { mode: "inline", route: "" });
  assert.deepEqual(revealPlan(undefined, "/feed"), { mode: "inline", route: "" });
});

test("extractContext produces the full baseline payload", () => {
  const el = makeEl({ tag: "button", className: "star-btn", text: "  ★  ", attrs: { role: "button", "aria-label": "Rate 3 stars" } });
  const win = {
    document: { querySelectorAll: () => [1] },
    location: { pathname: "/feed", search: "", hash: "" },
    innerWidth: 1440,
    innerHeight: 900,
    devicePixelRatio: 2,
  };
  const ctx = extractContext(el, "  too dim  ", win);
  assert.equal(ctx.comment, "too dim");
  assert.equal(ctx.route, "/feed");
  assert.deepEqual(ctx.viewport, { w: 1440, h: 900, dpr: 2 });
  assert.deepEqual(ctx.rect, { x: 10, y: 20, w: 30, h: 40 });
  assert.equal(ctx.text, "★");
  assert.equal(ctx.role, "button");
  assert.equal(ctx.a11yName, "Rate 3 stars");
  assert.equal(ctx.source, null);
  assert.ok("outerHTML" in ctx && "ancestors" in ctx && "selector" in ctx);
});

// --- changelog verification helpers ----------------------------------------

test("mergeChangelog appends new entries and de-dupes by id (existing wins)", () => {
  const first = mergeChangelog([], [
    { id: "c1", title: "Star gold", description: "d", context: { selector: ".s" } },
    { id: "c2", title: "Debounced" },
  ]);
  assert.equal(first.length, 2);
  assert.equal(first[1].description, ""); // normalised default
  assert.equal(first[1].context, null);
  // A re-delivered c1 (even with a different title) must not clobber the existing.
  const merged = mergeChangelog(first, [{ id: "c1", title: "CHANGED" }, { id: "c3", title: "New" }]);
  assert.equal(merged.length, 3);
  assert.equal(merged.find((e) => e.id === "c1").title, "Star gold");
});

test("buildVerificationItem carries kind/changelogId/comment over its context", () => {
  const item = buildVerificationItem("c1", "  still orange  ", {
    selector: ".rating > svg",
    route: "/movie/42",
    source: { file: "src/Rating.tsx", line: 18 },
    comment: "", // a raw extractContext snapshot has an empty comment — must not win
  });
  assert.equal(item.kind, "verification");
  assert.equal(item.changelogId, "c1");
  assert.equal(item.comment, "still orange"); // trimmed, and overrides context.comment
  assert.equal(item.selector, ".rating > svg");
  assert.equal(item.route, "/movie/42");
});

test("applyRowState creates, replaces, and removes a verification item by changelogId", () => {
  // Rejected with a comment → one verification item appears.
  let pending = applyRowState([], "c1", "rejected", "bad", { selector: ".x" });
  assert.equal(pending.length, 1);
  assert.equal(pending[0].kind, "verification");
  assert.equal(pending[0].changelogId, "c1");
  // Editing the comment replaces (never duplicates) the same-id item.
  pending = applyRowState(pending, "c1", "rejected", "still bad", { selector: ".x" });
  assert.equal(pending.filter((p) => p.changelogId === "c1").length, 1);
  assert.equal(pending[0].comment, "still bad");
  // Verified removes it.
  pending = applyRowState(pending, "c1", "verified", "", { selector: ".x" });
  assert.equal(pending.length, 0);
  // An empty rejection comment also drops it (nothing to send yet).
  pending = applyRowState([{ kind: "verification", changelogId: "c1", comment: "x" }], "c1", "rejected", "   ", null);
  assert.equal(pending.length, 0);
});

test("applyRowState leaves pins and notes untouched (mixed queue stays one array)", () => {
  const base = [
    { comment: "a pin", selector: "button.x" },
    { kind: "note", comment: "a note" },
  ];
  const pending = applyRowState(base, "c1", "rejected", "an issue", { selector: ".y" });
  assert.equal(pending.length, 3);
  assert.equal(pending.filter((p) => p.kind === "verification").length, 1);
  assert.equal(pending.filter((p) => p.kind === "note").length, 1);
  assert.equal(pending.filter((p) => !p.kind).length, 1); // the pin, unchanged
});
