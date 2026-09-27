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
