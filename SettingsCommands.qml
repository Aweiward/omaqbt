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
  // ticket -> {key, label}: this window's writes still running.
  property var tickets: ({})

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
      narrow: v.narrow === true, undoCount: 0 }
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
      "list.down", "list.up", "list.add", "list.remove", "list.back"].indexOf(commandId) !== -1
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
      if (a.confirmed === true && a.key) write(a.key, a.label, a.value)
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
      if (SettingsView.banHas(t.from, parsed.value)) { client.note(parsed.value + " is already banned.", "muted"); return }
      banWrite("add", parsed.value)
      return
    }
    var r = SettingsView.listWithAdded(t.key, t.from, t.after, parsed.value)
    if (r.same === true) { if (r.note) client.note(r.note, "muted"); return }
    // qbt checks every line: one it would refuse (stored by qBittorrent's
    // own UI) blocks the write until it's removed, which is always allowed.
    var bad = SettingsView.listBadLine(t.key, r.value)
    if (bad) { client.note(SettingsView.listBadNote(bad), "urgent"); return }
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

  function banWrite(op, ip) {
    var c = client
    var ticket = c.service.banList(op, ip, c.opts([]))
    var label = SettingsView.listTitle(SettingsView.BAN_KEY)
    c.messages = View.msgTrack(c.messages, ticket, "setting", 0, [],
      { progress: (op === "add" ? "Banning " : "Unbanning ") + ip + "…", done: SettingsView.listDoneNote(SettingsView.BAN_KEY, op, ip), raw: true })
    track(ticket, SettingsView.BAN_KEY, label)
  }

  // ---- secrets (slice 4b) -----------------------------------------------------------

  // Enter in the masked field. raw is the field's text, passed straight
  // through: the field is emptied before anything else, an empty Enter
  // changes nothing, a refused value stays (masked) with the reason.
  function commitSecret(t, raw) {
    if (raw === "") { closeSecret(); commands.endInput(); return }
    var parsed = SettingsView.parseListLine("secret", raw)
    if (parsed.error !== undefined) { commands.refuseInput(parsed.error); return }
    closeSecret()
    commands.endInput()
    var c = client
    var ticket = c.service.setSecret(t.key, raw, c.opts([]))
    c.messages = View.msgTrack(c.messages, ticket, "setting", 0, [],
      { progress: "Saving " + t.label + "…", done: SettingsView.secretDoneNote(t.key, "set"), raw: true })
    track(ticket, t.key, t.label)
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

  // The one setPref call: qbt pref-set <key> -- <value>, a composite time
  // as its "HH:MM" (qbt splits it), a list as its newline-joined value.
  // done: the note on success (a list's; SettingsView.doneNote otherwise).
  function write(k, label, value, done) {
    var c = client
    var ticket = c.service.setPref(k, String(value), c.opts([]))
    c.messages = View.msgTrack(c.messages, ticket, "setting", 0, [],
      { progress: "Saving " + label + "…", done: done || SettingsView.doneNote(k, value), raw: true })
    track(ticket, k, label)
  }

  // A running write of k (any kind): "saving…" until its ticket ends.
  function track(ticket, k, label) {
    if (!(Number(ticket) > 0)) return
    var n = ({})
    for (var t in tickets) n[t] = tickets[t]
    n[String(ticket)] = { key: k, label: label }
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
    c.messages = View.msgFinish(c.messages, ticket, ok, ok === true ? "" : View.settingFailure(w.label, error))
    if (ok === true && settingsView.open) {
      setSaving(w.key, "done")
      settingsView.reload(true)
    } else {
      setSaving(w.key, null)
    }
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

  // Client.close(): a settings question never outlives Settings.
  function dropConfirm() {
    var c = client
    if (c.mode !== "CONFIRM" || !c.confirm || (c.confirm.kind !== "settingConfirm" && c.confirm.kind !== "secretClear")) return
    var st = ({})
    for (var k in c.regState) st[k] = c.regState[k]
    st.mode = "NORMAL"
    st.pending = null
    c.regState = st
    c.confirm = null
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
    function onPrefsChanged() { edits.dropDone() }
    // A write still running keeps its mark across a close and reopen.
    function onOpenChanged() { if (!edits.settingsView.open) edits.dropDone() }
    function onFailedChanged() {
      var v = edits.settingsView
      if (v.failed) edits.dropDone()
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
