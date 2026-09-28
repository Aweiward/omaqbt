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
QtObject {
  id: edits

  // The Client, its ClientCommands (INSERT/PICKER plumbing) and SettingsPane.
  required property var client
  required property var commands
  required property var settingsView

  // An open input: {key, label, from, prefs}, captured at Enter. The commit
  // reads only this, never the cursor as it stands.
  property var input: null
  // An open picker's {key, label, from}, captured at Enter.
  property var pickerCapture: null
  // ticket -> {key, label}: this window's writes still running.
  property var tickets: ({})

  readonly property var picker: settingsView.picker
  readonly property bool pickerOpen: settingsView.pickerOpen
  readonly property string inputShown: input ? input.label : ""

  // ---- dispatch state ------------------------------------------------------------

  // The setting under the Settings cursor and whether Space/Enter edit it
  // now (View.dispatchState's `settings`), or null outside the list.
  function flags() {
    var v = settingsView
    if (!v.open || v.failed || v.column !== "settingsKeys" || !v.cursorRow) return null
    var k = v.cursorRow.key
    if (isSaving(k)) return { key: k, toggle: false, editable: false }
    var kind = SettingsView.editorFor(k, v.prefs).kind
    return { key: k, toggle: kind === "toggle", editable: kind === "input" || kind === "picker" }
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
    var k = args.settingKey
    if (commandId === "settings.write") {
      if (args.confirmed === true && args.key) write(args.key, args.label, args.value)
      return
    }
    if (!v.open || !k || isSaving(k)) return
    var ed = SettingsView.editorFor(k, v.prefs)
    var from = SettingsView.currentValue(k, v.prefs)
    var label = labelOf(k, v.prefs)
    if (commandId === "settings.toggle") {
      if (ed.kind === "toggle") propose(k, label, from, ed.next)
      return
    }
    if (ed.kind === "input") {
      input = { key: k, label: label, from: from, prefs: v.prefs }
      commands.startInput("settingEdit", ed.prefill)
    } else if (ed.kind === "picker") {
      openPicker(k, label, from)
    }
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
  // as its "HH:MM" (qbt splits it).
  function write(k, label, value) {
    var c = client
    var ticket = c.service.setPref(k, String(value), c.opts([]))
    c.messages = View.msgTrack(c.messages, ticket, "setting", 0, [],
      { progress: "Saving " + label + "…", done: SettingsView.doneNote(k, value), raw: true })
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
    if (c.mode !== "CONFIRM" || !c.confirm || c.confirm.kind !== "settingConfirm") return
    var st = ({})
    for (var k in c.regState) st[k] = c.regState[k]
    st.mode = "NORMAL"
    st.pending = null
    c.regState = st
    c.confirm = null
  }

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
    function onOpenChanged() { if (!edits.settingsView.open) edits.settingsView.saving = ({}) }
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
