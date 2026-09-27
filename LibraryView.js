.pragma library
.import "Model.js" as Model

// Pure rules for managing categories and tags (slice 3a): the new-name
// rules, the rename refusals, the file-move prediction (G8), the confirm
// copy, usage counts, the filter follow-up (OV9) and the tag picker's
// states. No I/O, no Date, no Qt objects: everything comes in through
// arguments, so tests/library-view.test.js can run it in node. Imports only
// Model.js -- never ClientView.js, since two `.pragma library` modules must
// not import each other.
//
// The `.pragma library` / `.import` lines above are QML-only. The node
// test strips them and runs this file in a vm context with `Model`
// supplied (see the test's loader), because node can't parse them and QML
// can't `require`.

// --- Small helpers (private) -------------------------------------------------

function plural(n, one, many) {
  return n === 1 ? one : many;
}

// "1 torrent" / "3 torrents".
function torrentsText(n) {
  return n + plural(n, " torrent", " torrents");
}

// "1 torrent's" / "3 torrents'".
function torrentsPossessive(n) {
  return n + plural(n, " torrent's", " torrents'");
}

// A list from a JS array or an array-like (a QML sequence can fail
// Array.isArray); anything else, a string included, is empty.
function names(list) {
  if (Array.isArray(list)) return list;
  if (list && typeof list === "object" && typeof list.length === "number") return Array.prototype.slice.call(list);
  return [];
}

// hashList(hashes) -> an array of hashes from a "|" list (the form window
// actions pass), an array or an array-like, with empty entries dropped.
// Service.qml uses it too, so the confirm and the call see the same list.
function hashList(hashes) {
  var list = typeof hashes === "string" ? hashes.split("|") : names(hashes);
  var out = [];
  for (var i = 0; i < list.length; i++) if (list[i]) out.push(String(list[i]));
  return out;
}

// Ruling BM: category writes wait until the status carries qBittorrent's
// default save path, since every category folder is resolved from it.
var LIBRARY_NOT_READY = "Still reading qBittorrent's folders; try again in a moment.";

// libraryReady(status) -> false while defaultSavePath is missing or empty.
function libraryReady(status) {
  return !!status && typeof status.defaultSavePath === "string" && status.defaultSavePath !== "";
}

// QDir::cleanPath, as qBittorrent's Path does: duplicate slashes collapse,
// "." segments go, ".." removes the segment before it (never above "/"),
// and a trailing slash goes. Used for every path compared or shown.
function cleanPath(p) {
  var s = String(p || "");
  if (s === "") return "";
  var abs = s.charAt(0) === "/";
  var parts = s.split("/");
  var out = [];
  for (var i = 0; i < parts.length; i++) {
    var seg = parts[i];
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      if (out.length > 0 && out[out.length - 1] !== "..") out.pop();
      else if (!abs) out.push("..");
      continue;
    }
    out.push(seg);
  }
  var joined = out.join("/");
  if (abs) return "/" + joined;
  return joined === "" ? "." : joined;
}

// Path's operator/: an empty side gives the other side; otherwise the two
// joined with "/" and cleaned.
function joinPath(base, rest) {
  var b = String(base || ""), r = String(rest || "");
  if (b === "") return cleanPath(r);
  if (r === "") return cleanPath(b);
  return cleanPath(b + "/" + r);
}

// --- Name rules (G4, OV5) -----------------------------------------------------

// The characters qbt refuses at either end of a new name: U+0020 plus every
// other character qBittorrent's QString::trimmed strips that isn't already
// a refused control character. The same list as qbt's NAME_EDGE_SPACES; JS
// `\s` differs (it adds U+FEFF, and U+0085 is a control here).
var EDGE_SPACES = [0x20, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
  0x2007, 0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000];

// C0 (U+0000-001F), DEL and the C1 block (U+0080-009F).
function isControl(cp) {
  return cp <= 0x1f || (cp >= 0x7f && cp <= 0x9f);
}

// nameError(kind, text, existing) -> "" or why `text` can't be a NEW
// category ("category") or tag ("tag") name, in qbt's rule order and with
// its exact messages (tests/fixtures/validation-cases.json "names"). Then a
// clash with one of `existing` (the status's names): "\"anime\" already exists."
function nameError(kind, text, existing) {
  var s = text === undefined || text === null ? "" : String(text);
  if (s === "") return "Type a name.";
  var chars = Array.from(s);
  for (var i = 0; i < chars.length; i++) {
    if (isControl(chars[i].codePointAt(0))) return "No control characters in a name.";
  }
  if (chars.length > 64) return "Keep it to 64 characters.";
  if (EDGE_SPACES.indexOf(chars[0].codePointAt(0)) !== -1
      || EDGE_SPACES.indexOf(chars[chars.length - 1].codePointAt(0)) !== -1) return "No spaces at the start or end.";
  if (kind === "tag") {
    if (s.indexOf(",") !== -1) return "No commas in a tag.";
  } else {
    if (s.indexOf("\\") !== -1) return "No backslashes in a category.";
    if (s.charAt(0) === "/" || s.charAt(s.length - 1) === "/") return "A category can't start or end with /.";
    if (s.indexOf("//") !== -1) return "No // in a category.";
  }
  if (names(existing).indexOf(s) !== -1) return "\"" + s + "\" already exists.";
  return "";
}

// renameError(old, new, categories) -> "" or qbt category-rename's refusal
// that the window can give before any confirm (ruling BG): 5.2.3's
// removeCategory also removes every "old/..." category, so the rename's
// final delete would take those with it. Categories only; share limits
// aren't in the status, so qbt's own refusal shows for those.
function renameError(oldName, newName, categories) {
  var prefix = String(oldName) + "/";
  if (String(newName).indexOf(prefix) === 0) return "Can't rename " + oldName + " into its own subcategory.";
  if (subcategoryCount(oldName, categories) > 0) return oldName + " has subcategories; rename or remove them first.";
  return "";
}

// --- Category hierarchy ---------------------------------------------------------

// parentCategoryName("anime/2026") -> "anime"; a top-level name -> "".
function parentCategoryName(name) {
  var s = String(name || "");
  var at = s.lastIndexOf("/");
  return at === -1 ? "" : s.substring(0, at);
}

function inCategoryTree(category, name) {
  var c = String(category || "");
  return c === name || c.indexOf(name + "/") === 0;
}

// subcategoryCount(name, categories) -> how many "name/..." categories exist.
function subcategoryCount(name, categories) {
  var prefix = String(name) + "/";
  var list = names(categories);
  var n = 0;
  for (var i = 0; i < list.length; i++) if (String(list[i]).indexOf(prefix) === 0) n++;
  return n;
}

// --- Where files live (G8, Deviation 3) -----------------------------------------------

// A category's explicit save path from status.categoryPaths, or "" (Task 1's
// parseStatusJson checks only the outer shape, so each entry is read
// defensively).
function explicitSavePath(name, status) {
  var paths = (status && status.categoryPaths) || {};
  var entry = Object.prototype.hasOwnProperty.call(paths, name) ? paths[name] : null;
  if (!entry || typeof entry !== "object" || typeof entry.savePath !== "string") return "";
  return entry.savePath;
}

// Utils::Fs::toValidPath on a leaf: each run of :?"*<>| becomes one space
// (no trimming).
function toValidLeaf(leaf) {
  return String(leaf).replace(/[:?"*<>|]+/g, " ");
}

// Where an auto-managed torrent on category `name` keeps its files, if the
// category's save path were `savePath` -- qBittorrent 5.2.3's
// SessionImpl::categorySavePath:
//   - name "" is the default save path;
//   - an absolute savePath is itself;
//   - a relative savePath is under the default save path (not the parent);
//   - an empty savePath is the parent category's own folder (resolved the
//     same way, recursively; a parent missing from categoryPaths counts as
//     empty) plus "/" plus the leaf after the last "/", through toValidPath.
// So top-level empty-path categories live at <default>/<name>.
function resolveSavePath(savePath, name, status) {
  var base = (status && status.defaultSavePath) || "";
  if (name === "") return cleanPath(base);
  var path = String(savePath || "");
  if (path === "") {
    path = toValidLeaf(name.substring(name.lastIndexOf("/") + 1));
    base = categorySavePath(parentCategoryName(name), status);
  }
  if (path.charAt(0) === "/") return cleanPath(path);
  return joinPath(base, path);
}

// categorySavePath(name, status) -> the folder category `name` uses now (a
// category not created yet counts as having an empty save path).
function categorySavePath(name, status) {
  var n = String(name || "");
  return resolveSavePath(n === "" ? "" : explicitSavePath(n, status), n, status);
}

// Which qBittorrent preference decides whether each action moves files
// (Deviation 3). When it is off, qBittorrent switches the torrent to manual
// mode instead, so nothing moves. If the live check shows another
// preference governing a move, only this table changes.
var RELOCATION_PREFERENCE = {
  setCategory: "torrentChanged",
  rename: "torrentChanged",
  remove: "torrentChanged",
  path: "categoryPathChanged"
};

// movePlan(action, rows, status) -> [{hash, from, to}] for the auto-managed
// rows whose files the action would move, or []. `rows` is every torrent
// (Service.torrents). action is one of:
//   {kind: "setCategory", hashes, name}         C (hashes: see hashList;
//                                               name "" = none)
//   {kind: "rename", old, new}                  c (a merge when new exists)
//   {kind: "remove", name}                      x
//   {kind: "path", name, path, home?}           p (path "" = default; "~/"
//                                               uses home, else shown as typed)
function movePlan(action, rows, status) {
  var pref = action ? RELOCATION_PREFERENCE[action.kind] : undefined;
  if (!pref || !status || !status.relocation || status.relocation[pref] !== true) return [];
  var affects, to;
  if (action.kind === "setCategory") {
    var hashes = hashList(action.hashes);
    affects = function(row) { return hashes.indexOf(Model.torrentId(row)) !== -1; };
    to = categorySavePath(action.name, status);
  } else if (action.kind === "rename") {
    // qbt's create step copies old's save path; a merge needs equal paths.
    var paths = status.categoryPaths || {};
    var source = Object.prototype.hasOwnProperty.call(paths, action.new) ? action.new : action.old;
    affects = function(row) { return String(row.category || "") === action.old; };
    to = resolveSavePath(explicitSavePath(source, status), String(action.new), status);
  } else if (action.kind === "remove") {
    // 5.2.3's removeCategory moves name and name/... to name's parent.
    var name = String(action.name || "");
    if (name === "") return [];
    affects = function(row) { return inCategoryTree(row.category, name); };
    to = categorySavePath(parentCategoryName(name), status);
  } else {
    var p = String(action.path || "");
    if (p.indexOf("~/") === 0 && action.home) p = joinPath(action.home, p.substring(2));
    affects = function(row) { return String(row.category || "") === action.name; };
    to = p.indexOf("~/") === 0 ? p : resolveSavePath(p, String(action.name || ""), status);
  }
  // Fail closed (ruling BM): a destination that didn't resolve to an
  // absolute folder (no default save path yet) is "", and every managed
  // row still counts, so a caller that skipped libraryReady still confirms.
  // A "~/" path without home stays as typed; qbt expands it.
  if (to.charAt(0) !== "/" && to.indexOf("~/") !== 0) to = "";
  var out = [];
  var list = rows || [];
  for (var i = 0; i < list.length; i++) {
    var row = list[i];
    if (!row || row.autoTmm !== true || !affects(row)) continue;
    var from = cleanPath(row.savePath);
    if (to === "" || from !== to) out.push({ hash: Model.torrentId(row), from: from, to: to });
  }
  return out;
}

// --- Confirm copy (one CONFIRM per action) ------------------------------------------

function destinationText(plan) {
  var seen = [];
  for (var i = 0; i < plan.length; i++) if (seen.indexOf(plan[i].to) === -1) seen.push(plan[i].to);
  if (seen.length !== 1) return seen.length + " folders";
  return seen[0] === "" ? "a folder qBittorrent picks" : seen[0];
}

// The move sentence folded into a delete, rename or path confirm: "Their
// files move to /dl." when every counted torrent moves, else "3 torrents'
// files move to /dl." "" when nothing moves.
function moveSentence(plan, count) {
  var list = plan || [];
  if (list.length === 0) return "";
  var dest = destinationText(list);
  if (list.length >= count) return plural(list.length, "Its", "Their") + " files move to " + dest + ".";
  return torrentsPossessive(list.length) + " files move to " + dest + ".";
}

// moveConfirmLine(plan, total) -> the C picker's confirm, or "" when nothing
// moves: "Changes 3 torrents' category; their files move to /srv/anime."
// total is how many torrents the change covers (a VISUAL range may mix
// auto-managed and manual ones); it defaults to the plan's length.
function moveConfirmLine(plan, total) {
  var list = plan || [];
  if (list.length === 0) return "";
  var n = Math.max(Number(total) || 0, list.length);
  var dest = destinationText(list);
  var tail = list.length === n
    ? plural(n, "its", "their") + " files move to " + dest + "."
    : torrentsPossessive(list.length) + " files move to " + dest + ".";
  return "Changes " + torrentsPossessive(n) + " category; " + tail;
}

function joinSentences(parts) {
  var out = [];
  for (var i = 0; i < parts.length; i++) if (parts[i]) out.push(parts[i]);
  return out.join(" ");
}

// deleteConfirmLine(kind, name, count, subcategories, plan) -> x's confirm.
// count is usageCount; subcategories is subcategoryCount; plan is movePlan
// for {kind: "remove"} (categories only).
function deleteConfirmLine(kind, name, count, subcategories, plan) {
  var n = Number(count) || 0;
  if (kind === "tag") {
    return "Delete tag " + name + "? " + (n === 0 ? "No torrents use it." : "It's removed from " + torrentsText(n) + ".");
  }
  var parent = parentCategoryName(name);
  var usage;
  if (n === 0) usage = "No torrents use it.";
  else if (parent === "") usage = torrentsText(n) + plural(n, " becomes", " become") + " Uncategorized.";
  else usage = torrentsText(n) + plural(n, " moves", " move") + " to " + parent + ".";
  var subs = Number(subcategories) || 0;
  return joinSentences([
    "Delete category " + name + "? " + usage,
    subs > 0 ? "It also deletes its " + subs + plural(subs, " subcategory.", " subcategories.") : "",
    moveSentence(plan, n)
  ]);
}

// renameConfirmLine(old, new, exists, count, plan) -> c's single confirm,
// or "" when there's nothing to confirm (a new name and no files move).
// exists: new is already a category/tag (G9, a merge); count: usageCount of
// old's own torrents; plan: movePlan for {kind: "rename"} (categories).
function renameConfirmLine(oldName, newName, exists, count, plan) {
  var n = Number(count) || 0;
  var move = moveSentence(plan, n);
  if (exists) {
    var ask = n === 0
      ? "No torrents use " + oldName + "; delete it?"
      : "Move " + torrentsText(n) + " into it and delete " + oldName + "?";
    return joinSentences([newName + " already exists. " + ask, move]);
  }
  if (move === "") return "";
  return "Rename " + oldName + " to " + newName + "? " + move;
}

// pathConfirmLine(name, plan) -> p's confirm, or "" when nothing moves.
function pathConfirmLine(name, plan) {
  var list = plan || [];
  if (list.length === 0) return "";
  return "Change " + name + "'s save path? " + torrentsPossessive(list.length) + " files move to " + destinationText(list) + ".";
}

// --- Usage (OV8) -------------------------------------------------------------------

// usageCount(kind, name, rows, pendingHashes, ownOnly) -> how many torrents
// the action touches. Callers pass rows = Service.torrents, never the
// table's rows (ruling BL): pending browser magnets count too (OV8), since the table
// hides them but qBittorrent changes them all the same. pendingHashes
// (Service.magnetPendingHashes) is part of the signature so the call site
// says so; a pending row is counted from rows like any other, never
// excluded (a magnet still in the inbox isn't in qBittorrent yet, so it has
// no category or tag to lose). A category counts name and name/... (5.2.3's
// removeCategory), or name alone with ownOnly (a rename, whose
// subcategories qbt refuses).
function usageCount(kind, name, rows, pendingHashes, ownOnly) {
  var n = String(name || "");
  if (n === "") return 0;
  var list = rows || [];
  var count = 0;
  for (var i = 0; i < list.length; i++) {
    var row = list[i] || {};
    if (kind === "tag") {
      if (names(row.tags).indexOf(n) !== -1) count++;
    } else if (ownOnly ? String(row.category || "") === n : inCategoryTree(row.category, n)) {
      count++;
    }
  }
  return count;
}

// --- Filter follow-up (OV9) -----------------------------------------------------------

// followFilter(filter, action) -> the active filter after a successful
// rename ({kind: "rename", group, old, new}) or delete ({kind: "remove",
// group, name}) of a category or tag. A deleted category's filter (or one
// on its subcategories) moves to its parent, or Uncategorized ("") at the
// top level; a deleted tag's to Untagged (""). Anything else is unchanged.
function followFilter(filter, action) {
  if (!filter || !action || filter.group !== action.group) return filter;
  if (action.group !== "category" && action.group !== "tag") return filter;
  var value = String(filter.value || "");
  if (action.kind === "rename") {
    return value === action.old ? { group: filter.group, value: String(action.new) } : filter;
  }
  if (action.kind !== "remove") return filter;
  var name = String(action.name || "");
  if (name === "") return filter;
  if (action.group === "tag") return value === name ? { group: "tag", value: "" } : filter;
  return inCategoryTree(value, name) ? { group: "category", value: parentCategoryName(name) } : filter;
}

// --- Tag picker ---------------------------------------------------------------------

var TAG_MARK = { all: "[x]", some: "[~]", none: "[ ]" };

// tagStates(tags, rows) -> [{name, state: "all"|"some"|"none", mark}] per
// tag, in the given order, for the target rows.
function tagStates(tags, rows) {
  var list = rows || [];
  var out = [];
  var t = names(tags);
  for (var i = 0; i < t.length; i++) {
    var have = 0;
    for (var j = 0; j < list.length; j++) if (names(list[j] && list[j].tags).indexOf(t[i]) !== -1) have++;
    var state = have === 0 ? "none" : (have === list.length ? "all" : "some");
    out.push({ name: t[i], state: state, mark: TAG_MARK[state] });
  }
  return out;
}

function stateMap(list) {
  var m = {};
  var l = names(list);
  for (var i = 0; i < l.length; i++) if (l[i]) m[l[i].name] = l[i].state;
  return m;
}

// tagChanges(before, after) -> {add, remove}: tags that became "all" or
// "none" (from tagStates-shaped lists). "some" is left as it was; a tag
// missing from before counts as "none".
function tagChanges(before, after) {
  var was = stateMap(before);
  var list = names(after);
  var add = [], remove = [];
  for (var i = 0; i < list.length; i++) {
    var item = list[i];
    if (!item) continue;
    var prev = was[item.name] || "none";
    if (item.state === "all" && prev !== "all") add.push(item.name);
    else if (item.state === "none" && prev !== "none") remove.push(item.name);
  }
  return { add: add, remove: remove };
}

if (typeof module !== "undefined") {
  module.exports = {
    nameError: nameError,
    renameError: renameError,
    parentCategoryName: parentCategoryName,
    subcategoryCount: subcategoryCount,
    categorySavePath: categorySavePath,
    RELOCATION_PREFERENCE: RELOCATION_PREFERENCE,
    movePlan: movePlan,
    moveConfirmLine: moveConfirmLine,
    deleteConfirmLine: deleteConfirmLine,
    renameConfirmLine: renameConfirmLine,
    pathConfirmLine: pathConfirmLine,
    usageCount: usageCount,
    followFilter: followFilter,
    tagStates: tagStates,
    hashList: hashList,
    libraryReady: libraryReady,
    LIBRARY_NOT_READY: LIBRARY_NOT_READY,
    tagChanges: tagChanges
  };
}
