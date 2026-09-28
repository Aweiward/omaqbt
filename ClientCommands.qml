pragma ComponentBehavior: Bound

import QtQuick
import "Model.js" as Model
import "CommandRegistry.js" as Registry
import "ClientView.js" as View
import "InspectorView.js" as InspectorView
import "LibraryView.js" as Library
import "LimitsView.js" as Limits

// The window's command -> action mapping: run() turns a command id from
// CommandRegistry into Service calls and view changes on the Client it is
// given. Service calls always carry {origin: "window", hashes}. Client.run
// delegates here, so callers keep calling Client.run and Client.handleKey.
QtObject {
  // The Client item whose state and helpers the commands act on.
  required property var client
  // The InspectorPane, for scrolling the Files cursor into view.
  required property var inspectorPane
  // The StatusLine whose input INSERT edits, and the item that takes the
  // keys again when INSERT ends.
  required property var inputLine
  required property Item keyItem
  // The CommandPalette the palette.* commands drive.
  required property var palette
  // The MagnetConfirm that runs magnet.start / magnet.cancel.
  required property var magnet
  // C's and T's pickers (slice 3a), which the picker.* commands drive.
  required property var categoryPicker
  required property var tagPicker
  // The Settings view (slice 4a, SettingsPane), which the settings.* commands drive.
  required property var settingsView
  // Its editors (Task 6, SettingsCommands): settings.toggle/edit/write, the
  // settingEdit INSERT and the choice picker are forwarded there.
  property var settingsCommands: null
  // The Search view (slice 5a, SearchPane): its INSERTs (searchQuery,
  // pluginInstall) are forwarded there; its commands go there from Client.run.
  property var searchView: null

  // ---- trackers and peers (inspector tabs 2, 3) ---------------------------

  // The tracker url / peer ip:port under each tab's cursor, so a refresh
  // that reorders the list (peers re-sort by speed every tick) keeps the
  // cursor on the same row (stickRow).
  property string trackerKey: ""
  property string peerKey: ""
  // hash|tab|error of the inspect error last put on the status line, so
  // each new error is noted once; "" after a success or a watch change.
  property string notedInspectError: ""

  // Moves inspectNow past tabState's 300 ms "blank" so a tab still
  // waiting for its first reply says "Loading…". A coarse timer can fire
  // up to ~5% early, which would still read "blank" and never re-check,
  // so the clock is advanced to at least since + TAB_BLANK_MS.
  property Timer inspectClock: Timer {
    interval: InspectorView.TAB_BLANK_MS
    onTriggered: client.inspectNow = Math.max(Date.now(), client.inspectSince + InspectorView.TAB_BLANK_MS)
  }

  // The window's watch changed (hashChanged: the cursor torrent, else the
  // tab): restart the stale-reply clock and tell Service. A new torrent
  // starts both lists at the top.
  function syncInspect(hashChanged) {
    var c = client
    if (hashChanged) {
      c.trackerIndex = 0
      c.peerIndex = 0
      trackerKey = ""
      peerKey = ""
    }
    notedInspectError = ""
    c.inspectSince = Date.now()
    c.inspectNow = c.inspectSince
    inspectClock.restart()
    if (c.service && typeof c.service.watch === "function") c.service.watch(c.watchHash, c.inspectorTab)
  }

  // The watched tab's reply changed: a fresh error goes to the status line
  // as an urgent note, once per hash|tab|error (Ruling L); a fresh success
  // re-arms it. A stale entry (older than inspectSince) is ignored.
  function checkInspectError() {
    var c = client
    var e = c.inspectEntry
    if (!e || !(Number(e.at) >= c.inspectSince)) return
    if (!e.error) { notedInspectError = ""; return }
    var k = c.watchHash + "|" + c.inspectorTab + "|" + e.error
    if (k === notedInspectError) return
    notedInspectError = k
    c.note("Couldn't read " + c.inspectorTab + ": " + e.error, "urgent")
  }

  // A refresh of tab's rows: the index of the row with the same key, or
  // the first row when that key is gone (Ruling M); an empty list leaves
  // the index alone.
  function stickRow(tab, rows, index) {
    if (rows.length === 0) return index
    var next = InspectorView.keyedIndex(rows, tab === "trackers" ? trackerKey : peerKey, 0)
    if (tab === "trackers") trackerKey = rows[next].key
    else peerKey = rows[next].key
    return next
  }

  function listRows(tab) {
    return tab === "trackers" ? client.trackersView.rows : client.peersView.rows
  }

  // Puts tab's cursor on row index (a key or a click).
  function setRow(tab, index) {
    var rows = listRows(tab)
    if (index < 0 || index >= rows.length) return
    if (tab === "trackers") { client.trackerIndex = index; trackerKey = rows[index].key }
    else { client.peerIndex = index; peerKey = rows[index].key }
  }

  // `y` in the inspector on trackers or peers (deviation 3: inside
  // torrent.copyMagnet): the tracker's full URL, or the peer's ip:port.
  function copyRow(tab, targets) {
    var c = client
    var row = listRows(tab)[tab === "trackers" ? c.trackerIndex : c.peerIndex]
    if (!row) {
      c.note(tab === "trackers" ? "No tracker to copy." : "No peer to copy.", "muted")
      return
    }
    c.track(c.service.copyText(tab === "trackers" ? row.url : row.ipPort, c.opts(targets)), "copyText", targets)
  }

  // A digit's inspector.* command: switch to tab and, when the inspector
  // is collapsed, open it as an overlay -- exactly as Ctrl-l does (Ruling
  // C: Task 8 adds "chart" here as one more call site).
  function openInspectorTab(tab) {
    var c = client
    c.setInspectorTab(tab)
    if (!c.inspectorDocked) c.setPane("inspector")
  }

  function isEnterKey(ev) {
    return ev.key === Registry.KEY.Return || ev.key === Registry.KEY.Enter
  }

  // A key whose command needs a torrent, pressed with none under the
  // cursor. In the empty library, `y` means "add from clipboard" (the
  // empty state's copy), since there is no torrent to copy a magnet from.
  // Client also sends an unmatched key here: the empty library's filters
  // pane keeps its own keys (ruling BS), where y matches nothing.
  // blocked: the registry's reason (needsReason), "" for none. In Settings
  // only u's "nothing to undo" has one (every other Settings row's reason
  // is "": its row already says why), shown as a muted sentence (Ruling EI).
  // Search (slice 5a) is the same: its reasons are muted sentences.
  function handleBlocked(ev, blocked) {
    var c = client
    if (c.activeView !== "torrents") {
      var why = String(blocked || "")
      if (c.mode === "NORMAL" && why !== "") c.note(why.charAt(0).toUpperCase() + why.slice(1) + ".", "muted")
      return
    }
    if (!c.service || !ev || c.mode !== "NORMAL") return
    if (c.tableState === "empty" && ev.text === "y" && !ev.modifiers.ctrl) {
      c.clipboardAskedAt = ev.now
      c.service.readClipboard()
    }
  }

  // Sets the mode without a dispatch (a click, or a palette row that stays
  // open), keeping the rest of the registry state.
  function setMode(mode) {
    var c = client
    var st = ({})
    for (var k in c.regState) st[k] = c.regState[k]
    st.mode = mode
    c.regState = st
  }

  // The text field that owns the keys in INSERT, COMMAND or PICKER, else null.
  function typingField() {
    var m = client.mode
    if (m === "PICKER") return openPicker() ? openPicker().inputField : null
    return m === "INSERT" ? inputLine.inputField : (m === "COMMAND" ? palette.inputField : null)
  }

  // ---- trackers tab actions (slice 2b) --------------------------------------

  // The torrent (and, for trackerEdit, the tracker) an open trackerAdd /
  // trackerEdit INSERT acts on, captured when a/c was pressed: {hash,
  // oldUrl, shown}, `shown` being the redacted form the prompt names. The
  // commit reads only this, never the cursor or the list as they stand.
  property var trackerInput: null

  function startTrackerInput(purpose, hash, oldUrl) {
    trackerInput = { hash: hash, oldUrl: oldUrl, shown: InspectorView.redactUrl(oldUrl) }
    startInput(purpose, "")
  }

  // Enter on a trackerAdd / trackerEdit field: an invalid URL keeps the
  // field open with the reason; a valid one goes to qbt, which checks it
  // again.
  function commitTracker(text) {
    var c = client
    var err = InspectorView.trackerUrlError(text)
    if (err !== "") {
      c.note(err, "urgent")
      stayInInsert()
      return
    }
    var t = trackerInput
    var h = [t.hash]
    if (c.inputPurpose === "trackerAdd") c.track(c.service.addTracker(t.hash, text, c.opts(h)), "trackerAdd", h)
    else c.track(c.service.editTracker(t.hash, t.oldUrl, text, c.opts(h)), "trackerEdit", h)
    trackerInput = null
    endInput()
  }

  // ---- categories and tags (the filters pane's a/c/p/x, slice 3a) --------------

  // Ruling BM: category writes wait for qBittorrent's default save path.
  // Fed to View.inspectorDispatch, which puts LIBRARY_NOT_READY on a
  // category target's `refusal` until then.
  readonly property bool libraryReady: Library.libraryReady(client.service)
  // The filters pane's footer: the keys that apply to its cursor row.
  readonly property var footerKeys: Library.footerKeys(client.inspectorNow.libraryTarget)
  // The name the INSERT prompt shows: a tracker's redacted URL, or the
  // category or tag being renamed or re-pathed.
  readonly property string inputShown: trackerInput ? trackerInput.shown : (libraryInput ? libraryInput.target.value
    : (limitInput ? limitInput.name : (settingsCommands ? settingsCommands.inputShown : "")))

  // The row an open a/c/p INSERT acts on, captured when the key was
  // pressed: {target} (Registry's frozen copy, {kind, value, label}). The
  // commit reads only this, never the filters cursor as it stands.
  property var libraryInput: null
  // ticket -> what a filters-pane write does once it succeeds: {follow}
  // (LibraryView.followFilter's action, OV9) or {cursor} (a's new row).
  property var libraryWatches: ({})

  function isLibraryPurpose(purpose) {
    return ["categoryAdd", "tagAdd", "categoryRename", "tagRename", "categoryPath"].indexOf(purpose) !== -1
  }

  // a, c or p: open INSERT on the captured row, or say why not (ruling BM).
  function startLibraryInput(commandId, target) {
    var c = client
    if (!target) return
    if (target.refusal) { c.note(target.refusal, "urgent"); return }
    libraryInput = { target: target }
    if (commandId === "library.add") startInput(target.kind + "Add", "")
    else if (commandId === "library.rename") startInput(target.kind + "Rename", target.value)
    else startInput("categoryPath", Library.explicitSavePath(target.value, c.service))
  }

  function refuseInput(text) {
    client.note(text, "urgent")
    stayInInsert()
  }

  // Ruling BQ (G8): the key-time gate isn't enough, since a status tick can
  // land between the key and Enter. A category write that could move files
  // checks again at Enter, before any plan: not ready (no default save
  // path, or the API down) refuses instead of computing an empty plan.
  function readyAtEnter() {
    return Library.libraryReady(client.service)
  }

  // Enter on a filters-pane INSERT. raw is the field exactly as typed: a
  // name is never trimmed, so an edge space gets its message instead of
  // being dropped silently. Counts and moves read every torrent
  // (Service.torrents, ruling BL), never the filtered table.
  function commitLibrary(raw) {
    var c = client
    var svc = c.service
    var t = libraryInput.target
    var purpose = c.inputPurpose
    var names = t.kind === "tag" ? svc.tags : svc.categories
    var err
    if (purpose === "categoryAdd" || purpose === "tagAdd") {
      err = Library.nameError(t.kind, raw, names)
      if (err !== "") { refuseInput(err); return }
      endLibraryInput()
      var ticket = t.kind === "tag" ? svc.addTag(raw, c.opts([])) : svc.addCategory(raw, "", c.opts([]))
      trackLibrary(ticket, Library.libraryCopy("add", t.kind, raw), { cursor: { group: t.kind, value: raw } })
      return
    }
    if (purpose === "categoryPath") {
      if (!readyAtEnter()) { refuseInput(Library.LIBRARY_NOT_READY); return }
      var path = raw.trim()
      err = Library.savePathError(path)
      if (err !== "") { refuseInput(err); return }
      endLibraryInput()
      var plan = Library.movePlan({ kind: "path", name: t.value, path: path, home: svc.homeDir }, svc.torrents, svc)
      askOrRun("library.path", "libraryPath", { target: t, path: path }, Library.pathConfirmLine(t.value, plan), "change")
      return
    }
    // A rename (ruling BG): the new-name rules first (an existing name is
    // a merge, not a clash), then qbt's rename refusals, then one CONFIRM
    // for the merge and/or the move (G8, G9).
    if (raw === t.value) { endLibraryInput(); return }
    if (t.kind === "category" && !readyAtEnter()) { refuseInput(Library.LIBRARY_NOT_READY); return }
    err = Library.nameError(t.kind, raw, [])
    if (err === "" && t.kind === "category") err = Library.renameError(t.value, raw, names)
    if (err !== "") { refuseInput(err); return }
    endLibraryInput()
    var exists = Library.hasName(names, raw)
    var count = Library.usageCount(t.kind, t.value, svc.torrents, svc.magnetPendingHashes, true)
    var moves = t.kind === "category" ? Library.movePlan({ kind: "rename", old: t.value, new: raw }, svc.torrents, svc) : []
    askOrRun("library.rename", "libraryRename", { target: t, newName: raw, merge: exists },
      Library.renameConfirmLine(t.value, raw, exists, count, moves), exists ? "merge" : "rename")
  }

  function endLibraryInput() {
    libraryInput = null
    endInput()
  }

  // Runs a c/p write now, or first raises its one CONFIRM (`line`, from
  // LibraryView) when it merges or moves files; `y` comes back through run
  // with args.confirmed.
  function askOrRun(commandId, kind, args, line, accept) {
    var c = client
    if (line === "") { runLibraryWrite(commandId, args); return }
    var r = Registry.raiseConfirm(c.regState, commandId, kind, args)
    c.regState = r.state
    c.confirmHashes = []
    c.confirm = withLine(r.confirm, line, accept)
  }

  function withLine(confirm, line, accept) {
    var out = ({})
    for (var k in confirm) out[k] = confirm[k]
    out.line = line
    if (accept) out.accept = accept
    return out
  }

  // Client.dispatchWith's hook for a CONFIRM a key raised: x's delete line
  // is built here, at key time, from the target x captured (BF: a
  // category counts its subcategories' torrents too, and names them).
  function describeConfirm(confirm) {
    if (!confirm || confirm.kind !== "libraryRemove" || !confirm.target) return confirm
    var svc = client.service
    var t = confirm.target
    var isCat = t.kind === "category"
    var count = Library.usageCount(t.kind, t.value, svc.torrents, svc.magnetPendingHashes)
    var plan = isCat ? Library.movePlan({ kind: "remove", name: t.value }, svc.torrents, svc) : []
    return withLine(confirm, Library.deleteConfirmLine(t.kind, t.value, count, isCat ? Library.subcategoryCount(t.value, svc.categories) : 0, plan), "delete")
  }

  // The write itself (args.target is the row captured at key time).
  function runLibraryWrite(commandId, args) {
    var svc = client.service
    var t = args.target
    var o = client.opts([])
    var tag = t.kind === "tag"
    if (commandId === "library.rename") {
      trackLibrary(tag ? svc.renameTag(t.value, args.newName, args.merge === true, o) : svc.renameCategory(t.value, args.newName, args.merge === true, o),
        Library.libraryCopy("rename", t.kind, t.value, args.newName), { follow: { kind: "rename", group: t.kind, old: t.value, new: args.newName } })
    } else if (commandId === "library.path") {
      trackLibrary(svc.setCategoryPath(t.value, args.path, o), Library.libraryCopy("path", t.kind, t.value), null)
    } else {
      trackLibrary(tag ? svc.removeTag(t.value, o) : svc.removeCategory(t.value, o),
        Library.libraryCopy("remove", t.kind, t.value), { follow: { kind: "remove", group: t.kind, name: t.value } })
    }
  }

  // ticket: one ticket, or a chunked write's array of them (one watch
  // each); hashes: the torrents a failure marks (none for a-x).
  function trackLibrary(ticket, copy, watch, hashes) {
    var c = client
    var own = hashes || []
    c.messages = View.msgTrack(c.messages, ticket, "library", own.length, own, copy)
    if (watch) watchTickets(Array.isArray(ticket) ? ticket : [ticket], watch)
  }

  function watchTickets(list, watch) {
    var n = ({})
    for (var k in libraryWatches) n[k] = libraryWatches[k]
    for (var i = 0; i < list.length; i++) if (Number(list[i]) > 0) n[String(list[i])] = watch
    libraryWatches = n
  }

  // Client's actionFinished: once one of these writes succeeds, the active
  // filter and the filters cursor follow a renamed or deleted name (OV9,
  // Review Focus 4) and view.json saves; a's cursor goes to the new row. A
  // picker write goes on to its next step, or reports its failure.
  function libraryFinished(ticket, ok, error) {
    var w = libraryWatches[String(ticket)]
    if (!w) return
    var n = ({})
    for (var k in libraryWatches) if (k !== String(ticket)) n[k] = libraryWatches[k]
    libraryWatches = n
    if (w.picker) { pickerFinished(ticket, ok, error, w.picker); return }
    // A limit write that failed may have changed part of what it asked
    // (a partial share-limit write): refresh so what did change shows.
    if (w.refresh) { if (ok !== true) client.service.refresh(); return }
    if (ok !== true) return
    var c = client
    if (w.cursor) { c.setFilterCursor(w.cursor); return }
    var f = Library.followFilter(c.filter, w.follow)
    var fc = Library.followFilter(c.filterCursor, w.follow)
    if (fc !== c.filterCursor) c.setFilterCursor(fc)
    if (f !== c.filter) c.applyFilter(f)
  }

  // ---- the Info tab's Limits group (slice 3b) ---------------------------------

  // hash -> the key of the Limits row under that torrent's cursor, so each
  // torrent keeps its own row (a new one starts at the top); the six keys
  // never change, so keyedIndex only has to fall back for a new torrent.
  property var limitCursors: ({})
  // LimitsView.limitRows for the cursor torrent, and the row under its
  // Limits cursor (null without a torrent).
  readonly property var limitRows: Limits.limitRows(client.cursorRow, client.service)
  readonly property var limitCursorRow: {
    var i = InspectorView.keyedIndex(limitRows, limitCursors[client.cursorHash], 0)
    return i >= 0 ? limitRows[i] : null
  }
  // The cursor shows only while the inspector is focused on Info.
  readonly property var shownLimitRow: View.dispatchPane(client.pane, client.tableState) === "inspector"
    && client.inspectorTab === "info" ? limitCursorRow : null
  readonly property var infoGroups: InspectorView.withLimits(client.infoTab.groups, limitRows, shownLimitRow ? shownLimitRow.key : "")
  readonly property var limitFooterKeys: Limits.footerKeys(shownLimitRow)
  // The torrents and row an open Limits INSERT acts on, captured when
  // Enter (or a palette bulk row) was pressed: {key, hashes, name, prefill}.
  // prefill is the text INSERT opened with (null for a bulk row): Enter on
  // it unchanged sends nothing (Ruling CL 2). The commit reads only this.
  property var limitInput: null

  function isLimitPurpose(purpose) {
    return String(purpose).indexOf("limit:") === 0
  }

  function isShareKey(k) {
    return k === "ratioLimit" || k === "seedingTimeLimit"
  }

  // Status rows for hashes, from every torrent (not the filtered table).
  function rowsFor(hashes) {
    var all = client.service.torrents || []
    var out = []
    for (var i = 0; i < all.length; i++) if (hashes.indexOf(Model.torrentId(all[i])) !== -1) out.push(all[i])
    return out
  }

  // j/k on Info: this torrent's Limits cursor, clamped to the rows.
  function moveLimit(delta) {
    var rows = limitRows
    if (rows.length === 0) return
    var next = View.moveIndex(rows.length, InspectorView.keyedIndex(rows, limitCursors[client.cursorHash], 0), delta)
    var n = ({})
    for (var k in limitCursors) n[k] = limitCursors[k]
    n[client.cursorHash] = rows[next].key
    limitCursors = n
    // Ruling CL 4: scroll the Info tab so the cursor row shows.
    inspectorPane.positionLimit()
  }

  // Enter on a Limits value row (key and torrent captured at key time):
  // INSERT prefilled with the current value in input form. A ratio or seed
  // time waits for the preferences behind the confirm (Ruling CG).
  function startLimitInput(hash, key) {
    var c = client
    var row = rowsFor([hash])[0]
    if (!row || Limits.editText(key, row) === "") return
    if (isShareKey(key) && !readyAtEnter()) { c.note(Limits.NOT_READY, "urgent"); return }
    var prefill = Limits.editText(key, row)
    limitInput = { key: key, hashes: [hash], name: String(row.name || ""), prefill: prefill }
    startInput("limit:" + key, prefill)
  }

  // A palette bulk row (Task 6) on the targets captured when it ran (the
  // VISUAL range ":" opened on, or the cursor row): an empty INSERT, parsed
  // and confirmed like Enter's. A ratio waits for the preferences (CG).
  function startBulkLimit(key, targets) {
    var c = client
    if (targets.length === 0) return
    if (isShareKey(key) && !readyAtEnter()) { c.note(Limits.NOT_READY, "urgent"); return }
    var rows = rowsFor(targets)
    var name = targets.length === 1 && rows.length === 1 ? String(rows[0].name || "") : View.countText(targets.length)
    limitInput = { key: key, hashes: targets.slice(), name: name, prefill: null }
    startInput("limit:bulk:" + key, "")
  }

  // Enter on a Limits INSERT. raw is the field exactly as typed (the
  // parsers never trim). A parse error, or a share limit whose preferences
  // aren't known any more (BQ), stays in INSERT; a ratio or seed time that
  // some target already meets raises one CONFIRM (D8) first.
  function commitLimit(raw) {
    var c = client
    var t = limitInput
    if (t.prefill !== null && t.prefill !== undefined && raw === t.prefill) { limitInput = null; endInput(); return }
    if (isShareKey(t.key) && !readyAtEnter()) { refuseInput(Limits.NOT_READY); return }
    var parsed = t.key === "ratioLimit" ? Limits.parseRatio(raw) : (t.key === "seedingTimeLimit" ? Limits.parseSeedTime(raw) : Limits.parseSpeed(raw))
    if (parsed.error) { refuseInput(parsed.error); return }
    var value = t.key === "ratioLimit" ? parsed.ratio : (t.key === "seedingTimeLimit" ? parsed.minutes : parsed.bytes)
    limitInput = null
    endInput()
    askOrWriteLimit({ key: t.key, value: value, hashes: t.hashes.slice(), force: false })
  }

  // {key, value, hashes} -> LimitsView.shareConfirmDetail's plan over those
  // targets as the status stands right now.
  function shareLimitPlan(key, value, hashes) {
    return Limits.shareConfirmDetail(key === "ratioLimit" ? { ratio: value } : { seedingTime: value }, rowsFor(hashes), client.service)
  }

  // Raises the D8 CONFIRM for args (key, value, hashes) with plan's line,
  // freezing plan's force, count and files onto args: the y-time re-check
  // (Ruling CN) compares a fresh count/files against these.
  function raiseLimitConfirm(args, plan) {
    var c = client
    args.force = plan.force
    args.confirmCount = plan.count
    args.confirmFiles = plan.files
    var r = Registry.raiseConfirm(c.regState, "limit.edit", "limitSet", args)
    c.regState = r.state
    c.confirmHashes = args.hashes.slice()
    c.confirm = withLine(r.confirm, plan.line, "set")
  }

  // args: {key, value, hashes, force}. A share limit runs LimitsView.
  // shareConfirmDetail over the targets as they stand now; a non-empty line
  // raises one CONFIRM whose `y` comes back as limit.edit with these
  // frozen args and its force. Shared with Task 6's palette commands.
  function askOrWriteLimit(args) {
    if (isShareKey(args.key)) {
      var plan = shareLimitPlan(args.key, args.value, args.hashes)
      if (plan.line !== "") { raiseLimitConfirm(args, plan); return }
      args.force = plan.force
    }
    writeLimit(args)
  }

  // The write: chunked like every window action, reported with
  // LimitsView.limitCopy, refreshed after a failure (libraryFinished).
  function writeLimit(args) {
    var c = client
    var svc = c.service
    var k = args.key
    var v = args.value
    var hashes = args.hashes || []
    if (hashes.length === 0) return
    var rows = rowsFor(hashes)
    var copy = Limits.limitCopy(k, v, rows.length === 1 ? rows[0] : null, hashes.length)
    if (!copy) return
    var tickets = c.perChunk(hashes, function(joined, chunk) {
      var o = c.opts(chunk)
      if (k === "dlLimit" || k === "upLimit") return svc.setSpeedLimit(joined, k === "dlLimit" ? "dl" : "up", v, o)
      if (k === "ratioLimit") return svc.setShareLimits(joined, { ratio: v }, args.force === true, o)
      if (k === "seedingTimeLimit") return svc.setShareLimits(joined, { seedingTime: v }, args.force === true, o)
      return k === "seqDl" ? svc.setSequential(joined, v, o) : svc.setFirstLast(joined, v, o)
    })
    // The refresh watch goes on the last chunk only: one refresh after a
    // failure (Service refreshes after a success anyway).
    trackLibrary(tickets, copy, null, hashes)
    var last = 0
    for (var i = 0; i < tickets.length; i++) if (Number(tickets[i]) > 0) last = Number(tickets[i])
    if (last > 0) watchTickets([last], { refresh: true })
  }

  // Space on Sequential or First/last: the value the row shows, negated
  // (D4; qbt's on/off is idempotent, so a double Space converges).
  function toggleLimit(hash, key) {
    var row = rowsFor([hash])[0]
    if (!row || (key !== "seqDl" && key !== "firstLast")) return
    writeLimit({ key: key, value: row[key] !== true, hashes: [hash], force: false })
  }

  // ---- the C and T pickers (slice 3a) ------------------------------------------

  // "category" or "tag" while a picker is open, else "".
  property string pickerKind: ""
  // The torrents it acts on, captured when C or T was pressed (the cursor
  // row or the VISUAL range); a status tick or a cursor move never changes
  // them. The table paints them while the picker is up.
  property var pickerTargets: []

  function openPicker() {
    if (settingsCommands && settingsCommands.pickerOpen) return settingsCommands.picker
    // Slice 5a: Search's category picker (SearchPane's hook).
    if (searchView && searchView.pickerOpen) return searchView.picker
    return pickerKind === "category" ? categoryPicker : (pickerKind === "tag" ? tagPicker : null)
  }

  // Dispatch's PICKER flags (Space/Tab), read fresh for every key.
  function pickerFlags() {
    var p = client.mode === "PICKER" ? openPicker() : null
    return p ? { queryEmpty: p.query === "", multi: p.multi } : null
  }

  // C or T (dispatch already put the mode in PICKER). C writes a category,
  // so it waits for qBittorrent's folders (ruling BM) and lands in NORMAL.
  function startPicker(kind, targets) {
    var c = client
    var svc = c.service
    if (targets.length === 0) { setMode("NORMAL"); return }
    if (kind === "category" && !libraryReady) {
      setMode("NORMAL")
      c.note(Library.LIBRARY_NOT_READY, "urgent")
      return
    }
    pickerTargets = targets.slice()
    pickerKind = kind
    var rows = []
    var all = svc.torrents || []
    for (var i = 0; i < all.length; i++) if (targets.indexOf(Model.torrentId(all[i])) !== -1) rows.push(all[i])
    if (kind === "category") categoryPicker.open(rows)
    else tagPicker.open(Library.tagStates(svc.tags, rows), targets.length)
  }

  // Esc, a scrim click, or an accept: nothing is left open.
  function closePicker() {
    if (settingsCommands) settingsCommands.dropPicker()
    if (searchView) searchView.dropPicker()
    pickerKind = ""
    pickerTargets = []
    setMode("NORMAL")
    keyItem.forceActiveFocus()
  }

  // A refused Enter (a "+ New" name nameError refuses) keeps it open.
  function reopenPicker(note) {
    client.note(note, "urgent")
    setMode("PICKER")
    openPicker().focusField()
  }

  // Enter (dispatch is back in NORMAL). C: set the category, after one
  // move CONFIRM that names the real folder when qBittorrent would move
  // files (G8; `y` comes back as torrent.category with args.confirmed).
  // T: send what the toggles changed, nothing when unchanged.
  function acceptPicker() {
    if (settingsCommands && settingsCommands.pickerOpen) { settingsCommands.acceptPicker(); return }
    if (searchView && searchView.pickerOpen) { searchView.acceptPicker(); return }
    var c = client
    var svc = c.service
    var targets = pickerTargets
    var kind = pickerKind
    var p = openPicker()
    if (!p) return
    if (kind === "category" && !readyAtEnter()) { reopenPicker(Library.LIBRARY_NOT_READY); return }
    var accept = kind === "category"
      ? Library.categoryAccept(p.currentRow(), targets, svc.torrents, svc)
      : Library.tagAccept(p.original, p.working, p.currentRow())
    if (accept.op === "refuse") { reopenPicker(accept.note); return }
    closePicker()
    var steps = Library.pickerSteps(kind, accept, targets)
    if (steps.length === 0) return
    if (kind === "category" && accept.line !== "") {
      var r = Registry.raiseConfirm(c.regState, "torrent.category", "categorySet", { steps: steps })
      c.regState = r.state
      c.confirmHashes = accept.hashes
      c.confirm = withLine(r.confirm, accept.line, "set")
      return
    }
    runPickerSteps(steps, [])
  }

  // Space/Tab on T: toggle the cursor row (a refused "+ New tag" says why).
  function togglePicker() {
    if (pickerKind !== "tag") return
    var row = tagPicker.currentRow()
    if (!row) return
    if (row.enabled === false) { client.note(row.reason, "urgent"); return }
    tagPicker.toggle(row.value)
  }

  // A click on a row: C picks it, T toggles it.
  function pickerClicked() {
    if (pickerKind === "tag") { togglePicker(); return }
    setMode("NORMAL")
    acceptPicker()
  }

  // Runs steps[0] (LibraryView.pickerSteps); each later step runs once the
  // one before succeeds (pickerFinished). created: the "+ New" names made.
  function runPickerStep(steps, created) {
    var c = client
    var svc = c.service
    var s = steps[0]
    var watch = { picker: { kind: s.kind, step: s.step, name: s.name, created: created, rest: steps.slice(1) } }
    var copy = Library.pickerCopy(s.kind, s.step, s.name)
    if (s.step === "add") {
      trackLibrary(s.kind === "tag" ? svc.addTag(s.name, c.opts([])) : svc.addCategory(s.name, "", c.opts([])), copy, watch)
      return
    }
    var sizes = ({})
    var tickets = c.perChunk(s.hashes, function(joined, chunk) {
      var t = s.kind === "tag" ? svc.editTags(joined, s.changes, c.opts(chunk)) : svc.setCategory(joined, s.name, c.opts(chunk))
      if (Number(t) > 0) sizes[String(t)] = chunk.length
      return t
    })
    var left = Object.keys(sizes)
    if (left.length > 0) {
      var tally = ({})
      for (var k in pickerTally) tally[k] = pickerTally[k]
      tally[left[0]] = { total: s.hashes.length, done: 0, left: left.length, error: null, sizes: sizes }
      pickerTally = tally
      watch.picker.group = left[0]
    }
    trackLibrary(tickets, copy, watch, s.hashes)
  }

  // group (a set's first ticket) -> {total, done, left, error, sizes}: a
  // chunked set's tally, so its one line can say how many chunks changed
  // before one failed (ruling BS, Minor 6). Chunks run in turn, and one
  // failing doesn't stop the rest.
  property var pickerTally: ({})

  // A set's chunk ended: the tally after it, or null when the set has no
  // tally (an add). Drops the tally once its last chunk is in.
  function tallyChunk(ticket, ok, error, group) {
    var t = pickerTally[group]
    if (!t) return null
    var next = { total: t.total, done: t.done + (ok === true ? (t.sizes[String(ticket)] || 0) : 0), left: t.left - 1,
      error: ok !== true && t.error === null ? String(error || "") : t.error, sizes: t.sizes }
    var tally = ({})
    for (var k in pickerTally) if (k !== group) tally[k] = pickerTally[k]
    if (next.left > 0) tally[group] = next
    pickerTally = tally
    return next
  }

  function runPickerSteps(steps, created) {
    if (steps.length > 0) runPickerStep(steps, created)
  }

  // A picker write ended. A failure reports one line that names the action
  // (LibraryView.pickerFailure, OV7) and refreshes, so what did change
  // shows; a create that succeeded goes on to the next step.
  function pickerFinished(ticket, ok, error, p) {
    var c = client
    var t = p.group ? tallyChunk(ticket, ok, error, p.group) : null
    if (t && t.left > 0) {
      // An earlier chunk: bookkeeping only; the last one reports.
      c.messages = View.msgFinish(c.messages, ticket, true, "")
      return
    }
    if (t && t.error !== null) { ok = false; error = t.error }
    if (ok !== true) {
      c.messages = View.msgFinish(c.messages, ticket, false,
        Library.pickerFailure(p.kind, p.step, p.name, p.created, error, t ? { done: t.done, total: t.total } : null))
      c.service.refresh()
      return
    }
    if (p.rest.length === 0) return
    c.messages = View.msgFinish(c.messages, ticket, true, "")
    runPickerSteps(p.rest, p.step === "add" ? p.created.concat([p.name]) : p.created)
  }

  // ---- fetch metadata only (f, slice 2b) ---------------------------------------

  // hash -> {ticket, done, at}: this window's fetch-metadata swaps. A
  // ticket that succeeded stays in client.messages, so "Fetching
  // metadata…" keeps showing until Service lists the hash with a size
  // (checkFetches); `at` is when it succeeded (View.fetchHolds).
  property var fetchWatches: ({})

  function setFetchWatch(hash, watch) {
    var n = ({})
    for (var h in fetchWatches) if (h !== hash) n[h] = fetchWatches[h]
    if (watch) n[hash] = watch
    fetchWatches = n
  }

  function startFetchMetadata(hash) {
    var c = client
    var refusal = View.fetchMetaRefusal(c.rawRow(hash), fetchWatches[hash] !== undefined)
    if (refusal !== "") { c.note(refusal, "urgent"); return }
    var ticket = c.service.fetchMetadata(hash, c.opts([hash]))
    c.track(ticket, "fetchMeta", [hash])
    if (ticket > 0) setFetchWatch(hash, { ticket: ticket, done: false, at: 0 })
  }

  // Client's actionFinished, before msgFinish: true for a fetch-metadata
  // ticket that succeeded, whose report waits for the metadata. A failed
  // one drops its watch and reports as usual (qbt's error, e.g. the magnet
  // went back to the inbox).
  function fetchFinished(ticket, ok) {
    for (var h in fetchWatches) {
      if (String(fetchWatches[h].ticket) !== String(ticket)) continue
      if (ok !== true) { setFetchWatch(h, null); return false }
      setFetchWatch(h, { ticket: ticket, done: true, at: Date.now() })
      checkFetches()
      return true
    }
    return false
  }

  // A status tick: a finished swap whose torrent reports a size is done;
  // one whose torrent is still gone once the hold ran out, or stopped
  // with no metadata, ends quietly (View.fetchWatchOutcome).
  function checkFetches() {
    var c = client
    var now = Date.now()
    for (var h in fetchWatches) {
      var w = fetchWatches[h]
      var outcome = View.fetchWatchOutcome(w, View.fetchMetaProgress(c.service.torrents, h), now)
      if (outcome === "keep") continue
      setFetchWatch(h, null)
      c.messages = View.msgFinish(c.messages, w.ticket, true, "")
      if (outcome === "received") c.note(View.FETCH_META_DONE_NOTE, "muted")
    }
  }

  // Whether rebuildRows keeps the cursor on hash although the status
  // stream doesn't list it (a swap in progress, View.fetchHolds).
  function holdsCursor(hash) {
    return View.fetchHolds(fetchWatches[hash], Date.now())
  }

  // ---- INSERT ------------------------------------------------------------------

  function startInput(purpose, initial) {
    var c = client
    c.inputPurpose = purpose
    c.queryBeforeEdit = c.textQuery
    inputLine.setInput(initial)
    setMode("INSERT")
    inputLine.focusInput()
  }

  function endInput() {
    client.inputPurpose = ""
    keyItem.forceActiveFocus()
  }

  function stayInInsert() {
    setMode("INSERT")
    inputLine.focusInput()
  }

  function commitInput() {
    var c = client
    // Search's query and plugin URL (slice 5a): SearchPane ends or keeps
    // the INSERT itself (endInput / stayInInsert).
    if (View.SEARCH_INPUT_PURPOSES.indexOf(c.inputPurpose) !== -1) {
      if (searchView) searchView.commitInput(c.inputPurpose, inputLine.inputValue())
      else endInput()
      return
    }
    // The Settings search: never an add target or a torrent filter.
    if (c.inputPurpose === "settingsSearch") {
      settingsView.commitSearch(inputLine.inputValue())
      endInput()
      return
    }
    if (c.inputPurpose === "settingEdit") {
      settingsCommands.commitInput(inputLine.inputValue())
      return
    }
    if (isLimitPurpose(c.inputPurpose)) {
      if (limitInput) commitLimit(inputLine.inputValue())
      else endInput()
      return
    }
    if (isLibraryPurpose(c.inputPurpose)) {
      if (libraryInput) commitLibrary(inputLine.inputValue())
      else endInput()
      return
    }
    var text = inputLine.inputValue().trim()
    // Before the add-target check: a tracker URL is never added as a torrent.
    if (c.inputPurpose === "trackerAdd" || c.inputPurpose === "trackerEdit") {
      if (trackerInput) commitTracker(text)
      else endInput()
      return
    }
    if (c.inputPurpose === "move") {
      if (!View.isAbsolutePath(text)) {
        c.note("Enter an absolute path to move to.", "urgent")
        stayInInsert()
        return
      }
      c.track(c.service.setLocation(c.moveHashes.join("|"), text, c.opts(c.moveHashes)), "move", c.moveHashes)
      c.moveHashes = []
    } else if (Model.isAddableTarget(text)) {
      c.track(c.service.addTarget(text, false, "", c.opts([])), "add", [])
      c.textQuery = ""
      c.rebuildRows(true)
    } else {
      c.textQuery = Model.listQuery(text)
      c.rebuildRows(true)
    }
    endInput()
  }

  // Client.leaveInsert (a click during INSERT) ends INSERT through here too.
  function cancelInput() {
    var c = client
    if (c.inputPurpose === "settingsSearch") settingsView.clearSearch()
    if (searchView && View.SEARCH_INPUT_PURPOSES.indexOf(c.inputPurpose) !== -1) searchView.cancelInput(c.inputPurpose)
    if (c.inputPurpose === "filter") {
      c.textQuery = c.queryBeforeEdit
      c.rebuildRows(true)
    }
    c.moveHashes = []
    trackerInput = null
    libraryInput = null
    limitInput = null
    if (settingsCommands) settingsCommands.input = null
    endInput()
  }

  // ---- COMMAND (the palette) ----------------------------------------------------

  // The VISUAL range ":" opened the palette on (captured then; [] when it
  // opened from NORMAL): a range command run from it acts on this range,
  // as its key would have (Task 6).
  property var paletteRange: []
  // The rows the table paints as held while the palette, or a bulk limit
  // INSERT, acts on more than one torrent.
  readonly property var heldRange: client.mode === "COMMAND" ? paletteRange
    : (client.mode === "INSERT" && limitInput && limitInput.hashes.length > 1 ? limitInput.hashes : [])

  function closePalette() {
    paletteRange = []
    setMode("NORMAL")
    keyItem.forceActiveFocus()
  }

  // Runs a palette row (Enter, or a click). A disabled row (or none) keeps
  // the palette open and says why. An enabled one closes it, goes to the
  // top of the MRU, and runs through the registry like its key would:
  // the same targets, the same CONFIRM, the same mode change afterwards.
  function runPaletteRow(row) {
    var c = client
    if (!row || row.kind !== "command" || !row.enabled) {
      if (row && row.kind === "command") c.note(View.paletteReasonNote(row), "urgent")
      setMode("COMMAND")
      palette.focusField()
      return
    }
    var range = paletteRange
    closePalette()
    // From Settings or Search, only that view's rows (and : and ?) run
    // there; anything else runs on the torrents, so the view makes way
    // first (Client.activeView decides; ":Search" from Settings leaves
    // Settings, then opens Search from the torrents).
    var inView = c.activeView !== "torrents" && View.paletteView(Registry.commands, row.id, c.keyPane) === c.activeView
    if (c.activeView !== "torrents" && !inView) c.leaveView()
    c.paletteMru = View.mruPush(c.paletteMru, row.id)
    // A view's row runs in that view: the torrent pane underneath stays.
    if (!inView) c.setPane(View.palettePane(Registry.commands, row.id, c.pane))
    c.saveView()
    // A neutral event: the Enter that ran the palette must not also count
    // as Enter for the command (Files would start the daemon).
    var ev = View.keyEvent(0, "", 0, Date.now())
    // Opened on a range: a range command resolves as in VISUAL (a CONFIRM
    // counts the range) on the range captured at ":".
    if (range.length > 0 && View.paletteRangeCommand(Registry.commands, row.id)) {
      c.dispatchWith(function(st) { return Registry.dispatchCommand(View.rangeState(st, range.length), row.id) }, ev, range)
      return
    }
    c.dispatchWith(function(st) { return Registry.dispatchCommand(st, row.id) }, ev)
  }

  // ---- commands ------------------------------------------------------------------

  // targets: View.targetHashes as it stood before dispatch (the VISUAL
  // range, or the cursor row).
  function run(commandId, args, ev, targets) {
    var c = client
    if (!c.service) return
    var hashes, rows, starts, ticket
    targets = targets || []

    switch (commandId) {
    case "cursor.down":
    case "cursor.up":
    case "cursor.top":
    case "cursor.bottom":
      c.setCursor(View.moveCursor(c.tableRows, c.cursorHash, commandId))
      return

    case "visual.enter":
    case "visual.exit":
      // The mode and the anchor were set in handleKey.
      return

    case "help.toggle":
      c.helpPane = c.keyPane
      c.helpOpen = true
      return

    case "torrent.toggle":
      hashes = targets
      if (hashes.length === 0) return
      starts = View.toggleStarts(c.rawFor(hashes))
      c.track(c.perChunk(hashes, function(joined, chunk) {
        return starts ? c.service.startHash(joined, c.opts(chunk)) : c.service.stopHash(joined, c.opts(chunk))
      }), starts ? "start" : "stop", hashes)
      return

    case "torrent.remove":
    case "torrent.delete":
      hashes = args.confirmed === true ? c.confirmHashes : targets
      c.confirmHashes = []
      if (hashes.length === 0) return
      var withFiles = commandId === "torrent.delete"
      c.track(c.perChunk(hashes, function(joined, chunk) {
        return c.service.deleteHash(joined, withFiles, c.opts(chunk))
      }), withFiles ? "delete" : "remove", hashes)
      return

    case "torrent.recheck":
      hashes = targets
      if (hashes.length === 0) return
      c.track(c.perChunk(hashes, function(joined, chunk) {
        return c.service.recheckHash(joined, c.opts(chunk))
      }), "recheck", hashes)
      return

    case "torrent.openFolder":
      rows = c.rawFor(targets)
      if (rows.length > 0 && rows[0].savePath) c.service.openPath(rows[0].savePath, c.opts(targets))
      return

    case "torrent.copyMagnet":
      if (c.pane === "inspector" && (c.inspectorTab === "trackers" || c.inspectorTab === "peers")) {
        copyRow(c.inspectorTab, targets)
        return
      }
      rows = c.rawFor(targets)
      if (rows.length === 0) return
      // The window validates its own input: Service returns 0 silently.
      if (!Model.magnetUriFor(rows[0])) {
        c.note("No magnet for this torrent.", "urgent")
        return
      }
      c.track(c.service.copyMagnet(rows[0], c.opts(targets)), "copy", targets)
      return

    case "torrent.move":
      hashes = targets
      rows = c.rawFor(hashes)
      if (rows.length === 0) return
      c.moveHashes = hashes
      startInput("move", String(rows[0].savePath || ""))
      return

    case "inspector.files":
      // Enter doubles as the primary action of a blocking state.
      if (isEnterKey(ev) && c.tableState === "daemon") {
        ticket = c.service.startDaemon(c.opts([]))
        if (ticket > 0) c.track(ticket, "daemon", [])
        else c.note(View.progressText("daemon", 0), "muted")
        return
      }
      if (isEnterKey(ev) && c.tableState === "notInstalled") {
        ticket = c.service.installDaemon(c.opts([]))
        if (ticket > 0) c.track(ticket, "install", [])
        else c.note(View.progressText("install", 0), "muted")
        return
      }
      openInspectorTab("files")
      return

    case "inspector.info":
      openInspectorTab("info")
      return

    case "inspector.trackers":
      openInspectorTab("trackers")
      return

    case "inspector.peers":
      openInspectorTab("peers")
      return

    case "inspector.chart":
      openInspectorTab("chart")
      return

    case "all.toggle":
      var live = Model.excludePending(c.service.torrents || [], c.service.magnetPendingHashes || [])
      hashes = []
      for (var i = 0; i < live.length; i++) hashes.push(Model.torrentId(live[i]))
      if (hashes.length === 0) return
      starts = !Model.anyActive(live)
      c.track(c.service.toggleAll(c.opts(hashes)), starts ? "startAll" : "stopAll", hashes)
      return

    case "turtle.toggle":
      c.track(c.service.toggleTurtle(c.opts([])), "turtle", [])
      return

    case "sort.next":
      var n = View.nextSort(c.sortMode)
      c.sortMode = n.sort
      c.sortDesc = n.desc
      c.rebuildRows(true)
      c.saveView()
      return

    case "sort.reverse":
      c.sortDesc = !c.sortDesc
      c.rebuildRows(true)
      c.saveView()
      return

    case "filter.text":
      startInput("filter", c.textQuery)
      return

    case "filter.clearText":
      if (c.textQuery === "") return
      c.textQuery = ""
      c.rebuildRows(true)
      return

    case "filter.reset":
      c.textQuery = ""
      c.filter = View.defaultFilter()
      c.filterCursor = View.defaultFilter()
      c.rebuildRows(true)
      c.saveView()
      return

    case "filter.down":
    case "filter.up":
      c.setFilterCursor(View.moveFilterCursor(c.filterEntries, c.filterCursor, commandId === "filter.down" ? 1 : -1))
      return

    case "filter.apply":
      if (View.filterIndex(c.filterEntries, c.filterCursor) < 0) return
      c.applyFilter(c.filterCursor)
      return

    case "file.down":
    case "file.up":
      // Moves the cursor of whichever list the current tab shows.
      if (c.inspectorTab === "trackers" || c.inspectorTab === "peers") {
        var tabRows = listRows(c.inspectorTab)
        if (tabRows.length === 0) return
        var at = c.inspectorTab === "trackers" ? c.trackerIndex : c.peerIndex
        setRow(c.inspectorTab, View.moveIndex(tabRows.length, at, commandId === "file.down" ? 1 : -1))
        inspectorPane.positionRow(c.inspectorTab, c.inspectorTab === "trackers" ? c.trackerIndex : c.peerIndex)
        return
      }
      if (c.inspectorTab !== "files" || c.filesState.state !== "rows") return
      c.fileIndex = View.moveIndex(c.filesState.rows.length, c.fileIndex, commandId === "file.down" ? 1 : -1)
      inspectorPane.positionFile(c.fileIndex)
      return

    case "file.cycle":
      if (c.inspectorTab === "files" && c.filesState.state === "rows") {
        c.cycleFile(c.fileIndex)
        return
      }
      // Deviation 3: on a no-metadata torrent's Info or Files tab, Space
      // is `Space Start download`: it starts a stopped one (the toggle's
      // start path) and never stops a running one (e.g. a magnet in
      // metaDL, or a fetch-metadata re-add).
      if ((c.inspectorTab === "info" || c.inspectorTab === "files") && c.cursorRow && c.infoTab.noMeta
          && View.toggleStarts(c.rawFor(targets))) run("torrent.toggle", args, ev, targets)
      return

    // The Info tab's Limits group (slice 3b): args.limitKey is the row
    // under the Limits cursor when the key was pressed; limit.edit comes
    // back with args.confirmed (and its frozen args) after the D8 CONFIRM.
    case "limit.down":
    case "limit.up":
      moveLimit(commandId === "limit.down" ? 1 : -1)
      return

    case "limit.edit":
      if (args.confirmed === true) {
        c.confirmHashes = []
        // Ruling CN: re-check the frozen plan against the current status
        // before writing. A target crossing the limit since the confirm was
        // raised (a higher count), or a plan that now removes files where
        // the frozen one didn't, raises the confirm again instead of
        // writing; the write only ever uses the frozen force.
        if (isShareKey(args.key)) {
          var recheck = shareLimitPlan(args.key, args.value, args.hashes)
          if (recheck.count > args.confirmCount || (recheck.files && !args.confirmFiles)) {
            raiseLimitConfirm({ key: args.key, value: args.value, hashes: args.hashes }, recheck)
            return
          }
        }
        writeLimit(args)
        return
      }
      if (targets.length === 0 || !args.limitKey) return
      startLimitInput(targets[0], args.limitKey)
      return

    case "limit.toggle":
      if (targets.length === 0 || !args.limitKey) return
      toggleLimit(targets[0], args.limitKey)
      return

    // The palette's bulk limits (Task 6): the cursor row or the range.
    case "limit.setDownload":
      startBulkLimit("dlLimit", targets)
      return

    case "limit.setUpload":
      startBulkLimit("upLimit", targets)
      return

    case "limit.setRatio":
      startBulkLimit("ratioLimit", targets)
      return

    // The trackers tab (Deviation 4: R too). The registry only lets these
    // through there, so targets[0] is the torrent whose trackers show.
    case "tracker.reannounce":
      if (targets.length === 0) return
      c.track(c.service.reannounce(targets[0], c.opts([targets[0]])), "reannounce", [targets[0]])
      return

    case "tracker.add":
      if (targets.length === 0) return
      startTrackerInput("trackerAdd", targets[0], "")
      return

    case "tracker.edit":
      if (targets.length === 0 || !args.target) return
      var editRefusal = InspectorView.trackerRefusal(args.target.value)
      if (editRefusal !== "") { c.note(editRefusal, "urgent"); return }
      startTrackerInput("trackerEdit", targets[0], args.target.value)
      return

    case "tracker.remove":
      // Unconfirmed only when the registry refused the CONFIRM (the target
      // has a refusal: a "|" in the URL, F13, or a URL qbt would reject):
      // say why and do nothing else.
      var removeRefusal = args.target ? InspectorView.trackerRefusal(args.target.value) : ""
      if (args.confirmed !== true) {
        if (removeRefusal !== "") c.note(removeRefusal, "urgent")
        return
      }
      // `y`: the torrent and the tracker named when x was pressed, never
      // the cursor as it stands now.
      hashes = c.confirmHashes
      c.confirmHashes = []
      if (hashes.length === 0 || !args.target) return
      if (removeRefusal !== "") { c.note(removeRefusal, "urgent"); return }
      c.track(c.service.removeTracker(hashes[0], args.target.value, c.opts([hashes[0]])), "trackerRemove", [hashes[0]])
      return

    case "peer.ban":
      // Unconfirmed only when the registry refused the CONFIRM (the peer
      // has a refusal: an address qbt's ban-peer would reject): say why
      // and do nothing else.
      var banRefusal = args.target ? InspectorView.peerRefusal(args.target.value) : ""
      if (args.confirmed !== true) {
        if (banRefusal !== "") c.note(banRefusal, "urgent")
        return
      }
      // `y`: the peer named when b was pressed. The ban is global, so it
      // needs no torrent; the hashes stored with the CONFIRM just go.
      c.confirmHashes = []
      if (!args.target) return
      if (banRefusal !== "") { c.note(banRefusal, "urgent"); return }
      c.track(c.service.banPeer(args.target.value, c.opts([])), "ban", [])
      return

    // The filters pane (slice 3a): a/c/p open INSERT on the row captured
    // at key time; c and p come back here with args.confirmed after their
    // CONFIRM. x comes confirmed, or unconfirmed only when the registry
    // refused it (a category before its folders are known): say why.
    case "library.add":
      startLibraryInput(commandId, args.target)
      return

    case "library.rename":
    case "library.path":
      if (args.confirmed === true && args.target) runLibraryWrite(commandId, args)
      else startLibraryInput(commandId, args.target)
      return

    case "library.remove":
      c.confirmHashes = []
      if (!args.target) return
      if (args.confirmed !== true) {
        if (args.target.refusal) c.note(args.target.refusal, "urgent")
        return
      }
      runLibraryWrite(commandId, args)
      return

    // C and T: open the picker on the targets captured now; C's move
    // CONFIRM comes back here with args.confirmed and the steps it asked about.
    case "torrent.category":
      if (args.confirmed === true) { c.confirmHashes = []; runPickerSteps(args.steps || [], []); return }
      startPicker("category", targets)
      return

    case "torrent.tags":
      startPicker("tag", targets)
      return

    case "picker.accept":
      acceptPicker()
      return

    case "picker.cancel":
      closePicker()
      return

    case "picker.up":
    case "picker.down":
      if (openPicker()) openPicker().move(commandId === "picker.down" ? 1 : -1)
      return

    case "picker.toggle":
      togglePicker()
      return

    case "torrent.fetchMetadata":
      if (targets.length === 0) return
      startFetchMetadata(targets[0])
      return

    case "insert.commit":
      commitInput()
      return

    case "insert.cancel":
      cancelInput()
      return

    case "refresh":
      c.service.refresh()
      c.syncFiles(true)
      return

    case "pane.next":
    case "pane.prev":
      // Tab/Shift-Tab cycle through collapsed panes (opening each as an
      // overlay); Ctrl-h/Ctrl-l on an open overlay close it.
      c.setPane(View.paneStep(c.pane, commandId === "pane.next" ? 1 : -1, c.layout, ev))
      return

    case "window.close":
      c.close()
      return

    case "palette.open":
      paletteRange = args.range === true ? targets.slice() : []
      palette.open()
      return

    case "palette.close":
      closePalette()
      return

    case "palette.up":
    case "palette.down":
      palette.move(commandId === "palette.down" ? 1 : -1)
      return

    case "palette.complete":
      palette.complete()
      return

    case "palette.run":
      runPaletteRow(palette.currentRow())
      return

    case "magnet.start":
    case "magnet.cancel":
      magnet.act(commandId)
      return

    case "settings.open":
      c.showView("settings")
      return

    // Slice 5a: every other Search row is SearchPane's (Client.run).
    case "search.open":
      c.showView("search")
      return

    case "settings.back":
      settingsView.back()
      return

    case "settings.down":
    case "settings.up":
      settingsView.move(commandId === "settings.down" ? 1 : -1)
      return

    case "settings.enter":
      settingsView.enter()
      return

    case "settings.leave":
      settingsView.leave()
      return

    case "settings.search":
      // Nothing to search on the down screen.
      if (settingsView.failed) { setMode("NORMAL"); return }
      settingsView.beginSearch()
      startInput("settingsSearch", settingsView.query)
      return

    case "settings.toggle":
    case "settings.edit":
    case "settings.write":
      settingsCommands.run(commandId, args)
      return

    case "confirm.cancel":
      c.confirm = null
      c.confirmHashes = []
      return

    default:
      return
    }
  }
}
