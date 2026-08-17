const { test } = require("node:test");
const assert = require("node:assert/strict");
const Model = require("../Model.js");

test("classifyState maps downloading family to downloading", () => {
  for (const state of [
    "downloading", "metaDL", "stalledDL", "queuedDL", "forcedDL", "allocating", "checkingDL"
  ]) {
    assert.equal(Model.classifyState(state, 0.2), "downloading", state);
  }
});

test("classifyState maps uploading family to seeding", () => {
  for (const state of ["uploading", "stalledUP", "queuedUP", "forcedUP", "checkingUP"]) {
    assert.equal(Model.classifyState(state, 1), "seeding", state);
  }
});

test("classifyState maps paused/stopped under 100% to paused", () => {
  for (const state of ["pausedDL", "pausedUP", "stoppedDL", "stoppedUP"]) {
    assert.equal(Model.classifyState(state, 0.4), "paused", state);
  }
});

test("classifyState maps paused/stopped at 100% to completed", () => {
  assert.equal(Model.classifyState("stoppedUP", 1), "completed");
  assert.equal(Model.classifyState("pausedDL", 1.0), "completed");
});

test("classifyState maps error family to error", () => {
  assert.equal(Model.classifyState("error", 0), "error");
  assert.equal(Model.classifyState("missingFiles", 0.5), "error");
  assert.equal(Model.classifyState("unknown", 0), "error");
});

test("classifyState maps checkingResumeData and moving to other", () => {
  assert.equal(Model.classifyState("checkingResumeData", 0.5), "other");
  assert.equal(Model.classifyState("moving", 0.9), "other");
});

const sample = [
  { name: "dl", state: "downloading", progress: 0.2 },
  { name: "seed", state: "uploading", progress: 1 },
  { name: "paused", state: "stoppedDL", progress: 0.3 },
  { name: "done", state: "stoppedUP", progress: 1 },
  { name: "err", state: "missingFiles", progress: 0.1 },
  { name: "move", state: "moving", progress: 0.5 }
];

test("filterTorrents active keeps downloading and seeding only", () => {
  const got = Model.filterTorrents(sample, "active").map((t) => t.name);
  assert.deepEqual(got, ["dl", "seed"]);
});

test("filterTorrents paused excludes completed", () => {
  const got = Model.filterTorrents(sample, "paused").map((t) => t.name);
  assert.deepEqual(got, ["paused"]);
});

test("filterTorrents completed is finished and not seeding", () => {
  const got = Model.filterTorrents(sample, "completed").map((t) => t.name);
  assert.deepEqual(got, ["done"]);
});

test("filterTorrents all keeps every row", () => {
  assert.equal(Model.filterTorrents(sample, "all").length, sample.length);
});

test("filterTorrents defaults to active", () => {
  const got = Model.filterTorrents(sample).map((t) => t.name);
  assert.deepEqual(got, ["dl", "seed"]);
});

test("torrentId prefers hash, then infohash_v1, then infohash_v2", () => {
  assert.equal(Model.torrentId({ hash: "aaa", infohash_v1: "bbb" }), "aaa");
  assert.equal(Model.torrentId({ hash: "", infohash_v1: "bbb" }), "bbb");
  assert.equal(Model.torrentId({ infohash_v2: "ccc" }), "ccc");
  assert.equal(Model.torrentId({}), "");
});

test("anyActive is true only when something is downloading or seeding", () => {
  assert.equal(Model.anyActive(sample), true);
  assert.equal(Model.anyActive(Model.filterTorrents(sample, "paused")), false);
});

test("formatSize uses 1024 units", () => {
  assert.equal(Model.formatSize(0), "0 B");
  assert.equal(Model.formatSize(512), "512 B");
  assert.equal(Model.formatSize(1024), "1.0 KiB");
  assert.equal(Model.formatSize(1536), "1.5 KiB");
  assert.equal(Model.formatSize(1048576), "1.0 MiB");
  assert.equal(Model.formatSize(2202009), "2.1 MiB");
});

test("formatRate appends /s", () => {
  assert.equal(Model.formatRate(0), "0 B/s");
  assert.equal(Model.formatRate(143360), "140.0 KiB/s");
});

test("formatEta treats missing or 8640000 as em dash", () => {
  assert.equal(Model.formatEta(-1), "—");
  assert.equal(Model.formatEta(8640000), "—");
  assert.equal(Model.formatEta(45), "45s");
  assert.equal(Model.formatEta(125), "2m");
  assert.equal(Model.formatEta(7200), "2h");
});

test("formatPercent rounds a 0-1 fraction", () => {
  assert.equal(Model.formatPercent(0.42), "42%");
  assert.equal(Model.formatPercent(1), "100%");
});

test("isAddableUrl accepts magnets and http .torrent URLs", () => {
  assert.equal(Model.isAddableUrl("magnet:?xt=urn:btih:abc"), true);
  assert.equal(
    Model.isAddableUrl("https://example.com/debian.torrent"),
    true
  );
  assert.equal(
    Model.isAddableUrl("https://example.com/debian.torrent?token=1"),
    true
  );
  assert.equal(Model.isAddableUrl("https://example.com/debian.iso"), false);
  assert.equal(Model.isAddableUrl("not a url"), false);
  assert.equal(Model.isAddableUrl(""), false);
});

test("plainText strips angle brackets so hero title cannot become rich text", () => {
  assert.equal(
    Model.plainText('<img src="http://evil/x">Ubuntu'),
    'img src="http://evil/x"Ubuntu'
  );
  assert.equal(Model.plainText("<b>100%</b>"), "b100%/b");
  assert.equal(Model.plainText("Plain Torrent Name"), "Plain Torrent Name");
  assert.equal(Model.plainText(null), "");
});

test("priorityLabel and cycle walk Skip Low Normal High", () => {
  assert.equal(Model.priorityLabel(0), "Skip");
  assert.equal(Model.priorityLabel(1), "Low");
  assert.equal(Model.priorityLabel(6), "Normal");
  assert.equal(Model.priorityLabel(7), "High");
  assert.equal(Model.priorityLabel(99), "Low");
  assert.equal(Model.cyclePriority(0), 1);
  assert.equal(Model.cyclePriority(1), 6);
  assert.equal(Model.cyclePriority(6), 7);
  assert.equal(Model.cyclePriority(7), 0);
});

test("parseStatusJson reads helper snapshot and assigns torrentId", () => {
  const status = Model.parseStatusJson(JSON.stringify({
    installed: true,
    daemon: true,
    lockHolder: "nox",
    api: true,
    dlSpeed: 10,
    upSpeed: 2,
    torrents: [
      { hash: "", infohash_v1: "deadbeef", name: "iso", state: "downloading", progress: 0.2, dlSpeed: 1, upSpeed: 0, eta: 10, ratio: 0, size: 100 }
    ]
  }));
  assert.equal(status.ok, true);
  assert.equal(status.installed, true);
  assert.equal(status.torrents[0].hash, "deadbeef");
  assert.equal(status.torrents[0].bucket, "downloading");
});

test("parseStatusJson returns not-ok for garbage", () => {
  const status = Model.parseStatusJson("nope");
  assert.equal(status.ok, false);
  assert.equal(status.installed, false);
  assert.deepEqual(status.torrents, []);
});

test("sanitizeError strips SID cookies and password fields", () => {
  const cleaned = Model.sanitizeError("fail SID=abc+def/12; password=secret leftover");
  assert.equal(/SID=/i.test(cleaned), false);
  assert.equal(/password=secret/i.test(cleaned), false);
  assert.match(cleaned, /fail/);
  assert.match(cleaned, /leftover/);
});

test("nextStatusError keeps a previous install error when still not installed", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({
    installed: false,
    daemon: false,
    lockHolder: "none",
    api: false,
    dlSpeed: 0,
    upSpeed: 0,
    torrents: []
  }));
  assert.equal(
    Model.nextStatusError(parsed, "sudo: a password is required"),
    "sudo: a password is required"
  );
});

test("nextStatusError uses parsed.error when present", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({
    installed: false,
    daemon: false,
    lockHolder: "none",
    api: false,
    dlSpeed: 0,
    upSpeed: 0,
    torrents: [],
    error: "HTTP 403"
  }));
  assert.equal(Model.nextStatusError(parsed, "old"), "HTTP 403");
});

test("nextStatusError clears when the daemon is ready", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({
    installed: true,
    daemon: true,
    lockHolder: "nox",
    api: true,
    dlSpeed: 0,
    upSpeed: 0,
    torrents: []
  }));
  assert.equal(Model.nextStatusError(parsed, "old"), "");
});

test("installCommand uses pkexec when there is no tty", () => {
  assert.deepEqual(Model.installCommand(false), ["pkexec", "omarchy", "pkg", "add", "qbittorrent-nox"]);
});

test("installCommand uses omarchy pkg add on a tty", () => {
  assert.deepEqual(Model.installCommand(true), ["omarchy", "pkg", "add", "qbittorrent-nox"]);
});



test("formatCompactRate rounds into bare K/M/G units", () => {
  assert.equal(Model.formatCompactRate(0), "0K");
  assert.equal(Model.formatCompactRate(143360), "140K");
  assert.equal(Model.formatCompactRate(1258291), "1.2M");
  assert.equal(Model.formatCompactRate(22 * 1048576), "22M");
  assert.equal(Model.formatCompactRate(1.5 * 1073741824), "1.5G");
  assert.equal(Model.formatCompactRate(-5), "0K");
  assert.equal(Model.formatCompactRate("junk"), "0K");
});

test("barSpeedText is empty when idle", () => {
  assert.equal(Model.barSpeedText(1000, 2000, false), "");
});

test("barSpeedText shows compact down and up rates when active", () => {
  assert.equal(Model.barSpeedText(143360, 1258291, true), "↓140K ↑1.2M");
  assert.equal(Model.barSpeedText(0, 0, true), "↓0K ↑0K");
});

const prevPoll = [
  { hash: "a", name: "almost", progress: 0.98 },
  { hash: "b", name: "done-already", progress: 1 },
  { hash: "c", name: "midway", progress: 0.4 }
];

test("newlyCompleted reports torrents that crossed the finish line", () => {
  const next = [
    { hash: "a", name: "almost", progress: 1 },
    { hash: "b", name: "done-already", progress: 1 },
    { hash: "c", name: "midway", progress: 0.6 }
  ];
  assert.deepEqual(Model.newlyCompleted(prevPoll, next), ["almost"]);
});

test("newlyCompleted ignores torrents unseen in the previous poll", () => {
  const next = [{ hash: "new", name: "instant", progress: 1 }];
  assert.deepEqual(Model.newlyCompleted(prevPoll, next), []);
  assert.deepEqual(Model.newlyCompleted([], next), []);
});

test("newlyCompleted does not re-report torrents that stay complete", () => {
  assert.deepEqual(Model.newlyCompleted(prevPoll, prevPoll), []);
});

test("completionText names one finisher and counts many", () => {
  assert.equal(Model.completionText([]), "");
  assert.equal(Model.completionText(["debian.iso"]), "debian.iso finished downloading");
  assert.equal(Model.completionText(["<b>x</b>"]), "bx/b finished downloading");
  assert.equal(Model.completionText(["a", "b", "c"]), "3 torrents finished downloading");
});

test("parseStatusJson carries vpnIface and bindIface", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({
    installed: true,
    daemon: true,
    lockHolder: "nox",
    api: true,
    dlSpeed: 0,
    upSpeed: 0,
    torrents: [],
    vpnIface: "wg0-mullvad",
    bindIface: ""
  }));
  assert.equal(parsed.vpnIface, "wg0-mullvad");
  assert.equal(parsed.bindIface, "");
});

test("parseStatusJson defaults missing iface fields to empty strings", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({ installed: true, daemon: true, api: true, torrents: [] }));
  assert.equal(parsed.vpnIface, "");
  assert.equal(parsed.bindIface, "");
});

test("vpnUnbound warns only when the daemon runs off the VPN while it is up", () => {
  const base = { daemon: true, api: true, vpnIface: "wg0-mullvad", bindIface: "" };
  assert.equal(Model.vpnUnbound(base), true);
  assert.equal(Model.vpnUnbound({ ...base, bindIface: "wg0-mullvad" }), false);
  assert.equal(Model.vpnUnbound({ ...base, vpnIface: "" }), false);
  assert.equal(Model.vpnUnbound({ ...base, daemon: false }), false);
  assert.equal(Model.vpnUnbound({ ...base, api: false }), false);
  assert.equal(Model.vpnUnbound(null), false);
});

test("parseStatusJson maps detail fields with safe defaults", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({
    installed: true, daemon: true, api: true,
    torrents: [
      {
        hash: "a", name: "x", state: "downloading", progress: 0.5,
        savePath: "/dl", contentPath: "/dl/x", numSeeds: 4, numLeechs: 12, addedOn: 1755400000
      },
      { hash: "b", name: "y", state: "uploading", progress: 1 }
    ]
  }));
  assert.equal(parsed.torrents[0].savePath, "/dl");
  assert.equal(parsed.torrents[0].contentPath, "/dl/x");
  assert.equal(parsed.torrents[0].numSeeds, 4);
  assert.equal(parsed.torrents[0].numLeechs, 12);
  assert.equal(parsed.torrents[0].addedOn, 1755400000);
  assert.equal(parsed.torrents[1].savePath, "");
  assert.equal(parsed.torrents[1].contentPath, "");
  assert.equal(parsed.torrents[1].numSeeds, 0);
  assert.equal(parsed.torrents[1].numLeechs, 0);
  assert.equal(parsed.torrents[1].addedOn, 0);
});

const sortSample = [
  { name: "slow", dlSpeed: 10, upSpeed: 0, eta: 8640000, addedOn: 300 },
  { name: "fast", dlSpeed: 500, upSpeed: 100, eta: 60, addedOn: 100 },
  { name: "mid", dlSpeed: 100, upSpeed: 0, eta: 600, addedOn: 200 }
];

test("sortTorrents default keeps original order and copies", () => {
  const got = Model.sortTorrents(sortSample, "default");
  assert.deepEqual(got.map((t) => t.name), ["slow", "fast", "mid"]);
  assert.notEqual(got, sortSample);
});

test("sortTorrents speed puts the fastest first", () => {
  const got = Model.sortTorrents(sortSample, "speed").map((t) => t.name);
  assert.deepEqual(got, ["fast", "mid", "slow"]);
});

test("sortTorrents eta puts unknown etas last", () => {
  const got = Model.sortTorrents(sortSample, "eta").map((t) => t.name);
  assert.deepEqual(got, ["fast", "mid", "slow"]);
  const zeros = Model.sortTorrents([{ name: "z", eta: 0 }, { name: "e", eta: 5 }], "eta");
  assert.deepEqual(zeros.map((t) => t.name), ["e", "z"]);
});

test("sortTorrents added puts the newest first", () => {
  const got = Model.sortTorrents(sortSample, "added").map((t) => t.name);
  assert.deepEqual(got, ["slow", "mid", "fast"]);
});

test("cycleSort walks default speed eta added", () => {
  assert.equal(Model.cycleSort("default"), "speed");
  assert.equal(Model.cycleSort("speed"), "eta");
  assert.equal(Model.cycleSort("eta"), "added");
  assert.equal(Model.cycleSort("added"), "default");
  assert.equal(Model.cycleSort("junk"), "speed");
});

test("sortLabel names the active sort", () => {
  assert.equal(Model.sortLabel("default"), "");
  assert.equal(Model.sortLabel("speed"), "by speed");
  assert.equal(Model.sortLabel("eta"), "by eta");
  assert.equal(Model.sortLabel("added"), "by added");
});

test("filterByQuery matches names case-insensitively", () => {
  const list = [{ name: "Debian.iso" }, { name: "arch.iso" }];
  assert.deepEqual(Model.filterByQuery(list, "DEB").map((t) => t.name), ["Debian.iso"]);
  assert.equal(Model.filterByQuery(list, "").length, 2);
  assert.equal(Model.filterByQuery(list, "  ").length, 2);
  assert.equal(Model.filterByQuery(list, "zzz").length, 0);
});

test("listQuery treats addable urls as no filter", () => {
  assert.equal(Model.listQuery("magnet:?xt=urn:btih:abc"), "");
  assert.equal(Model.listQuery("https://example.com/x.torrent"), "");
  assert.equal(Model.listQuery(" deb "), "deb");
  assert.equal(Model.listQuery(""), "");
});

test("formatDate renders an ISO day or em dash", () => {
  assert.equal(Model.formatDate(1786924800), "2026-08-17");
  assert.equal(Model.formatDate(86400), "1970-01-02");
  assert.equal(Model.formatDate(0), "—");
  assert.equal(Model.formatDate(-1), "—");
  assert.equal(Model.formatDate("junk"), "—");
});
