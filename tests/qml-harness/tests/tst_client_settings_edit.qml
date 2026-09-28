import QtQuick
import QtTest
import qs.Commons
import "../../.."
import "../../../SettingsSchema.js" as Schema
import "../../../SettingsView.js" as SettingsView

// Editing settings (slice 4a, Task 6): Space toggles, Enter opens the
// status-line INSERT or the choice picker, every write path asks
// SettingsView.confirmFor first (one CONFIRM, `y` writes what was captured,
// `n`/Esc sends nothing), the row shows "saving…" while qbt pref-set runs,
// and the window re-reads after a success or shows qbt's reason after a
// failure. The service stub records setPref and keeps each readPrefs
// callback so a test answers it; finish() plays Service's actionFinished.
TestCase {
  id: tc
  name: "ClientSettingsEdit"
  when: windowShown

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function tt(hash, name) {
    return { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1,
      category: "", tags: [], tracker: "", savePath: "/dl" }
  }

  // One or more keys of every editor type, the locked and multi-line rows,
  // and two keys the schema doesn't know (Other).
  function prefs(extra) {
    var p = {
      dl_limit: 0, up_limit: 1048576,
      scheduler_enabled: true, schedule_from_hour: 8, schedule_from_min: 0, schedule_to_hour: 20, schedule_to_min: 0,
      listen_port: 51413, upnp: false, max_connec: 500,
      dht: true, pex: true, lsd: true, encryption: 0, anonymous_mode: false,
      torrent_content_layout: "Original", save_path: "/srv/dl", announce_ip: "",
      excluded_file_names_enabled: true, excluded_file_names: "*.exe\n*.scr",
      web_ui_address: "127.0.0.1", web_ui_port: 8080, current_network_interface: "wg0-mullvad",
      disk_io_type: 0,
      zz_new_flag: false, zz_new_count: 7
    }
    for (var k in extra || {}) p[k] = extra[k]
    return p
  }

  Component {
    id: serviceComp
    QtObject {
      property bool installed: true
      property bool daemon: true
      property string lockHolder: "none"
      property bool api: true
      property bool altSpeed: false
      property real dlSpeed: 0
      property real upSpeed: 0
      property string vpnIface: ""
      property string bindIface: ""
      property bool vpnUnbound: false
      property string sidecarState: "up"
      property bool sidecarDown: false
      property string lastError: ""
      property var torrents: []
      property var categories: []
      property var tags: []
      property var filesByHash: ({})
      property var filesStatusByHash: ({})
      property var inspectByKey: ({})
      property var magnetPending: []
      property var magnetInbox: []
      property var magnetPendingHashes: []
      property var viewState: ({ filter: { group: "status", value: "All" }, sort: "added", desc: true, cursorHash: "", pane: "table" })
      property bool windowOpen: false
      property var calls: []
      property var prefsCbs: []
      property int seq: 0
      signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
      signal clipboardRead(string text)
      function rec(name, args) { calls.push({ name: name, args: args }); seq++; return seq }
      function saveViewState(s) { viewState = s }
      function refresh() { rec("refresh", []) }
      function refreshSlow() { rec("refreshSlow", []) }
      function watch(h, t) { calls.push({ name: "watch", args: [h, t] }) }
      function readClipboard() { rec("readClipboard", []) }
      function filesFor(h) { return [] }
      function loadFiles(h, o) { calls.push({ name: "loadFiles", args: [h, o] }) }
      function loadMagnetSnapshot() { rec("loadMagnetSnapshot", []) }
      // busy: Service refuses a window call with 0 while its queue is full.
      property bool busy: false
      function setPref(k, v, o) { if (busy) { calls.push({ name: "setPref", args: [k, v, o] }); return 0 } return rec("setPref", [k, v, o]) }
      function readPrefs(cb) { rec("readPrefs", []); prefsCbs.push(cb) }
      function answer(result) { var cb = prefsCbs.shift(); cb(result) }
    }
  }

  Component {
    id: shellComp
    QtObject {
      property var target: null
      function hide(id) { if (target) target.close() }
    }
  }

  Component { id: clientComp; Client {} }

  function key(c, text, code, mods) {
    c.handleKey({ key: code !== undefined ? code : text.toUpperCase().charCodeAt(0), text: text, modifiers: mods || 0 })
  }
  function esc(o) { key(o.c, "", 0x01000000) }
  function enter(o) { key(o.c, "", 0x01000004) }
  function space(o) { key(o.c, " ", 0x20) }
  function comma(o) { key(o.c, ",", 0x2c) }
  function findWith(obj, fn) {
    if (!obj) return null
    if (typeof obj[fn] === "function") return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findWith(kids[i], fn); if (r) return r }
    return null
  }
  function findName(obj, name) {
    if (!obj) return null
    if (obj.objectName === name) return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findName(kids[i], name); if (r) return r }
    return null
  }
  function visibleNamed(obj, name, out) {
    out = out || []
    if (!obj || obj.visible === false) return out
    if (obj.objectName === name) out.push(obj)
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) visibleNamed(kids[i], name, out)
    return out
  }
  function winOf(c) { for (var i = 0; i < c.data.length; i++) if (c.data[i] && c.data[i].contentItem) return c.data[i]; return null }
  function content(o) { return winOf(o.c).contentItem }
  function line(o) { return findWith(content(o), "setInput") }
  function view(o) { return findName(content(o), "settingsView") }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  function writes(o) { return calls(o.svc, "setPref").map(function(x) { return [x.args[0], x.args[1]] }) }
  function rowItem(o, key) {
    wait(30)
    var rows = visibleNamed(content(o), "settingsRow")
    for (var i = 0; i < rows.length; i++) if (rows[i].row.key === key) return rows[i]
    return null
  }
  function valueText(o, key) { var r = rowItem(o, key); return r ? findName(r, "settingsValue").text : null }
  function status(o) { return o.c.statusMessage.text }

  function make(p) {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    svc.torrents = [tt(hh("a"), "alpha")]
    var o = { c: c, svc: svc }
    comma(o)
    svc.answer({ ok: true, prefs: p || prefs() })
    return o
  }
  // The settings cursor on `key` (its section, then its row), as j/k/l would.
  function focusKey(o, k) {
    var v = view(o)
    var row = SettingsView.rowFor(k, v.prefs)
    verify(row !== null, k + " shows")
    for (var i = 0; i < v.sectionList.length; i++) if (v.sectionList[i].name === row.section) v.sectionIndex = i
    compare(v.sectionName, row.section)
    var rows = v.shownRows
    var at = -1
    for (var j = 0; j < rows.length; j++) if (rows[j].key === k) at = j
    verify(at >= 0, k + " in its section")
    var cur = {}
    for (var s in v.cursors) cur[s] = v.cursors[s]
    cur[row.section] = at
    v.cursors = cur
    v.column = "settingsKeys"
    compare(v.cursorRow.key, k)
  }
  function finish(o, ok, err) { o.svc.actionFinished(o.svc.seq, ok, err || "", "window", []) }
  function typeAndEnter(o, text) { line(o).setInput(text); enter(o) }
  function picker(o) { return view(o).picker }
  function choose(o, value) {
    var p = picker(o)
    var at = -1
    for (var i = 0; i < p.rows.length; i++) if (String(p.rows[i].value) === String(value)) at = i
    verify(at >= 0, "the picker lists " + value)
    p.cursor = at
    enter(o)
  }

  // ---- toggles ------------------------------------------------------------------

  function test_space_flips_an_on_off_setting_and_writes_it_at_once() {
    var o = make()
    focusKey(o, "zz_new_flag")
    space(o)
    compare(writes(o), [["zz_new_flag", "true"]], "an Other boolean toggles by its JSON type")
    compare(calls(o.svc, "setPref")[0].args[2].origin, "window")
    compare(o.c.mode, "NORMAL")
  }

  function test_the_row_shows_saving_until_the_re_read_arrives_then_the_done_note() {
    var o = make()
    focusKey(o, "upnp")
    compare(valueText(o, "upnp"), "off")
    key(o.c, "", 0x20)
    // upnp on confirms; answer it.
    compare(o.c.mode, "CONFIRM")
    key(o.c, "y")
    compare(writes(o), [["upnp", "true"]])
    compare(valueText(o, "upnp"), "saving…")
    compare(findName(rowItem(o, "upnp"), "settingsValue").color, Color.muted)
    var reads = calls(o.svc, "readPrefs").length
    finish(o, true)
    compare(calls(o.svc, "readPrefs").length, reads + 1, "a success re-reads")
    verify(view(o).prefs !== null, "the values stay up while re-reading (reload(true))")
    compare(status(o), "UPnP / NAT-PMP port forwarding on · u undoes")
    compare(valueText(o, "upnp"), "saving…", "still saving until qBittorrent's value is back")
    o.svc.answer({ ok: true, prefs: prefs({ upnp: true }) })
    compare(valueText(o, "upnp"), "on")
  }

  function test_a_second_space_while_saving_sends_nothing() {
    var o = make()
    focusKey(o, "zz_new_flag")
    space(o)
    space(o)
    compare(writes(o).length, 1, "the row is saving: its captured value would be stale")
    finish(o, true)
    o.svc.answer({ ok: true, prefs: prefs({ zz_new_flag: true }) })
    space(o)
    compare(writes(o), [["zz_new_flag", "true"], ["zz_new_flag", "false"]])
  }

  // ---- inputs -------------------------------------------------------------------

  function test_an_int_with_a_sentinel_parses_in_insert_and_a_bad_value_stays() {
    var o = make()
    focusKey(o, "max_connec")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "settingEdit")
    compare(line(o).inputValue(), "500", "prefilled with the current value")
    compare(line(o).inputPrompt.prompt, "Global connections")
    typeAndEnter(o, "0")
    compare(o.c.mode, "INSERT", "out of range stays in INSERT")
    compare(status(o), "Use a number from 1 to 2147483647, or -1 for unlimited.")
    compare(writes(o).length, 0)
    typeAndEnter(o, "-1")
    compare(o.c.mode, "NORMAL")
    compare(writes(o), [["max_connec", "-1"]])
    finish(o, true)
    compare(status(o), "Global connections set to unlimited · u undoes")
  }

  function test_a_speed_rounds_to_whole_kib_before_it_is_written() {
    var o = make()
    focusKey(o, "dl_limit")
    enter(o)
    compare(line(o).inputValue(), "u")
    typeAndEnter(o, "1.5K")
    compare(writes(o), [["dl_limit", "2048"]])
    finish(o, true)
    compare(status(o), "Download limit set to 2 KiB/s · u undoes")
  }

  function test_a_time_composite_writes_hh_mm_under_its_own_key() {
    var o = make()
    focusKey(o, "schedule_from")
    enter(o)
    compare(line(o).inputValue(), "08:00")
    typeAndEnter(o, "25:00")
    compare(o.c.mode, "INSERT")
    compare(status(o), SettingsView.TIME_ERROR)
    typeAndEnter(o, "09:15")
    compare(writes(o), [["schedule_from", "09:15"]], "qbt splits it into hour and minute")
    finish(o, true)
    compare(status(o), "From set to 09:15 · u undoes")
  }

  function test_a_path_takes_a_tilde_path_as_typed() {
    var o = make()
    focusKey(o, "save_path")
    enter(o)
    typeAndEnter(o, "downloads")
    compare(status(o), SettingsView.PATH_ERROR)
    typeAndEnter(o, "~/dl & more")
    compare(writes(o), [["save_path", "~/dl & more"]], "qbt expands ~/")
  }

  function test_text_is_taken_exactly_as_typed() {
    // Ruling DV: announce_ip is no longer a good example here, since qbt
    // (and now the window) refuses it with surrounding whitespace.
    // app_instance_name has no such rule, so it stays a plain "as typed" case.
    var o = make(prefs({ app_instance_name: "" }))
    focusKey(o, "app_instance_name")
    enter(o)
    compare(line(o).inputValue(), "")
    typeAndEnter(o, " padded ")
    compare(writes(o), [["app_instance_name", " padded "]], "never trimmed by the window")
    finish(o, true)
    compare(status(o), "Instance name set to  padded  · u undoes")
  }

  function test_an_other_number_edits_by_its_json_type() {
    var o = make()
    focusKey(o, "zz_new_count")
    enter(o)
    compare(line(o).inputValue(), "7")
    typeAndEnter(o, "1.5")
    compare(status(o), SettingsView.WHOLE_NUMBER_ERROR)
    typeAndEnter(o, "9")
    compare(writes(o), [["zz_new_count", "9"]])
    finish(o, true)
    compare(status(o), "zz_new_count set to 9 · u undoes")
  }

  function test_an_unchanged_value_sends_nothing() {
    var o = make()
    focusKey(o, "listen_port")
    enter(o)
    typeAndEnter(o, "51413")
    compare(o.c.mode, "NORMAL")
    compare(writes(o).length, 0)
    compare(o.c.confirm, null, "and asks nothing")
    focusKey(o, "encryption")
    enter(o)
    choose(o, 0)
    compare(writes(o).length, 0)
  }

  function test_esc_in_the_field_sends_nothing() {
    var o = make()
    focusKey(o, "listen_port")
    enter(o)
    line(o).setInput("6881")
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.inputPurpose, "")
    compare(writes(o).length, 0)
    verify(view(o).open)
  }

  // ---- pickers ------------------------------------------------------------------

  function test_a_choice_int_opens_the_picker_with_the_current_value_marked() {
    var o = make()
    focusKey(o, "disk_io_type")
    enter(o)
    compare(o.c.mode, "PICKER")
    var p = picker(o)
    verify(p.visible)
    compare(p.rows.length, 4)
    compare(p.rows[p.cursor].value, 0, "the cursor starts on the current value")
    compare(p.rows[0].keys, "current")
    compare(p.rows[1].keys, "")
    choose(o, 1)
    compare(o.c.mode, "NORMAL")
    verify(!picker(o), "the picker is gone")
    compare(writes(o), [["disk_io_type", "1"]])
    finish(o, true)
    compare(status(o), "Disk I/O type set to Memory-mapped files" + SettingsView.RESTART_NOTE + " · u undoes")
  }

  function test_a_choice_string_goes_through_the_picker_and_esc_cancels_it() {
    var o = make()
    focusKey(o, "torrent_content_layout")
    enter(o)
    compare(o.c.mode, "PICKER")
    esc(o)
    compare(o.c.mode, "NORMAL")
    verify(!picker(o))
    compare(writes(o).length, 0)
    enter(o)
    picker(o).setQuery("sub")
    wait(30)
    compare(picker(o).rows.map(function(r) { return r.value }), ["Subfolder", "NoSubfolder"], "typing filters the choices")
    choose(o, "Subfolder")
    compare(writes(o), [["torrent_content_layout", "Subfolder"]])
  }

  // ---- confirms, driven from the schema --------------------------------------------

  // For each schema key with a confirm, the values that raise it and a
  // from/prefs that makes the row editable (its dependsOn met).
  function confirmCases() {
    var out = []
    for (var k in Schema.SCHEMA) {
      var e = Schema.SCHEMA[k]
      if (!e.confirm) continue
      var tos = e.confirm.values ? e.confirm.values.slice() : [e.type === "int" ? 51414 : (e.choices ? e.choices[1].value : "notify-send %N")]
      for (var i = 0; i < tos.length; i++) {
        var to = tos[i]
        var from
        if (e.type === "bool") from = !to
        else if (e.choices) { for (var c = 0; c < e.choices.length; c++) if (String(e.choices[c].value) !== String(to)) { from = e.choices[c].value; break } }
        else if (e.type === "int") from = 51413
        else from = ""
        var extra = {}
        extra[k] = from
        var dep = e.dependsOn
        while (dep) {
          extra[dep.key] = Array.isArray(dep.value) ? dep.value[0] : dep.value
          dep = Schema.SCHEMA[dep.key] ? Schema.SCHEMA[dep.key].dependsOn : null
        }
        out.push({ key: k, entry: e, from: from, to: to, prefs: extra })
      }
    }
    return out
  }

  // Space, a picker choice or typed text: whatever makes `to` for this key.
  function propose(o, cs) {
    var ed = SettingsView.editorFor(cs.key, view(o).prefs)
    verify(ed.kind !== "none", cs.key + " is editable here (" + ed.why + "), so n proves the confirm, not a dead row")
    if (ed.kind === "toggle") { space(o); return }
    enter(o)
    if (ed.kind === "picker") { choose(o, cs.to); return }
    typeAndEnter(o, String(cs.to))
  }

  function test_every_confirm_key_asks_first_and_y_writes() {
    var cases = confirmCases()
    verify(cases.length >= 18, "every confirm key and value: " + cases.length)
    for (var i = 0; i < cases.length; i++) {
      var cs = cases[i]
      var o = make(prefs(cs.prefs))
      focusKey(o, cs.key)
      propose(o, cs)
      compare(o.c.mode, "CONFIRM", cs.key + " " + cs.to)
      compare(writes(o).length, 0, cs.key + ": nothing before y")
      var want = SettingsView.confirmFor(cs.key, cs.from, cs.to)
      verify(want !== "", cs.key)
      compare(o.c.confirm.detail, want, cs.key)
      var q = o.c.confirm.line
      verify(q.indexOf(cs.entry.label) >= 0, cs.key + " names its setting: " + q)
      key(o.c, "y")
      compare(o.c.mode, "NORMAL", cs.key)
      compare(writes(o), [[cs.key, String(cs.to)]], cs.key)
    }
  }

  function test_every_confirm_key_with_n_or_esc_sends_nothing() {
    var cases = confirmCases()
    for (var i = 0; i < cases.length; i++) {
      for (var how = 0; how < 2; how++) {
        var cs = cases[i]
        var o = make(prefs(cs.prefs))
        focusKey(o, cs.key)
        propose(o, cs)
        compare(o.c.mode, "CONFIRM", cs.key)
        if (how === 0) key(o.c, "n"); else esc(o)
        compare(o.c.mode, "NORMAL", cs.key)
        compare(o.c.confirm, null, cs.key)
        compare(writes(o).length, 0, cs.key)
        verify(view(o).open, cs.key + ": still in Settings")
      }
    }
  }

  function test_a_non_confirm_value_of_a_confirm_key_writes_directly() {
    var o = make()
    focusKey(o, "encryption")
    enter(o)
    choose(o, 2)
    compare(o.c.mode, "NORMAL")
    compare(writes(o), [["encryption", "2"]], "Disable isn't on the list")
    o = make(prefs({ dht: false }))
    focusKey(o, "dht")
    space(o)
    compare(writes(o), [["dht", "true"]], "turning DHT back on doesn't ask")
  }

  function test_max_ratio_act_names_file_deletion_for_remove_with_files() {
    var o = make(prefs({ max_ratio_act: 0 }))
    focusKey(o, "max_ratio_act")
    enter(o)
    choose(o, 3)
    compare(o.c.confirm.detail, "Torrents that reach their share limit will be removed with their downloaded files.")
    compare(o.c.statusMessage !== undefined, true)
  }

  function test_moving_the_cursor_under_the_confirm_still_writes_the_captured_key() {
    var o = make()
    focusKey(o, "dht")
    space(o)
    compare(o.c.mode, "CONFIRM")
    // A click on another row moves the cursor without a key.
    rowItem(o, "pex").clicked()
    compare(view(o).cursorRow.key, "pex")
    // And a re-read that changes the value under it.
    view(o).reload(true)
    o.svc.answer({ ok: true, prefs: prefs({ dht: true, pex: false }) })
    key(o.c, "y")
    compare(writes(o), [["dht", "false"]], "the key and value captured at Space")
  }

  function test_settings_write_without_its_confirm_writes_nothing() {
    var o = make()
    focusKey(o, "dht")
    o.c.run("settings.write", { key: "dht", label: "DHT", value: false }, null, [])
    o.c.run("settings.write", { key: "dht", label: "DHT", value: false, confirmed: "yes" }, null, [])
    compare(writes(o).length, 0, "only the CONFIRM's y (confirmed: true) writes")
  }

  function test_the_confirm_line_shows_the_question_and_the_consequence() {
    var o = make()
    focusKey(o, "dht")
    space(o)
    wait(30)
    var sl = findWith(content(o), "focusInput")
    compare(sl.confirmParts.lead, "Turn DHT off? ")
    compare(sl.confirmParts.tail, "Magnets without trackers will stop finding peers.")
    compare(sl.confirmParts.accept, "turn off")
  }

  // ---- failures ---------------------------------------------------------------------

  function test_an_ignored_write_keeps_the_value_and_shows_qbts_sentence() {
    var o = make()
    focusKey(o, "announce_ip")
    enter(o)
    typeAndEnter(o, "10.0.0.1")
    compare(valueText(o, "announce_ip"), "saving…")
    var reads = calls(o.svc, "readPrefs").length
    finish(o, false, "qBittorrent ignored IP reported to trackers\n")
    compare(status(o), "qBittorrent ignored IP reported to trackers")
    compare(o.c.statusMessage.tone, "urgent")
    compare(valueText(o, "announce_ip"), "empty", "the row keeps its value")
    compare(calls(o.svc, "readPrefs").length, reads, "no re-read after a failure")
  }

  function test_a_couldnt_confirm_failure_shows_as_it_is() {
    var o = make()
    focusKey(o, "zz_new_flag")
    space(o)
    finish(o, false, "Couldn't confirm zz_new_flag (HTTP 409)")
    compare(status(o), "Couldn't confirm zz_new_flag (HTTP 409)")
    compare(valueText(o, "zz_new_flag"), "off")
  }

  function test_any_other_failure_names_the_setting() {
    var o = make()
    focusKey(o, "zz_new_flag")
    space(o)
    finish(o, false, "qBittorrent refused it (HTTP 409)")
    compare(status(o), "Setting zz_new_flag failed: HTTP 409")
  }

  function test_another_windows_ticket_is_not_ours() {
    var o = make()
    focusKey(o, "zz_new_flag")
    space(o)
    var reads = calls(o.svc, "readPrefs").length
    o.svc.actionFinished(o.svc.seq + 5, true, "", "window", [])
    compare(calls(o.svc, "readPrefs").length, reads)
    compare(valueText(o, "zz_new_flag"), "saving…")
  }

  function test_a_busy_service_marks_nothing_saving() {
    var o = make()
    o.svc.busy = true
    focusKey(o, "zz_new_flag")
    space(o)
    compare(status(o), "Busy, try again.")
    compare(valueText(o, "zz_new_flag"), "off")
  }

  // ---- rows that don't edit -----------------------------------------------------------

  function test_a_locked_row_does_nothing_on_space_or_enter() {
    var o = make()
    focusKey(o, "web_ui_port")
    space(o)
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.inputPurpose, "")
    compare(writes(o).length, 0)
    compare(status(o), "", "no note: the help line says why")
    verify(findName(content(o), "settingsHelp").text.indexOf("OmaqBT") >= 0)
  }

  // test_a_multiline_row_does_nothing moved to tst_client_settings_lists.qml
  // as test_enter_on_a_list_row_opens_its_lines_and_esc_goes_back (slice 4b
  // lifts Ruling DH: Enter opens the list editor).

  function test_a_dimmed_row_and_a_loading_view_do_nothing() {
    var o = make(prefs({ scheduler_enabled: false }))
    focusKey(o, "schedule_from")
    enter(o)
    compare(o.c.mode, "NORMAL")
    view(o).reload(false)
    compare(view(o).prefs, null)
    space(o)
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(writes(o).length, 0)
  }

  function test_space_on_an_input_row_and_enter_on_a_toggle_do_nothing() {
    var o = make()
    focusKey(o, "listen_port")
    space(o)
    compare(o.c.mode, "NORMAL")
    focusKey(o, "zz_new_flag")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(writes(o).length, 0)
  }

  // ---- keys, hints and the window ---------------------------------------------------------

  function test_question_mark_lists_space_and_enter_on_the_settings_list() {
    var o = make()
    focusKey(o, "dht")
    key(o.c, "?", 0x3f, 0x02000000)
    verify(o.c.helpOpen)
    wait(30)
    var texts = []
    ;(function walk(obj) {
      if (!obj || obj.visible === false) return
      if (typeof obj.text === "string" && obj.font !== undefined) texts.push(obj.text)
      for (var i = 0; i < (obj.children || []).length; i++) walk(obj.children[i])
    })(content(o))
    verify(texts.indexOf("Toggle the setting") >= 0, texts.join("|"))
    verify(texts.indexOf("Edit the setting") >= 0)
  }

  function test_the_footer_and_hints_name_the_cursor_rows_editor() {
    var o = make()
    focusKey(o, "dht")
    wait(30)
    var sl = findWith(content(o), "focusInput")
    verify(sl.hints.some(function(h) { return h.key === "Space" && h.label === "toggle" }))
    focusKey(o, "listen_port")
    wait(30)
    verify(sl.hints.some(function(h) { return h.key === "Enter" && h.label === "edit" }))
    focusKey(o, "web_ui_port")
    wait(30)
    verify(!sl.hints.some(function(h) { return h.key === "Enter" || h.key === "Space" }))
  }

  function test_closing_the_window_mid_edit_or_mid_confirm_leaves_nothing_behind() {
    var o = make()
    focusKey(o, "listen_port")
    enter(o)
    compare(o.c.mode, "INSERT")
    o.c.close()
    o.c.open("")
    compare(o.c.mode, "NORMAL")
    compare(o.c.inputPurpose, "")
    compare(o.c.keyPane, "table")

    o = make()
    focusKey(o, "dht")
    space(o)
    compare(o.c.mode, "CONFIRM")
    o.c.close()
    o.c.open("")
    compare(o.c.mode, "NORMAL", "a settings question never outlives Settings")
    compare(o.c.confirm, null)
    compare(o.c.regState.pending, null, "so no later y can resolve it")
    compare(writes(o).length, 0)

    o = make()
    focusKey(o, "encryption")
    enter(o)
    compare(o.c.mode, "PICKER")
    o.c.close()
    o.c.open("")
    compare(o.c.mode, "NORMAL")
    verify(!picker(o))
  }

  function test_a_failed_read_with_qbittorrent_up_names_itself_in_the_status_line() {
    var o = make()
    esc(o)
    comma(o)
    o.svc.answer({ ok: false, error: "qBittorrent refused it (HTTP 403)" })
    compare(status(o), "Couldn't read settings: HTTP 403")
    o.svc.api = false
    wait(30)
    esc(o)
    comma(o)
    o.svc.answer({ ok: false, error: "qBittorrent refused it (couldn't reach qBittorrent)" })
    compare(status(o), "", "the api-down screen says it already")
  }

  // ---- final fix wave (Ruling DU) ------------------------------------------------------

  function test_a_write_still_running_keeps_saving_across_a_close_and_reopen() {
    var o = make()
    focusKey(o, "zz_new_flag")
    space(o)
    compare(writes(o), [["zz_new_flag", "true"]])
    var ticket = o.svc.seq
    compare(valueText(o, "zz_new_flag"), "saving…")
    o.c.close()
    o.c.open("")
    comma(o)
    o.svc.answer({ ok: true, prefs: prefs() })
    focusKey(o, "zz_new_flag")
    compare(valueText(o, "zz_new_flag"), "saving…", "the write is still running")
    space(o)
    compare(writes(o).length, 1, "and Space does nothing on it")
    o.svc.actionFinished(ticket, true, "", "window", [])
    o.svc.answer({ ok: true, prefs: prefs({ zz_new_flag: true }) })
    compare(valueText(o, "zz_new_flag"), "on")
  }

  function test_qbittorrent_going_down_while_settings_shows_switches_to_the_down_screen() {
    var o = make()
    focusKey(o, "dht")
    compare(view(o).failed, false)
    o.svc.api = false
    compare(o.c.tableState, "api")
    compare(view(o).failed, true, "the down screen shows")
    compare(status(o), "", "the down screen says it; no read note")
    space(o)
    compare(writes(o).length, 0, "nothing is editable on the down screen")
    var reads = calls(o.svc, "readPrefs").length
    o.svc.api = true
    compare(calls(o.svc, "readPrefs").length, reads + 1, "qBittorrent is back: read again")
    o.svc.answer({ ok: true, prefs: prefs() })
    compare(view(o).failed, false)

    // A read in flight when it goes down can't land over the down screen.
    esc(o)
    comma(o)
    o.svc.daemon = false
    compare(view(o).failed, true)
    o.svc.answer({ ok: true, prefs: prefs() })
    compare(view(o).failed, true, "the late answer is dropped")
  }

  // Rulings DQ, DR, DS: the window refuses first, with qbt's sentences.
  function test_an_unclean_path_a_bad_ip_and_a_short_username_stay_in_insert() {
    var o = make(prefs({ web_ui_username: "admin" }))
    var cases = [["save_path", "/srv//dl", "Use a clean path without //, /./ or /../."],
      ["announce_ip", "not.an.ip", "Use an IPv4 or IPv6 address, or leave it empty."],
      ["web_ui_username", "a:b", "Use at least 3 characters and no colon."]]
    for (var i = 0; i < cases.length; i++) {
      focusKey(o, cases[i][0])
      enter(o)
      typeAndEnter(o, cases[i][1])
      compare(o.c.mode, "INSERT", cases[i][0] + " stays in INSERT")
      compare(status(o), cases[i][2])
      esc(o)
      compare(o.c.mode, "NORMAL")
    }
    compare(writes(o).length, 0)
  }

  function choiceItem(o, value) {
    return (function find(obj) {
      if (!obj) return null
      if (obj.isRow === true && obj.modelData && String(obj.modelData.value) === String(value)) return obj
      var kids = obj.children || []
      for (var i = 0; i < kids.length; i++) { var r = find(kids[i]); if (r) return r }
      return null
    })(picker(o))
  }

  function test_a_click_on_a_choice_sets_it() {
    var o = make()
    focusKey(o, "disk_io_type")
    enter(o)
    compare(o.c.mode, "PICKER")
    wait(30)
    var item = choiceItem(o, 1)
    verify(item !== null, "the choice is on screen")
    mouseClick(item)
    compare(o.c.mode, "NORMAL")
    verify(!picker(o), "the picker is gone")
    compare(writes(o), [["disk_io_type", "1"]])
  }

  function test_a_click_on_the_scrim_dismisses_the_picker_and_sends_nothing() {
    var o = make()
    focusKey(o, "disk_io_type")
    enter(o)
    compare(o.c.mode, "PICKER")
    wait(30)
    mouseClick(picker(o), 4, 4)
    compare(o.c.mode, "NORMAL")
    verify(!picker(o))
    compare(view(o).pickerOpen, false)
    compare(writes(o).length, 0)
  }

  function sectionsFooter(o) {
    return (function find(obj) {
      if (!obj) return null
      if (Array.isArray(obj.keys) && obj.keys.length > 1 && obj.keys[0].key === "j/k" && obj.keys[1].label === "keys") return obj
      var kids = obj.children || []
      for (var i = 0; i < kids.length; i++) { var r = find(kids[i]); if (r) return r }
      return null
    })(view(o))
  }

  function test_the_sections_footer_says_esc_clears_a_live_search() {
    var o = make()
    var f = sectionsFooter(o)
    verify(f !== null)
    compare(f.keys[f.keys.length - 1].label, "back")
    view(o).setSearch("port")
    compare(f.keys[f.keys.length - 1].label, "clear search")
    view(o).clearSearch()
    compare(f.keys[f.keys.length - 1].label, "back")
  }

  function test_the_palette_disables_settings_while_settings_is_open() {
    var o = make()
    key(o.c, ":", 0x3a)
    compare(o.c.mode, "COMMAND")
    var pal = (function find(obj) {
      if (!obj) return null
      if (obj.totalCount !== undefined && obj.evalState !== undefined) return obj
      var kids = obj.children || []
      for (var i = 0; i < kids.length; i++) { var r = find(kids[i]); if (r) return r }
      return null
    })(content(o))
    var row = pal.rows.filter(function(r) { return r.id === "settings.open" })[0]
    compare(row.enabled, false)
    compare(row.reason, "already open")
    pal.setQuery("Settings")
    pal.cursor = pal.rows.map(function(r) { return r.id }).indexOf("settings.open")
    enter(o)
    compare(o.c.mode, "COMMAND", "Enter on it keeps the palette open")
    compare(status(o), "Settings: already open.")
    verify(view(o).open, "Settings stays open")
  }

  // ---- end to end, through the real Service ---------------------------------------------

  Component { id: realServiceComp; Service {} }

  function procWhere(svc, pred) {
    for (var i = 0; i < svc.data.length; i++) { var o = svc.data[i]; if (o && pred(o)) return o }
    return null
  }
  function actionProc(svc, verb) {
    return procWhere(svc, function(o) { return o.running === true && o.command && o.command.length > 1 && o.command[1] === verb })
  }
  function endProc(p, code, out, err) {
    p.stdout.text = out || ""
    p.stderr.text = err || ""
    p.running = false
    p.exited(code, 0)
  }
  function wireOf(svc) {
    var sc = procWhere(svc, function(o) { return o.attemptOpen !== undefined })
    for (var i = 0; i < sc.data.length; i++) if (sc.data[i] && sc.data[i].stdinEnabled !== undefined) return sc.data[i]
    return null
  }
  function wireCmds(wire, name) {
    return wire.writes.filter(function(w) { try { return JSON.parse(w).cmd === name } catch (e) { return false } })
  }

  // Space -> qbt pref-set (argv) -> success -> Service's refresh-slow to the
  // sidecar (T3's finishAction) and the window's own re-read (qbt prefs).
  function test_a_write_through_the_real_service_runs_pref_set_then_refresh_slow_and_a_re_read() {
    var svc = createTemporaryObject(realServiceComp, tc)
    endProc(actionProc(svc, "magnet-install-handler"), 0, "", "")
    var wire = wireOf(svc)
    svc.handleSidecarLine(JSON.stringify({ type: "status", torrents: [{ hash: hh("a"), name: "alpha" }] }))
    compare(svc.sidecarState, "up")
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    var o = { c: c, svc: svc }
    comma(o)
    var read = actionProc(svc, "prefs") || procWhere(svc, function(p) { return p.cb !== undefined && p.running === true })
    verify(read !== null, "qbt prefs runs")
    endProc(read, 0, JSON.stringify(prefs()), "")
    verify(view(o).prefs !== null)
    focusKey(o, "dht")
    space(o)
    compare(c.mode, "CONFIRM")
    key(c, "y")
    var w = actionProc(svc, "pref-set")
    verify(w !== null, "qbt pref-set runs")
    compare(w.command.slice(1), ["pref-set", "dht", "--", "false"])
    var before = wireCmds(wire, "refresh-slow").length
    endProc(w, 0, "{\"ok\":true}", "")
    compare(wireCmds(wire, "refresh-slow").length, before + 1, "the sidecar re-reads its cached preferences")
    var again = procWhere(svc, function(p) { return p.cb !== undefined && p.running === true })
    verify(again !== null, "the window re-reads preferences")
    compare(valueText(o, "dht"), "saving…")
    endProc(again, 0, JSON.stringify(prefs({ dht: false })), "")
    compare(valueText(o, "dht"), "off")
    compare(status(o), "DHT off · u undoes")
  }
}
