pragma ComponentBehavior: Bound

import QtQuick
import "CommandRegistry.js" as Registry
import "ClientView.js" as View
import "SearchView.js" as SearchView
import "Model.js" as Model

// The Search view's commands (slice 5a, Task 3): what SearchPane.run hands
// here, the two INSERTs (`/` and the overlay's `i`), and the ends of the
// `qbt search*` runs (Service.searchFinished) and the sidecar's replies
// (Service.searchReply). SearchPane holds the state and draws it; this
// holds the behaviour, the way SettingsCommands sits beside SettingsPane.
//
// - `/` (OV8: an enabled plugin, the registry's searchPluginOn) opens the
//   query INSERT; Enter checks the pattern rule (a refusal stays in INSERT
//   with the case file's reason), then `qbt search start` with the category
//   (Ruling FB: one an enabled plugin still supports, else "all"). qbt
//   deletes the job search.id names first, so a new `/` replaces the old
//   job; starts run one at a time (Service's jobs lane) and only the latest
//   start's id is kept.
// - The window owns the offset (OV7): a reply applies only when its id is
//   the job's and its offset is the rows held (the raw rows received, not
//   the merged rows shown); any other offset re-sends the watch at the rows
//   held. The final reply (Ruling FB) is applied, re-sorts, and then the
//   job is deleted (OV14). "gone" says the case file's sentence.
// - Esc stops a running search first (qbt search stop; an Esc before the
//   start has its id stops it once the id arrives), then leaves.
// - Enter raises A1's CONFIRM (or "Already in your library.", or the
//   addLink refusal); its `y` runs `qbt search add <link> [<plugin>]`. The
//   done note: "Sent …" for via "plugin" and an https .torrent; "Added …"
//   for a magnet only once its hash is in the library.
// - d: the pageLink rule, then D3's CONFIRM; `y` opens it detached (OV10).
// - The plugins overlay: Space on/off, x uninstall (after a CONFIRM), i
//   install (the pluginUrl rule in INSERT, then D4's CONFIRM), U update all.
//   One plugin change at a time (pluginsBusy: Service's
//   searchPluginChange, so a reopened window still waits); SearchPane
//   reads the list again when it ends.
// Every sentence is SearchView's (the case file's); qbt's own sentences
// show as they are.
QtObject {
  id: cmds

  required property var view

  // ticket -> {kind, ...}: this window's qbt search runs still going.
  property var tickets: ({})
  // Magnets added (via "add") whose hash isn't in the library yet:
  // "Added <name>." shows once it is, and "Couldn't confirm <name> was
  // added." once view.addConfirmMs passes (FD).
  property AddAwaiter awaiter: AddAwaiter {
    libSet: cmds.view.libSet
    confirmMs: cmds.view.addConfirmMs
    onConfirmed: (name) => cmds.note(SearchView.addedText(name), "muted")
    onUnconfirmed: (name) => cmds.note(SearchView.fill(SearchView.WINDOW.addUnconfirmed, { name: name }), "urgent")
  }

  readonly property var client: view.client
  readonly property var service: view.service

  function svcHas(name) {
    return !!service && typeof service[name] === "function"
  }

  function remember(ticket, entry) {
    if (!(Number(ticket) > 0)) return false
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

  function note(text, tone) {
    if (client) client.note(text, tone || "muted")
  }

  function fail(text) {
    if (client) client.messages = View.msgError(client.messages, text, [])
  }

  // Raises one of Search's CONFIRMs (View.SEARCH_ACCEPT's kinds): `y`
  // comes back as commandId with args plus confirmed.
  function raise(commandId, kind, args, line, detail) {
    var c = client
    var r = Registry.raiseConfirm(c.regState, commandId, kind, args)
    var cf = ({})
    for (var f in r.confirm) cf[f] = r.confirm[f]
    cf.line = line
    if (detail) cf.detail = detail
    c.regState = r.state
    c.confirmHashes = []
    c.confirm = cf
  }

  // ---- plugins ---------------------------------------------------------------------

  function loadPlugins() {
    if (!svcHas("searchPluginList")) return
    var t = service.searchPluginList()
    if (remember(t, { kind: "list" })) view.pluginsReading = true
  }

  function pluginWrite(kind, ticket, name) {
    if (!remember(ticket, { kind: kind, name: name })) return
    view.localBusy = kind
  }

  function togglePlugin(p) {
    if (!p || view.pluginsBusy) return
    var ok = SearchView.checkPluginName(p.name)
    if (!ok.ok) { fail(ok.message); return }
    if (svcHas("searchPluginEnable")) pluginWrite("toggle", service.searchPluginEnable(p.name, p.enabled !== true), p.name)
  }

  function uninstallPlugin(p, confirmed) {
    if (!p || view.pluginsBusy) return
    var ok = SearchView.checkPluginName(p.name)
    if (!ok.ok) { fail(ok.message); return }
    if (confirmed !== true) {
      raise("plugin.uninstall", "pluginUninstall", { plugin: p }, SearchView.uninstallConfirm(p.name))
      return
    }
    if (svcHas("searchPluginUninstall")) pluginWrite("uninstall", service.searchPluginUninstall(p.name), p.name)
  }

  function updatePlugins() {
    // U waits while any plugin change (an update included) runs (OV4).
    if (view.pluginsBusy) return
    if (svcHas("searchPluginUpdate")) pluginWrite("update", service.searchPluginUpdate(), "")
  }

  // i's INSERT, Enter: the pluginUrl rule; a refusal stays in INSERT.
  function commitInstall(text) {
    var r = SearchView.checkPluginUrl(text)
    if (!r.ok) {
      note(r.message, "urgent")
      view.commands.stayInInsert()
      return
    }
    view.commands.endInput()
    var q = SearchView.installConfirm(r.normalised, r.host)
    raise("plugin.install", "pluginInstall", { url: text, name: r.normalised }, q.line, q.detail)
  }

  function installPlugin(args) {
    if (view.pluginsBusy) return
    // Checked again on the frozen text: `y` never runs an unchecked URL.
    var r = SearchView.checkPluginUrl(args.url)
    if (!r.ok) { fail(r.message); return }
    if (svcHas("searchPluginInstall")) pluginWrite("install", service.searchPluginInstall(args.url), r.normalised)
  }

  // ---- a search ----------------------------------------------------------------------

  function commitQuery(text) {
    var r = SearchView.checkPattern(text)
    if (!r.ok) {
      note(r.message, "urgent")
      view.commands.stayInInsert()
      return
    }
    view.commands.endInput()
    if (view.enabledPlugins === 0) {
      // OV8, as the registry says it for `/`.
      var why = view.plugins > 0 ? Registry.SEARCH_REASONS.allOff : Registry.SEARCH_REASONS.noPlugins
      note(why.charAt(0).toUpperCase() + why.slice(1) + ".", "muted")
      return
    }
    startSearch(SearchView.qtTrim(String(text)))
  }

  // Enter on a Recent row (Ruling FF): the same checks as `/`.
  function rerun(query) {
    var r = SearchView.checkPattern(query)
    if (!r.ok) { note(r.message, "urgent"); return }
    if (view.enabledPlugins === 0) {
      var why = view.plugins > 0 ? Registry.SEARCH_REASONS.allOff : Registry.SEARCH_REASONS.noPlugins
      note(why.charAt(0).toUpperCase() + why.slice(1) + ".", "muted")
      return
    }
    startSearch(SearchView.qtTrim(String(query)))
  }

  function startSearch(query) {
    if (!svcHas("searchStart")) return
    var v = view
    var cat = SearchView.effectiveCategory(v.category, v.pluginList)
    v.category = cat
    // The old job: its watch goes; qbt search start deletes it.
    if (v.jobId > 0 && svcHas("searchUnwatch")) service.searchUnwatch()
    v.jobId = 0
    v.resetResults()
    v.query = query
    v.setRecent(SearchView.recentPush(v.recent, query))
    v.stopWanted = false
    v.jobState = "starting"
    var t = service.searchStart(query, cat)
    v.startTicket = Number(t) || 0
    if (!remember(t, { kind: "start" })) {
      v.jobState = "failed"
      note(View.BUSY_NOTE, "muted")
    }
  }

  function started(ticket, ok, error, data) {
    var v = view
    // Only the latest `/` counts; an older start's job is deleted by the
    // newer start (qbt's search.id), or by Service once the window closed
    // (it abandons the starts still going).
    if (Number(ticket) !== v.startTicket) return
    v.startTicket = 0
    if (!ok) {
      v.jobState = "failed"
      fail(error)
      return
    }
    var id = data && typeof data === "object" ? data.id : undefined
    if (typeof id !== "number" || !SearchView.checkSearchId(String(id)).ok) {
      v.jobState = "failed"
      fail(SearchView.SENTENCES.unreadable)
      return
    }
    v.jobId = id
    if (v.stopWanted) {
      v.stopWanted = false
      // Esc came before the id: stop it now (or delete it, sidecar down).
      if (!v.sidecarUp) { dropJob(); return }
      if (svcHas("searchStop")) remember(service.searchStop(id), { kind: "stop" })
    } else {
      v.jobState = "running"
    }
    if (svcHas("searchWatch")) service.searchWatch(id, 0)
  }

  // Esc with a search running: stop it (the view stays; the next Esc leaves).
  function stopSearch() {
    var v = view
    if (v.jobState !== "starting" && v.jobState !== "running") return false
    v.jobState = "stopped"
    if (v.jobId > 0) {
      // No sidecar, no final reply to wait for: the job goes now (review 4).
      if (!v.sidecarUp) dropJob()
      else if (svcHas("searchStop")) remember(service.searchStop(v.jobId), { kind: "stop" })
    } else {
      v.stopWanted = true
    }
    return true
  }

  // The job goes without a final read: unwatched and deleted.
  function dropJob() {
    var v = view
    var id = v.jobId
    v.jobId = 0
    if (id <= 0) return
    if (svcHas("searchUnwatch")) service.searchUnwatch()
    if (svcHas("searchDelete")) service.searchDelete(id)
  }

  // The sidecar's reply (OV7, Ruling FB).
  function reply(r) {
    var v = view
    var act = SearchView.replyAction(r, v.jobId, v.held)
    if (act === "stale") return
    if (act === "gone") {
      v.jobId = 0
      if (v.jobState === "starting" || v.jobState === "running") v.jobState = "gone"
      fail(SearchView.WINDOW.gone)
      return
    }
    if (act === "resend") {
      if (svcHas("searchWatch")) service.searchWatch(v.jobId, v.held)
      return
    }
    var rows = r.rows.slice(0, Math.max(0, SearchView.ROW_CAP - v.held))
    v.total = Number(r.total) || 0
    v.capped = r.capped === true
    if (rows.length > 0) v.appendRaw(rows)
    if (!SearchView.isFinal(r)) return
    var id = v.jobId
    v.jobId = 0
    if (v.jobState === "starting" || v.jobState === "running") v.jobState = "done"
    v.rebuild()
    if (svcHas("searchUnwatch")) service.searchUnwatch()
    if (svcHas("searchDelete")) service.searchDelete(id)
  }

  // A restarted sidecar: the watch again, from the rows held.
  function watchLost() {
    var v = view
    if (v.jobId > 0 && svcHas("searchWatch")) service.searchWatch(v.jobId, v.held)
  }

  // The window closes: the job goes (A5/OV14). A start still going is
  // Service's: windowOpen going false abandons it, and Service deletes its
  // job once the id arrives (this window is rebuilt, never reopened).
  function closeJob() {
    var v = view
    if (v.jobState === "starting" || v.jobState === "running") v.jobState = "stopped"
    v.startTicket = 0
    v.stopWanted = false
    if (v.jobId > 0) {
      if (svcHas("searchUnwatch")) service.searchUnwatch()
      if (svcHas("searchDelete")) service.searchDelete(v.jobId)
    }
    v.jobId = 0
  }

  // ---- a result ----------------------------------------------------------------------

  function sizeText(size) {
    return typeof size === "number" ? Model.formatSize(size) : SearchView.EMPTY
  }

  function addResult(result, confirmed) {
    if (!result) return
    var plan = SearchView.addPlan(result, sizeText(result.size), view.libSet)
    if (plan.kind === "library") { note(plan.note, "muted"); return }
    if (plan.kind === "refuse") { note(plan.note, "urgent"); return }
    if (confirmed !== true) {
      raise("search.add", "searchAdd", { result: result }, plan.line)
      return
    }
    if (!svcHas("searchAdd")) return
    var t = service.searchAdd(plan.link, plan.plugin)
    if (!remember(t, { kind: "add", name: result.name, link: plan.link, via: plan.via, v1: result.v1, v2: result.v2 })) note(View.BUSY_NOTE, "muted")
  }

  function added(e, data) {
    var via = data && typeof data === "object" && (data.via === "add" || data.via === "plugin") ? data.via : e.via
    var text = SearchView.addedNote(via, e.link, e.name)
    if (text !== null) { note(text, "muted"); return }
    awaiter.add(e.v1, e.v2, e.name)
  }

  // SearchPane.syncLibrary calls this on every library refresh.
  function checkAwaiting() { awaiter.check() }

  function copyLink(result) {
    if (!result) return
    var link = String(result.fileUrl || "")
    if (!SearchView.copyableLink(link)) {
      note(SearchView.MSG.noLink, "urgent")
      return
    }
    if (!svcHas("copyText")) return
    client.track(service.copyText(link, client.opts([])), "copyText", [])
  }

  function openPage(result, confirmed) {
    if (!result) return
    var r = SearchView.checkPageLink(result.descrLink)
    if (!r.ok) { note(r.message, "urgent"); return }
    if (confirmed !== true) {
      raise("search.openPage", "searchOpenPage", { result: result }, SearchView.openConfirm(r.host))
      return
    }
    if (svcHas("openUrl") && !service.openUrl(result.descrLink)) note(View.BUSY_NOTE, "muted")
  }

  // ---- the ends of qbt's runs ----------------------------------------------------------

  function finished(ticket, ok, error, data) {
    var e = take(ticket)
    if (!e) return
    var v = view
    if (e.kind === "start") {
      started(ticket, ok, error, data)
      return
    }
    if (e.kind === "list") {
      v.pluginsReading = false
      if (!ok) { if (v.tableState === "rows" || v.tableState === "empty") fail(error); return }
      if (!Array.isArray(data)) { fail(SearchView.SENTENCES.unreadable); return }
      v.setPlugins(data)
      return
    }
    if (e.kind === "add") {
      if (!ok) { fail(error); return }
      added(e, data)
      return
    }
    if (e.kind === "stop") {
      if (!ok) fail(error)
      return
    }
    // A plugin change: the list is read again whatever happened (SearchPane,
    // when pluginsBusy goes false).
    if (e.kind === "install" || e.kind === "uninstall" || e.kind === "toggle" || e.kind === "update") {
      if (!ok) fail(error)
      v.localBusy = ""
    }
  }

  property Connections serviceLink: Connections {
    target: cmds.service
    ignoreUnknownSignals: true
    function onSearchFinished(ticket, ok, error, data) { cmds.finished(ticket, ok, error, data) }
    function onSearchReply(reply) { cmds.reply(reply) }
    function onSearchWatchLost() { cmds.watchLost() }
  }
}
