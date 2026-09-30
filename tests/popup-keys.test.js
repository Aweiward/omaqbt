// Discoverability Task 1: PopupKeys.js, the popup's key routing and its
// "Open the window" entry point (Review Focus 1-3).
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// tests/search-view.test.js's loader: strip .pragma/.import, run as a module.
function load(name, params, args) {
  const file = path.join(__dirname, "..", name);
  const src = fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module"].concat(params), { filename: file })(mod, ...args);
  return mod.exports;
}

const K = load("PopupKeys.js", [], []);
const action = (sig, arg, state) => K.route(sig, arg, state).action;

// ---- copy -------------------------------------------------------------------------------

test("the row's copy and the fallback note", () => {
  assert.equal(K.ROW_LABEL, "Open the window");
  assert.equal(K.ROW_KEY, "w");
  assert.equal(K.FALLBACK_NOTE, "Open the window with: omarchy-shell shell toggle aweiward.omaqbt");
  assert.doesNotMatch(K.ROW_LABEL + K.FALLBACK_NOTE, /panel/i, "user-facing copy never says panel");
});

// ---- w ----------------------------------------------------------------------------------

test("w opens the window from the list view only", () => {
  assert.equal(action("text", "w", { view: "list" }), "openWindow");
  assert.equal(action("text", "w", { view: "list", section: "rows", cursorActive: true }), "openWindow");
  assert.equal(action("text", "w", { view: "detail" }), "none");
});

test("w is ignored while a browser magnet confirm owns the keys (Review Focus 3)", () => {
  assert.equal(action("text", "w", { view: "list", magnetConfirmOpen: true }), "none");
  assert.equal(action("text", "w", { view: "list", section: "magnetConfirm", magnetConfirmOpen: true }), "none");
});

test("other text keys pass through to handleTextKey unchanged", () => {
  for (const t of ["t", "/", "y", "m", "e", "r", "a", "p", "c", "*", "s", "z", "o", "W"]) {
    const r = K.route("text", t, { view: "list" });
    assert.equal(r.action, "text", t);
    assert.deepEqual(r.args, [t], t);
  }
});

// ---- x / X ------------------------------------------------------------------------------

test("x removes and X deletes files on the list row under the cursor", () => {
  assert.equal(action("delete", "x", { view: "list", section: "rows" }), "remove");
  assert.equal(action("delete", "X", { view: "list", section: "rows" }), "deleteFiles");
});

test("x and X in the detail view keep handleTextKey's meaning", () => {
  // Panel.qml dispatches remove -> handleTextKey("x") and deleteFiles -> handleTextKey("X"),
  // so the detail view's x skips the selected file (README) and X asks to delete the detail torrent.
  for (const section of ["remove", "files", "copyMagnet", "deleteFiles"]) {
    assert.equal(action("delete", "x", { view: "detail", section }), "remove", section);
    assert.equal(action("delete", "X", { view: "detail", section }), "deleteFiles", section);
  }
});

test("x and X do nothing with no cursor row", () => {
  for (const section of ["header", "window", "clipboard", "install", "daemon", undefined]) {
    assert.equal(action("delete", "x", { view: "list", section }), "none", String(section));
    assert.equal(action("delete", "X", { view: "list", section }), "none", String(section));
  }
});

test("x and X do nothing while a magnet confirm waits, or when the key is unknown", () => {
  assert.equal(action("delete", "x", { view: "list", section: "rows", magnetConfirmOpen: true }), "none");
  assert.equal(action("delete", "X", { view: "list", section: "rows", magnetConfirmOpen: true }), "none");
  assert.equal(action("delete", "", { view: "list", section: "rows" }), "none");
  assert.equal(action("delete", undefined, { view: "list", section: "rows" }), "none");
});

test("deleteKey reads the delete key's case from the last key press", () => {
  assert.equal(K.deleteKey("x", false), "x");
  assert.equal(K.deleteKey("X", false), "X");
  assert.equal(K.deleteKey("X", true), "X");
  assert.equal(K.deleteKey("x", true), "X", "Shift+x is X");
  assert.equal(K.deleteKey("", false), "");
  assert.equal(K.deleteKey("q", false), "");
  assert.equal(K.deleteKey(undefined, false), "");
});

// ---- h / Left ---------------------------------------------------------------------------

test("h (move -1,0) goes back in the detail view", () => {
  assert.equal(action("move", { dx: -1, dy: 0 }, { view: "detail" }), "back");
  assert.equal(action("move", { dx: -1, dy: 0 }, { view: "detail", section: "files", cursorActive: false }), "back");
});

test("h stays a cursor move (a no-op) in the list view, and other moves are unchanged", () => {
  const r = K.route("move", { dx: -1, dy: 0 }, { view: "list", section: "rows" });
  assert.equal(r.action, "moveCursor");
  assert.deepEqual(r.args, [-1, 0]);
  assert.deepEqual(K.route("move", { dx: 0, dy: 1 }, { view: "detail" }), { action: "moveCursor", args: [0, 1] });
  assert.deepEqual(K.route("move", { dx: 1, dy: 0 }, { view: "detail" }), { action: "moveCursor", args: [1, 0] });
  assert.deepEqual(K.route("move", { dx: 0, dy: -1 }, { view: "list" }), { action: "moveCursor", args: [0, -1] });
});

// ---- activate / close -------------------------------------------------------------------

test("Enter on the window row opens the window", () => {
  assert.equal(action("activate", null, { view: "list", section: "window" }), "openWindow");
});

test("activate otherwise keeps today's behaviour", () => {
  assert.equal(action("activate", null, { view: "list", section: "rows" }), "activateCursor");
  assert.equal(action("activate", null, { view: "list", section: "header" }), "activateCursor");
  assert.equal(action("activate", null, { view: "detail", section: "remove" }), "activateCursor");
  assert.equal(action("activate", null, { view: "list", section: "window", magnetConfirmOpen: true }), "startMagnet");
  assert.equal(action("activate", null, { view: "list", section: "rows", magnetConfirmOpen: true }), "startMagnet");
});

test("close cancels a waiting magnet first, else closes", () => {
  assert.equal(action("close", null, { view: "list", magnetConfirmOpen: true }), "cancelMagnet");
  assert.equal(action("close", null, { view: "list" }), "close");
  assert.equal(action("close", null, { view: "detail" }), "close");
});

test("an unknown signal does nothing", () => {
  assert.equal(action("tab", 1, { view: "list" }), "none");
  assert.deepEqual(K.route("move", null, { view: "detail" }), { action: "moveCursor", args: [0, 0] });
});

// ---- blocked (a field focused, the delete confirm open): state x key table (Review Focus 1)

test("nothing but none while the catcher is blocked", () => {
  const signals = [
    ["text", "w"], ["text", "t"], ["text", "/"], ["delete", "x"], ["delete", "X"],
    ["move", { dx: -1, dy: 0 }], ["move", { dx: 0, dy: 1 }], ["activate", null], ["close", null]
  ];
  const states = [];
  for (const view of ["list", "detail"])
    for (const section of ["header", "window", "clipboard", "rows", "magnetConfirm", "remove", "files"])
      for (const magnetConfirmOpen of [false, true])
        for (const cursorActive of [false, true])
          states.push({ view, section, blocked: true, magnetConfirmOpen, cursorActive });
  for (const s of states)
    for (const [sig, arg] of signals)
      assert.deepEqual(K.route(sig, arg, s), { action: "none", args: [] }, sig + " " + JSON.stringify(arg) + " " + JSON.stringify(s));
});

test("route tolerates a missing state", () => {
  assert.equal(action("text", "w", null), "openWindow");
  assert.equal(action("delete", "x", undefined), "none");
});

// ---- openWindow (Review Focus 2) --------------------------------------------------------

test("openWindow summons the window once", () => {
  const calls = [];
  const r = K.openWindow({ summon: (...a) => calls.push(a) });
  assert.deepEqual(calls, [["aweiward.omaqbt", ""]]);
  assert.equal(r.ok, true);
  assert.equal(r.note, "");
});

test("openWindow runs beforeSummon (the popup close) first, and only when it can summon", () => {
  const order = [];
  const r = K.openWindow({ summon: () => order.push("summon") }, () => order.push("close"));
  assert.deepEqual(order, ["close", "summon"]);
  assert.equal(r.ok, true);

  let closed = 0;
  const missing = K.openWindow({}, () => closed++);
  assert.equal(closed, 0, "the popup stays open when the shell cannot summon");
  assert.deepEqual(missing, { ok: false, note: K.FALLBACK_NOTE });
});

test("openWindow with no shell API shows the fallback note and never throws", () => {
  assert.deepEqual(K.openWindow(null), { ok: false, note: K.FALLBACK_NOTE });
  assert.deepEqual(K.openWindow(undefined), { ok: false, note: K.FALLBACK_NOTE });
  assert.deepEqual(K.openWindow({}), { ok: false, note: K.FALLBACK_NOTE });
  assert.deepEqual(K.openWindow({ summon: "not a function" }), { ok: false, note: K.FALLBACK_NOTE });
  assert.deepEqual(K.openWindow({ summon: () => { throw new Error("gone"); } }), { ok: false, note: K.FALLBACK_NOTE });
});
