pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons


// The RSS rules area (slice 5b2). Task 1 wrote this placeholder and the
// contract below; Task 3 (the window lane) fills it in, keeping this
// interface, with RssRuleCommands.qml for the behaviour behind each key and
// RssRules.js for the pure rules (RULE_FIELDS, fieldRows, draftDiff,
// previewGroups, confirmLine, sentence) and the copy. RssRules.js pins its
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

  // The contract (the header). Task 1's placeholder: nothing under a cursor.
  readonly property var flags: ({ rssRule: null, rssField: null, rssFieldEditable: false, rssFieldToggle: false, rssRuleDirty: false, rssAutoDl: false })
  readonly property bool pickerOpen: false
  readonly property var picker: null

  visible: open
  z: 2

  // ---- RssPane's calls ------------------------------------------------------------------

  function openRules(item) {
  }

  function closeRules() {
  }

  function windowClosed() {
  }

  function run(commandId, args, ev) {
    // The placeholder never has a draft, so Esc in the list leaves at once.
    if (commandId === "rss.rulesBack" && view) view.leaveRules()
  }

  function commitInput(purpose, text) {
    if (commands) commands.endInput()
  }

  function cancelInput(purpose) {
  }

  function inputEdited(purpose, text) {
  }

  function acceptPicker() {
  }

  function dropPicker() {
  }

  function togglePicker() {
    return false
  }

  // ---- the placeholder: an opaque area over the feeds and articles ---------------------------

  Rectangle {
    anchors.fill: parent
    color: Color.background

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }
  }

  ClientPane {
    anchors.fill: parent
    title: "Rules"
    focusedPane: rules.open
  }
}
