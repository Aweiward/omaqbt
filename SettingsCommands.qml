pragma ComponentBehavior: Bound

import QtQuick
import "CommandRegistry.js" as Registry
import "ClientView.js" as View
import "SettingsView.js" as SettingsView

// The Settings editors (slice 4a, Task 6): Space on an on/off row, Enter on
// an input row (the status-line INSERT) or a choice row (the ListOverlay
// picker SettingsPane holds). ClientCommands forwards settings.toggle,
// settings.edit and settings.write here, and the INSERT/PICKER hooks.
//
// Every write goes through propose(), the window's confirm gate (Ruling DN:
// qbt pref-set has no confirm flag, so this is the only one): the key, its
// value then and the value to write are captured at key time; an unchanged
// value sends nothing; SettingsView.confirmFor's line raises one CONFIRM
// whose `y` comes back as settings.write with those frozen args. That id
// has no command row, so neither a key nor the palette reaches it, and
// buildArgs never sets `confirmed`. write() is the only setPref call.
//
// While a write runs its row shows "saving…" (SettingsPane.saving) and
// takes no Space/Enter (flags()); a success re-reads (reload(true)) and
// keeps "saving…" until the new values are in; a failure keeps the value
// and says why (View.settingFailure). Service sends refresh-slow itself.
//
// Slice 4b (Task 3): the list editor, secrets and the narrow keys. Client
// routes the new command ids here (owns()). Enter on a list row opens the
// list (SettingsPane.openList); a adds a line through the status-line
// INSERT, x removes the cursor line: a ban goes to Service.banList, a
// list write to setPref with the whole value, built from the value
// captured at key time so every other line round-trips exactly. Enter on
// a writable secret opens a masked INSERT (still purpose "settingEdit",
// so ClientCommands' commit routes it here); the value goes straight from
// the field to Service.setSecret and the field is emptied at once. It is
// never kept in a property here: `input` holds only the key. x on a set
// secret asks first (SettingsView.secretQuestion), then clearSecret.
//
// Slice 4b (Task 4): undo (design D3, eng D11/D12). Each write through
// write() and each unban through banWrite() carries a record of what
// qBittorrent held before (SettingsView.undoValue of the prefs at the
// write); once it succeeds and the re-read is in, the record becomes a
// history entry {key, label, from, to}, or {kind: "ban", ip} for an
// unban, unless the read-back equals the value before (Ruling EC). Ban
// adds, secrets (Ruling EH) and undo's own writes record nothing. u
// (settings.undo) re-reads, then takes the newest entry off: already
// back: a note; a value the editors would refuse now (undoRefusal, or a
// ban-list add that would refuse the address): skipped with a note;
// unchanged since the edit: the write goes out through the same confirm
// gate as an edit; changed since: one CONFIRM, the "changed since your
// edit" question with the risky-change reason as its detail. n keeps the
// current value and the entry is gone, so the next u moves on; a failed
// undo write puts its entry back. Leaving Settings clears the history.
//
// Slice 5b2 (Task 2, D8): a key whose schema entry has confirmVia
// "rssAutoDl" (rss_auto_downloading_enabled) turning on first counts what
// would download (Service.rssAutoPreview), then raises CONFIRM rssAutoDlOn
// (View.SETTINGS_ACCEPT) with SettingsView.autoDlQuestion's line; its y
// comes back as settings.write like any setting's. A failed count still
// asks, without numbers. Turning it off asks nothing. An answer that lands
// after Settings closed or reopened, or over another mode, is dropped. u
// undoing a turn-off goes through the same count and question.
QtObject {
  id: edits

  // The Client, its ClientCommands (INSERT/PICKER plumbing) and SettingsPane.
  required property var client
  required property var commands
  required property var settingsView

  // An open input: {kind, key, label, prompt, from, prefs, after},
  // captured at Enter (or a): kind "value" (4a's editors), "list" (a line
  // for the list `key`: from is its value then, after the cursor line) or
  // "secret" (only the key: the value stays in the field). The commit
  // reads only this, never the cursor as it stands.
  property var input: null
  // The masked secret field is (or was just) open: closing it any way
  // (Enter, Esc, a click, closing the window) empties the field.
  property bool secretOpen: false
  readonly property bool masked: input !== null && input.kind === "secret"
  // An open picker's {key, label, from}, captured at Enter.
  property var pickerCapture: null
  // ticket -> {key, label, record, undo, visit}: this window's writes
  // still running (record: what the history gets once it succeeds; undo:
  // the history entry an undo write took off, put back if it fails).
  property var tickets: ({})
  // This visit's history, newest last (see the header), the records of
  // writes that succeeded and wait for their re-read, and the visit they
  // belong to: bumped each time Settings opens or closes.
  property var undoStack: []
  property var undoPending: []
  property int visit: 0
  // u's re-read is out.
  property bool undoReading: false
  // D8: the auto-download count is out (the key it's for), or "".
  property string autoDlCounting: ""

  readonly property var picker: settingsView.picker
  readonly property bool pickerOpen: settingsView.pickerOpen
  readonly property string inputShown: input ? (input.prompt || input.label) : ""

  // ---- dispatch state ------------------------------------------------------------

  // The setting under the Settings cursor and whether Space/Enter edit it
  // now (View.dispatchState's `settings`), or null outside Settings. In a
  // list: its key, whether it can be written now and the cursor line.
  // narrow always (the overlay rows need it); undoCount is Task 4's.
  function flags() {
    var v = settingsView
    if (!v.open) return null
    var out = { key: null, toggle: false, editable: false, listRow: false, secretSet: false, listEditable: false, listItem: null,
      narrow: v.narrow === true, undoCount: undoStack.length, listSection: !!v.section.list }
    if (v.failed) return out
    if (v.column === "settingsList") {
      out.key = v.listKey
      out.listEditable = v.prefs !== null && !isSaving(v.listKey)
      var it = v.listItem
      out.listItem = it ? { index: it.index, value: it.value, tierBreak: it.tierBreak === true } : null
      return out
    }
    if (v.column !== "settingsKeys" || !v.cursorRow) return out
    var k = v.cursorRow.key
    out.key = k
    if (isSaving(k)) return out
    var ed = SettingsView.editorFor(k, v.prefs)
    out.toggle = ed.kind === "toggle"
    out.editable = ed.kind === "input" || ed.kind === "picker" || ed.kind === "secret"
    out.listRow = ed.kind === "list"
    out.secretSet = ed.kind === "secret" && ed.set === true
    return out
  }

  // The command ids Client.run hands here rather than to ClientCommands.
  function owns(commandId) {
    return ["settings.sections", "settings.sectionsClose", "settings.openList", "settings.clearSecret",
      "list.down", "list.up", "list.add", "list.remove", "list.back", "settings.undo"].indexOf(commandId) !== -1
  }

  function isSaving(k) {
    return Object.prototype.hasOwnProperty.call(settingsView.saving, k)
  }

  function setSaving(k, state) {
    var n = ({})
    for (var s in settingsView.saving) if (s !== k) n[s] = settingsView.saving[s]
    if (state) n[k] = state
    settingsView.saving = n
  }

  function labelOf(k, prefs) {
    var row = SettingsView.rowFor(k, prefs)
    return row ? row.label : k
  }

  // ---- commands --------------------------------------------------------------------

  function run(commandId, args) {
    var v = settingsView
    var a = args || ({})
    var k = a.settingKey
    if (commandId === "settings.write") {
      // An undo's CONFIRM carries its done note and its history entry.
      if (a.confirmed === true && a.key) write(a.key, a.label, a.value, a.done, a.undo)
      return
    }
    if (!v.open) return
    switch (commandId) {
    case "settings.sections": v.openSections(); return
    case "settings.sectionsClose": v.closeSections(); return
    case "list.down": v.listMove(1); return
    case "list.up": v.listMove(-1); return
    case "list.back": v.closeList(); return
    case "list.add": startListAdd(k); return
    case "list.remove": removeLine(k, a.listItem); return
    case "settings.clearSecret": clearSecret(k, a.confirmed === true); return
    case "settings.undo": undo(); return
    }
    if (!k || isSaving(k)) return
    var ed = SettingsView.editorFor(k, v.prefs)
    if (commandId === "settings.openList") {
      if (ed.kind === "list") v.openList(k)
      return
    }
    var from = SettingsView.currentValue(k, v.prefs)
    var label = labelOf(k, v.prefs)
    if (commandId === "settings.toggle") {
      if (ed.kind === "toggle") propose(k, label, from, ed.next)
      return
    }
    if (ed.kind === "input") {
      input = { kind: "value", key: k, label: label, from: from, prefs: v.prefs }
      commands.startInput("settingEdit", ed.prefill)
    } else if (ed.kind === "picker") {
      openPicker(k, label, from)
    } else if (ed.kind === "secret") {
      // An empty masked field; the value never comes back out of qbt.
      input = { kind: "secret", key: k, label: label }
      secretOpen = true
      commands.startInput("settingEdit", "")
    }
  }

  // ---- lists (slice 4b) -------------------------------------------------------------

  // a: a line for the open list, after the cursor line (first when empty).
  function startListAdd(k) {
    var v = settingsView
    if (!k || k !== v.listKey || isSaving(k) || v.prefs === null) return
    var items = v.listItems
    var after = items.length === 0 ? -1 : items[v.listIndex].index
    input = { kind: "list", key: k, label: SettingsView.listTitle(k), prompt: SettingsView.listPrompt(k),
      from: String(v.prefs[k] === undefined ? "" : v.prefs[k]), after: after }
    commands.startInput("settingEdit", "")
  }

  // Enter on a list line: checked by the list's rule (list-rules-cases.json),
  // then a ban or the whole list with the line added.
  function commitListLine(t, raw) {
    var kind = SettingsView.listKindOf(t.key)
    var parsed = SettingsView.parseListLine(kind, raw)
    if (parsed.error !== undefined) { commands.refuseInput(parsed.error); return }
    input = null
    commands.endInput()
    // A re-read landed while the line was typed: the list isn't the one the
    // line was placed in, and writing t.from's lines back would undo it.
    var now = settingsView.prefs ? settingsView.prefs[t.key] : undefined
    if (t.key !== SettingsView.BAN_KEY && String(now === undefined ? "" : now) !== t.from) {
      client.note("The list changed; nothing was added.", "urgent")
      return
    }
    if (t.key === SettingsView.BAN_KEY) {
      // The list as it stands now: a re-read may have landed since a.
      if (SettingsView.banHas(now, parsed.value)) { client.note(parsed.value + " is already banned.", "muted"); return }
      banWrite("add", parsed.value)
      return
    }
    var r = SettingsView.listWithAdded(t.key, t.from, t.after, parsed.value)
    if (r.same === true) { if (r.note) client.note(r.note, "muted"); return }
    settingsView.setListCursor(t.key, r.index)
    write(t.key, t.label, r.value, SettingsView.listDoneNote(t.key, "add", parsed.value))
  }

  // x: the line captured at key time (args.listItem); no confirm (u undoes).
  function removeLine(k, item) {
    var v = settingsView
    if (!k || !item || k !== v.listKey || isSaving(k) || v.prefs === null) return
    if (k === SettingsView.BAN_KEY) { banWrite("remove", item.value); return }
    var r = SettingsView.listWithout(k, String(v.prefs[k] === undefined ? "" : v.prefs[k]), item)
    if (r.stale === true) { client.note("The list changed; nothing was removed.", "urgent"); return }
    write(k, SettingsView.listTitle(k), r.value, SettingsView.listDoneNote(k, "remove", item.value))
  }

  // An unban records the list before it (undo re-adds the address); an
  // add records nothing. undoEntry/done: an undo's re-add and its note.
  function banWrite(op, ip, undoEntry, done) {
    var c = client
    var prefs = settingsView.prefs
    var record = op === "remove" && !undoEntry && prefs
      ? { kind: "ban", ip: ip, before: String(prefs[SettingsView.BAN_KEY] === undefined ? "" : prefs[SettingsView.BAN_KEY]) } : null
    var ticket = c.service.banList(op, ip, c.opts([]))
    var label = SettingsView.listTitle(SettingsView.BAN_KEY)
    var note = done || SettingsView.listDoneNote(SettingsView.BAN_KEY, op, ip)
    c.messages = View.msgTrack(c.messages, ticket, "setting", 0, [],
      { progress: (op === "add" ? "Banning " : "Unbanning ") + ip + "…", done: record ? note + SettingsView.UNDO_HINT : note, raw: true })
    track(ticket, SettingsView.BAN_KEY, label, record, undoEntry)
  }

  // ---- secrets (slice 4b) -----------------------------------------------------------

  // Enter in the masked field. raw is the field's text, passed straight
  // through: the field is emptied before anything else, an empty Enter
  // changes nothing, a refused value stays (masked) with the reason.
  // Service runs one secret at a time: while another saves, the value
  // stays (masked) in its field with a note, rather than being emptied and
  // then refused.
  function commitSecret(t, raw) {
    if (raw === "") { closeSecret(); commands.endInput(); return }
    var parsed = SettingsView.parseListLine("secret", raw)
    if (parsed.error !== undefined) { commands.refuseInput(parsed.error); return }
    if (secretSaving()) { commands.refuseInput(SettingsView.SECRET_BUSY); return }
    closeSecret()
    commands.endInput()
    var c = client
    var ticket = c.service.setSecret(t.key, raw, c.opts([]))
    c.messages = View.msgTrack(c.messages, ticket, "setting", 0, [],
      { progress: "Saving " + t.label + "…", done: SettingsView.secretDoneNote(t.key, "set"), raw: true })
    track(ticket, t.key, t.label, null, null, true)
  }

  // A secret this window sent (Service.setSecret) hasn't finished.
  function secretSaving() {
    for (var t in tickets) if (tickets[t].secret === true) return true
    return false
  }

  // Empties the masked field and forgets that it was open.
  function closeSecret() {
    if (commands.inputLine) commands.inputLine.setInput("")
    secretOpen = false
    input = null
  }

  // x on a set secret: SettingsView.secretQuestion's CONFIRM; its y comes
  // back here with confirmed.
  function clearSecret(k, confirmed) {
    var v = settingsView
    if (!k || isSaving(k)) return
    var ed = SettingsView.editorFor(k, v.prefs)
    if (ed.kind !== "secret" || ed.set !== true) return
    var c = client
    if (confirmed !== true) {
      var r = Registry.raiseConfirm(c.regState, "settings.clearSecret", "secretClear", { settingKey: k })
      var cf = ({})
      for (var f in r.confirm) cf[f] = r.confirm[f]
      cf.line = SettingsView.secretQuestion(k)
      c.regState = r.state
      c.confirmHashes = []
      c.confirm = cf
      return
    }
    var label = labelOf(k, v.prefs)
    var ticket = c.service.clearSecret(k, c.opts([]))
    c.messages = View.msgTrack(c.messages, ticket, "setting", 0, [],
      { progress: "Clearing " + label + "…", done: SettingsView.secretDoneNote(k, "clear"), raw: true })
    track(ticket, k, label)
  }

  // The confirm gate: nothing when unchanged; confirmFor's line raises one
  // CONFIRM on the captured key and value; otherwise the write runs now.
  function propose(k, label, from, to) {
    if (SettingsView.equalValue(k, from, to)) return
    if (SettingsView.confirmVia(k) === "rssAutoDl" && to === true) { countAutoDl(k, label, from, to); return }
    var detail = SettingsView.confirmFor(k, from, to)
    if (detail === "") { write(k, label, to); return }
    var c = client
    var r = Registry.raiseConfirm(c.regState, "settings.write", "settingConfirm", { key: k, label: label, value: to, from: from })
    var q = View.settingQuestion(label, typeof to === "boolean", to, SettingsView.formatValue(k, to))
    var cf = ({})
    for (var f in r.confirm) cf[f] = r.confirm[f]
    cf.line = q.line
    cf.detail = detail
    cf.accept = q.accept
    c.regState = r.state
    c.confirmHashes = []
    c.confirm = cf
  }

  // D8: count, then ask. One count at a time; a second Space while it's
  // out does nothing. done/undoEntry: an undo's (undoWith), carried to the
  // write; an undo whose count can't ask gets its entry back.
  function countAutoDl(k, label, from, to, done, undoEntry) {
    var c = client
    if (autoDlCounting !== "") { if (undoEntry) restoreUndo(undoEntry); return }
    if (!c.service || typeof c.service.rssAutoPreview !== "function") {
      raiseAutoDl(k, label, from, to, SettingsView.autoDlQuestion(false, null), done, undoEntry)
      return
    }
    var myVisit = visit
    autoDlCounting = k
    c.service.rssAutoPreview(function(ok, err, data) {
      if (myVisit !== edits.visit) return
      edits.autoDlCounting = ""
      if (!edits.settingsView.open) return
      // A re-read meanwhile already shows it on: nothing to ask.
      if (SettingsView.equalValue(k, SettingsView.currentValue(k, edits.settingsView.prefs), to)) return
      if (edits.client.mode !== "NORMAL") { if (undoEntry) edits.restoreUndo(undoEntry); return }
      edits.raiseAutoDl(k, label, from, to, SettingsView.autoDlQuestion(ok, data), done, undoEntry)
    })
  }

  function raiseAutoDl(k, label, from, to, line, done, undoEntry) {
    var c = client
    var args = { key: k, label: label, value: to, from: from }
    if (done) args.done = done
    if (undoEntry) args.undo = undoEntry
    var r = Registry.raiseConfirm(c.regState, "settings.write", "rssAutoDlOn", args)
    var cf = ({})
    for (var f in r.confirm) cf[f] = r.confirm[f]
    cf.line = line
    c.regState = r.state
    c.confirmHashes = []
    c.confirm = cf
  }

  // The one setPref call: qbt pref-set <key> -- <value>, a composite time
  // as its "HH:MM" (qbt splits it), a list as its newline-joined value.
  // done: the note on success (a list's; SettingsView.doneNote otherwise).
  // undoEntry: the history entry this write undoes (it records nothing);
  // any other write records the value qBittorrent held before it.
  function write(k, label, value, done, undoEntry) {
    var c = client
    var from = undoEntry ? undefined : SettingsView.undoValue(k, settingsView.prefs)
    var record = from === undefined ? null : { kind: "pref", key: k, label: label, from: from }
    var ticket = c.service.setPref(k, String(value), c.opts([]))
    var note = done || SettingsView.doneNote(k, value)
    // A write u can undo says so (Ruling EJ); finished() takes it back off
    // when the write ends outside this visit.
    c.messages = View.msgTrack(c.messages, ticket, "setting", 0, [],
      { progress: "Saving " + label + "…", done: record ? note + SettingsView.UNDO_HINT : note, raw: true })
    track(ticket, k, label, record, undoEntry)
  }

  // A running write of k (any kind): "saving…" until its ticket ends.
  // record/undoEntry: write()'s and banWrite()'s (none for a secret);
  // secret: a Service.setSecret ticket. A write Service refused outright
  // puts its undo entry back.
  function track(ticket, k, label, record, undoEntry, secret) {
    if (!(Number(ticket) > 0)) { if (undoEntry) restoreUndo(undoEntry); return }
    var n = ({})
    for (var t in tickets) n[t] = tickets[t]
    n[String(ticket)] = { key: k, label: label, record: record || null, undo: undoEntry || null, visit: visit, secret: secret === true }
    tickets = n
    setSaving(k, "run")
  }

  // Client's actionFinished, before its own msgFinish: only this window's
  // write tickets. A success re-reads with the values kept up; a failure
  // keeps the row's value and shows qbt's sentence or names the setting.
  function finished(ticket, ok, error) {
    var w = tickets[String(ticket)]
    if (!w) return
    var n = ({})
    for (var t in tickets) if (t !== String(ticket)) n[t] = tickets[t]
    tickets = n
    var c = client
    var here = settingsView.open && w.visit === visit
    var hinted = ok === true && !here && w.record && c.messages.tickets && c.messages.tickets[String(ticket)]
      ? String(c.messages.tickets[String(ticket)].done || "") : ""
    c.messages = View.msgFinish(c.messages, ticket, ok, ok === true ? "" : View.settingFailure(w.label, error))
    // Ended after leaving: nothing records it, so the note doesn't offer u.
    if (hinted !== "" && c.messages.note === hinted && hinted.slice(-SettingsView.UNDO_HINT.length) === SettingsView.UNDO_HINT) {
      c.note(hinted.slice(0, hinted.length - SettingsView.UNDO_HINT.length), "muted")
    }
    if (ok === true && here && w.record) undoPending = undoPending.concat([w.record])
    if (ok !== true && here && w.undo) restoreUndo(w.undo)
    if (ok === true && settingsView.open) {
      setSaving(w.key, "done")
      settingsView.reload(true)
    } else {
      setSaving(w.key, null)
    }
  }

  // ---- undo (slice 4b, Task 4) -------------------------------------------------------

  // The re-read after a write is in: each waiting record becomes a history
  // entry, unless qBittorrent holds what it held before (EC: a no-op).
  function resolvePending() {
    var p = settingsView.prefs
    if (undoPending.length === 0 || !p) return
    var stack = undoStack.slice()
    for (var i = 0; i < undoPending.length; i++) {
      var r = undoPending[i]
      if (r.kind === "ban") {
        var now = p[SettingsView.BAN_KEY]
        if (SettingsView.banHolds(r.before, r.ip) && !SettingsView.banHolds(now, r.ip)) stack.push({ kind: "ban", ip: r.ip })
        continue
      }
      var to = SettingsView.undoValue(r.key, p)
      if (to !== undefined && !SettingsView.sameStored(r.key, r.from, to)) stack.push({ key: r.key, label: r.label, from: r.from, to: to })
    }
    undoPending = []
    undoStack = stack
  }

  // A failed undo write's entry goes back at the depth it was taken from
  // (entry.at, set by undoWith), under any entry recorded since.
  function restoreUndo(entry) {
    var e = ({})
    for (var f in entry) if (f !== "at") e[f] = entry[f]
    var stack = undoStack.slice()
    var at = typeof entry.at === "number" ? Math.max(0, Math.min(entry.at, stack.length)) : stack.length
    stack.splice(at, 0, e)
    undoStack = stack
  }

  function clearUndo() {
    undoStack = []
    undoPending = []
    undoReading = false
    autoDlCounting = ""
    visit = visit + 1
  }

  // u: re-reads, then undoWith the fresh values. Nothing while a write or
  // its re-read is still out (the newest entry may be about to change).
  function undo() {
    var c = client
    if (undoReading) { c.note(SettingsView.UNDO_CHECKING, "muted"); return }
    if (undoStack.length === 0) { c.note(SettingsView.UNDO_EMPTY, "muted"); return }
    // The down screen: nothing shows to undo against.
    if (settingsView.failed) { c.note(SettingsView.UNDO_DOWN, "muted"); return }
    if (Object.keys(tickets).length > 0 || undoPending.length > 0) { c.note(SettingsView.UNDO_WAIT, "muted"); return }
    if (!c.service || typeof c.service.readPrefs !== "function") return
    undoReading = true
    var myVisit = visit
    var seq = settingsView.readSeq
    c.service.readPrefs(function(res) {
      if (myVisit !== edits.visit || !edits.settingsView.open) return
      edits.undoReading = false
      // The down screen came up meanwhile: it stays, and the entry too.
      if (edits.settingsView.failed) return
      if (!res || res.ok !== true || !res.prefs) { edits.client.note(SettingsView.UNDO_READ_FAILED, "urgent"); return }
      // The view shows these too, unless a newer read is already out.
      if (edits.settingsView.readSeq === seq) edits.settingsView.prefs = res.prefs
      edits.undoWith(res.prefs)
    })
  }

  // The newest entry against prefs as they are now (see the header).
  function undoWith(p) {
    var c = client
    if (undoStack.length === 0) return
    // A key pressed while the read was out opened a field, the palette, a
    // picker or a question: nothing lands over it, and the entry stays.
    if (c.mode !== "NORMAL") return
    if (Object.keys(tickets).length > 0 || undoPending.length > 0) { c.note(SettingsView.UNDO_WAIT, "muted"); return }
    var stack = undoStack.slice()
    // at: its depth, should a failed write put it back (restoreUndo).
    var e = ({})
    var top = stack.pop()
    for (var f0 in top) e[f0] = top[f0]
    e.at = stack.length
    undoStack = stack
    var more = stack.length
    var why = ""
    if (e.kind === "ban") {
      if (SettingsView.banHolds(p[SettingsView.BAN_KEY], e.ip)) { c.note(SettingsView.undoBanSameNote(e.ip, more), "muted"); return }
      why = SettingsView.undoBanRefusal(e.ip)
      if (why !== "") { c.note(SettingsView.undoSkipNote("the unban of " + e.ip, why, more), "urgent"); return }
      banWrite("add", e.ip, e, SettingsView.undoBanDoneNote(e.ip, more))
      return
    }
    var k = e.key
    var now = SettingsView.undoValue(k, p)
    if (SettingsView.sameStored(k, now, e.from)) { c.note(SettingsView.undoSameNote(k, e.label, e.from, more), "muted"); return }
    why = SettingsView.undoRefusal(k, e.from, p)
    if (why !== "") { c.note(SettingsView.undoSkipNote(e.label, why, more), "urgent"); return }
    var target = SettingsView.undoWriteValue(k, e.from)
    var cur = SettingsView.currentValue(k, p)
    var done = SettingsView.undoDoneNote(k, e.label, e.from, more)
    var stale = !SettingsView.sameStored(k, now, e.to)
    // D8: undo never turns auto-download on without its count and question.
    if (SettingsView.confirmVia(k) === "rssAutoDl" && target === true) { countAutoDl(k, e.label, cur, target, done, e); return }
    var detail = SettingsView.confirmFor(k, cur, target)
    if (!stale && detail === "") { write(k, e.label, target, done, e); return }
    // One CONFIRM: the "changed since" question (or the edit's own), with
    // the risky-change reason as its detail.
    var q = stale ? SettingsView.undoQuestion(e.label, k, now, e.from)
      : View.settingQuestion(e.label, typeof target === "boolean", target, SettingsView.formatValue(k, target))
    var r = Registry.raiseConfirm(c.regState, "settings.write", "settingConfirm", { key: k, label: e.label, value: target, from: cur, done: done, undo: e })
    var cf = ({})
    for (var f in r.confirm) cf[f] = r.confirm[f]
    cf.line = q.line
    cf.detail = detail
    cf.accept = q.accept
    c.regState = r.state
    c.confirmHashes = []
    c.confirm = cf
  }

  // ---- INSERT ------------------------------------------------------------------------

  // Enter in the field: raw exactly as typed (parseInput never trims). An
  // error stays in INSERT with its message.
  function commitInput(raw) {
    var t = input
    if (!t) { commands.endInput(); return }
    if (t.kind === "secret") { commitSecret(t, raw); return }
    if (t.kind === "list") { commitListLine(t, raw); return }
    var parsed = SettingsView.parseInput(t.key, raw, t.prefs)
    if (parsed.error !== undefined) { commands.refuseInput(parsed.error); return }
    input = null
    commands.endInput()
    propose(t.key, t.label, t.from, parsed.value)
  }

  // ---- the picker ----------------------------------------------------------------------

  function openPicker(k, label, from) {
    pickerCapture = { key: k, label: label, from: from }
    settingsView.pickerOpen = true
    picker.prompt = label
    picker.setQuery("")
    refreshPicker()
    commands.setMode("PICKER")
    picker.focusField()
  }

  // The choices matching the query, in the schema's order, the current
  // value marked; the cursor starts on it.
  function refreshPicker() {
    var cap = pickerCapture
    if (!cap) return
    var ed = SettingsView.editorFor(cap.key, settingsView.prefs)
    var choices = ed.kind === "picker" ? ed.choices : []
    var rows = []
    var at = -1
    for (var i = 0; i < choices.length; i++) {
      var ch = choices[i]
      var m = View.fuzzyMatch(picker.query, ch.label)
      if (!m) continue
      var current = String(ch.value) === String(cap.from)
      if (current) at = rows.length
      rows.push({ kind: "choice", id: String(ch.value), value: ch.value, title: ch.label, indices: m.indices, enabled: true, reason: "", keys: current ? "current" : "" })
    }
    picker.rows = rows
    picker.cursor = at >= 0 ? at : View.paletteFirst(rows)
  }

  // Enter (or a click) on a choice: the picker closes, then the choice goes
  // through the confirm gate.
  function acceptPicker() {
    var cap = pickerCapture
    var row = picker.currentRow()
    commands.closePicker()
    if (cap && row) propose(cap.key, cap.label, cap.from, row.value)
  }

  // ClientCommands.closePicker's hook: nothing of the picker stays.
  function dropPicker() {
    pickerCapture = null
    settingsView.pickerOpen = false
  }

  // Client.close(): a settings question never outlives Settings (its own
  // kinds and View.SETTINGS_ACCEPT's view-copy ones, D8's rssAutoDlOn).
  function dropConfirm() {
    var c = client
    if (c.mode !== "CONFIRM" || !c.confirm) return
    var kind = c.confirm.kind
    if (kind !== "settingConfirm" && kind !== "secretClear" && !Object.prototype.hasOwnProperty.call(View.SETTINGS_ACCEPT, kind)) return
    var st = ({})
    for (var k in c.regState) st[k] = c.regState[k]
    st.mode = "NORMAL"
    st.pending = null
    c.regState = st
    c.confirm = null
  }

  // SettingsPane's footer shows "u undo" while there's something to undo.
  property Binding undoCountLink: Binding {
    target: edits.settingsView
    property: "undoCount"
    value: edits.undoStack.length
  }

  // A secret write's end (its own Service signal, not actionFinished).
  property Connections secretLink: Connections {
    target: edits.client.service
    ignoreUnknownSignals: true
    function onSecretFinished(ticket, ok, error) { edits.finished(ticket, ok, error) }
  }

  // The masked field: echo off while a secret is typed; closed any other
  // way than Enter (Esc sets input to null), it's emptied too.
  property Binding maskLink: Binding {
    target: edits.commands.inputLine ? edits.commands.inputLine.inputField : null
    property: "echoMode"
    value: edits.masked ? TextInput.Password : TextInput.Normal
  }
  // (masked itself may not have caught up when this runs: read input.)
  onInputChanged: if (secretOpen && (input === null || input.kind !== "secret")) closeSecret()

  property Connections pickerLink: Connections {
    target: edits.picker
    function onKeyForwarded(event) { edits.client.handleKey(event) }
    function onActivated(row) { edits.commands.setMode("NORMAL"); edits.acceptPicker() }
    function onDismissed() { edits.commands.closePicker() }
    function onQueryChanged() { edits.refreshPicker() }
  }

  // "saving…" stays until the re-read is in (or fails, or Settings closes);
  // a read that fails while qBittorrent is up says so (Ruling DO).
  property Connections viewLink: Connections {
    target: edits.settingsView
    function onPrefsChanged() { edits.dropDone(); edits.resolvePending() }
    // A write still running keeps its mark across a close and reopen.
    // Leaving Settings (or coming back) starts a new history.
    function onOpenChanged() { if (!edits.settingsView.open) edits.dropDone(); edits.clearUndo() }
    function onFailedChanged() {
      var v = edits.settingsView
      // A failed re-read: the writes waiting on it record nothing.
      if (v.failed) { edits.dropDone(); edits.undoPending = [] }
      var line = View.settingsReadNote(edits.client.tableState, v.failed, v.error)
      if (line !== "") edits.client.messages = View.msgError(edits.client.messages, line, [])
    }
  }

  function dropDone() {
    var n = ({})
    for (var s in settingsView.saving) if (settingsView.saving[s] !== "done") n[s] = settingsView.saving[s]
    settingsView.saving = n
  }
}
