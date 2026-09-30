pragma ComponentBehavior: Bound

import QtQuick
import "CommandRegistry.js" as Registry
import "ClientView.js" as View
import "RssRules.js" as Rules

// The RSS rules area's commands (slice 5b2, Task 3): what RssRulesPane.run
// hands here, its three INSERTs (a's name, n's rename, a field's value),
// its field pickers, the reads (`qbt rss rules`, rule-check, rule-preview,
// through Service's callbacks) and the ends of the writes
// (Service.rssFinished). RssRulesPane holds the state and draws it; this
// holds the behaviour, as RssCommands sits beside RssPane. The contract is
// the header of RssRulesPane.qml and tests/fixtures/rss-rules-contract.md.
//
// - Edit while off (OV15): Enter on an enabled rule asks confirmEditOff,
//   and its y turns the rule off before the fields take the keys.
// - The draft: entering the fields snapshots the rule's fields (enabled
//   included) and torrentParams.use_auto_tmm. Auto-download off, each
//   commit (a field's INSERT once rule-check accepts it, a toggle, a
//   picker's apply) saves that field at once (keep) and previews; a
//   refused save puts the field back and says why. Auto-download on
//   (OV2), a commit changes only the draft; p saves it once and previews,
//   as do the leave confirm's y and turning the rule on. After a save the
//   snapshot is the written values (useAutoTmm stays).
// - Leaving a dirty draft's rule asks confirmLeave first: y saves, then the
//   action runs again as if pressed; a refused save runs nothing and the
//   draft stays dirty. n keeps editing.
// - Turning on never carries changes: a dirty draft is saved first, then
//   the saved rule is previewed; noTorrent > 0 refuses with a note, else
//   the confirm names n, and its y is the only rssRuleSet(name, {}, {},
//   "on"). Turning off is immediate. A rule turned on from its fields
//   leaves them (an enabled rule isn't edited).
// - Previews (D12): one at a time, the newest queued request wins, and an
//   answer is dropped when a write for its rule was sent after it was
//   asked for (each rule's generation).
// - Every write re-reads the rules once it ends, ok or not.
QtObject {
  id: cmds

  required property var area

  // (area is gone for a moment while the window is torn down.)
  readonly property var client: area ? area.client : null
  readonly property var service: area ? area.service : null
  readonly property var commands: area ? area.commands : null
  readonly property var view: area ? area.view : null

  // ticket -> {kind, name, ...}: this window's rule writes still going.
  property var tickets: ({})
  // A rules read is running; another asked for meanwhile runs after it.
  property bool reading: false
  property bool readAgain: false
  // The INSERT a, n or a field's Enter opened: {purpose, feedUrl} |
  // {purpose, rule} | {purpose, key} (frozen then).
  property var input: null
  // Each rule-check's token: an answer after Esc, or after a newer Enter,
  // is ignored.
  property int checkToken: 0
  // Each turn-on preview's token: dropped when the rules close.
  property int onToken: 0
  // The field picker's state: {kind, key, from, working (the feeds'
  // list)}; null while none is open.
  property var pickerCap: null

  function svcHas(name) {
    return !!service && typeof service[name] === "function"
  }

  function note(text, tone) {
    if (client) client.note(text, tone || "muted")
  }

  // Every write failure speaks (RssCommands.fail).
  function fail(text) {
    if (client) client.messages = View.msgError(client.messages, String(text || ""), [])
  }

  function remember(ticket, entry) {
    if (!(Number(ticket) > 0)) {
      note(View.BUSY_NOTE, "muted")
      return false
    }
    var n = ({})
    for (var t in tickets) n[t] = tickets[t]
    n[String(ticket)] = entry
    tickets = n
    return true
  }

  function take(ticket) {
    var k = String(ticket)
    var e = tickets[k]
    if (!e) return null
    var n = ({})
    for (var t in tickets) if (t !== k) n[t] = tickets[t]
    tickets = n
    return e
  }

  // Raises one of the rules' CONFIRMs (RssCommands.raise's recipe): `y`
  // comes back as commandId with args plus confirmed.
  function raise(commandId, kind, args, line) {
    var c = client
    var r = Registry.raiseConfirm(c.regState, commandId, kind, args)
    var cf = ({})
    for (var f in r.confirm) cf[f] = r.confirm[f]
    cf.line = line
    c.regState = r.state
    c.confirmHashes = []
    c.confirm = cf
  }

  function copyArgs(a, drop) {
    var out = ({})
    for (var k in a || ({})) if ((drop || []).indexOf(k) === -1) out[k] = a[k]
    return out
  }

  // ---- the reads ---------------------------------------------------------------------

  // check: "open" (the rules opened: a kept draft whose rule went or was
  // turned on elsewhere leaves the fields) or "reload" (r: also a fresh
  // snapshot of the rule), else "" (a write's read-back: the draft keeps
  // its snapshot, D6).
  function readRules(check) {
    if (check) area.pendingCheck = check
    if (!svcHas("rssRules")) return
    if (reading) { readAgain = true; return }
    var t = service.rssRules(function(ok, error, data) { cmds.rulesRead(ok, error, data) })
    reading = Number(t) > 0
  }

  function rulesRead(ok, error, data) {
    reading = false
    if (!ok) fail(error)
    else if (data && typeof data === "object" && Array.isArray(data.rules)) area.applyRules(data)
    if (readAgain) {
      readAgain = false
      readRules("")
    }
  }

  // ---- RssRulesPane.run's commands ----------------------------------------------------

  function run(commandId, args) {
    var a = args || ({})
    // The leave confirm's y: save, then the action again (without the mark).
    if (a.confirmed === true && a.leave === true) {
      saveDraft({ commandId: commandId, args: copyArgs(a, ["confirmed", "leave"]) })
      return
    }
    var rule = a.rule && typeof a.rule === "object" ? a.rule : null
    var yes = a.confirmed === true
    switch (commandId) {
    case "rss.ruleDown": area.move(1); return
    case "rss.ruleUp": area.move(-1); return
    case "rss.ruleEdit":
      if (!rule || guardLeave(commandId, a, rule.name)) return
      ruleEdit(rule, yes)
      return
    case "rss.ruleNew": startNew(a.item); return
    case "rss.ruleRename":
      if (!rule || guardLeave(commandId, a, rule.name)) return
      startRename(rule)
      return
    case "rss.ruleRemove":
      if (!rule || guardLeave(commandId, a, rule.name)) return
      remove(rule, yes)
      return
    case "rss.ruleToggle":
      if (!rule || guardLeave(commandId, a, rule.name)) return
      toggle(rule, yes)
      return
    case "rss.ruleReload": reload(yes); return
    case "rss.fieldEdit": if (a.field) fieldEdit(a.field.key); return
    case "rss.fieldToggle":
      if (!a.field) return
      if (a.field.key === "enabled") { run("rss.ruleToggle", { rule: rule }); return }
      fieldToggle(a.field.key)
      return
    case "rss.rulePreview": previewKey(); return
    case "rss.ruleDiscard": discard(rule, yes); return
    case "rss.fieldsBack":
      if (guardLeave(commandId, a)) return
      area.leaveFields()
      return
    case "rss.rulesBack":
      if (guardLeave(commandId, a)) return
      view.leaveRules()
      return
    case "rss.rulesSwitch":
      if (area.column() === "rssRules") {
        var cur = area.cursorRule()
        if (cur) run("rss.ruleEdit", { rule: { name: cur.name, enabled: cur.enabled === true } })
        return
      }
      if (area.narrow) { area.openRuleList(); return }
      if (guardLeave(commandId, a)) return
      area.leaveFields()
      return
    case "rss.ruleListPick": {
      var picked = area.overlayRule()
      if (!picked) return
      if (area.draft && picked.name === area.draft.name) { area.setColumn("rssRuleFields"); return }
      run("rss.ruleEdit", { rule: { name: picked.name, enabled: picked.enabled === true } })
      return
    }
    case "rss.ruleListClose":
    case "rss.previewClose":
      area.setColumn("rssRuleFields")
      return
    default: return
    }
  }

  // A dirty draft's rule is left (name: the rule the action names; none
  // means the action always leaves): confirmLeave first. true: raised.
  function guardLeave(commandId, a, name) {
    var d = area.draft
    if (!d || !area.dirty()) return false
    if (name !== undefined && name === d.name) return false
    var args = copyArgs(a, ["confirmed"])
    args.leave = true
    raise(commandId, "rssRuleLeave", args, Rules.confirmLine("rssRuleLeave", { name: d.name }))
    return true
  }

  // ---- Enter, a, n, x ------------------------------------------------------------------

  function ruleEdit(rule, confirmed) {
    var cur = area.ruleByName(rule.name)
    if (!cur) return
    if (area.draft && area.draft.name === rule.name) { area.enterFields(rule.name); return }
    if (cur.enabled !== true) { area.enterFields(rule.name); return }
    if (confirmed !== true) {
      raise("rss.ruleEdit", "rssRuleEditOff", { rule: rule }, Rules.confirmLine("rssRuleEditOff", { name: rule.name }))
      return
    }
    if (!svcHas("rssRuleSet")) return
    area.bumpGen(rule.name)
    remember(service.rssRuleSet(rule.name, ({}), ({}), "off"), { kind: "off", name: rule.name, edit: true })
  }

  function startNew(item) {
    var url = item && item.folder !== true && typeof item.path === "string" ? view.feedUrl(item.path) : ""
    input = { purpose: "rssRuleName", feedUrl: url }
    commands.startInput("rssRuleName", "")
  }

  function startRename(rule) {
    input = { purpose: "rssRuleRename", rule: rule }
    commands.startInput("rssRuleRename", rule.name)
  }

  function remove(rule, confirmed) {
    if (confirmed !== true) {
      raise("rss.ruleRemove", "rssRuleRemove", { rule: rule }, Rules.confirmLine("rssRuleRemove", { name: rule.name }))
      return
    }
    if (!svcHas("rssRuleRemove")) return
    area.bumpGen(rule.name)
    remember(service.rssRuleRemove(rule.name), { kind: "remove", name: rule.name })
  }

  // ---- e: on and off --------------------------------------------------------------------

  function toggle(rule, confirmed) {
    var cur = area.ruleByName(rule.name)
    if (!cur || !svcHas("rssRuleSet")) return
    if (cur.enabled === true) {
      area.bumpGen(rule.name)
      remember(service.rssRuleSet(rule.name, ({}), ({}), "off"), { kind: "off", name: rule.name })
      return
    }
    if (confirmed === true) {
      area.bumpGen(rule.name)
      remember(service.rssRuleSet(rule.name, ({}), ({}), "on"), { kind: "on", name: rule.name })
      return
    }
    // A dirty draft is saved first (keep); a refused save turns nothing on.
    if (area.draft && area.draft.name === rule.name && area.dirty()) {
      saveDraft({ turnOn: rule.name })
      return
    }
    turnOnPreview(rule.name)
  }

  // The saved rule's preview, then the confirm with its n (or the
  // noTorrent refusal). An answer after the rules closed, or with another
  // mode up, raises nothing.
  function turnOnPreview(name) {
    if (!svcHas("rssRulePreview")) return
    onToken++
    var token = onToken
    var gen = area.genOf(name)
    var t = service.rssRulePreview(name, function(ok, error, data) {
      if (token !== cmds.onToken) return
      if (!ok) { cmds.fail(error); return }
      var g = Rules.previewGroups(data)
      cmds.area.storePreview(name, gen, { groups: g })
      if (g.m > 0) { cmds.note(Rules.sentence("noTorrentBlock", { m: g.m }), "urgent"); return }
      if (!cmds.area.open || !cmds.client || cmds.client.mode !== "NORMAL") return
      var auto = cmds.area.autoDl()
      cmds.raise("rss.ruleToggle", "rssRuleOn", { rule: { name: name, enabled: false } }, Rules.confirmLine("rssRuleOn", { name: name, n: g.n, autoDl: auto }))
    })
    if (!(Number(t) > 0)) note(View.BUSY_NOTE, "muted")
  }

  // ---- r, D -----------------------------------------------------------------------------

  function reload(confirmed) {
    if (area.dirty() && confirmed !== true) {
      raise("rss.ruleReload", "rssRuleDiscard", ({}), Rules.confirmLine("rssRuleDiscard", { name: area.draft.name }))
      return
    }
    if (area.draft) area.discardDraft()
    readRules("reload")
  }

  function discard(rule, confirmed) {
    if (!area.dirty()) return
    if (confirmed !== true) {
      raise("rss.ruleDiscard", "rssRuleDiscard", { rule: rule }, Rules.confirmLine("rssRuleDiscard", { name: area.draft.name }))
      return
    }
    area.discardDraft()
  }

  // ---- the fields ------------------------------------------------------------------------

  function fieldEdit(key) {
    var d = area.draft
    var f = Rules.fieldOf(key)
    if (!d || !f || area.writing(d.name)) return
    if (Rules.isInsert(f.kind)) {
      var v = d.values[key]
      input = { purpose: "rssRuleField", key: key }
      commands.startInput("rssRuleField", typeof v === "number" ? String(v) : (typeof v === "string" ? v : ""))
      return
    }
    if (Rules.isPicker(f.kind)) openPicker(key)
  }

  function fieldToggle(key) {
    var d = area.draft
    if (!d || area.writing(d.name)) return
    commit(key, d.values[key] !== true)
  }

  // A committed value: into the draft; auto-download off, saved at once
  // (that field, keep) and previewed.
  function commit(key, value) {
    var d = area.draft
    if (!d || Rules.sameValue(d.values[key], value)) return
    area.setValue(key, value)
    if (area.autoDl()) return
    saveDraft({ preview: true, revert: true, key: key })
  }

  // p: auto-download on with a dirty draft, save it first; then preview.
  // Narrow, the preview shows full width.
  function previewKey() {
    var d = area.draft
    if (!d) return
    if (area.narrow) area.setColumn("rssRulePreview")
    if (area.dirty()) { saveDraft({ preview: true }); return }
    area.requestPreview(d.name)
  }

  // Saves the draft (keep). next: {preview, revert, key} | {turnOn} |
  // {commandId, args}, what runs once it's saved.
  function saveDraft(next) {
    var d = area.draft
    if (!d || !svcHas("rssRuleSet")) return
    // One save per rule at a time: a second one would carry the same stale
    // snapshot and be refused as changed elsewhere.
    if (area.writing(d.name)) { note(View.BUSY_NOTE, "muted"); return }
    var diff = Rules.draftDiff(d.values, d.snapshot)
    if (Object.keys(diff.changes).length === 0) { afterSave(next, d.name); return }
    area.bumpGen(d.name)
    if (remember(service.rssRuleSet(d.name, diff.changes, diff.snapshot, "keep"), { kind: "save", name: d.name, changes: diff.changes, next: next }))
      area.markWriting(d.name, next && next.key ? next.key : "", true)
  }

  function afterSave(next, name) {
    var n = next || ({})
    if (n.preview === true) area.requestPreview(name)
    if (typeof n.turnOn === "string") turnOnPreview(n.turnOn)
    if (typeof n.commandId === "string") run(n.commandId, n.args)
  }

  // ---- the INSERTs -----------------------------------------------------------------------

  function stay(message) {
    note(message, "urgent")
    commands.stayInInsert()
  }

  function commitInput(purpose, text) {
    var inp = input
    if (!inp || inp.purpose !== purpose) { input = null; commands.endInput(); return }
    if (purpose === "rssRuleField") { checkField(inp, text); return }
    if (purpose === "rssRuleRename" && String(text) === inp.rule.name) { input = null; commands.endInput(); return }
    var r = Rules.checkRuleName(text)
    if (!r.ok) { stay(r.message); return }
    if (purpose === "rssRuleRename" && r.normalised === inp.rule.name) { input = null; commands.endInput(); return }
    if (Rules.ruleExists(area.rules(), r.normalised)) { stay(Rules.sentence("ruleExists", { name: r.normalised })); return }
    input = null
    commands.endInput()
    if (purpose === "rssRuleName" && svcHas("rssRuleCreate")) {
      remember(service.rssRuleCreate(r.normalised, inp.feedUrl), { kind: "create", name: r.normalised })
    } else if (purpose === "rssRuleRename" && svcHas("rssRuleRename")) {
      area.bumpGen(inp.rule.name)
      remember(service.rssRuleRename(inp.rule.name, r.normalised), { kind: "rename", name: inp.rule.name, to: r.normalised })
    }
  }

  // A field's Enter: the INSERT stays open while qbt checks the value
  // (rule-check); a refusal keeps it with qbt's sentence, an ok commits
  // qbt's normalised value.
  function checkField(inp, text) {
    var d = area.draft
    if (!d || !svcHas("rssRuleCheck")) { input = null; commands.endInput(); return }
    commands.stayInInsert()
    checkToken++
    var token = checkToken
    var key = inp.key
    var t = service.rssRuleCheck(key, String(text), d.values.useRegex === true, function(ok, error, data) {
      if (token !== cmds.checkToken || cmds.input !== inp) return
      if (!ok) { cmds.stay(error); return }
      cmds.input = null
      cmds.commands.setMode("NORMAL")
      cmds.commands.endInput()
      var value = data && typeof data === "object" && data.value !== undefined ? data.value : String(text)
      cmds.commit(key, value)
    })
    if (!(Number(t) > 0)) stay(View.BUSY_NOTE)
  }

  function cancelInput(purpose) {
    input = null
    checkToken++
  }

  // ---- the field pickers -----------------------------------------------------------------

  function openPicker(key) {
    var d = area.draft
    var from = d.values[key]
    pickerCap = { key: key, kind: Rules.fieldOf(key).kind, from: Array.isArray(from) ? from.slice() : from,
      working: Array.isArray(from) ? from.slice() : [] }
    area.pickerOpen = true
    var p = area.picker
    p.prompt = Rules.fieldOf(key).label
    p.setQuery("")
    refreshPicker(true)
    commands.setMode("PICKER")
    p.focusField()
  }

  function pickerChoices(cap) {
    var out = []
    var i
    if (cap.kind === "feeds") {
      var feeds = view.items && Array.isArray(view.items.feeds) ? view.items.feeds : []
      var known = ({})
      for (i = 0; i < feeds.length; i++) {
        var f = feeds[i]
        if (!f || f.folder === true || typeof f.url !== "string" || typeof f.path !== "string") continue
        known[f.url] = true
        out.push({ value: f.url, title: Rules.displayName(f.path) })
      }
      for (i = 0; i < cap.from.length; i++) {
        var u = String(cap.from[i])
        if (known[u] === true) continue
        known[u] = true
        out.push({ value: u, title: Rules.sentence("feedGone", { url: Rules.displayName(u) }) })
      }
      return out
    }
    if (cap.kind === "category") {
      out.push({ value: "", title: Rules.WINDOW.categoryNone })
      var cats = service && service.categories ? service.categories : []
      var seen = ({ "": true })
      for (i = 0; i < cats.length; i++) {
        var c = String(cats[i])
        if (seen[c] === true) continue
        seen[c] = true
        out.push({ value: c, title: Rules.displayName(c) })
      }
      if (seen[String(cap.from)] !== true) out.push({ value: String(cap.from), title: Rules.displayName(String(cap.from)) })
      return out
    }
    return [{ value: "default", title: Rules.WINDOW.addStoppedDefault }, { value: "yes", title: Rules.WINDOW.addStoppedYes },
      { value: "no", title: Rules.WINDOW.addStoppedNo }]
  }

  // The choices matching the query; a multi picker's rows carry [x] or
  // [ ]. first: the cursor starts on the current value (a multi picker's on
  // row 0); else it stays where it was.
  function refreshPicker(first) {
    var cap = pickerCap
    var p = area.picker
    if (!cap || !p) return
    var choices = pickerChoices(cap)
    var multi = cap.kind === "feeds"
    var rows = []
    var at = -1
    for (var i = 0; i < choices.length; i++) {
      var ch = choices[i]
      var m = View.fuzzyMatch(p.query, ch.title)
      if (!m) continue
      var current = !multi && String(ch.value) === String(cap.from)
      if (current) at = rows.length
      var row = { kind: "choice", id: String(ch.value), value: ch.value, title: ch.title, indices: m.indices, enabled: true, reason: "",
        keys: current ? "current" : "" }
      if (multi) row.prefix = cap.working.indexOf(ch.value) !== -1 ? "[x]" : "[ ]"
      rows.push(row)
    }
    var keep = p.cursor
    p.rows = rows
    if (first === true) p.cursor = at >= 0 ? at : View.paletteFirst(rows)
    else p.cursor = Math.max(0, Math.min(rows.length - 1, keep))
  }

  // Space on the feeds picker: tick or untick the cursor row (a new tick
  // goes last, so the rule's order is kept).
  function togglePicker() {
    var cap = pickerCap
    var p = area.picker
    if (!area.pickerOpen || !cap || cap.kind !== "feeds" || !p) return false
    var row = p.currentRow()
    if (!row) return true
    var w = cap.working.slice()
    var at = w.indexOf(row.value)
    if (at === -1) w.push(row.value)
    else w.splice(at, 1)
    pickerCap = { key: cap.key, kind: cap.kind, from: cap.from, working: w }
    refreshPicker(false)
    return true
  }

  // Enter: the choice (or the ticked feeds) into the draft, as a commit.
  function acceptPicker() {
    var cap = pickerCap
    var p = area.picker
    var row = p ? p.currentRow() : null
    commands.closePicker()
    if (!cap) return
    if (cap.kind === "feeds") commit(cap.key, cap.working.slice())
    else if (row) commit(cap.key, row.value)
  }

  function dropPicker() {
    pickerCap = null
    area.pickerOpen = false
  }

  // A click on a row: a single picker takes it, the feeds picker ticks it.
  function pickerClicked(row) {
    var p = area.picker
    if (!p || !row) return
    if (pickerCap && pickerCap.kind === "feeds") {
      for (var i = 0; i < p.rows.length; i++) if (p.rows[i].id === row.id) p.cursor = i
      togglePicker()
      return
    }
    commands.setMode("NORMAL")
    acceptPicker()
  }

  // ---- the ends of the writes -------------------------------------------------------------

  function finished(ticket, ok, error, data) {
    var e = take(ticket)
    if (!e) return
    var d = data && typeof data === "object" ? data : ({})
    if (e.kind === "save") {
      area.markWriting(e.name, "", false)
      if (ok) {
        area.saved(e.name, e.changes)
        readRules("")
        afterSave(e.next, e.name)
        return
      }
      fail(error)
      // Auto-download off, nothing stays unsaved: the field goes back.
      if (e.next && e.next.revert === true) area.discardDraft()
      readRules("")
      return
    }
    if (!ok) {
      fail(error)
      readRules("")
      return
    }
    if (e.kind === "off") {
      if (e.edit === true) area.pendingEnter = e.name
      else note(Rules.sentence("noteOff", { name: Rules.displayName(e.name) }), "muted")
    } else if (e.kind === "on") {
      note(Rules.sentence("noteOn", { name: Rules.displayName(e.name) }), "muted")
      area.turnedOn(e.name)
    } else if (e.kind === "create") {
      var made = typeof d.name === "string" ? d.name : e.name
      note(Rules.sentence("noteCreated", { name: Rules.displayName(made) }), "muted")
      area.pendingFollow = made
    } else if (e.kind === "rename") {
      area.pendingFollow = typeof d.name === "string" ? d.name : e.to
    } else if (e.kind === "remove") {
      note(Rules.sentence("noteRemoved", { name: Rules.displayName(e.name) }), "muted")
      area.forgetPreview(e.name)
    }
    readRules("")
  }

  // The window closed, or the rules closed: nothing here answers anyone.
  function reset(all) {
    input = null
    checkToken++
    onToken++
    if (all === true) tickets = ({})
  }

  property Connections serviceLink: Connections {
    target: cmds.service || null
    ignoreUnknownSignals: true
    function onRssFinished(ticket, ok, error, data) { cmds.finished(ticket, ok, error, data) }
  }
}
