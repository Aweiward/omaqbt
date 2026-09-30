pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons
import "ClientView.js" as View
import "RssRules.js" as Rules


// The RSS rules area (slice 5b2). Task 1 wrote the contract below; Task 3
// (the window lane) filled it in, keeping this interface, with
// RssRuleCommands.qml for the behaviour behind each key and RssRules.js
// for the pure rules (RULE_FIELDS, fieldRows, draftDiff, previewGroups,
// confirmLine, sentence) and the copy. RssRules.js pins its
// WINDOW and SENTENCES to tests/fixtures/rss-autorules-cases.json, which
// holds every rule, sentence and window line; the view reads, never
// retypes. See tests/fixtures/rss-rules-contract.md for qbt's side (`qbt rss
// rules|rule-*`, every value on stdin) and the RULE_FIELDS table.
//
// RssPane mounts it and hands it every rss.rule*, rss.field*, rss.rules*
// and rss.preview* command. `R` (rss.rules, from the feeds or the articles)
// opens it: RssPane sets its `column` to "rssRules" and calls openRules.
// Esc in the rule list (rss.rulesBack) comes here like every rules command;
// once no dirty draft is left (saved after rssRuleLeave's y, or none) this
// area calls view.leaveRules(), which calls closeRules and sets `column`
// back to "rssFeeds". While it's open it covers the feeds and articles, and
// the status line stays.
//
// Wide: three columns, the rule list (220 px; each rule's name, and "on" or
// "off": window stateOn/stateOff) | the fields (RULE_FIELDS, drawn with
// Settings' row delegate: label, value, help) | the preview (320 px: window
// previewWill, then muted previewNoTorrent and previewRead, each article
// title with previewDup when dup > 1, previewUnpreviewable per name,
// previewUpdating while one runs, previewEmpty, previewFailed). Narrow: one
// column at a time: the rule list full width (pane rssRules); the fields
// with a rule chip (pane rssRuleFields; Tab opens the rule-list overlay,
// pane rssRuleList, a ListOverlay without its field); `p` shows the preview
// full width (pane rssRulePreview; Esc back). Every rule name, pattern,
// title, URL and path is PlainText. qBittorrent down shows the torrent
// view's down screen (RssPane's).
//
// Given by RssPane:
//   service      Service. The rules calls (Task 3 adds them to Service.qml,
//                on 5b1's serial `rss` lane): rssRules(cb),
//                rssRuleCheck(key, value, useRegex, cb), rssRuleCreate(name,
//                feedUrl), rssRuleSet(name, changes, snapshot, enable),
//                rssRulePreview(name, cb), rssRuleRename(from, to),
//                rssRuleRemove(name), with their answers as RssPane's other
//                rss calls; Task 2 adds rssAutoPreview(cb) for Settings.
//   client       the Client (note, regState/confirm, messages), as RssPane.
//   commands     ClientCommands: startInput(purpose, initial), endInput(),
//                stayInInsert(), setMode(mode), inputLine.
//   view         the RssPane: view.column (the pane keys dispatch in; this
//                area sets it among "rssRules", "rssRuleFields",
//                "rssRulePreview" and "rssRuleList" while open), view.flags
//                (rssItem: the Feeds cursor's feed, for `a`'s feed),
//                view.items (the feeds, for the feeds picker and "(gone)"),
//                view.downShown, view.flags.rssUp.
//   narrow       below the breakpoint.
//   open         the rules area is showing (RssPane: RSS open and `column`
//                one of the four rules panes).
//
// Read by RssPane:
//   flags        always an object; RssPane copies each into its own flags
//                (View.VIEW_FLAG_STATE.rss writes them into the dispatch
//                state; View.rssFooterKeys reads them for the footer):
//                  rssRulesOpen      the rules area shows (RssPane sets it
//                                    from `column`, not from here);
//                  rssRule           {name, enabled} of the rule under the
//                                    list cursor, or of the rule being
//                                    edited while the fields have the keys;
//                                    null with no rules;
//                  rssField          {key, kind, value} of the field under
//                                    the fields cursor (key and kind from
//                                    RULE_FIELDS, value the draft's), or
//                                    null outside the fields;
//                  rssFieldEditable  that field edits with Enter: kinds
//                                    regexText, episode, number, path (an
//                                    INSERT), feeds, category, triBool (a
//                                    picker); false for toggles, and false
//                                    while a write for this rule runs;
//                  rssFieldToggle    that field toggles with Space: enabled
//                                    (routed to rss.ruleToggle), useRegex,
//                                    smartFilter;
//                  rssRuleDirty      the local draft has changes not saved
//                                    (only while auto-download is on: OV2);
//                  rssAutoDl         auto-download is on in qBittorrent
//                                    (`qbt rss rules`' autoDownload, re-read
//                                    at each openRules and after each write).
//   pickerOpen, picker  a field's ListOverlay (feeds: multi, every feed by
//                path with [x] marks and "(gone) <url>" rows for a rule URL no
//                feed has; category: single, the library's categories plus
//                "(none)"; addStopped: single, default/yes/no). RssPane
//                passes these through as the view host's.
//
// Called by RssPane:
//   openRules(item)  `R`: read `qbt rss rules`; item is the Feeds cursor's
//                feed or folder at key time (or null).
//   closeRules()  the rules area closes: after view.leaveRules() (no dirty
//                draft is left by then), or when the Client closes RSS
//                itself (a magnet's CONFIRM, a torrent row from the palette),
//                where no confirm can run: a dirty draft is then KEPT, still
//                dirty, as the view's state survives leaving (as Search's
//                does), so it is there when the rules reopen and the leave
//                confirm still guards it. Only windowClosed() drops a dirty
//                draft, with no write. Drops a picker.
//   windowClosed()  the window closes: drop a dirty draft (no write) and a
//                rules CONFIRM still up (kinds rssRuleRemove, rssRuleOn,
//                rssRuleEditOff, rssRuleLeave, rssRuleDiscard: mode NORMAL,
//                no pending, client.confirm null).
//   run(commandId, args, ev)  one of them. args (frozen at key time):
//                  args.rule     rssRule (rss.ruleEdit, rss.ruleRename,
//                                rss.ruleRemove, rss.ruleToggle,
//                                rss.rulePreview, rss.ruleDiscard,
//                                rss.fieldEdit, rss.fieldToggle);
//                  args.field    rssField's plain values (rss.fieldEdit,
//                                rss.fieldToggle; a list value, the feeds',
//                                isn't copied: read it from the draft);
//                  args.item     the Feeds cursor's feed (rss.rules,
//                                rss.ruleNew, rss.ruleReload);
//                  args.confirmed  true after this area's own CONFIRM's y.
//                It raises every CONFIRM itself with
//                Registry.raiseConfirm(client.regState, commandId, kind,
//                args) and client.confirm = {..., kind, line}; `y` comes back
//                as the same commandId with args.confirmed:
//                  rss.ruleRemove → rssRuleRemove (confirmRemove);
//                  rss.ruleToggle on a rule that's off → rssRuleOn, in this
//                    order (turning on never carries changes): a dirty draft
//                    is saved first (rssRuleSet(name, changes, snapshot,
//                    "keep")); then the SAVED rule is previewed; noTorrent >
//                    0 refuses with noTorrentBlock as a note and no confirm;
//                    otherwise the confirm names that preview's n
//                    (confirmRuleOn, confirmRuleOnNone with n = 0, or
//                    confirmRuleOnAutoOff while auto-download is off); y
//                    runs rssRuleSet(name, {}, {}, "on"), which previews
//                    again and writes nothing if noTorrent grew. On a rule
//                    that's on: off at once (rssRuleSet(name, {}, {},
//                    "off")), no confirm;
//                  rss.ruleEdit on an enabled rule → rssRuleEditOff
//                    (confirmEditOff; y: rssRuleSet enable "off", then the
//                    fields); a disabled rule goes straight into the fields;
//                  every action that leaves a dirty draft's rule →
//                    rssRuleLeave first (confirmLeave; y saves the draft,
//                    then the action runs as if pressed again, raising its
//                    own confirm if it has one; n keeps editing and the
//                    action doesn't run): rss.fieldsBack, rss.rulesSwitch
//                    (Tab), rss.rulesBack, rss.ruleListPick, rss.ruleEdit,
//                    rss.ruleRemove, rss.ruleToggle and rss.ruleRename on a
//                    different rule, rss.rules (R), and closing the rules
//                    by a key;
//                  rss.ruleDiscard and rss.ruleReload with a dirty draft →
//                    rssRuleDiscard (confirmDiscard).
//                The INSERTs it starts (commands.startInput): rss.ruleNew
//                (rssRuleName), rss.ruleRename (rssRuleRename, prefilled
//                with the name), rss.fieldEdit on an INSERT kind
//                (rssRuleField, prefilled with the value; the field key
//                stays in this area's own input state).
//                Auto-download off: each committed field (Enter in the
//                INSERT after rssRuleCheck accepts it, a toggle, a picker's
//                apply) saves at once (rssRuleSet with that field's change
//                and snapshot, enable "keep") and previews (D12: one run at
//                a time, the newest queued request wins, stale answers
//                dropped by generation). Auto-download on: commits change
//                the draft only, with no write (Review Focus 2); `p` saves
//                it once and previews; so do leaving (y) and turning the
//                rule on (saved with "keep" before its preview). After any
//                successful save the draft is clean and its snapshot
//                becomes the written values (enabled included; useAutoTmm
//                stays as it was when the fields were entered). While
//                auto-download is on, View.rssRulesFooterNote(pane, flags)
//                gives autoDlFooter: show it as a muted line under this
//                area's footer key hints.
//                rss.rulesSwitch: Tab between the columns; narrow, from the
//                fields it opens rssRuleList. rss.rulePreview narrow: shows
//                rssRulePreview. rss.previewClose, rss.ruleListPick,
//                rss.ruleListClose: as named. rss.rulesBack: view.leaveRules()
//                (after rssRuleLeave if the draft is dirty).
//   commitInput(purpose, text), cancelInput(purpose), inputEdited(purpose,
//                text)  this area's INSERTs (rssRuleName, rssRuleRename,
//                rssRuleField): end with commands.endInput, or keep the
//                INSERT open with qbt's sentence (client.note +
//                commands.stayInInsert), as RssPane's.
//   acceptPicker(), dropPicker()  the picker's Enter (apply to the draft)
//                and Esc (discard).
//   togglePicker() -> true while a multi picker (the feeds) is open: Space
//                toggles its row here; false otherwise (5b0's host hook).
//
// Caches (Task 3): the last `qbt rss rules` answer (autoDownload and the
// rules, each with fields and raw), the draft (the rule's name, the
// snapshot of its fields, enabled included, and of torrentParams.use_auto_tmm
// when the fields were entered, the changes, a generation), and the last
// preview per rule with its generation.
Item {
  id: rules
  objectName: "rssRulesView"

  property var service: null
  property var client: null
  property var commands: null
  property var view: null
  property bool narrow: false
  property bool open: false

  // ---- the caches (the header) ------------------------------------------------------------
  // `qbt rss rules`' last answer ({autoDownload, rules: [{name, enabled,
  // fields, raw}]}) and whether one arrived.
  property var rulesData: null
  property bool loaded: false
  // The rule list's cursor, kept on its rule by name across reads.
  property string listName: ""
  property int listIndex: 0
  // The narrow rule list's own cursor (Enter picks it).
  property int overlayIndex: 0
  // The fields' cursor (a RULE_FIELDS index).
  property int fieldIndex: 0
  // The draft: {name, snapshot (the rule's fields, enabled included, plus
  // useAutoTmm), values (the fields as edited)}, or null outside the
  // fields. It outlives closeRules (a forced leave); windowClosed drops it.
  property var draft: null
  // name -> {groups (RssRules.previewGroups) | failed, gen}: the last
  // preview per rule. gens: name -> the rule's generation (a write sent
  // for it bumps it; an older preview answer is dropped).
  property var previews: ({})
  property var gens: ({})
  property string busyPreview: ""
  property string queuedPreview: ""
  // name -> the field key being saved ("" for the whole draft): a write
  // for that rule is running.
  property var writes: ({})
  // After a read: enter this rule's fields (Enter's turn-off), put the
  // cursor on this rule (a, n), check a kept draft ("open", "reload").
  property string pendingEnter: ""
  property string pendingFollow: ""
  property string pendingCheck: ""
  // Bumped on every change the bindings below read through functions.
  property int version: 0

  property bool pickerOpen: false
  readonly property var picker: pickerLoader.item

  readonly property var cmds: ruleCmds
  readonly property var ruleList: rulesData && Array.isArray(rulesData.rules) ? rulesData.rules : []
  readonly property string pane: view ? String(view.column) : ""
  readonly property bool inFields: draft !== null && (pane === "rssRuleFields" || pane === "rssRulePreview" || pane === "rssRuleList")
  // The rule the fields and the preview show: the draft's in the fields,
  // else the one under the list cursor.
  readonly property var shownRule: {
    void rules.version
    if (rules.inFields) return rules.ruleByName(rules.draft.name)
    return rules.ruleList[rules.listIndex] || null
  }
  readonly property var shownFields: rules.inFields ? rules.draft.values : (rules.shownRule ? rules.shownRule.fields : null)
  readonly property var fieldRowsList: {
    void rules.version
    return rules.shownFields ? Rules.fieldRows(rules.shownFields, rules.view && rules.view.items ? rules.view.items.feeds : []) : []
  }
  readonly property var cursorField: pane === "rssRuleFields" && inFields ? fieldRowsList[fieldIndex] || null : null

  // The contract (the header).
  readonly property var flags: {
    void rules.version
    var r = rules.shownRule
    var f = rules.cursorField
    var busy = rules.inFields && rules.writes[rules.draft.name] !== undefined
    var editable = !!f && (Rules.isInsert(f.kind) || Rules.isPicker(f.kind)) && !busy
    var toggle = !!f && Rules.isToggle(f.kind) && (f.key === "enabled" || !busy)
    return {
      rssRule: rules.inFields ? { name: rules.draft.name, enabled: !!r && r.enabled === true } : (r ? { name: r.name, enabled: r.enabled === true } : null),
      rssField: f ? { key: f.key, kind: f.kind, value: f.value } : null,
      rssFieldEditable: editable,
      rssFieldToggle: toggle,
      rssRuleDirty: rules.dirty(),
      rssAutoDl: rules.autoDl()
    }
  }

  readonly property int padX: Style.space(12)
  readonly property int rowHeight: Style.space(28)
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  visible: open
  z: 2

  // Widened: the narrow-only panes (the rule list overlay, the preview
  // full width) give the keys back to the fields.
  onNarrowChanged: if (!narrow && open && (pane === "rssRuleList" || pane === "rssRulePreview")) setColumn(draft !== null ? "rssRuleFields" : "rssRules")

  // ---- RssPane's calls ------------------------------------------------------------------

  function openRules(item) {
    ruleCmds.reset(false)
    pendingEnter = ""
    pendingFollow = ""
    // A draft kept across a forced leave is there again, still dirty.
    if (draft !== null) setColumn("rssRuleFields")
    ruleCmds.readRules("open")
  }

  function closeRules() {
    if (pickerOpen) ruleCmds.dropPicker()
    ruleCmds.reset(false)
    // A read landing after this moves nothing (the draft itself is kept).
    pendingEnter = ""
    pendingFollow = ""
    pendingCheck = ""
  }

  function windowClosed() {
    if (pickerOpen) ruleCmds.dropPicker()
    ruleCmds.reset(true)
    draft = null
    writes = ({})
    busyPreview = ""
    queuedPreview = ""
    pendingEnter = ""
    pendingFollow = ""
    pendingCheck = ""
    version++
    dropConfirm()
  }

  // A rules CONFIRM still up goes: mode back to NORMAL, no pending.
  function dropConfirm() {
    var c = client
    var kinds = ["rssRuleRemove", "rssRuleOn", "rssRuleEditOff", "rssRuleLeave", "rssRuleDiscard"]
    if (!c || c.mode !== "CONFIRM" || !c.confirm || kinds.indexOf(c.confirm.kind) === -1) return
    var st = ({})
    for (var k in c.regState) st[k] = c.regState[k]
    st.mode = "NORMAL"
    st.pending = null
    c.regState = st
    c.confirm = null
  }

  function run(commandId, args, ev) { ruleCmds.run(commandId, args) }
  function commitInput(purpose, text) { ruleCmds.commitInput(purpose, text) }
  function cancelInput(purpose) { ruleCmds.cancelInput(purpose) }
  function inputEdited(purpose, text) {}
  function acceptPicker() { ruleCmds.acceptPicker() }
  function dropPicker() { ruleCmds.dropPicker() }
  function togglePicker() { return ruleCmds.togglePicker() }

  // ---- state -------------------------------------------------------------------------------

  function column() { return pane }
  function setColumn(c) { if (view) view.column = c }
  function rules() { return ruleList }
  function autoDl() { return !!rulesData && rulesData.autoDownload === true }

  function ruleByName(name) {
    var list = ruleList
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].name === name) return list[i]
    return null
  }

  function cursorRule() { return ruleList[listIndex] || null }
  function overlayRule() { return ruleList[overlayIndex] || null }

  // The draft has changes not saved: only while auto-download is on (OV2).
  // Off, a commit's save is already on its way, and nothing waits for p.
  function dirty() { return draft !== null && autoDl() && Rules.isDirty(draft.values, draft.snapshot) }
  function writing(name) { return writes[name] !== undefined }

  function markWriting(name, key, on) {
    var n = ({})
    for (var k in writes) if (k !== name) n[k] = writes[k]
    if (on) n[name] = key
    writes = n
    version++
  }

  function copyFields(f) {
    var out = ({})
    for (var k in f || ({})) out[k] = Array.isArray(f[k]) ? f[k].slice() : f[k]
    return out
  }

  function applyRules(data) {
    rulesData = data
    loaded = true
    var list = ruleList
    var want = pendingFollow !== "" ? pendingFollow : listName
    pendingFollow = ""
    var at = -1
    for (var i = 0; i < list.length; i++) if (list[i].name === want) { at = i; break }
    if (at === -1) at = Math.max(0, Math.min(listIndex, list.length - 1))
    listIndex = list.length > 0 ? at : 0
    listName = list.length > 0 ? list[listIndex].name : ""
    var check = pendingCheck
    pendingCheck = ""
    if (draft !== null && check !== "") checkDraft(check === "reload")
    if (pendingEnter !== "" && open) {
      var name = pendingEnter
      pendingEnter = ""
      var r = ruleByName(name)
      if (r && r.enabled !== true) enterFields(name)
    }
    version++
  }

  // A kept draft whose rule went, or was turned on elsewhere, leaves the
  // fields (an enabled rule is edited only after confirmEditOff again);
  // r also takes a fresh snapshot of it.
  function checkDraft(resnap) {
    var r = ruleByName(draft.name)
    if (!r || r.enabled === true) {
      if (!r) ruleCmds.note(Rules.SENTENCES.ruleGone, "urgent")
      else ruleCmds.note(Rules.sentence("ruleChanged", { name: Rules.displayName(draft.name) }), "muted")
      draft = null
      if (inFieldsPane()) setColumn("rssRules")
      return
    }
    if (resnap) draft = newDraft(r)
  }

  function inFieldsPane() { return pane === "rssRuleFields" || pane === "rssRulePreview" || pane === "rssRuleList" }

  function newDraft(r) {
    var tp = r.raw && typeof r.raw === "object" && r.raw.torrentParams && typeof r.raw.torrentParams === "object" ? r.raw.torrentParams : null
    var uat = tp && typeof tp.use_auto_tmm === "boolean" ? tp.use_auto_tmm : null
    var snap = copyFields(r.fields)
    snap.useAutoTmm = uat
    var values = copyFields(r.fields)
    return { name: r.name, snapshot: snap, values: values }
  }

  // The rule's fields take the keys: a new draft (or the one kept for it),
  // and its preview.
  function enterFields(name) {
    var r = ruleByName(name)
    if (!r) return
    if (draft === null || draft.name !== name) {
      draft = newDraft(r)
      fieldIndex = 0
    }
    for (var i = 0; i < ruleList.length; i++) if (ruleList[i].name === name) { listIndex = i; break }
    listName = name
    setColumn("rssRuleFields")
    version++
    requestPreview(name)
  }

  // h (no dirty draft by now): back to the rule list, on this rule.
  function leaveFields() {
    draft = null
    version++
    setColumn("rssRules")
  }

  function openRuleList() {
    overlayIndex = listIndex
    setColumn("rssRuleList")
  }

  function setValue(key, value) {
    var v = copyFields(draft.values)
    v[key] = Array.isArray(value) ? value.slice() : value
    draft = { name: draft.name, snapshot: draft.snapshot, values: v }
    version++
  }

  // D, r, or a refused save with auto-download off: the draft is its
  // snapshot again.
  function discardDraft() {
    if (draft === null) return
    var v = copyFields(draft.snapshot)
    delete v.useAutoTmm
    draft = { name: draft.name, snapshot: draft.snapshot, values: v }
    version++
  }

  // A save ended ok: the snapshot is the written values (useAutoTmm and
  // enabled stay).
  function saved(name, changes) {
    if (draft === null || draft.name !== name) return
    var s = copyFields(draft.snapshot)
    for (var k in changes) s[k] = Array.isArray(changes[k]) ? changes[k].slice() : changes[k]
    draft = { name: name, snapshot: s, values: draft.values }
    version++
  }

  // The rule is on: its fields end (an enabled rule is edited only after
  // confirmEditOff), the cursor on it.
  function turnedOn(name) {
    if (draft === null || draft.name !== name) return
    draft = null
    version++
    if (inFieldsPane()) setColumn("rssRules")
  }

  function move(delta) {
    if (pane === "rssRuleFields") {
      fieldIndex = Math.max(0, Math.min(Rules.RULE_FIELDS.length - 1, fieldIndex + delta))
      return
    }
    var n = ruleList.length
    if (n === 0) return
    if (pane === "rssRuleList") { overlayIndex = Math.max(0, Math.min(n - 1, overlayIndex + delta)); return }
    listIndex = Math.max(0, Math.min(n - 1, listIndex + delta))
    listName = ruleList[listIndex].name
    version++
    ruleRows.positionViewAtIndex(listIndex, ListView.Contain)
  }

  // ---- the preview (D12) -----------------------------------------------------------------

  function genOf(name) { return gens[name] || 0 }

  function bumpGen(name) {
    var n = ({})
    for (var k in gens) n[k] = gens[k]
    n[name] = (gens[name] || 0) + 1
    gens = n
  }

  function requestPreview(name) {
    if (busyPreview !== "") {
      queuedPreview = name
      version++
      return
    }
    startPreview(name)
  }

  function startPreview(name) {
    if (!service || typeof service.rssRulePreview !== "function") return
    var gen = genOf(name)
    busyPreview = name
    version++
    var t = service.rssRulePreview(name, function(ok, error, data) { rules.previewAnswered(name, gen, ok, data) })
    if (!(Number(t) > 0)) { busyPreview = ""; version++ }
  }

  function previewAnswered(name, gen, ok, data) {
    busyPreview = ""
    storePreview(name, gen, ok ? { groups: Rules.previewGroups(data) } : { failed: true })
    if (queuedPreview !== "") {
      var q = queuedPreview
      queuedPreview = ""
      startPreview(q)
    }
    version++
  }

  // A preview answer, kept only if no write for its rule was sent since.
  function storePreview(name, gen, entry) {
    if (genOf(name) !== gen) return
    var n = ({})
    for (var k in previews) n[k] = previews[k]
    n[name] = entry
    previews = n
    version++
  }

  function forgetPreview(name) {
    var n = ({})
    for (var k in previews) if (k !== name) n[k] = previews[k]
    previews = n
    version++
  }

  readonly property var previewState: {
    void rules.version
    var r = rules.shownRule
    if (!r) return { updating: false, failed: false, lines: [] }
    var e = rules.previews[r.name]
    return {
      updating: rules.busyPreview === r.name || rules.queuedPreview === r.name,
      failed: !!e && e.failed === true,
      lines: e && e.groups ? e.groups.lines : []
    }
  }

  RssRuleCommands {
    id: ruleCmds
    area: rules
  }

  // ---- drawing -------------------------------------------------------------------------------

  Rectangle {
    visible: !(rules.view && rules.view.downShown)
    anchors.fill: parent
    color: Color.background

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }
  }

  // The footer: the key hints (View.rssFooterKeys) and, while
  // auto-download is on, the muted note under them (View.rssRulesFooterNote).
  component RulesFooter: Item {
    id: footerItem
    property string pane: ""
    property var flags: ({})
    readonly property var keys: View.rssFooterKeys(pane, flags)
    readonly property string noteText: View.rssRulesFooterNote(pane, flags)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: keyFlow.implicitHeight + (noteLine.visible ? noteLine.implicitHeight + Style.space(4) : 0) + Style.space(12)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: 1
      color: Util.alpha(Color.foreground, Style.normalBorderAlpha)
    }

    Flow {
      id: keyFlow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.topMargin: Style.space(6)
      spacing: Style.space(12)
      Repeater {
        model: footerItem.keys
        delegate: Row {
          id: hint
          required property var modelData
          Text {
            text: hint.modelData.key
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: Color.foreground
          }
          Text {
            text: " " + hint.modelData.label
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: Color.muted
          }
        }
      }
    }
    Text {
      id: noteLine
      objectName: "rssRulesFooterNote"
      visible: footerItem.noteText !== ""
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: keyFlow.bottom
      anchors.topMargin: Style.space(4)
      leftPadding: Style.space(12)
      rightPadding: Style.space(12)
      wrapMode: Text.Wrap
      text: footerItem.noteText
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: Color.muted
    }
  }

  // ---- the rule list --------------------------------------------------------------------------

  ClientPane {
    id: listPane
    objectName: "rssRuleListPane"
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: rules.narrow ? parent.width : Style.space(220)
    title: Rules.WINDOW.rulesTitle
    titleRight: rules.ruleList.length > 0 ? String(rules.ruleList.length) : ""
    focusedPane: rules.pane === "rssRules"
    swappedOut: !!rules.view && rules.view.downShown || (rules.narrow && rules.pane !== "rssRules")

    ListView {
      id: ruleRows
      objectName: "rssRuleRows"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: listFooter.top
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: rules.ruleList
      highlightFollowsCurrentItem: false
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      delegate: Item {
        id: ruleRow
        required property var modelData
        required property int index
        readonly property bool current: index === rules.listIndex
        width: ruleRows.width
        height: rules.rowHeight

        Rectangle {
          visible: ruleRow.current
          anchors.fill: parent
          color: Style.selectedAccentFill
        }
        Rectangle {
          visible: ruleRow.current && listPane.focusedPane
          width: Style.space(3)
          height: parent.height
          color: Color.accent
        }
        Text {
          anchors.left: parent.left
          anchors.leftMargin: rules.padX
          anchors.right: ruleState.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: Rules.displayName(ruleRow.modelData.name)
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.body
          color: ruleRow.current ? Color.accent : Color.foreground
        }
        Text {
          id: ruleState
          anchors.right: parent.right
          anchors.rightMargin: rules.padX
          anchors.verticalCenter: parent.verticalCenter
          text: ruleRow.modelData.enabled === true ? Rules.WINDOW.stateOn : Rules.WINDOW.stateOff
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: ruleRow.modelData.enabled === true ? Color.accent : Color.muted
        }
      }
    }

    Text {
      objectName: "rssRulesEmpty"
      visible: rules.loaded && rules.ruleList.length === 0
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(24)
      leftPadding: Style.space(16)
      rightPadding: Style.space(16)
      wrapMode: Text.Wrap
      text: Rules.WINDOW.rulesEmpty
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.subtitle
      color: Color.muted
    }

    RulesFooter {
      id: listFooter
      pane: "rssRules"
      flags: rules.view ? rules.view.flags : ({})
    }
  }

  // ---- the fields -----------------------------------------------------------------------------

  ClientPane {
    id: fieldsPane
    objectName: "rssRuleFieldsPane"
    anchors.left: rules.narrow ? parent.left : listPane.right
    anchors.right: rules.narrow ? parent.right : previewPane.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    title: rules.shownRule ? Rules.displayName(rules.shownRule.name) : ""
    focusedPane: rules.pane === "rssRuleFields" || rules.pane === "rssRuleList"
    swappedOut: !!rules.view && rules.view.downShown || (rules.narrow && rules.pane !== "rssRuleFields" && rules.pane !== "rssRuleList")

    // Narrow: the rule list is this chip (Tab opens the list).
    Rectangle {
      id: ruleChip
      objectName: "rssRuleChip"
      visible: rules.narrow
      anchors.left: parent.left
      anchors.leftMargin: rules.padX
      anchors.top: parent.top
      anchors.topMargin: Style.space(4)
      width: visible ? chipText.implicitWidth + Style.space(14) : 0
      height: visible ? Style.space(22) : 0
      color: "transparent"
      border.width: 1
      border.color: rules.lineColor
      Text {
        id: chipText
        anchors.centerIn: parent
        text: (rules.shownRule ? Rules.displayName(rules.shownRule.name) : Rules.WINDOW.rulesTitle) + " ▾"
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.accent
      }
      MouseArea {
        anchors.fill: parent
        onClicked: rules.openRuleList()
      }
    }

    Flickable {
      id: fieldFlick
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: ruleChip.bottom
      anchors.topMargin: rules.narrow ? Style.space(4) : 0
      anchors.bottom: helpPanel.top
      clip: true
      contentWidth: width
      contentHeight: fieldColumn.height + Style.space(8)
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: fieldColumn
        width: fieldFlick.width
        Repeater {
          model: rules.fieldRowsList
          delegate: SettingRow {
            id: fieldRow
            required property var modelData
            required property int index
            width: fieldColumn.width
            height: rules.rowHeight
            row: ({ label: fieldRow.modelData.label, text: fieldRow.modelData.text, muted: fieldRow.modelData.muted, typeTag: "" })
            current: rules.inFields && fieldRow.index === rules.fieldIndex
            focused: fieldsPane.focusedPane
            compact: rules.narrow
            saving: rules.inFields && rules.writes[rules.draft.name] === fieldRow.modelData.key
            onClicked: if (rules.inFields) { rules.setColumn("rssRuleFields"); rules.fieldIndex = fieldRow.index }
          }
        }
      }
    }

    // The cursor field's help: its label, then the case file's help line.
    Item {
      id: helpPanel
      readonly property var shown: rules.cursorField
      visible: shown !== null
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: fieldsFooter.top
      height: shown === null ? 0 : helpText.implicitHeight + Style.space(18)

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: rules.lineColor
      }
      Text {
        id: helpText
        objectName: "rssRuleHelp"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Style.space(9)
        leftPadding: rules.padX
        rightPadding: rules.padX
        wrapMode: Text.Wrap
        maximumLineCount: rules.narrow ? 6 : 3
        elide: Text.ElideRight
        text: helpPanel.shown ? helpPanel.shown.label + " · " + helpPanel.shown.help : ""
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.muted
      }
    }

    RulesFooter {
      id: fieldsFooter
      pane: "rssRuleFields"
      flags: rules.view ? rules.view.flags : ({})
    }
  }

  // ---- the preview --------------------------------------------------------------------------

  ClientPane {
    id: previewPane
    objectName: "rssRulePreviewPane"
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: rules.narrow ? parent.width : Style.space(320)
    title: Rules.WINDOW.previewTitle
    focusedPane: rules.pane === "rssRulePreview"
    rightLine: false
    swappedOut: !!rules.view && rules.view.downShown || (rules.narrow && rules.pane !== "rssRulePreview")

    Flickable {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: previewFooter.visible ? previewFooter.top : parent.bottom
      clip: true
      contentWidth: width
      contentHeight: previewColumn.height + Style.space(16)
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: previewColumn
        x: rules.padX
        width: parent.width - 2 * rules.padX
        topPadding: Style.space(8)
        spacing: Style.space(4)

        Text {
          objectName: "rssPreviewStatus"
          visible: text !== ""
          width: parent.width
          wrapMode: Text.Wrap
          text: rules.previewState.updating ? Rules.WINDOW.previewUpdating : (rules.previewState.failed ? Rules.WINDOW.previewFailed : "")
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: rules.previewState.failed && !rules.previewState.updating ? Color.urgent : Color.muted
        }
        Repeater {
          model: rules.previewState.failed ? [] : rules.previewState.lines
          delegate: Text {
            id: previewLine
            required property var modelData
            width: previewColumn.width
            leftPadding: previewLine.modelData.head ? 0 : Style.space(10)
            topPadding: previewLine.modelData.head ? Style.space(6) : 0
            elide: Text.ElideRight
            text: previewLine.modelData.text
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: previewLine.modelData.head ? Style.font.body : Style.font.bodySmall
            font.bold: previewLine.modelData.head && !previewLine.modelData.muted
            color: previewLine.modelData.muted ? Color.muted : Color.foreground
          }
        }
      }
    }

    RulesFooter {
      id: previewFooter
      visible: rules.narrow
      pane: "rssRulePreview"
      flags: rules.view ? rules.view.flags : ({})
    }
  }

  // ---- the narrow rule list (Tab): ListOverlay without its field ------------------------------

  function overlayRows() {
    var out = []
    for (var i = 0; i < ruleList.length; i++) {
      var r = ruleList[i]
      out.push({ kind: "rule", title: Rules.displayName(r.name), indices: [], enabled: true, reason: "", keys: r.enabled === true ? Rules.WINDOW.stateOn : Rules.WINDOW.stateOff })
    }
    return out
  }

  function footerText(keys) {
    var parts = []
    for (var i = 0; i < keys.length; i++) parts.push(keys[i].key + " " + keys[i].label)
    return parts.join(" · ")
  }

  Loader {
    id: overlayLoader
    anchors.fill: parent
    active: rules.open && rules.pane === "rssRuleList"
    sourceComponent: Component {
      ListOverlay {
        id: ruleOverlay
        objectName: "rssRuleOverlay"
        keyMode: "PICKER"
        prompt: Rules.WINDOW.rulesTitle
        rows: rules.overlayRows()
        cursor: rules.overlayIndex
        footerHint: rules.footerText(View.rssFooterKeys("rssRuleList", rules.view ? rules.view.flags : ({})))
        onDismissed: rules.run("rss.ruleListClose", ({}))
        onActivated: function(row) { rules.overlayIndex = ruleOverlay.cursor; rules.run("rss.ruleListPick", ({})) }
        Component.onCompleted: {
          ruleOverlay.inputField.visible = false
          ruleOverlay.inputField.enabled = false
        }
      }
    }
  }

  // ---- a field's picker (feeds: multi; category, addStopped: single) ---------------------------
  // Loaded only while open, so the window's palette stays the first
  // ListOverlay a search of the tree finds.

  Loader {
    id: pickerLoader
    anchors.fill: parent
    active: rules.open && rules.pickerOpen
    sourceComponent: Component {
      ListOverlay {
        objectName: "rssRulePicker"
        keyMode: "PICKER"
        multi: !!ruleCmds.pickerCap && ruleCmds.pickerCap.kind === "feeds"
        placeholder: " type to find"
        footerHint: multi ? "↑↓ move · Space tick · Enter apply · Esc cancel" : "↑↓ / Ctrl-n Ctrl-p move · Enter choose · Esc cancel"
        onKeyForwarded: function(event) { if (rules.client) rules.client.handleKey(event) }
        onActivated: function(row) { ruleCmds.pickerClicked(row) }
        onDismissed: if (rules.commands) rules.commands.closePicker()
        onQueryChanged: ruleCmds.refreshPicker(false)
      }
    }
  }
}
