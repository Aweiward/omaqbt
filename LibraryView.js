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

// hasName(list, name) -> whether list (a status's categories or tags, a JS
// array or a QML sequence) has exactly name.
function hasName(list, name) {
  return names(list).indexOf(String(name)) !== -1;
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

// libraryReady(status) -> false while defaultSavePath is missing or empty,
// or while the API is down (status.api false: its torrents and categories
// are empty, not real). A status without `api` is judged on its folders.
function libraryReady(status) {
  return !!status && status.api !== false && typeof status.defaultSavePath === "string" && status.defaultSavePath !== "";
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

// movePlan(action, rows, status) -> [{hash, from, to, unfinished?}] for the
// auto-managed rows whose files the action would move, or []. `rows` is
// every torrent (Service.torrents). action is one of:
//   {kind: "setCategory", hashes, name}         C (hashes: see hashList;
//                                               name "" = none)
//   {kind: "rename", old, new}                  c (a merge when new exists)
//   {kind: "remove", name}                      x
//   {kind: "path", name, path, home?}           p (path "" = default; "~/"
//                                               uses home, else shown as typed)
//
// Not ready (libraryReady false: no default save path, or the API down) it
// fails closed before the relocation check (ruling BQ): the relocation
// preferences and the folders aren't known, so every affected managed row
// counts, with to "". A setCategory hash missing from rows is an unknown
// managed row ({hash, from: "", to: ""}) whenever a move is possible.
//
// Ruling BR: qBittorrent 5.2.3's adjustStorageLocation moves an unfinished
// torrent to its download path when it has one, and download paths differ
// per category, so an auto-managed row with progress < 1 counts whenever
// its category changes (setCategory to another category, rename, remove),
// even when the save paths are equal; it carries unfinished: true. Not for
// "path": a save-path change leaves unfinished torrents where they are.
function movePlan(action, rows, status) {
  var pref = action ? RELOCATION_PREFERENCE[action.kind] : undefined;
  if (!pref) return [];
  var ready = libraryReady(status);
  if (ready && (!status.relocation || status.relocation[pref] !== true)) return [];
  var affects, to;
  var changes = function(row) { return true; };
  var st = status || {};
  if (action.kind === "setCategory") {
    var hashes = hashList(action.hashes);
    var target = String(action.name || "");
    affects = function(row) { return hashes.indexOf(Model.torrentId(row)) !== -1; };
    changes = function(row) { return String(row.category || "") !== target; };
    to = categorySavePath(action.name, status);
  } else if (action.kind === "rename") {
    // qbt's create step copies old's save path; a merge needs equal paths.
    var paths = st.categoryPaths || {};
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
    changes = function(row) { return false; };
    to = p.indexOf("~/") === 0 ? p : resolveSavePath(p, String(action.name || ""), status);
  }
  if (!ready) to = "";
  // Fail closed (ruling BM): a destination that didn't resolve to an
  // absolute folder (no default save path yet) is "", and every managed
  // row still counts, so a caller that skipped libraryReady still confirms.
  // A "~/" path without home stays as typed; qbt expands it.
  if (to.charAt(0) !== "/" && to.indexOf("~/") !== 0) to = "";
  var out = [];
  var seen = [];
  var list = rows || [];
  for (var i = 0; i < list.length; i++) {
    var row = list[i];
    if (!row) continue;
    if (action.kind === "setCategory") seen.push(Model.torrentId(row));
    if (row.autoTmm !== true || !affects(row)) continue;
    var from = cleanPath(row.savePath);
    var unfinished = Number(row.progress) < 1 && changes(row);
    if (to !== "" && from === to && !unfinished) continue;
    var entry = { hash: Model.torrentId(row), from: from, to: to };
    if (unfinished) entry.unfinished = true;
    out.push(entry);
  }
  if (action.kind === "setCategory") {
    for (var j = 0; j < hashes.length; j++) if (seen.indexOf(hashes[j]) === -1) out.push({ hash: hashes[j], from: "", to: "" });
  }
  return out;
}

// --- Confirm copy (one CONFIRM per action) ------------------------------------------

// Ruling BR: the rows that move to a save path, i.e. all but the unfinished
// ones whose save path stays (those move only to their download folder).
function movers(plan) {
  var out = [];
  for (var i = 0; i < plan.length; i++) if (!(plan[i].unfinished === true && plan[i].to !== "" && plan[i].from === plan[i].to)) out.push(plan[i]);
  return out;
}

function unfinishedCount(plan) {
  var n = 0;
  for (var i = 0; i < plan.length; i++) if (plan[i].unfinished === true) n++;
  return n;
}

// "; unfinished ones move to their download folder" when the plan has any.
function unfinishedClause(plan) {
  return unfinishedCount(plan) > 0 ? "; unfinished ones move to their download folder" : "";
}

// When only unfinished rows move: "2 unfinished torrents' files move to
// their download folder".
function unfinishedOnly(plan) {
  var u = unfinishedCount(plan);
  return u + " unfinished" + plural(u, " torrent's", " torrents'") + " files move to " + plural(u, "its", "their") + " download folder";
}

function destinationText(plan) {
  var seen = [];
  for (var i = 0; i < plan.length; i++) if (seen.indexOf(plan[i].to) === -1) seen.push(plan[i].to);
  if (seen.length !== 1) return seen.length + " folders";
  return seen[0] === "" ? "a folder qBittorrent picks" : seen[0];
}

// The move sentence folded into a delete, rename or path confirm: "Their
// files move to /dl." when every counted torrent moves, else "3 torrents'
// files move to /dl." "" when nothing moves.
// Unfinished rows (ruling BR) add "; unfinished ones move to their
// download folder", or, when they are all that moves, "1 unfinished
// torrent's files move to its download folder."
function moveSentence(plan, count) {
  var list = plan || [];
  if (list.length === 0) return "";
  var m = movers(list);
  if (m.length === 0) return unfinishedOnly(list) + ".";
  var dest = destinationText(m);
  var tail = unfinishedClause(list) + ".";
  if (m.length >= count) return plural(m.length, "Its", "Their") + " files move to " + dest + tail;
  return torrentsPossessive(m.length) + " files move to " + dest + tail;
}

// moveConfirmLine(plan, total) -> the C picker's confirm, or "" when nothing
// moves: "Changes 3 torrents' category; their files move to /srv/anime."
// total is how many torrents the change covers (a VISUAL range may mix
// auto-managed and manual ones); it defaults to the plan's length.
function moveConfirmLine(plan, total) {
  var list = plan || [];
  if (list.length === 0) return "";
  var n = Math.max(Number(total) || 0, list.length);
  var m = movers(list);
  var tail;
  if (m.length === 0) tail = unfinishedOnly(list) + ".";
  else {
    var dest = destinationText(m);
    var rest = unfinishedClause(list) + ".";
    tail = m.length === n
      ? plural(n, "its", "their") + " files move to " + dest + rest
      : torrentsPossessive(m.length) + " files move to " + dest + rest;
  }
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

// --- The filters pane (Task 5) --------------------------------------------------------

// libraryCopy(verb, kind, name, newName) -> the status line's copy for a
// filters-pane write (ClientView.msgTrack's `copy`): verb "add", "rename",
// "path" or "remove"; kind "category" or "tag". A rename is raw: its
// failure shows qbt's own sentence as-is, which stands alone (e.g. "Rename
// incomplete (12 of 21 moved); press c on anime again to finish."). The
// others carry `fail`, the action a failure names first: "Deleting
// category anime failed: HTTP 409" (ruling BS, Minor 5).
function libraryCopy(verb, kind, name, newName) {
  var what = kind === "tag" ? "tag" : "category";
  if (verb === "add") return { progress: "Adding " + what + "…", done: (what === "tag" ? "Tag" : "Category") + " added", fail: "Adding " + what + " " + name + " failed" };
  if (verb === "rename") return { progress: "Renaming " + name + " → " + newName + "…", done: "Renamed " + name + " → " + newName, raw: true };
  if (verb === "path") return { progress: "Setting " + name + "'s save path…", done: "Save path set", fail: "Setting " + name + "'s save path failed" };
  return { progress: "Deleting " + what + " " + name + "…", done: "Deleted " + what + " " + name, fail: "Deleting " + what + " " + name + " failed" };
}

// savePathError(text) -> "" or why `p` can't use text: qbt category-path
// takes "" (qBittorrent's default), an absolute path or ~/..., with this
// same message.
function savePathError(text) {
  var s = String(text === undefined || text === null ? "" : text);
  if (s === "" || s.charAt(0) === "/" || s.indexOf("~/") === 0) return "";
  return "The save path must be absolute or start with ~/.";
}

// footerKeys(target) -> [{key, label}] for the filters pane's footer: the
// keys that apply to the row under the filters cursor (ClientView.
// libraryTarget). A named category: a c p x; a named tag: a c x;
// Uncategorized/Untagged: a, to add to that group; anything else: none.
function footerKeys(target) {
  var t = target || {};
  if (t.kind !== "category" && t.kind !== "tag") return [];
  if (String(t.value || "") === "") return [{ key: "a", label: t.kind === "tag" ? "new tag" : "new category" }];
  var keys = [{ key: "a", label: "add" }, { key: "c", label: "rename" }];
  if (t.kind === "category") keys.push({ key: "p", label: "save path" });
  keys.push({ key: "x", label: "delete" });
  return keys;
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

// --- The C and T pickers (Task 6) ---------------------------------------------------
//
// Rows are ListOverlay's {kind, id, title, indices, enabled, reason, keys,
// prefix}, plus `value` (the category or tag name) and `isNew` ("+ New").
// `match` is ClientView.fuzzyMatch (query, title) -> {score, indices} or
// null, passed in because this file can't import ClientView.

var NO_CATEGORY = "(no category)";

// The rows a query keeps, best match first (ties keep their order).
function matchRows(query, rows, match) {
  if (query === "") return rows;
  var hits = [];
  for (var i = 0; i < rows.length; i++) {
    var m = match(query, rows[i].title);
    if (!m) continue;
    rows[i].indices = m.indices;
    hits.push({ row: rows[i], score: m.score, at: i });
  }
  hits.sort(function(a, b) { return b.score - a.score || a.at - b.at; });
  return hits.map(function(h) { return h.row; });
}

// The "+ New …" row for a query that names nothing yet: enabled only when
// nameError passes, else dimmed with the reason.
function newRow(kind, query) {
  var err = nameError(kind, query, []);
  return { kind: kind, id: "new", value: query, title: "+ New " + kind + " \"" + query + "\"", indices: [],
    enabled: err === "", reason: err, keys: "", isNew: true };
}

// categoryPickerRows(query, categories, targetRows, match) -> C's rows:
// "(no category)", then every category (legacy names too: assigning an
// existing one is allowed), each with "N of M now" when N of the M target
// torrents are on it; and "+ New category "<query>"" unless the query is
// exactly an existing name.
function categoryPickerRows(query, categories, targetRows, match) {
  var q = String(query || "");
  var targets = names(targetRows);
  var list = [""].concat(names(categories).map(String));
  var rows = [];
  for (var i = 0; i < list.length; i++) {
    var have = 0;
    for (var j = 0; j < targets.length; j++) if (String((targets[j] || {}).category || "") === list[i]) have++;
    rows.push({ kind: "category", id: "c:" + list[i], value: list[i], title: list[i] === "" ? NO_CATEGORY : list[i], indices: [],
      enabled: true, reason: "", keys: have > 0 ? have + " of " + targets.length + " now" : "" });
  }
  var out = matchRows(q, rows, match);
  if (q !== "" && !hasName(categories, q)) out.push(newRow("category", q));
  return out;
}

function rowFor(torrents, hash) {
  var list = names(torrents);
  for (var i = 0; i < list.length; i++) if (list[i] && Model.torrentId(list[i]) === hash) return list[i];
  return null;
}

// categoryAccept(row, targets, torrents, status) -> what C's Enter does on
// the target hashes captured when C was pressed:
//   {op: "none"}                      no row, or every target is already on it
//   {op: "refuse", note}              a "+ New" name nameError refuses
//   {op: "set"|"create", name, hashes, line}
// hashes are the targets whose category changes; "create" adds the
// category (empty save path) before the set. line is the move CONFIRM
// (G8), "" when nothing moves; it comes before any write. A new category's
// folder is <parent's folder or default>/<name>, as qBittorrent makes it.
function categoryAccept(row, targets, torrents, status) {
  if (!row) return { op: "none" };
  if (row.enabled === false) return { op: "refuse", note: String(row.reason || "") };
  var name = String(row.value || "");
  if (row.isNew === true) {
    var err = nameError("category", name, status && status.categories);
    if (err !== "") return { op: "refuse", note: err };
  }
  var all = hashList(targets);
  var hashes = [];
  for (var i = 0; i < all.length; i++) {
    var t = rowFor(torrents, all[i]);
    if (!t || String(t.category || "") !== name) hashes.push(all[i]);
  }
  if (hashes.length === 0 && row.isNew !== true) return { op: "none" };
  var plan = movePlan({ kind: "setCategory", hashes: hashes, name: name }, torrents, status);
  return { op: row.isNew === true ? "create" : "set", name: name, hashes: hashes, line: moveConfirmLine(plan, hashes.length) };
}

// tagPickerRows(query, states, match) -> T's rows from the working states
// ([{name, state, mark, isNew?}], tagStates plus toggles): the mark as the
// prefix, and "+ New tag "<query>"" unless a tag is exactly the query.
function tagPickerRows(query, states, match) {
  var q = String(query || "");
  var list = names(states);
  var rows = [];
  var known = [];
  for (var i = 0; i < list.length; i++) {
    known.push(list[i].name);
    rows.push({ kind: "tag", id: "t:" + list[i].name, value: list[i].name, title: list[i].name, indices: [],
      enabled: true, reason: "", keys: "", prefix: list[i].mark });
  }
  var out = matchRows(q, rows, match);
  if (q !== "" && known.indexOf(q) === -1) out.push(newRow("tag", q));
  return out;
}

function withState(item, state) {
  var out = { name: item.name, state: state, mark: TAG_MARK[state] };
  if (item.isNew) out.isNew = true;
  return out;
}

// toggleTag(states, original, name) -> a new working list with `name`
// toggled: some -> all -> none -> (some again, when it started as some)
// -> all. A name not in the list is a new tag: it joins as all (isNew),
// and toggling it off drops it again. Neither input is changed.
function toggleTag(states, original, name) {
  var list = names(states);
  var was = stateMap(original)[name];
  var out = [];
  var found = false;
  for (var i = 0; i < list.length; i++) {
    var item = list[i];
    if (item.name !== name) { out.push(item); continue; }
    found = true;
    if (item.state === "all") {
      if (!item.isNew) out.push(withState(item, "none"));
    } else if (item.state === "none" && was === "some") {
      out.push(withState(item, "some"));
    } else {
      out.push(withState(item, "all"));
    }
  }
  if (!found) out.push({ name: String(name), state: "all", mark: TAG_MARK.all, isNew: true });
  return out;
}

// tagAccept(original, working, row) -> what T's Enter sends: {creates:
// new tags to add first, changes: tagChanges(original, working), op:
// "change" or "none" when nothing changed}. An ordinary cursor row is never
// toggled by Enter; `row` matters only when it is "+ New tag": Enter then
// creates and adds that tag too, or {op: "refuse", note} when nameError
// refuses it.
function tagAccept(original, working, row) {
  if (row && row.isNew === true) {
    if (row.enabled === false) return { op: "refuse", note: String(row.reason || "") };
    working = toggleTag(working, original, String(row.value));
  }
  var list = names(working);
  var creates = [];
  for (var i = 0; i < list.length; i++) if (list[i].isNew && list[i].state === "all") creates.push(list[i].name);
  var changes = tagChanges(original, working);
  return { creates: creates, changes: changes, op: changes.add.length + changes.remove.length > 0 ? "change" : "none" };
}

// pickerSteps(kind, accept, hashes) -> the writes an accepted picker runs,
// in order, each after the one before succeeds: every "+ New" create
// ({kind, step: "add", name}), then the one set ({kind, step: "set", name,
// hashes} for a category, {..., changes} for tags). A category sets only
// accept.hashes (the targets whose category changes, the ones its CONFIRM
// counted); tags go to every target in `hashes`. accept is categoryAccept's
// or tagAccept's result.
function pickerSteps(kind, accept, hashes) {
  var a = accept || {};
  var steps = [];
  if (kind === "tag") {
    if (a.op !== "change") return [];
    var creates = names(a.creates);
    for (var i = 0; i < creates.length; i++) steps.push({ kind: "tag", step: "add", name: creates[i] });
    steps.push({ kind: "tag", step: "set", name: "", hashes: hashList(hashes), changes: a.changes });
    return steps;
  }
  if (a.op !== "set" && a.op !== "create") return [];
  if (a.op === "create") steps.push({ kind: "category", step: "add", name: a.name });
  steps.push({ kind: "category", step: "set", name: a.name, hashes: hashList(a.hashes) });
  return steps;
}

// pickerCopy(kind, step, name) -> ClientView.msgTrack's copy for a picker
// write: step "add" (a "+ New" create, no done note: the set follows) or
// "set" (set-category, or tags).
function pickerCopy(kind, step, name) {
  if (step === "add") return { progress: "Creating " + kind + " " + name + "…", done: "", raw: true };
  if (kind === "tag") return { progress: "Changing tags…", done: "Tags changed", raw: true };
  if (name === "") return { progress: "Removing the category…", done: "Category removed", raw: true };
  return { progress: "Setting category " + name + "…", done: "Category set to " + name, raw: true };
}

// pickerFailure(kind, step, name, created, error) -> the one status line
// for a failed picker write (OV7). error is qbt's stderr; created are the
// names this Enter already created. Every line names the action: qbt's
// "Tags: …" and "Category set on N of M …" sentences already do and pass
// through; its bare "qBittorrent refused it (HTTP 409)" becomes "Setting
// the category failed: HTTP 409"; after a create, "Created <name>;
// setting it failed (HTTP 409)". chunk ({done, total}, optional): the
// hashes a chunked set covered, and how many of them were in chunks that
// succeeded; when some did, the line says so (ruling BS, Minor 6):
// "Category set on 1000 of 1500; the rest failed (HTTP 409)".
function pickerFailure(kind, step, name, created, error, chunk) {
  var err = String(error || "").trim();
  var m = /^qBittorrent refused it \((.*)\)$/.exec(err);
  var detail = m ? m[1] : err;
  var made = names(created);
  var lead = made.length > 0 ? "Created " + made.join(", ") + "; " : "";
  var paren = detail === "" ? "" : " (" + detail.replace(/\.$/, "") + ")";
  var colon = detail === "" ? "." : ": " + detail;
  var done = chunk ? Number(chunk.done) || 0 : 0;
  var total = chunk ? Number(chunk.total) || 0 : 0;
  if (step !== "add" && done > 0 && done < total) {
    var head = kind === "tag" ? "Tags changed on " : (name === "" ? "Category removed from " : "Category set on ");
    var rest = kind === "tag" && err.indexOf("Tags: ") === 0 ? "; the rest: " + err.substring(6) : "; the rest failed" + (paren === "" ? "." : paren);
    var partial = head + done + " of " + total + rest;
    return lead === "" ? partial : lead + partial.charAt(0).toLowerCase() + partial.substring(1);
  }
  if (step === "add") {
    return lead === "" ? "Creating " + kind + " " + name + " failed" + colon : lead + "creating " + kind + " " + name + " failed" + paren;
  }
  var named = kind === "tag" ? err.indexOf("Tags: ") === 0 : err.indexOf("Category set on ") === 0;
  if (named) return lead === "" ? err : lead + err.charAt(0).toLowerCase() + err.substring(1);
  if (lead !== "") return lead + (kind === "tag" ? "tagging failed" : "setting it failed") + paren;
  return (kind === "tag" ? "Changing the tags failed" : "Setting the category failed") + colon;
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
    tagChanges: tagChanges,
    libraryCopy: libraryCopy,
    savePathError: savePathError,
    footerKeys: footerKeys,
    hasName: hasName,
    explicitSavePath: explicitSavePath,
    categoryPickerRows: categoryPickerRows,
    categoryAccept: categoryAccept,
    tagPickerRows: tagPickerRows,
    toggleTag: toggleTag,
    tagAccept: tagAccept,
    pickerSteps: pickerSteps,
    pickerCopy: pickerCopy,
    pickerFailure: pickerFailure
  };
}
