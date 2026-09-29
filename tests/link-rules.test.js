// Slice 5b0 (Task 4): LinkRules.js, the link and text rules Search and RSS
// share, against every row of tests/fixtures/link-rules-cases.json.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// LinkRules.js starts with a QML-only `.pragma library` line, which node
// can't parse. Strip it and run the file as a function body
// (tests/settings-view.test.js's loader).
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

const L = load("LinkRules.js", [], []);
const fixture = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8"));
const LINK = fixture("link-rules-cases.json");
const SEARCH = fixture("search-rules-cases.json");

for (const kind of ["pageLink", "magnetHash"]) {
  test("link case file: every " + kind + " row", () => {
    const rows = LINK.cases.filter((c) => c.kind === kind);
    assert.ok(rows.length > 0);
    for (const c of rows) {
      const label = c.why + " " + JSON.stringify(c.input).slice(0, 120);
      const got = L.check(kind, c.input);
      assert.equal(got.ok, c.ok, label);
      if (!c.ok && "message" in c) assert.equal(got.message, c.message, label);
      if ("normalised" in c) assert.deepEqual(got.normalised, c.normalised, label);
      if ("host" in c) assert.equal(got.host, c.host, label);
    }
  });
}

test("no case kind lives in both files", () => {
  const kinds = (d) => new Set(d.cases.map((c) => c.kind));
  const a = kinds(SEARCH), b = kinds(LINK);
  for (const k of b) assert.ok(!a.has(k), k);
});

test("every link message is a link case-file message", () => {
  const messages = new Set(LINK.cases.filter((c) => c.message).map((c) => c.message));
  for (const [k, m] of Object.entries(L.MSG_LINK)) assert.ok(messages.has(m), "MSG_LINK." + k + ": " + m);
});

test("the shared helpers are exported", () => {
  for (const n of ["codePoints", "punycode", "splitUrl", "portOk", "hostOf", "startsWithCi", "qtTrim", "cleanName", "plainText",
    "base32Hex", "magnetHash", "checkPageLink", "librarySet", "inLibrary", "refuse", "fill", "check"]) {
    assert.equal(typeof L[n], "function", n);
  }
  for (const n of ["BAD", "BIDI", "CONTROLS", "CONTROL", "QT_SPACE"]) assert.ok(L[n] instanceof RegExp, n);
});
