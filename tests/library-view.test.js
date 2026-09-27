const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Model = require("../Model.js");

// LibraryView.js starts with QML-only `.pragma library` / `.import
// "Model.js" as Model` lines, which node can't parse. Strip them and run
// the rest as a function body in this realm, with `Model` supplied exactly
// as QML would (tests/inspector-view.test.js's loader, copied).
function loadLibraryView() {
  const file = path.join(__dirname, "..", "LibraryView.js");
  const src = fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module", "Model"], { filename: file })(mod, Model);
  return mod.exports;
}

const L = loadLibraryView();
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "validation-cases.json"), "utf8"));
const H = (c) => c.repeat(40);

function row(overrides) {
  return Object.assign({ hash: H("a"), category: "", tags: [], autoTmm: true, savePath: "/dl" }, overrides || {});
}

function status(overrides) {
  return Object.assign({
    defaultSavePath: "/dl",
    categoryPaths: {},
    relocation: { torrentChanged: true, categoryPathChanged: true }
  }, overrides || {});
}

// --- nameError (G4, OV5; shared with qbt) -----------------------------------

test("nameError gives exactly the shared fixture's message for every case (parity with qbt)", () => {
  assert.ok(CASES.names.length > 50);
  for (const c of CASES.names) {
    assert.equal(L.nameError(c.kind, c.input, []), c.error, c.kind + ": " + c.why);
    assert.equal(c.ok, c.error === "", c.why);
  }
});

test("nameError refuses a clash with an existing name, quoted, only after the rules pass", () => {
  assert.equal(L.nameError("category", "linux-isos", ["anime", "linux-isos"]), "\"linux-isos\" already exists.");
  assert.equal(L.nameError("tag", "keep", ["keep"]), "\"keep\" already exists.");
  assert.equal(L.nameError("tag", "Keep", ["keep"]), "", "names are case-sensitive, like qBittorrent's");
  assert.equal(L.nameError("category", "anime/", ["anime/"]), "A category can't start or end with /.");
  assert.equal(L.nameError("category", "anime", undefined), "");
  assert.equal(L.nameError("category", "anime", null), "");
});

test("nameError: every character qbt treats as an edge space, and nothing JS \\s adds", () => {
  const spaces = [0x20, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
    0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000];
  for (const cp of spaces) {
    const sp = String.fromCodePoint(cp);
    assert.equal(L.nameError("tag", sp + "a", []), "No spaces at the start or end.", cp.toString(16));
    assert.equal(L.nameError("category", "a" + sp, []), "No spaces at the start or end.", cp.toString(16));
    assert.equal(L.nameError("tag", "a" + sp + "b", []), "", "inner " + cp.toString(16));
  }
  // \s also matches U+FEFF; qbt's list (QString::trimmed) doesn't.
  assert.equal(L.nameError("tag", "﻿a", []), "");
  assert.equal(L.nameError("tag", "a​", []), "", "zero-width space isn't trimmed");
});

test("nameError: every control character, C0, DEL and C1, including U+0000", () => {
  for (let cp = 0; cp <= 0x1f; cp++) assert.equal(L.nameError("tag", "a" + String.fromCharCode(cp), []), "No control characters in a name.", cp.toString(16));
  assert.equal(L.nameError("tag", "a\u007f", []), "No control characters in a name.");
  for (let cp = 0x80; cp <= 0x9f; cp++) assert.equal(L.nameError("category", String.fromCharCode(cp) + "a", []), "No control characters in a name.", cp.toString(16));
  assert.equal(L.nameError("category", "a¡", []), "");
});

test("nameError counts code points, not UTF-16 units", () => {
  assert.equal(L.nameError("tag", "\u{1F600}".repeat(64), []), "");
  assert.equal(L.nameError("tag", "\u{1F600}".repeat(65), []), "Keep it to 64 characters.");
});

test("nameError treats a missing text as empty", () => {
  assert.equal(L.nameError("tag", undefined, []), "Type a name.");
  assert.equal(L.nameError("tag", null, []), "Type a name.");
});

// --- renameError (ruling BG) --------------------------------------------------

test("renameError refuses a rename into the old name's own subcategory", () => {
  assert.equal(L.renameError("anime", "anime/2026", ["anime"]), "Can't rename anime into its own subcategory.");
  assert.equal(L.renameError("anime", "anime/2026/deep", ["anime"]), "Can't rename anime into its own subcategory.");
});

test("renameError refuses an old name that has subcategories", () => {
  assert.equal(L.renameError("anime", "cartoons", ["anime", "anime/2026"]), "anime has subcategories; rename or remove them first.");
  assert.equal(L.renameError("anime", "anime/x", ["anime", "anime/2026"]), "Can't rename anime into its own subcategory.", "the subcategory check comes first, like qbt");
});

test("renameError allows a leaf, a sibling prefix and a rename up out of a parent", () => {
  assert.equal(L.renameError("anime/2026", "anime/2027", ["anime", "anime/2026"]), "");
  assert.equal(L.renameError("anime", "animation", ["anime", "animes", "anime-old"]), "", "anime-old and animes aren't subcategories");
  assert.equal(L.renameError("anime/2026", "anime", ["anime", "anime/2026"]), "");
  assert.equal(L.renameError("anime", "animes", undefined), "");
});

// --- parentCategoryName -------------------------------------------------------

test("parentCategoryName is the part before the last /, or \"\"", () => {
  assert.equal(L.parentCategoryName("anime"), "");
  assert.equal(L.parentCategoryName("anime/2026"), "anime");
  assert.equal(L.parentCategoryName("a/b/c"), "a/b");
  assert.equal(L.parentCategoryName(""), "");
});

// --- categorySavePath -----------------------------------------------------------

test("categorySavePath: empty = <default>/<name>, explicit as-is, \"\" = the default", () => {
  const st = status({ defaultSavePath: "/dl/", categoryPaths: {
    anime: { savePath: "", downloadPath: "" },
    linux: { savePath: "/srv/linux/", downloadPath: "" },
    rel: { savePath: "sub/dir", downloadPath: "" },
    junk: "not an object",
    num: { savePath: 5 }
  } });
  assert.equal(L.categorySavePath("", st), "/dl");
  assert.equal(L.categorySavePath("anime", st), "/dl/anime");
  assert.equal(L.categorySavePath("anime/2026", st), "/dl/anime/2026", "unknown (not yet created) = empty path");
  assert.equal(L.categorySavePath("linux", st), "/srv/linux");
  assert.equal(L.categorySavePath("rel", st), "/dl/sub/dir", "a relative path is under the default");
  assert.equal(L.categorySavePath("junk", st), "/dl/junk");
  assert.equal(L.categorySavePath("num", st), "/dl/num");
});

// --- categorySavePath: qBittorrent 5.2.3's SessionImpl::categorySavePath (fix 0) ---

test("categorySavePath: a nested empty-path category under an explicit-path parent", () => {
  const st = status({ categoryPaths: { anime: { savePath: "/srv/anime", downloadPath: "" }, "anime/2026": { savePath: "", downloadPath: "" } } });
  assert.equal(L.categorySavePath("anime/2026", st), "/srv/anime/2026");
  assert.equal(L.categorySavePath("anime/2026/deep", st), "/srv/anime/2026/deep", "recursive through an unknown middle");
});

test("categorySavePath: a nested category under an empty-path parent", () => {
  const st = status({ categoryPaths: { anime: { savePath: "", downloadPath: "" }, "anime/2026": { savePath: "", downloadPath: "" } } });
  assert.equal(L.categorySavePath("anime/2026", st), "/dl/anime/2026");
  assert.equal(L.categorySavePath("x/y", status()), "/dl/x/y", "a parent missing from categoryPaths counts as empty");
});

test("categorySavePath: a relative explicit path resolves under the default, not the parent", () => {
  const st = status({ categoryPaths: { anime: { savePath: "/srv/anime", downloadPath: "" }, "anime/rel": { savePath: "sub//dir/", downloadPath: "" } } });
  assert.equal(L.categorySavePath("anime/rel", st), "/dl/sub/dir");
});

test("categorySavePath: an absolute explicit path is cleaned but kept", () => {
  const st = status({ categoryPaths: { a: { savePath: "/srv//x/./y/../z/", downloadPath: "" } } });
  assert.equal(L.categorySavePath("a", st), "/srv/x/z");
});

test("categorySavePath: a leaf's :?\"*<>| runs become one space, untrimmed", () => {
  assert.equal(L.categorySavePath("a:b?c", status()), "/dl/a b c");
  assert.equal(L.categorySavePath("p/::x**", status()), "/dl/p/ x ");
  assert.equal(L.categorySavePath("<|>", status()), "/dl/ ");
});

test("categorySavePath: a \"..\" or \".\" leaf is resolved like QDir::cleanPath", () => {
  assert.equal(L.categorySavePath("..", status({ defaultSavePath: "/home/u/dl" })), "/home/u");
  assert.equal(L.categorySavePath("a/..", status()), "/dl");
  assert.equal(L.categorySavePath("..", status({ defaultSavePath: "/" })), "/");
});

test("movePlan remove: a nested category whose parent has an explicit path", () => {
  const st = status({ categoryPaths: { anime: { savePath: "/srv/anime", downloadPath: "" }, "anime/2026": { savePath: "", downloadPath: "" } } });
  const rows = [
    row({ hash: H("a"), category: "anime/2026", savePath: "/srv/anime/2026" }),
    row({ hash: H("b"), category: "anime/2026/x", savePath: "/srv/anime/2026/x" })
  ];
  assert.deepEqual(L.movePlan({ kind: "remove", name: "anime/2026" }, rows, st), [
    { hash: H("a"), from: "/srv/anime/2026", to: "/srv/anime" },
    { hash: H("b"), from: "/srv/anime/2026/x", to: "/srv/anime" }
  ]);
});

test("movePlan setCategory, rename and path use the same resolution", () => {
  const st = status({ categoryPaths: { anime: { savePath: "/srv/anime", downloadPath: "" }, "anime/2026": { savePath: "", downloadPath: "" } } });
  const r = [row({ hash: H("a"), category: "anime/2026", savePath: "/srv/anime/2026" })];
  assert.deepEqual(L.movePlan({ kind: "setCategory", hashes: [H("a")], name: "anime/2027" }, r, st),
    [{ hash: H("a"), from: "/srv/anime/2026", to: "/srv/anime/2027" }]);
  assert.deepEqual(L.movePlan({ kind: "rename", old: "anime/2026", new: "anime/b:c" }, r, st),
    [{ hash: H("a"), from: "/srv/anime/2026", to: "/srv/anime/b c" }]);
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime/2026", path: "rel" }, r, st),
    [{ hash: H("a"), from: "/srv/anime/2026", to: "/dl/rel" }]);
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime/2026", path: "" }, r, st), [], "\"\" = parent/leaf = where it is");
});

// --- movePlan (G8, Deviation 3) ----------------------------------------------------

test("movePlan setCategory: only the targeted auto-managed rows whose path changes", () => {
  const rows = [
    row({ hash: H("a"), savePath: "/dl" }),
    row({ hash: H("b"), savePath: "/dl", autoTmm: false }),
    row({ hash: H("c"), savePath: "/dl/anime/" }),
    row({ hash: H("d"), savePath: "/dl" })
  ];
  const plan = L.movePlan({ kind: "setCategory", hashes: [H("a"), H("b"), H("c")], name: "anime" }, rows, status());
  assert.deepEqual(plan, [{ hash: H("a"), from: "/dl", to: "/dl/anime" }],
    "b is manual, c is already there (trailing / ignored), d isn't targeted");
});

test("movePlan setCategory to an explicit path, to none, and to a new category", () => {
  const st = status({ categoryPaths: { linux: { savePath: "/srv/linux", downloadPath: "" } } });
  const rows = [row({ hash: H("a"), category: "linux", savePath: "/srv/linux" })];
  assert.deepEqual(L.movePlan({ kind: "setCategory", hashes: [H("a")], name: "linux" }, rows, st), []);
  assert.deepEqual(L.movePlan({ kind: "setCategory", hashes: [H("a")], name: "" }, rows, st),
    [{ hash: H("a"), from: "/srv/linux", to: "/dl" }]);
  assert.deepEqual(L.movePlan({ kind: "setCategory", hashes: [H("a")], name: "brand-new" }, rows, st),
    [{ hash: H("a"), from: "/srv/linux", to: "/dl/brand-new" }]);
});

test("movePlan: a category change moves nothing when torrent_changed_tmm_enabled is off", () => {
  const st = status({ relocation: { torrentChanged: false, categoryPathChanged: true } });
  const rows = [row({ hash: H("a"), category: "anime", savePath: "/dl/anime" })];
  assert.deepEqual(L.movePlan({ kind: "setCategory", hashes: [H("a")], name: "linux" }, rows, st), []);
  assert.deepEqual(L.movePlan({ kind: "rename", old: "anime", new: "animation" }, rows, st), []);
  assert.deepEqual(L.movePlan({ kind: "remove", name: "anime" }, rows, st), []);
  assert.equal(L.movePlan({ kind: "path", name: "anime", path: "/srv/a" }, rows, st).length, 1, "p follows the other preference");
});

test("movePlan: a missing relocation or status moves nothing", () => {
  const rows = [row({ category: "anime", savePath: "/dl/anime" })];
  assert.deepEqual(L.movePlan({ kind: "remove", name: "anime" }, rows, { defaultSavePath: "/dl" }), []);
  assert.deepEqual(L.movePlan({ kind: "remove", name: "anime" }, rows, null), []);
  assert.deepEqual(L.movePlan({ kind: "nope" }, rows, status()), []);
  assert.deepEqual(L.movePlan(null, rows, status()), []);
});

test("movePlan rename: an empty-path category moves from <default>/old to <default>/new", () => {
  const st = status({ categoryPaths: { anime: { savePath: "", downloadPath: "" } } });
  const rows = [
    row({ hash: H("a"), category: "anime", savePath: "/dl/anime" }),
    row({ hash: H("b"), category: "anime", savePath: "/dl/anime", autoTmm: false }),
    row({ hash: H("c"), category: "other", savePath: "/dl/other" })
  ];
  assert.deepEqual(L.movePlan({ kind: "rename", old: "anime", new: "animation" }, rows, st),
    [{ hash: H("a"), from: "/dl/anime", to: "/dl/animation" }]);
});

test("movePlan rename: an explicit path is copied, so nothing moves", () => {
  const st = status({ categoryPaths: { anime: { savePath: "/srv/anime", downloadPath: "" } } });
  const rows = [row({ category: "anime", savePath: "/srv/anime" })];
  assert.deepEqual(L.movePlan({ kind: "rename", old: "anime", new: "animation" }, rows, st), []);
});

test("movePlan rename onto an existing category (merge) uses the target's path", () => {
  const st = status({ categoryPaths: {
    anime: { savePath: "", downloadPath: "" },
    animation: { savePath: "", downloadPath: "" }
  } });
  const rows = [row({ hash: H("a"), category: "anime", savePath: "/dl/anime" })];
  assert.deepEqual(L.movePlan({ kind: "rename", old: "anime", new: "animation" }, rows, st),
    [{ hash: H("a"), from: "/dl/anime", to: "/dl/animation" }]);
  const same = status({ categoryPaths: {
    anime: { savePath: "/srv/x", downloadPath: "" },
    animation: { savePath: "/srv/x", downloadPath: "" }
  } });
  assert.deepEqual(L.movePlan({ kind: "rename", old: "anime", new: "animation" }, [row({ category: "anime", savePath: "/srv/x" })], same), []);
});

test("movePlan remove: a top-level category's torrents go to the default path", () => {
  const st = status({ categoryPaths: { anime: { savePath: "", downloadPath: "" }, "anime/2026": { savePath: "/srv/a26", downloadPath: "" } } });
  const rows = [
    row({ hash: H("a"), category: "anime", savePath: "/dl/anime" }),
    row({ hash: H("b"), category: "anime/2026", savePath: "/srv/a26" }),
    row({ hash: H("c"), category: "animes", savePath: "/dl/animes" }),
    row({ hash: H("d"), category: "anime", savePath: "/dl/anime", autoTmm: false }),
    row({ hash: H("e"), category: "anime", savePath: "/dl" })
  ];
  assert.deepEqual(L.movePlan({ kind: "remove", name: "anime" }, rows, st), [
    { hash: H("a"), from: "/dl/anime", to: "/dl" },
    { hash: H("b"), from: "/srv/a26", to: "/dl" }
  ], "subcategory rows move too; animes isn't one; e is already there");
});

test("movePlan remove: a nested category's torrents go to the parent's path", () => {
  const rows = [
    row({ hash: H("a"), category: "anime/2026", savePath: "/dl/anime/2026" }),
    row({ hash: H("b"), category: "anime/2026/deep", savePath: "/dl/anime/2026/deep" }),
    row({ hash: H("c"), category: "anime", savePath: "/dl/anime" })
  ];
  const implicit = status({ categoryPaths: { anime: { savePath: "", downloadPath: "" } } });
  assert.deepEqual(L.movePlan({ kind: "remove", name: "anime/2026" }, rows, implicit), [
    { hash: H("a"), from: "/dl/anime/2026", to: "/dl/anime" },
    { hash: H("b"), from: "/dl/anime/2026/deep", to: "/dl/anime" }
  ]);
  const explicit = status({ categoryPaths: { anime: { savePath: "/srv/anime", downloadPath: "" } } });
  assert.deepEqual(L.movePlan({ kind: "remove", name: "anime/2026" }, rows, explicit).map((p) => p.to), ["/srv/anime", "/srv/anime"]);
});

test("movePlan path: only when category_changed_tmm_enabled is on, rows on exactly that name", () => {
  const rows = [
    row({ hash: H("a"), category: "anime", savePath: "/dl/anime" }),
    row({ hash: H("b"), category: "anime/2026", savePath: "/dl/anime/2026" }),
    row({ hash: H("c"), category: "anime", savePath: "/dl/anime", autoTmm: false })
  ];
  const on = status({ categoryPaths: { anime: { savePath: "", downloadPath: "" } } });
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime", path: "/srv/anime" }, rows, on),
    [{ hash: H("a"), from: "/dl/anime", to: "/srv/anime" }]);
  const off = status({ relocation: { torrentChanged: true, categoryPathChanged: false } });
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime", path: "/srv/anime" }, rows, off), [],
    "qBittorrent switches them to manual instead");
});

test("movePlan path: \"\" is <default>/<name>, ~/ uses home when given, the same path moves nothing", () => {
  const rows = [row({ hash: H("a"), category: "anime", savePath: "/srv/anime" })];
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime", path: "" }, rows, status()),
    [{ hash: H("a"), from: "/srv/anime", to: "/dl/anime" }]);
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime", path: "~/Videos/anime", home: "/home/u/" }, rows, status()),
    [{ hash: H("a"), from: "/srv/anime", to: "/home/u/Videos/anime" }]);
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime", path: "~/Videos/anime" }, rows, status()),
    [{ hash: H("a"), from: "/srv/anime", to: "~/Videos/anime" }], "no home: shown as typed, and always confirmed");
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime", path: "/srv/anime/" }, rows, status()), []);
});

// --- moveConfirmLine and the combined confirms --------------------------------------

const P = (n, to) => Array.from({ length: n }, (_, i) => ({ hash: H(String(i % 10)), from: "/old", to: typeof to === "function" ? to(i) : to }));

test("moveConfirmLine: the brief's wording, singular, several folders, and nothing to move", () => {
  assert.equal(L.moveConfirmLine(P(3, "/srv/anime")), "Changes 3 torrents' category; their files move to /srv/anime.");
  assert.equal(L.moveConfirmLine(P(1, "/srv/anime")), "Changes 1 torrent's category; its files move to /srv/anime.");
  assert.equal(L.moveConfirmLine(P(3, (i) => (i === 0 ? "/a" : "/b"))), "Changes 3 torrents' category; their files move to 2 folders.");
  assert.equal(L.moveConfirmLine([]), "");
  assert.equal(L.moveConfirmLine(null), "");
});

test("moveConfirmLine with a larger target count (a VISUAL range mixing managed and manual)", () => {
  assert.equal(L.moveConfirmLine(P(3, "/srv/anime"), 5), "Changes 5 torrents' category; 3 torrents' files move to /srv/anime.");
  assert.equal(L.moveConfirmLine(P(1, "/srv/anime"), 2), "Changes 2 torrents' category; 1 torrent's files move to /srv/anime.");
  assert.equal(L.moveConfirmLine(P(3, "/srv/anime"), 3), "Changes 3 torrents' category; their files move to /srv/anime.");
  assert.equal(L.moveConfirmLine(P(3, "/srv/anime"), 1), "Changes 3 torrents' category; their files move to /srv/anime.", "never fewer than the plan");
});

test("deleteConfirmLine for a top-level category", () => {
  assert.equal(L.deleteConfirmLine("category", "anime", 21, 0, []), "Delete category anime? 21 torrents become Uncategorized.");
  assert.equal(L.deleteConfirmLine("category", "anime", 1, 0, []), "Delete category anime? 1 torrent becomes Uncategorized.");
  assert.equal(L.deleteConfirmLine("category", "anime", 0, 0, []), "Delete category anime? No torrents use it.");
});

test("deleteConfirmLine for a nested category moves them to the parent", () => {
  assert.equal(L.deleteConfirmLine("category", "anime/2026", 21, 0, []), "Delete category anime/2026? 21 torrents move to anime.");
  assert.equal(L.deleteConfirmLine("category", "anime/2026", 1, 0, []), "Delete category anime/2026? 1 torrent moves to anime.");
  assert.equal(L.deleteConfirmLine("category", "a/b/c", 0, 0), "Delete category a/b/c? No torrents use it.");
});

test("deleteConfirmLine names the subcategories it also deletes", () => {
  assert.equal(L.deleteConfirmLine("category", "anime", 21, 2, []), "Delete category anime? 21 torrents become Uncategorized. It also deletes its 2 subcategories.");
  assert.equal(L.deleteConfirmLine("category", "anime", 0, 1, []), "Delete category anime? No torrents use it. It also deletes its 1 subcategory.");
});

test("deleteConfirmLine folds the move into the same line", () => {
  assert.equal(L.deleteConfirmLine("category", "anime", 21, 0, P(21, "/dl")),
    "Delete category anime? 21 torrents become Uncategorized. Their files move to /dl.");
  assert.equal(L.deleteConfirmLine("category", "anime", 1, 0, P(1, "/dl")),
    "Delete category anime? 1 torrent becomes Uncategorized. Its files move to /dl.");
  assert.equal(L.deleteConfirmLine("category", "anime/2026", 5, 1, P(2, "/srv/anime")),
    "Delete category anime/2026? 5 torrents move to anime. It also deletes its 1 subcategory. 2 torrents' files move to /srv/anime.");
  assert.equal(L.deleteConfirmLine("category", "anime", 5, 0, P(1, "/dl")),
    "Delete category anime? 5 torrents become Uncategorized. 1 torrent's files move to /dl.");
});

test("deleteConfirmLine for a tag", () => {
  assert.equal(L.deleteConfirmLine("tag", "seedbox", 4), "Delete tag seedbox? It's removed from 4 torrents.");
  assert.equal(L.deleteConfirmLine("tag", "seedbox", 1), "Delete tag seedbox? It's removed from 1 torrent.");
  assert.equal(L.deleteConfirmLine("tag", "seedbox", 0), "Delete tag seedbox? No torrents use it.");
});

test("renameConfirmLine: merge, merge plus move, a plain rename with a move, and no confirm", () => {
  assert.equal(L.renameConfirmLine("anime", "animation", true, 21, []), "animation already exists. Move 21 torrents into it and delete anime?");
  assert.equal(L.renameConfirmLine("anime", "animation", true, 1, []), "animation already exists. Move 1 torrent into it and delete anime?");
  assert.equal(L.renameConfirmLine("anime", "animation", true, 0, []), "animation already exists. No torrents use anime; delete it?");
  assert.equal(L.renameConfirmLine("anime", "animation", true, 21, P(21, "/srv/animation")),
    "animation already exists. Move 21 torrents into it and delete anime? Their files move to /srv/animation.");
  assert.equal(L.renameConfirmLine("anime", "animation", false, 21, P(3, "/dl/animation")),
    "Rename anime to animation? 3 torrents' files move to /dl/animation.");
  assert.equal(L.renameConfirmLine("anime", "animation", false, 3, P(3, "/dl/animation")),
    "Rename anime to animation? Their files move to /dl/animation.");
  assert.equal(L.renameConfirmLine("anime", "animation", false, 21, []), "", "nothing to confirm");
});

test("pathConfirmLine: a confirm only when files move", () => {
  assert.equal(L.pathConfirmLine("anime", P(3, "/srv/anime")), "Change anime's save path? 3 torrents' files move to /srv/anime.");
  assert.equal(L.pathConfirmLine("anime", P(1, "/srv/anime")), "Change anime's save path? 1 torrent's files move to /srv/anime.");
  assert.equal(L.pathConfirmLine("anime", []), "");
});

// --- usageCount (OV8) and subcategoryCount ----------------------------------------

test("usageCount for a category delete counts name and name/..., pending magnets included", () => {
  const rows = [
    row({ hash: H("a"), category: "anime" }),
    row({ hash: H("b"), category: "anime/2026" }),
    row({ hash: H("c"), category: "anime/2026/deep" }),
    row({ hash: H("d"), category: "animes" }),
    row({ hash: H("e"), category: "" }),
    row({ hash: H("f"), category: "anime" })
  ];
  const pending = [H("f")];
  assert.equal(L.usageCount("category", "anime", rows, pending), 4, "f is a pending browser magnet: it's hidden from the table but still moves");
  assert.equal(Model.excludePending(rows, pending).filter((r) => r.category === "anime").length, 1, "the table's own count leaves it out");
  assert.equal(L.usageCount("category", "anime/2026", rows, pending), 2);
  assert.equal(L.usageCount("category", "nope", rows, pending), 0);
  assert.equal(L.usageCount("category", "", rows, pending), 0);
});

test("usageCount can count a category's own torrents only (rename, merge)", () => {
  const rows = [row({ category: "anime" }), row({ category: "anime/2026" })];
  assert.equal(L.usageCount("category", "anime", rows, [], true), 1);
});

test("usageCount for a tag", () => {
  const rows = [
    row({ hash: H("a"), tags: ["seedbox", "keep"] }),
    row({ hash: H("b"), tags: ["seedbox/x"] }),
    row({ hash: H("c"), tags: [] }),
    row({ hash: H("d"), tags: ["seedbox"] }),
    row({ hash: H("e") , tags: undefined })
  ];
  assert.equal(L.usageCount("tag", "seedbox", rows, [H("d")]), 2);
  assert.equal(L.usageCount("tag", "keep", rows, []), 1);
  assert.equal(L.usageCount("tag", "seedbox", null, null), 0);
});

test("subcategoryCount counts every name/... category", () => {
  assert.equal(L.subcategoryCount("anime", ["anime", "anime/2026", "anime/2026/deep", "animes", "anime-x"]), 2);
  assert.equal(L.subcategoryCount("anime", ["anime"]), 0);
  assert.equal(L.subcategoryCount("anime", null), 0);
});

// --- followFilter (OV9, ruling BF) ------------------------------------------------

test("followFilter after a category rename follows the new name", () => {
  const act = { kind: "rename", group: "category", old: "anime", new: "animation" };
  assert.deepEqual(L.followFilter({ group: "category", value: "anime" }, act), { group: "category", value: "animation" });
  assert.deepEqual(L.followFilter({ group: "category", value: "animes" }, act), { group: "category", value: "animes" });
  assert.deepEqual(L.followFilter({ group: "tag", value: "anime" }, act), { group: "tag", value: "anime" }, "a tag named the same is untouched");
  assert.deepEqual(L.followFilter({ group: "status", value: "All" }, act), { group: "status", value: "All" });
});

test("followFilter after a category delete: the parent, or Uncategorized", () => {
  const top = { kind: "remove", group: "category", name: "anime" };
  assert.deepEqual(L.followFilter({ group: "category", value: "anime" }, top), { group: "category", value: "" });
  assert.deepEqual(L.followFilter({ group: "category", value: "anime/2026" }, top), { group: "category", value: "" });
  assert.deepEqual(L.followFilter({ group: "category", value: "animes" }, top), { group: "category", value: "animes" });
  assert.deepEqual(L.followFilter({ group: "category", value: "" }, top), { group: "category", value: "" });
  const nested = { kind: "remove", group: "category", name: "anime/2026" };
  assert.deepEqual(L.followFilter({ group: "category", value: "anime/2026" }, nested), { group: "category", value: "anime" });
  assert.deepEqual(L.followFilter({ group: "category", value: "anime/2026/deep" }, nested), { group: "category", value: "anime" });
  assert.deepEqual(L.followFilter({ group: "category", value: "anime" }, nested), { group: "category", value: "anime" });
});

test("followFilter after a tag rename or delete", () => {
  assert.deepEqual(L.followFilter({ group: "tag", value: "seedbox" }, { kind: "rename", group: "tag", old: "seedbox", new: "sb" }), { group: "tag", value: "sb" });
  assert.deepEqual(L.followFilter({ group: "tag", value: "seedbox" }, { kind: "remove", group: "tag", name: "seedbox" }), { group: "tag", value: "" });
  assert.deepEqual(L.followFilter({ group: "tag", value: "seedbox/x" }, { kind: "remove", group: "tag", name: "seedbox" }), { group: "tag", value: "seedbox/x" }, "tags have no hierarchy");
  assert.deepEqual(L.followFilter({ group: "tag", value: "" }, { kind: "remove", group: "tag", name: "" }), { group: "tag", value: "" });
});

test("followFilter tolerates a missing filter or action", () => {
  assert.deepEqual(L.followFilter(null, { kind: "remove", group: "tag", name: "x" }), null);
  assert.deepEqual(L.followFilter({ group: "tag", value: "x" }, null), { group: "tag", value: "x" });
});

// --- tagStates / tagChanges --------------------------------------------------------

test("tagStates gives [x] / [~] / [ ] per tag, in the given order", () => {
  const rows = [row({ tags: ["keep", "seedbox"] }), row({ tags: ["keep"] })];
  assert.deepEqual(L.tagStates(["seedbox", "keep", "new"], rows), [
    { name: "seedbox", state: "some", mark: "[~]" },
    { name: "keep", state: "all", mark: "[x]" },
    { name: "new", state: "none", mark: "[ ]" }
  ]);
  assert.deepEqual(L.tagStates(["keep"], []), [{ name: "keep", state: "none", mark: "[ ]" }]);
  assert.deepEqual(L.tagStates(null, rows), []);
});

test("tagChanges: only what changed, some stays untouched", () => {
  const before = [
    { name: "a", state: "none" }, { name: "b", state: "some" }, { name: "c", state: "all" },
    { name: "d", state: "some" }, { name: "e", state: "some" }, { name: "f", state: "all" }
  ];
  const after = [
    { name: "a", state: "all" }, { name: "b", state: "all" }, { name: "c", state: "none" },
    { name: "d", state: "none" }, { name: "e", state: "some" }, { name: "f", state: "all" }
  ];
  assert.deepEqual(L.tagChanges(before, after), { add: ["a", "b"], remove: ["c", "d"] });
  assert.deepEqual(L.tagChanges(before, before), { add: [], remove: [] });
  assert.deepEqual(L.tagChanges([], [{ name: "new", state: "all" }]), { add: ["new"], remove: [] }, "a tag new to the picker counts as none before");
  assert.deepEqual(L.tagChanges(null, null), { add: [], remove: [] });
});

// --- Fix round 1: hash forms, fail-closed destinations, tagStates on none ------

test("hashList: a \"|\" string, an array or an array-like, empties dropped", () => {
  assert.deepEqual(L.hashList(H("a") + "|" + H("b")), [H("a"), H("b")]);
  assert.deepEqual(L.hashList("|" + H("a") + "||"), [H("a")]);
  assert.deepEqual(L.hashList([H("a"), "", H("b")]), [H("a"), H("b")]);
  assert.deepEqual(L.hashList({ length: 2, 0: H("a"), 1: H("b") }), [H("a"), H("b")]);
  assert.deepEqual(L.hashList(""), []);
  assert.deepEqual(L.hashList(null), []);
  assert.deepEqual(L.hashList(undefined), []);
});

test("movePlan setCategory takes the \"|\" string and an array-like (a QML sequence)", () => {
  const rows = [row({ hash: H("a") }), row({ hash: H("b") }), row({ hash: H("c") })];
  const want = [{ hash: H("a"), from: "/dl", to: "/dl/anime" }, { hash: H("b"), from: "/dl", to: "/dl/anime" }];
  assert.deepEqual(L.movePlan({ kind: "setCategory", hashes: H("a") + "|" + H("b"), name: "anime" }, rows, status()), want);
  assert.deepEqual(L.movePlan({ kind: "setCategory", hashes: { length: 2, 0: H("a"), 1: H("b") }, name: "anime" }, rows, status()), want);
});

test("tagStates and usageCount read array-like tag lists", () => {
  const seq = (arr) => Object.assign({ length: arr.length }, arr);
  assert.deepEqual(L.tagStates(seq(["keep"]), [row({ tags: seq(["keep"]) })]), [{ name: "keep", state: "all", mark: "[x]" }]);
  assert.equal(L.usageCount("tag", "keep", [row({ tags: seq(["keep"]) })], []), 1);
  assert.equal(L.tagStates(["keep"], [row({ tags: "keep" })])[0].state, "none", "a string is not a tag list");
});

test("libraryReady is false until the status carries a default save path", () => {
  assert.equal(L.libraryReady(status()), true);
  assert.equal(L.libraryReady(status({ defaultSavePath: "" })), false);
  assert.equal(L.libraryReady({ categoryPaths: {} }), false);
  assert.equal(L.libraryReady(null), false);
  assert.equal(L.LIBRARY_NOT_READY, "Still reading qBittorrent's folders; try again in a moment.");
});

test("movePlan fails closed without a default save path: every managed row, to \"\"", () => {
  const st = status({ defaultSavePath: "" });
  const rows = [
    row({ hash: H("a"), category: "anime", savePath: "/dl/anime" }),
    row({ hash: H("b"), category: "anime", savePath: "" }),
    row({ hash: H("c"), category: "anime", savePath: "/dl/anime", autoTmm: false })
  ];
  assert.deepEqual(L.movePlan({ kind: "remove", name: "anime" }, rows, st), [
    { hash: H("a"), from: "/dl/anime", to: "" },
    { hash: H("b"), from: "", to: "" }
  ]);
  assert.deepEqual(L.movePlan({ kind: "setCategory", hashes: [H("a")], name: "x" }, rows, st), [{ hash: H("a"), from: "/dl/anime", to: "" }]);
  assert.deepEqual(L.movePlan({ kind: "rename", old: "anime", new: "b" }, rows, st).map((p) => p.to), ["", ""]);
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime", path: "" }, rows, st).map((p) => p.to), ["", ""]);
  assert.deepEqual(L.movePlan({ kind: "path", name: "anime", path: "/srv/a" }, rows, st).map((p) => p.to), ["/srv/a", "/srv/a"],
    "an absolute path still resolves");
  const relDefault = status({ defaultSavePath: "dl" });
  assert.deepEqual(L.movePlan({ kind: "remove", name: "anime" }, [rows[0]], relDefault), [{ hash: H("a"), from: "/dl/anime", to: "" }],
    "a relative default never yields a relative destination");
});

test("the confirms name an unknown destination honestly", () => {
  const unknown = [{ hash: H("a"), from: "/x", to: "" }, { hash: H("b"), from: "/y", to: "" }];
  assert.equal(L.moveConfirmLine(unknown), "Changes 2 torrents' category; their files move to a folder qBittorrent picks.");
  assert.equal(L.deleteConfirmLine("category", "anime", 2, 0, unknown),
    "Delete category anime? 2 torrents become Uncategorized. Their files move to a folder qBittorrent picks.");
  assert.equal(L.pathConfirmLine("anime", unknown.slice(0, 1)), "Change anime's save path? 1 torrent's files move to a folder qBittorrent picks.");
});

test("tagStates with no target rows marks every tag none", () => {
  assert.deepEqual(L.tagStates(["keep", "seedbox"], []), [
    { name: "keep", state: "none", mark: "[ ]" },
    { name: "seedbox", state: "none", mark: "[ ]" }
  ]);
  assert.deepEqual(L.tagStates(["keep"], null), [{ name: "keep", state: "none", mark: "[ ]" }]);
});

// --- slice 3a, Task 5: the filters pane's copy, footer and p's path rule -------

test("libraryCopy: progress and done copy per action, qbt's error shown as-is", () => {
  assert.deepEqual(L.libraryCopy("add", "category", "anime"), { progress: "Adding category…", done: "Category added", raw: true });
  assert.deepEqual(L.libraryCopy("add", "tag", "keep"), { progress: "Adding tag…", done: "Tag added", raw: true });
  assert.deepEqual(L.libraryCopy("rename", "category", "anime", "animation"), { progress: "Renaming anime → animation…", done: "Renamed anime → animation", raw: true });
  assert.deepEqual(L.libraryCopy("rename", "tag", "keep", "kept"), { progress: "Renaming keep → kept…", done: "Renamed keep → kept", raw: true });
  assert.deepEqual(L.libraryCopy("path", "category", "anime"), { progress: "Setting anime's save path…", done: "Save path set", raw: true });
  assert.deepEqual(L.libraryCopy("remove", "category", "anime"), { progress: "Deleting category anime…", done: "Deleted category anime", raw: true });
  assert.deepEqual(L.libraryCopy("remove", "tag", "seedbox"), { progress: "Deleting tag seedbox…", done: "Deleted tag seedbox", raw: true });
});

test("savePathError: empty (the default), absolute or ~/ -- qbt category-path's rule and message", () => {
  for (const ok of ["", "/srv/anime", "/", "~/Downloads/anime", "~/"]) assert.equal(L.savePathError(ok), "", JSON.stringify(ok));
  for (const bad of ["anime", "./x", "~", "~user/x", " /srv"]) assert.equal(L.savePathError(bad), "The save path must be absolute or start with ~/.", JSON.stringify(bad));
});

test("footerKeys: only the keys that apply to the filters cursor row", () => {
  const f = (t) => L.footerKeys(t).map((k) => k.key + " " + k.label);
  assert.deepEqual(f({ kind: "category", value: "anime", label: "anime" }), ["a add", "c rename", "p save path", "x delete"]);
  assert.deepEqual(f({ kind: "tag", value: "keep", label: "keep" }), ["a add", "c rename", "x delete"]);
  assert.deepEqual(f({ kind: "category", value: "", label: "" }), ["a new category"]);
  assert.deepEqual(f({ kind: "tag", value: "", label: "" }), ["a new tag"]);
  assert.deepEqual(f(null), []);
  assert.deepEqual(f({ kind: "tracker", value: "x" }), []);
  // the not-ready refusal doesn't hide keys: the key says why
  assert.deepEqual(f({ kind: "category", value: "anime", label: "anime", refusal: L.LIBRARY_NOT_READY }), ["a add", "c rename", "p save path", "x delete"]);
});

test("hasName and explicitSavePath: what c's merge check and p's prefill read", () => {
  assert.equal(L.hasName(["anime", "animation"], "animation"), true);
  assert.equal(L.hasName({ length: 1, 0: "anime" }, "anime"), true, "a QML sequence");
  assert.equal(L.hasName(["anime"], "anim"), false);
  assert.equal(L.hasName(null, "anime"), false);
  const st = { categoryPaths: { anime: { savePath: "/srv/anime", downloadPath: "" }, bad: { savePath: 3 } } };
  assert.equal(L.explicitSavePath("anime", st), "/srv/anime");
  assert.equal(L.explicitSavePath("bad", st), "");
  assert.equal(L.explicitSavePath("gone", st), "");
  assert.equal(L.explicitSavePath("anime", {}), "");
});

// --- The C and T pickers (Task 6) ------------------------------------------------------

// The pickers match with ClientView.fuzzyMatch (the palette's), passed in:
// LibraryView can't import ClientView.
const FUZZY = (() => {
  const file = path.join(__dirname, "..", "ClientView.js");
  const src = fs.readFileSync(file, "utf8").split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line)).join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module", "Model", "Registry"], { filename: file })(mod, Model, require("../CommandRegistry.js"));
  return mod.exports.fuzzyMatch;
})();

const catRow = (rows, title) => rows.find((r) => r.title === title);

test("categoryPickerRows: (no category), each category with N of M now, in order, all enabled", () => {
  const targets = [row({ hash: H("a"), category: "anime" }), row({ hash: H("b"), category: "anime" }), row({ hash: H("c"), category: "" })];
  const rows = L.categoryPickerRows("", ["anime", "anime/2026", "  legacy//x"], targets, FUZZY);
  assert.deepEqual(rows.map((r) => r.title), ["(no category)", "anime", "anime/2026", "  legacy//x"]);
  assert.deepEqual(rows.map((r) => r.value), ["", "anime", "anime/2026", "  legacy//x"]);
  assert.deepEqual(rows.map((r) => r.keys), ["1 of 3 now", "2 of 3 now", "", ""]);
  assert.ok(rows.every((r) => r.enabled === true && r.isNew !== true && r.kind !== "divider"));
  assert.equal(new Set(rows.map((r) => r.id)).size, rows.length, "ids are unique");
});

test("categoryPickerRows: a query filters fuzzily, best first, and offers + New for a name that doesn't exist", () => {
  const rows = L.categoryPickerRows("ani", ["linux", "anime", "manila"], [row()], FUZZY);
  assert.deepEqual(rows.map((r) => r.title), ["anime", "manila", "+ New category \"ani\""]);
  assert.deepEqual(rows[0].indices, [0, 1, 2]);
  const n = rows[2];
  assert.equal(n.isNew, true);
  assert.equal(n.value, "ani");
  assert.equal(n.enabled, true);
  assert.deepEqual(n.indices, []);
});

test("categoryPickerRows: an exact name gets no + New row; an invalid one is shown disabled with the reason", () => {
  assert.equal(L.categoryPickerRows("anime", ["anime"], [row()], FUZZY).filter((r) => r.isNew).length, 0);
  const bad = L.categoryPickerRows("a//b", ["anime"], [row()], FUZZY).find((r) => r.isNew);
  assert.equal(bad.enabled, false);
  assert.equal(bad.reason, "No // in a category.");
  const edge = L.categoryPickerRows("x ", [], [row()], FUZZY);
  assert.equal(edge.length, 1);
  assert.equal(edge[0].reason, "No spaces at the start or end.");
  // (no category) matches like any row
  assert.ok(catRow(L.categoryPickerRows("no cat", ["anime"], [row()], FUZZY), "(no category)"));
});

function catStatus(overrides) {
  return status(Object.assign({ categories: ["anime", "anime/2026"], categoryPaths: { anime: { savePath: "" } } }, overrides || {}));
}

test("categoryAccept: set on the targets that change; nothing when every target is already there", () => {
  const torrents = [row({ hash: H("a"), category: "anime", autoTmm: false }), row({ hash: H("b"), category: "", autoTmm: false })];
  const rows = L.categoryPickerRows("", ["anime"], torrents, FUZZY);
  const r = L.categoryAccept(catRow(rows, "anime"), [H("a"), H("b")], torrents, catStatus());
  assert.equal(r.op, "set");
  assert.equal(r.name, "anime");
  assert.deepEqual(r.hashes, [H("b")], "only the torrent whose category changes");
  assert.equal(r.line, "", "manual torrents never move: no confirm");
  assert.equal(L.categoryAccept(catRow(rows, "anime"), [H("a")], torrents, catStatus()).op, "none");
  const none = L.categoryAccept(catRow(rows, "(no category)"), [H("a"), H("b")], torrents, catStatus());
  assert.equal(none.op, "set");
  assert.equal(none.name, "");
  assert.deepEqual(none.hashes, [H("a")]);
  assert.equal(L.categoryAccept(null, [H("a")], torrents, catStatus()).op, "none");
});

test("categoryAccept: an auto-managed move confirms with the real folder (G8), a mixed range counts both", () => {
  const torrents = [
    row({ hash: H("a"), category: "anime", autoTmm: true, savePath: "/dl/anime" }),
    row({ hash: H("d"), category: "", autoTmm: false, savePath: "/dl" })
  ];
  const rows = L.categoryPickerRows("", ["anime", "anime/2026"], torrents, FUZZY);
  const r = L.categoryAccept(catRow(rows, "anime/2026"), [H("a"), H("d")], torrents, catStatus());
  assert.equal(r.op, "set");
  assert.deepEqual(r.hashes, [H("a"), H("d")]);
  assert.equal(r.line, "Changes 2 torrents' category; 1 torrent's files move to /dl/anime/2026.");
  const one = L.categoryAccept(catRow(rows, "anime/2026"), [H("a")], torrents, catStatus());
  assert.equal(one.line, "Changes 1 torrent's category; its files move to /dl/anime/2026.");
  const off = L.categoryAccept(catRow(rows, "anime/2026"), [H("a")], torrents, catStatus({ relocation: { torrentChanged: false } }));
  assert.equal(off.line, "", "relocation off: qBittorrent switches it to manual, nothing moves");
  const back = L.categoryAccept(catRow(rows, "(no category)"), [H("a")], torrents, catStatus());
  assert.equal(back.line, "Changes 1 torrent's category; its files move to /dl.");
});

test("categoryAccept: + New creates, then sets; its folder is <parent path or default>/<name>, confirmed first", () => {
  const torrents = [row({ hash: H("a"), category: "", autoTmm: true, savePath: "/dl" })];
  const st = catStatus({ categoryPaths: { anime: { savePath: "/srv/anime" } } });
  const rows = L.categoryPickerRows("anime/new", st.categories, torrents, FUZZY);
  const r = L.categoryAccept(rows.find((x) => x.isNew), [H("a")], torrents, st);
  assert.equal(r.op, "create");
  assert.equal(r.name, "anime/new");
  assert.deepEqual(r.hashes, [H("a")]);
  assert.equal(r.line, "Changes 1 torrent's category; its files move to /srv/anime/new.");
  const top = L.categoryAccept(L.categoryPickerRows("fresh", st.categories, torrents, FUZZY).find((x) => x.isNew), [H("a")], torrents, st);
  assert.equal(top.line, "Changes 1 torrent's category; its files move to /dl/fresh.");
  // a disabled + New is refused with its reason
  const bad = L.categoryAccept(L.categoryPickerRows("a//b", st.categories, torrents, FUZZY).find((x) => x.isNew), [H("a")], torrents, st);
  assert.deepEqual([bad.op, bad.note], ["refuse", "No // in a category."]);
  // a name that appeared since the rows were built is refused as a clash
  const late = L.categoryAccept({ isNew: true, enabled: true, value: "anime" }, [H("a")], torrents, st);
  assert.deepEqual([late.op, late.note], ["refuse", "\"anime\" already exists."]);
});

test("tagPickerRows: marks from the working states, a fuzzy query, + New tag for a new name", () => {
  const states = L.tagStates(["seedbox", "keep"], [row({ tags: ["seedbox"] }), row({ tags: ["seedbox", "keep"] })]);
  const rows = L.tagPickerRows("", states, FUZZY);
  assert.deepEqual(rows.map((r) => r.prefix + " " + r.title), ["[x] seedbox", "[~] keep"]);
  assert.ok(rows.every((r) => r.enabled === true));
  const q = L.tagPickerRows("kee", states, FUZZY);
  assert.deepEqual(q.map((r) => r.title), ["keep", "+ New tag \"kee\""]);
  assert.equal(q[1].isNew, true);
  assert.equal(q[1].value, "kee");
  assert.equal(L.tagPickerRows("keep", states, FUZZY).filter((r) => r.isNew).length, 0);
  assert.equal(L.tagPickerRows("a,b", states, FUZZY).find((r) => r.isNew).reason, "No commas in a tag.");
  assert.equal(L.tagPickerRows("anime 2026", states, FUZZY).find((r) => r.isNew).enabled, true, "an inner space is fine");
});

test("toggleTag: some -> all -> none -> back to some; none -> all; a new tag joins as all and leaves when toggled off", () => {
  const original = [{ name: "a", state: "some", mark: "[~]" }, { name: "b", state: "none", mark: "[ ]" }];
  const st = (list, n) => list.find((x) => x.name === n);
  let w = L.toggleTag(original, original, "a");
  assert.equal(st(w, "a").state, "all");
  assert.equal(st(w, "a").mark, "[x]");
  w = L.toggleTag(w, original, "a");
  assert.equal(st(w, "a").state, "none");
  w = L.toggleTag(w, original, "a");
  assert.equal(st(w, "a").state, "some", "back to how it was");
  assert.equal(st(L.toggleTag(original, original, "b"), "b").state, "all");
  assert.equal(st(original, "a").state, "some", "the input is never changed");
  w = L.toggleTag(original, original, "fresh");
  assert.deepEqual(st(w, "fresh"), { name: "fresh", state: "all", mark: "[x]", isNew: true });
  w = L.toggleTag(w, original, "fresh");
  assert.equal(st(w, "fresh"), undefined);
});

test("tagAccept: the new tags to create, then tagChanges only; nothing when unchanged", () => {
  const original = [{ name: "a", state: "some", mark: "[~]" }, { name: "b", state: "all", mark: "[x]" }];
  assert.deepEqual(L.tagAccept(original, original), { creates: [], changes: { add: [], remove: [] }, op: "none" });
  let w = L.toggleTag(original, original, "b");
  w = L.toggleTag(w, original, "new tag");
  assert.deepEqual(L.tagAccept(original, w), { creates: ["new tag"], changes: { add: ["new tag"], remove: ["b"] }, op: "change" });
});

test("pickerCopy: progress and done lines name what changes", () => {
  assert.deepEqual(L.pickerCopy("category", "set", "anime"), { progress: "Setting category anime…", done: "Category set to anime", raw: true });
  assert.deepEqual(L.pickerCopy("category", "set", ""), { progress: "Removing the category…", done: "Category removed", raw: true });
  assert.deepEqual(L.pickerCopy("category", "add", "anime"), { progress: "Creating category anime…", done: "", raw: true });
  assert.deepEqual(L.pickerCopy("tag", "set", ""), { progress: "Changing tags…", done: "Tags changed", raw: true });
  assert.deepEqual(L.pickerCopy("tag", "add", "keep"), { progress: "Creating tag keep…", done: "", raw: true });
});

test("pickerFailure: every line names the action; never a bare HTTP code (OV7)", () => {
  const f = L.pickerFailure;
  // set-category's first chunk
  assert.equal(f("category", "set", "anime", [], "qBittorrent refused it (HTTP 409)"), "Setting the category failed: HTTP 409");
  assert.equal(f("category", "set", "anime", [], "Category set on 1000 of 1001 torrents; qBittorrent refused the rest (HTTP 409)"),
    "Category set on 1000 of 1001 torrents; qBittorrent refused the rest (HTTP 409)");
  assert.equal(f("category", "set", "anime", [], "anime doesn't exist."), "Setting the category failed: anime doesn't exist.");
  assert.equal(f("category", "set", "anime", [], ""), "Setting the category failed.");
  // + New: created, then the set failed
  assert.equal(f("category", "set", "omaqbt-test", ["omaqbt-test"], "qBittorrent refused it (HTTP 409)"), "Created omaqbt-test; setting it failed (HTTP 409)");
  assert.equal(f("category", "set", "x", ["x"], "Category set on 1000 of 1001 torrents; qBittorrent refused the rest (HTTP 409)"),
    "Created x; category set on 1000 of 1001 torrents; qBittorrent refused the rest (HTTP 409)");
  assert.equal(f("category", "set", "x", ["x"], "couldn't reach qBittorrent"), "Created x; setting it failed (couldn't reach qBittorrent)");
  // the add itself
  assert.equal(f("category", "add", "x", [], "qBittorrent refused it (HTTP 409)"), "Creating category x failed: HTTP 409");
  // tags: qbt's own sentence names the tag
  assert.equal(f("tag", "set", "", [], "Tags: added keep; removing seedbox failed (HTTP 409)"), "Tags: added keep; removing seedbox failed (HTTP 409)");
  assert.equal(f("tag", "set", "", [], "qBittorrent refused it (HTTP 500)"), "Changing the tags failed: HTTP 500");
  assert.equal(f("tag", "set", "", ["keep"], "Tags: adding keep failed (HTTP 409)"), "Created keep; tags: adding keep failed (HTTP 409)");
  assert.equal(f("tag", "set", "", ["keep"], "qBittorrent refused it (HTTP 409)"), "Created keep; tagging failed (HTTP 409)");
  assert.equal(f("tag", "add", "b", ["a"], "qBittorrent refused it (HTTP 409)"), "Created a; creating tag b failed (HTTP 409)");
  assert.equal(f("tag", "add", "b", [], "qBittorrent refused it (HTTP 409)"), "Creating tag b failed: HTTP 409");
  for (const line of [f("category", "set", "", [], "HTTP 409"), f("tag", "set", "", [], "HTTP 409")]) {
    assert.notEqual(line, "HTTP 409");
    assert.match(line, /failed/);
  }
});

test("tagAccept with the cursor row: Enter on + New tag creates and adds it; a refused + New stays open with the reason", () => {
  const original = [{ name: "a", state: "none", mark: "[ ]" }];
  const rows = L.tagPickerRows("new one", original, FUZZY);
  const plus = rows.find((r) => r.isNew);
  assert.deepEqual(L.tagAccept(original, original, plus), { creates: ["new one"], changes: { add: ["new one"], remove: [] }, op: "change" });
  const bad = L.tagPickerRows(" x", original, FUZZY).find((r) => r.isNew);
  assert.deepEqual(L.tagAccept(original, original, bad), { op: "refuse", note: "No spaces at the start or end." });
  // an ordinary cursor row is never toggled by Enter
  const aRow = L.tagPickerRows("", original, FUZZY)[0];
  assert.equal(L.tagAccept(original, original, aRow).op, "none");
});

test("pickerSteps: + New is two writes, the create first; a plain change is one", () => {
  assert.deepEqual(L.pickerSteps("category", { op: "set", name: "anime", hashes: [H("a")] }), [
    { kind: "category", step: "set", name: "anime", hashes: [H("a")] }
  ]);
  assert.deepEqual(L.pickerSteps("category", { op: "set", name: "anime", hashes: [H("c")] }, [H("b"), H("c")]), [
    { kind: "category", step: "set", name: "anime", hashes: [H("c")] }
  ], "only the targets whose category changes, as the CONFIRM counted them");
  assert.deepEqual(L.pickerSteps("category", { op: "create", name: "fresh", hashes: [H("a")] }), [
    { kind: "category", step: "add", name: "fresh" },
    { kind: "category", step: "set", name: "fresh", hashes: [H("a")] }
  ]);
  assert.deepEqual(L.pickerSteps("tag", { op: "change", creates: ["x", "y"], changes: { add: ["x", "y", "a"], remove: ["b"] } }, [H("a"), H("b")]), [
    { kind: "tag", step: "add", name: "x" },
    { kind: "tag", step: "add", name: "y" },
    { kind: "tag", step: "set", name: "", hashes: [H("a"), H("b")], changes: { add: ["x", "y", "a"], remove: ["b"] } }
  ]);
  assert.deepEqual(L.pickerSteps("tag", { op: "none", creates: [], changes: { add: [], remove: [] } }, [H("a")]), []);
});
