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
  assert.deepEqual(status.categories, []);
  assert.deepEqual(status.tags, []);
});

test("parseStatusJson copies category, tags and tracker per row with safe defaults", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({
    installed: true, daemon: true, api: true,
    torrents: [
      { hash: "a", name: "x", state: "downloading", category: "linux", tags: ["alpha", "beta"], tracker: "tracker.example.com" },
      { hash: "b", name: "y", state: "uploading" }
    ]
  }));
  assert.equal(parsed.torrents[0].category, "linux");
  assert.deepEqual(parsed.torrents[0].tags, ["alpha", "beta"]);
  assert.equal(parsed.torrents[0].tracker, "tracker.example.com");
  assert.equal(parsed.torrents[1].category, "");
  assert.deepEqual(parsed.torrents[1].tags, []);
  assert.equal(parsed.torrents[1].tracker, "");
});

test("parseStatusJson copies top-level categories and tags with safe defaults", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({
    installed: true, daemon: true, api: true,
    torrents: [],
    categories: ["linux", "os"],
    tags: ["extra", "iso"]
  }));
  assert.deepEqual(parsed.categories, ["linux", "os"]);
  assert.deepEqual(parsed.tags, ["extra", "iso"]);

  const missing = Model.parseStatusJson(JSON.stringify({ installed: true, torrents: [] }));
  assert.deepEqual(missing.categories, []);
  assert.deepEqual(missing.tags, []);
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

test("magnetUriFor prefers magnetUri when it is a magnet", () => {
  assert.equal(
    Model.magnetUriFor({ magnetUri: "magnet:?xt=urn:btih:abc", hash: "deadbeef" }),
    "magnet:?xt=urn:btih:abc"
  );
});

test("magnetUriFor ignores non-magnet magnetUri and builds from hash", () => {
  assert.equal(
    Model.magnetUriFor({ magnetUri: "http://example.invalid/x.torrent", hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }),
    "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  );
});

test("magnetUriFor builds from torrentId when magnetUri is empty", () => {
  assert.equal(
    Model.magnetUriFor({ hash: "", infohash_v1: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }),
    "magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  );
  assert.equal(Model.magnetUriFor({}), "");
  assert.equal(Model.magnetUriFor(null), "");
});

test("parseStatusJson copies magnetUri and defaults to empty", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({
    installed: true, daemon: true, api: true,
    torrents: [
      { hash: "a", name: "x", state: "downloading", magnetUri: "magnet:?xt=urn:btih:a" },
      { hash: "b", name: "y", state: "uploading" }
    ]
  }));
  assert.equal(parsed.torrents[0].magnetUri, "magnet:?xt=urn:btih:a");
  assert.equal(parsed.torrents[1].magnetUri, "");
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

test("isAddableFile accepts local .torrent paths only", () => {
  assert.equal(Model.isAddableFile("/home/u/d.torrent"), true);
  assert.equal(Model.isAddableFile("~/dl/d.torrent"), true);
  assert.equal(Model.isAddableFile("file:///home/u/d.torrent"), true);
  assert.equal(Model.isAddableFile(" /home/u/d.torrent "), true);
  assert.equal(Model.isAddableFile("/home/u/d.iso"), false);
  assert.equal(Model.isAddableFile("magnet:?xt=urn:btih:abc"), false);
  assert.equal(Model.isAddableFile("https://x.com/d.torrent"), false);
  assert.equal(Model.isAddableFile("relative/d.torrent"), false);
  assert.equal(Model.isAddableFile(""), false);
});

test("isAddableTarget accepts urls and local files", () => {
  assert.equal(Model.isAddableTarget("magnet:?xt=urn:btih:abc"), true);
  assert.equal(Model.isAddableTarget("/home/u/d.torrent"), true);
  assert.equal(Model.isAddableTarget("plain words"), false);
});

test("listQuery treats local torrent files as no filter", () => {
  assert.equal(Model.listQuery("/home/u/d.torrent"), "");
});

test("parseStatusJson carries altSpeed and per-torrent limit fields", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({
    installed: true, daemon: true, api: true, altSpeed: true,
    torrents: [
      { hash: "a", name: "x", state: "downloading", progress: 0.5, dlLimit: 1048576, upLimit: 0, seqDl: true, ratioLimit: -2 },
      { hash: "b", name: "y", state: "uploading", progress: 1 }
    ]
  }));
  assert.equal(parsed.altSpeed, true);
  assert.equal(parsed.torrents[0].dlLimit, 1048576);
  assert.equal(parsed.torrents[0].upLimit, 0);
  assert.equal(parsed.torrents[0].seqDl, true);
  assert.equal(parsed.torrents[0].ratioLimit, -2);
  assert.equal(parsed.torrents[1].dlLimit, 0);
  assert.equal(parsed.torrents[1].seqDl, false);
  assert.equal(parsed.torrents[1].ratioLimit, -2);
});

test("parseStatusJson defaults altSpeed to false", () => {
  const parsed = Model.parseStatusJson(JSON.stringify({ installed: true, torrents: [] }));
  assert.equal(parsed.altSpeed, false);
});

test("cycleLimit walks unlimited down through presets and back", () => {
  assert.equal(Model.cycleLimit(0), 8388608);
  assert.equal(Model.cycleLimit(8388608), 4194304);
  assert.equal(Model.cycleLimit(4194304), 1048576);
  assert.equal(Model.cycleLimit(1048576), 262144);
  assert.equal(Model.cycleLimit(262144), 0);
  assert.equal(Model.cycleLimit(999999), 0);
  assert.equal(Model.cycleLimit(-1), 8388608);
});

test("limitLabel shows infinity or a compact rate", () => {
  assert.equal(Model.limitLabel(0), "∞");
  assert.equal(Model.limitLabel(-1), "∞");
  assert.equal(Model.limitLabel(1048576), "1.0M/s");
  assert.equal(Model.limitLabel(262144), "256K/s");
});

test("cycleRatioLimit walks global, 1.0, 2.0, none", () => {
  assert.equal(Model.cycleRatioLimit(-2), 1);
  assert.equal(Model.cycleRatioLimit(1), 2);
  assert.equal(Model.cycleRatioLimit(2), -1);
  assert.equal(Model.cycleRatioLimit(-1), -2);
  assert.equal(Model.cycleRatioLimit(1.5), -1);
});

test("ratioLimitLabel names global and none", () => {
  assert.equal(Model.ratioLimitLabel(-2), "global");
  assert.equal(Model.ratioLimitLabel(-1), "none");
  assert.equal(Model.ratioLimitLabel(1), "1.0");
  assert.equal(Model.ratioLimitLabel(1.5), "1.5");
});

test("isRealName rejects empty and hash-equal names", () => {
  const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  assert.equal(Model.isRealName("", hash), false);
  assert.equal(Model.isRealName(hash, hash), false);
  assert.equal(Model.isRealName(hash.toUpperCase(), hash), false);
  assert.equal(Model.isRealName("debian.iso", hash), true);
});

test("excludePending drops rows whose hash is pending", () => {
  const rows = [
    { name: "dl", state: "downloading", progress: 0.2, hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
    { name: "seed", state: "uploading", progress: 1, hash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  ];
  const got = Model.excludePending(rows, ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]).map((t) => t.name);
  assert.deepEqual(got, ["seed"]);
});

test("anyActive ignores pending hashes", () => {
  const onlyDl = [
    { name: "dl", state: "downloading", progress: 0.2, hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  ];
  assert.equal(Model.anyActive(onlyDl), true);
  assert.equal(Model.anyActive(onlyDl, ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]), false);
});

test("pendingNeedsStop is true while metadata or payload is running", () => {
  for (const state of ["metaDL", "downloading", "checkingDL", "forcedDL", "stalledDL"]) {
    assert.equal(Model.pendingNeedsStop(state), true, state);
  }
  assert.equal(Model.pendingNeedsStop("stoppedDL"), false);
  assert.equal(Model.pendingNeedsStop("pausedDL"), false);
});

test("magnetMoreWaiting counts the queue after the current item", () => {
  assert.equal(Model.magnetMoreWaiting(1, 0), 0);
  assert.equal(Model.magnetMoreWaiting(1, 1), 1);
  assert.equal(Model.magnetMoreWaiting(0, 2), 1);
  assert.equal(Model.magnetMoreWaiting(0, 0), 0);
});

test("enqueueAction keeps FIFO order", () => {
  let q = [];
  q = Model.enqueueAction(q, { cmd: ["start", "a"] });
  q = Model.enqueueAction(q, { cmd: ["start", "b"] });
  const first = Model.shiftAction(q);
  assert.deepEqual(first.item.cmd, ["start", "a"]);
  const second = Model.shiftAction(first.rest);
  assert.deepEqual(second.item.cmd, ["start", "b"]);
  assert.equal(second.rest.length, 0);
});

test("makeActionItem shapes a widget item by default", () => {
  for (const opts of [undefined, null, {}, { origin: "widget" }, { origin: "Window" }, { origin: 1 }]) {
    const item = Model.makeActionItem(3, ["qbt", "start", "a"], "Starting…", opts);
    assert.deepEqual(item, {
      cmd: ["qbt", "start", "a"], status: "Starting…", ticket: 3, origin: "widget", hashes: []
    }, JSON.stringify(opts));
  }
});

test("makeActionItem keeps the window origin and copies hashes", () => {
  const hashes = ["a", "b"];
  const item = Model.makeActionItem(7, ["qbt", "stop", "a|b"], undefined, { origin: "window", hashes });
  assert.equal(item.origin, "window");
  assert.equal(item.ticket, 7);
  assert.equal(item.status, "");
  assert.deepEqual(item.hashes, ["a", "b"]);
  hashes.push("c");
  assert.deepEqual(item.hashes, ["a", "b"]);
});

test("makeActionItem drops empty hashes and ignores a non-array", () => {
  assert.deepEqual(Model.makeActionItem(1, ["x"], "", { hashes: ["a", "", null, "b"] }).hashes, ["a", "b"]);
  assert.deepEqual(Model.makeActionItem(1, ["x"], "", { hashes: "a" }).hashes, []);
});

// Tests for parseServeLine
test("parseServeLine parses a valid status line", () => {
  const result = Model.parseServeLine('{"type":"status","foo":"bar"}');
  assert.equal(result.type, "status");
  assert.equal(result.raw, '{"type":"status","foo":"bar"}');
  assert.deepEqual(result.data, { type: "status", foo: "bar" });
});

test("parseServeLine parses a valid files line", () => {
  const result = Model.parseServeLine('{"type":"files"}');
  assert.equal(result.type, "files");
  assert.deepEqual(result.data, { type: "files" });
});

test("parseServeLine parses a valid heartbeat line", () => {
  const result = Model.parseServeLine('{"type":"heartbeat"}');
  assert.equal(result.type, "heartbeat");
});

test("parseServeLine parses a valid fatal line", () => {
  const result = Model.parseServeLine('{"type":"fatal"}');
  assert.equal(result.type, "fatal");
});

test("parseServeLine parses a valid error line", () => {
  const result = Model.parseServeLine('{"type":"error"}');
  assert.equal(result.type, "error");
});

test("parseServeLine sets type to invalid for unknown type", () => {
  const result = Model.parseServeLine('{"type":"nope"}');
  assert.equal(result.type, "invalid");
  assert.equal(result.data, null);
});

test("parseServeLine sets type to invalid for empty string", () => {
  const result = Model.parseServeLine("");
  assert.equal(result.type, "invalid");
  assert.equal(result.data, null);
  assert.equal(result.raw, "");
});

test("parseServeLine sets type to invalid for null string", () => {
  const result = Model.parseServeLine("null");
  assert.equal(result.type, "invalid");
  assert.equal(result.data, null);
});

test("parseServeLine sets type to invalid for array", () => {
  const result = Model.parseServeLine("[]");
  assert.equal(result.type, "invalid");
  assert.equal(result.data, null);
});

test("parseServeLine sets type to invalid for invalid JSON", () => {
  const result = Model.parseServeLine("{bad json}");
  assert.equal(result.type, "invalid");
  assert.equal(result.data, null);
  assert.equal(result.raw, "{bad json}");
});

// Tests for cadenceMs
test("cadenceMs returns 250 when magnetWatching is truthy", () => {
  assert.equal(Model.cadenceMs(true, 5), 250);
  assert.equal(Model.cadenceMs(1, 10), 250);
  assert.equal(Model.cadenceMs("yes", 3600), 250);
});

test("cadenceMs clamps below 5 to 5000", () => {
  assert.equal(Model.cadenceMs(false, 1), 5000);
  assert.equal(Model.cadenceMs(false, 4), 5000);
  assert.equal(Model.cadenceMs(false, 0), 5000);
});

test("cadenceMs converts valid refreshIntervalSec to milliseconds", () => {
  assert.equal(Model.cadenceMs(false, 5), 5000);
  assert.equal(Model.cadenceMs(false, "10"), 10000);
  assert.equal(Model.cadenceMs(false, 30), 30000);
});

test("cadenceMs clamps above 3600 to 3600000", () => {
  assert.equal(Model.cadenceMs(false, 3601), 3600000);
  assert.equal(Model.cadenceMs(false, 99999), 3600000);
});

test("cadenceMs defaults undefined to 5000", () => {
  assert.equal(Model.cadenceMs(false, undefined), 5000);
});

// Tests for heartbeatExpired
test("heartbeatExpired returns false for exactly 2*interval", () => {
  const lastBeat = 0;
  const now = 10000;
  const interval = 5000;
  assert.equal(Model.heartbeatExpired(lastBeat, now, interval), false);
});

test("heartbeatExpired returns true for more than 2*interval", () => {
  const lastBeat = 0;
  const now = 10001;
  const interval = 5000;
  assert.equal(Model.heartbeatExpired(lastBeat, now, interval), true);
});

test("heartbeatExpired defaults interval to 5000", () => {
  const lastBeat = 0;
  const now = 10000;
  assert.equal(Model.heartbeatExpired(lastBeat, now), false);
  assert.equal(Model.heartbeatExpired(lastBeat, now + 1), true);
});

// Tests for nextBackoffMs
test("nextBackoffMs returns 0 for failures <= 0", () => {
  assert.equal(Model.nextBackoffMs(0), 0);
  assert.equal(Model.nextBackoffMs(-1), 0);
});

test("nextBackoffMs calculates exponential backoff", () => {
  assert.equal(Model.nextBackoffMs(1), 1000);
  assert.equal(Model.nextBackoffMs(2), 2000);
  assert.equal(Model.nextBackoffMs(3), 4000);
  assert.equal(Model.nextBackoffMs(4), 8000);
  assert.equal(Model.nextBackoffMs(5), 16000);
});

test("nextBackoffMs caps at 30000", () => {
  assert.equal(Model.nextBackoffMs(6), 30000);
  assert.equal(Model.nextBackoffMs(20), 30000);
});

// Tests for sidecarGaveUp
test("sidecarGaveUp returns false for failures < 5", () => {
  assert.equal(Model.sidecarGaveUp(4), false);
  assert.equal(Model.sidecarGaveUp(0), false);
});

test("sidecarGaveUp returns true for failures >= 5", () => {
  assert.equal(Model.sidecarGaveUp(5), true);
  assert.equal(Model.sidecarGaveUp(6), true);
});

// --- Task 5: sortTorrents(list, mode, desc) --------------------------------

const hashedSortSample = [
  { hash: "h-slow", name: "slow", dlSpeed: 10, upSpeed: 0, eta: 8640000, addedOn: 300, size: 500, progress: 0.1, ratio: 0.1 },
  { hash: "h-fast", name: "fast", dlSpeed: 500, upSpeed: 100, eta: 60, addedOn: 100, size: 900, progress: 0.9, ratio: 2.5 },
  { hash: "h-mid", name: "mid", dlSpeed: 100, upSpeed: 0, eta: 600, addedOn: 200, size: 200, progress: 0.5, ratio: 1.0 }
];

test("sortTorrents default ignores hash and keeps original order (exempt from tie-break)", () => {
  const got = Model.sortTorrents(hashedSortSample, "default");
  assert.deepEqual(got.map((t) => t.hash), ["h-slow", "h-fast", "h-mid"]);
});

test("sortTorrents speed/eta/added still match today's widget orders with hashes present", () => {
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "speed").map((t) => t.name), ["fast", "mid", "slow"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "eta").map((t) => t.name), ["fast", "mid", "slow"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "added").map((t) => t.name), ["slow", "mid", "fast"]);
});

test("sortTorrents ties break on hash ascending", () => {
  const rows = [
    { hash: "zzz", name: "a", dlSpeed: 10, upSpeed: 0 },
    { hash: "aaa", name: "b", dlSpeed: 10, upSpeed: 0 },
    { hash: "mmm", name: "c", dlSpeed: 10, upSpeed: 0 }
  ];
  const got = Model.sortTorrents(rows, "dl").map((t) => t.hash);
  assert.deepEqual(got, ["aaa", "mmm", "zzz"]);
});

test("sortTorrents tie-break stays hash-ascending under desc", () => {
  const rows = [
    { hash: "zzz", name: "a", dlSpeed: 10, upSpeed: 0 },
    { hash: "aaa", name: "b", dlSpeed: 10, upSpeed: 0 }
  ];
  const got = Model.sortTorrents(rows, "dl", true).map((t) => t.hash);
  assert.deepEqual(got, ["aaa", "zzz"]);
});

// desc is absolute: false is always ascending (oldest/smallest/A->Z first),
// true is always descending (newest/largest/Z->A first), the same meaning
// for every mode. There is no per-mode "natural direction" -- both
// directions are pinned explicitly for every mode below.
test("sortTorrents desc:false is ascending for every mode (oldest/smallest/A->Z first)", () => {
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "added", false).map((t) => t.name), ["fast", "mid", "slow"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "name", false).map((t) => t.name), ["fast", "mid", "slow"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "size", false).map((t) => t.name), ["mid", "slow", "fast"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "progress", false).map((t) => t.name), ["slow", "mid", "fast"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "dl", false).map((t) => t.name), ["slow", "mid", "fast"]);
  // ul: slow and mid both have upSpeed 0 -- their tie always breaks on hash
  // ascending (h-mid < h-slow), regardless of desc.
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "ul", false).map((t) => t.name), ["mid", "slow", "fast"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "ratio", false).map((t) => t.name), ["slow", "mid", "fast"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "eta", false).map((t) => t.name), ["fast", "mid", "slow"]);
});

test("sortTorrents desc:true is descending for every mode (newest/largest/Z->A first)", () => {
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "added", true).map((t) => t.name), ["slow", "mid", "fast"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "name", true).map((t) => t.name), ["slow", "mid", "fast"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "size", true).map((t) => t.name), ["fast", "slow", "mid"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "progress", true).map((t) => t.name), ["fast", "mid", "slow"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "dl", true).map((t) => t.name), ["fast", "mid", "slow"]);
  // The mid/slow tie still breaks on hash ascending even under desc:true --
  // only the non-tied comparison (against fast) flips.
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "ul", true).map((t) => t.name), ["fast", "mid", "slow"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "ratio", true).map((t) => t.name), ["fast", "mid", "slow"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "eta", true).map((t) => t.name), ["slow", "mid", "fast"]);
});

test("sortTorrents 'added' with no explicit desc defaults to true (newest first), matching the widget and the window's own default", () => {
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "added").map((t) => t.name), ["slow", "mid", "fast"]);
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "added"), Model.sortTorrents(hashedSortSample, "added", true));
});

test("every other mode with no explicit desc defaults to false (ascending), matching 'eta' today", () => {
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "eta"), Model.sortTorrents(hashedSortSample, "eta", false));
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "size"), Model.sortTorrents(hashedSortSample, "size", false));
});

test("sortTorrents name compares case-insensitively without locale surprises", () => {
  const rows = [{ hash: "1", name: "Bravo" }, { hash: "2", name: "alpha" }, { hash: "3", name: "Charlie" }];
  assert.deepEqual(Model.sortTorrents(rows, "name").map((t) => t.name), ["alpha", "Bravo", "Charlie"]);
});

test("sortTorrents falls back to no-sort for an unrecognized mode string", () => {
  assert.deepEqual(Model.sortTorrents(hashedSortSample, "junk").map((t) => t.hash), ["h-slow", "h-fast", "h-mid"]);
});

test("sortTorrents with no mode defaults to added (newest first)", () => {
  assert.deepEqual(Model.sortTorrents(hashedSortSample).map((t) => t.name), ["slow", "mid", "fast"]);
});

// --- Task 5: applyOps --------------------------------------------------------

test("applyOps set replaces a row at an index", () => {
  const rows = [{ hash: "a" }, { hash: "b" }];
  const got = Model.applyOps(rows, [{ op: "set", index: 1, row: { hash: "b", name: "B" } }]);
  assert.deepEqual(got, [{ hash: "a" }, { hash: "b", name: "B" }]);
});

test("applyOps insert adds a row at an index", () => {
  const rows = [{ hash: "a" }, { hash: "c" }];
  const got = Model.applyOps(rows, [{ op: "insert", index: 1, row: { hash: "b" } }]);
  assert.deepEqual(got.map((r) => r.hash), ["a", "b", "c"]);
});

test("applyOps remove drops a row at an index", () => {
  const rows = [{ hash: "a" }, { hash: "b" }, { hash: "c" }];
  const got = Model.applyOps(rows, [{ op: "remove", index: 1 }]);
  assert.deepEqual(got.map((r) => r.hash), ["a", "c"]);
});

test("applyOps move matches ListModel.move(from,to,1) splice semantics", () => {
  const rows = [{ hash: "a" }, { hash: "b" }, { hash: "c" }, { hash: "d" }, { hash: "e" }];
  const got = Model.applyOps(rows, [{ op: "move", from: 0, to: 4 }]);
  assert.deepEqual(got.map((r) => r.hash), ["b", "c", "d", "e", "a"]);
});

test("applyOps applies a sequence of ops in order", () => {
  const rows = [{ hash: "a" }, { hash: "b" }, { hash: "c" }];
  const got = Model.applyOps(rows, [
    { op: "remove", index: 0 },
    { op: "insert", index: 0, row: { hash: "z" } },
    { op: "move", from: 0, to: 2 }
  ]);
  assert.deepEqual(got.map((r) => r.hash), ["b", "c", "z"]);
});

test("applyOps does not mutate its input array", () => {
  const rows = [{ hash: "a" }, { hash: "b" }];
  Model.applyOps(rows, [{ op: "remove", index: 0 }]);
  assert.deepEqual(rows.map((r) => r.hash), ["a", "b"]);
});

// --- Task 5: diffRows ---------------------------------------------------

const DIFF_FIELDS = ["name", "dlSpeed", "upSpeed", "progress", "tags"];

test("diffRows on identical lists produces no ops", () => {
  const rows = [{ hash: "a", name: "A" }, { hash: "b", name: "B" }];
  const ops = Model.diffRows(rows, rows.map((r) => Object.assign({}, r)), DIFF_FIELDS);
  assert.deepEqual(ops, []);
});

test("diffRows detects an insert", () => {
  const oldRows = [{ hash: "a" }, { hash: "c" }];
  const newRows = [{ hash: "a" }, { hash: "b" }, { hash: "c" }];
  const ops = Model.diffRows(oldRows, newRows, DIFF_FIELDS);
  assert.deepEqual(Model.applyOps(oldRows, ops).map((r) => r.hash), ["a", "b", "c"]);
  assert.ok(ops.some((op) => op.op === "insert"));
});

test("diffRows detects a remove", () => {
  const oldRows = [{ hash: "a" }, { hash: "b" }, { hash: "c" }];
  const newRows = [{ hash: "a" }, { hash: "c" }];
  const ops = Model.diffRows(oldRows, newRows, DIFF_FIELDS);
  assert.deepEqual(Model.applyOps(oldRows, ops).map((r) => r.hash), ["a", "c"]);
  assert.ok(ops.some((op) => op.op === "remove"));
});

test("diffRows detects a field change as a single set", () => {
  const oldRows = [{ hash: "a", name: "A", dlSpeed: 1 }, { hash: "b", name: "B", dlSpeed: 1 }];
  const newRows = [{ hash: "a", name: "A", dlSpeed: 9 }, { hash: "b", name: "B", dlSpeed: 1 }];
  const ops = Model.diffRows(oldRows, newRows, DIFF_FIELDS);
  assert.deepEqual(ops, [{ op: "set", index: 0, row: newRows[0] }]);
});

test("diffRows moving one row to the back emits one move, not a cascade", () => {
  const oldRows = ["a", "b", "c", "d", "e"].map((h) => ({ hash: h }));
  const newRows = ["b", "c", "d", "e", "a"].map((h) => ({ hash: h }));
  const ops = Model.diffRows(oldRows, newRows, DIFF_FIELDS);
  const moves = ops.filter((op) => op.op === "move");
  assert.equal(moves.length, 1, `expected exactly one move, got ${JSON.stringify(ops)}`);
  assert.deepEqual(Model.applyOps(oldRows, ops).map((r) => r.hash), ["b", "c", "d", "e", "a"]);
});

test("diffRows a full reset returns {reset:true}", () => {
  const oldRows = [];
  const newRows = [];
  for (let i = 0; i < 40; i++) oldRows.push({ hash: "old-" + i, name: "n" + i });
  for (let i = 0; i < 40; i++) newRows.push({ hash: "new-" + i, name: "n" + i });
  const ops = Model.diffRows(oldRows, newRows, DIFF_FIELDS);
  assert.deepEqual(ops, { reset: true });
});

test("diffRows treats duplicate hashes as unsafe and resets", () => {
  const oldRows = [{ hash: "a" }, { hash: "a" }];
  const newRows = [{ hash: "a" }];
  assert.deepEqual(Model.diffRows(oldRows, newRows, DIFF_FIELDS), { reset: true });
});

test("diffRows compares array fields (tags) element-wise, not by reference", () => {
  const oldRows = [{ hash: "a", name: "A", tags: ["x", "y"] }];
  const newRows = [{ hash: "a", name: "A", tags: ["x", "y"] }];
  assert.deepEqual(Model.diffRows(oldRows, newRows, DIFF_FIELDS), []);
  const changed = [{ hash: "a", name: "A", tags: ["x"] }];
  const ops = Model.diffRows(oldRows, changed, DIFF_FIELDS);
  assert.deepEqual(ops, [{ op: "set", index: 0, row: changed[0] }]);
});

test("diffRows does not mutate its inputs", () => {
  const oldRows = [{ hash: "a" }, { hash: "b" }];
  const newRows = [{ hash: "b" }, { hash: "a" }];
  const oldCopy = oldRows.map((r) => Object.assign({}, r));
  const newCopy = newRows.map((r) => Object.assign({}, r));
  Model.diffRows(oldRows, newRows, DIFF_FIELDS);
  assert.deepEqual(oldRows, oldCopy);
  assert.deepEqual(newRows, newCopy);
});

test("diffRows handles an empty old list (every row is an insert)", () => {
  const oldRows = [];
  const newRows = [{ hash: "a", name: "A" }, { hash: "b", name: "B" }, { hash: "c", name: "C" }];
  const ops = Model.diffRows(oldRows, newRows, DIFF_FIELDS);
  assert.ok(Array.isArray(ops), `expected ops, got ${JSON.stringify(ops)}`);
  assert.ok(ops.every((op) => op.op === "insert"));
  assert.deepEqual(Model.applyOps(oldRows, ops), newRows);
});

test("diffRows handles an empty new list (every row is a remove)", () => {
  const oldRows = [{ hash: "a", name: "A" }, { hash: "b", name: "B" }, { hash: "c", name: "C" }];
  const newRows = [];
  const ops = Model.diffRows(oldRows, newRows, DIFF_FIELDS);
  assert.ok(Array.isArray(ops), `expected ops, got ${JSON.stringify(ops)}`);
  assert.ok(ops.every((op) => op.op === "remove"));
  assert.deepEqual(Model.applyOps(oldRows, ops), []);
});

test("diffRows handles both lists empty (no ops)", () => {
  assert.deepEqual(Model.diffRows([], [], DIFF_FIELDS), []);
});

test("applyOps handles an empty rows array and/or an empty ops list", () => {
  assert.deepEqual(Model.applyOps([], []), []);
  assert.deepEqual(Model.applyOps([], [{ op: "insert", index: 0, row: { hash: "a" } }]), [{ hash: "a" }]);
  assert.deepEqual(Model.applyOps([{ hash: "a" }], []), [{ hash: "a" }]);
});

test("applyOps throws rather than splicing at index -1 when a move's from/to is missing", () => {
  assert.throws(() => Model.applyOps([{ hash: "a" }], [{ op: "move", from: -1, to: 0 }]));
});

// --- Task 5: diffRows fuzz (applyOps is the executable contract) -----------

function mulberry32(seed) {
  return function () {
    seed |= 0;
    seed = (seed + 0x6D2B79F5) | 0;
    let t = seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function fuzzPair(rng, n) {
  const hashes = [];
  for (let i = 0; i < n; i++) hashes.push("t" + i);
  const oldRows = hashes.map((h) => ({ hash: h, name: h, dlSpeed: 1, upSpeed: 1, progress: 0, tags: ["x"] }));

  let next = oldRows.map((r) => Object.assign({}, r, { tags: r.tags.slice() }));
  // removes (light: diffRows' reset threshold is max(8, n/2), so heavy churn
  // on a small n mostly just proves the reset fallback, not the ops path)
  next = next.filter(() => rng() > 0.05);
  // field mutations
  next = next.map((r) => {
    if (rng() > 0.8) {
      return Object.assign({}, r, { dlSpeed: r.dlSpeed + 1, tags: rng() > 0.5 ? ["y"] : r.tags.slice() });
    }
    return r;
  });
  // inserts
  const maxHash = n;
  let nextHashSeed = maxHash;
  const insertCount = Math.floor(rng() * 3);
  for (let i = 0; i < insertCount; i++) {
    const h = "new" + (nextHashSeed++);
    const pos = Math.floor(rng() * (next.length + 1));
    next.splice(pos, 0, { hash: h, name: h, dlSpeed: 0, upSpeed: 0, progress: 0, tags: [] });
  }
  // shuffle (reorder), a light touch per position
  for (let i = next.length - 1; i > 0; i--) {
    if (rng() > 0.93) {
      const j = Math.floor(rng() * (i + 1));
      const tmp = next[i];
      next[i] = next[j];
      next[j] = tmp;
    }
  }
  return { oldRows, newRows: next };
}

test("fuzz: applyOps(old, diffRows(old,new)) reproduces new, or diffRows says reset", () => {
  const rng = mulberry32(1234567);
  let resets = 0;
  let checked = 0;
  for (let i = 0; i < 500; i++) {
    const n = 5 + Math.floor(rng() * 45);
    const { oldRows, newRows } = fuzzPair(rng, n);
    const ops = Model.diffRows(oldRows, newRows, DIFF_FIELDS);
    if (ops && ops.reset === true) {
      resets++;
      continue;
    }
    checked++;
    const got = Model.applyOps(oldRows, ops);
    assert.deepEqual(got, newRows, `mismatch on iteration ${i} (seed run): ops=${JSON.stringify(ops)}`);
  }
  // The fuzz must exercise the real ops path on most cases, not just prove
  // the reset fallback (churn is tuned low enough that resets stay a
  // minority -- this run: checked=442, resets=58 out of 500).
  assert.ok(checked >= 200, `expected most fuzz cases to exercise the ops path; checked=${checked} resets=${resets}`);
});

// --- Task 5: filterGroups / matchFilter / statusGroup -----------------------

const filterRows = [
  { hash: "1", state: "downloading", progress: 0.2, category: "movies", tags: ["a", "b"], tracker: "tracker1.example" },
  { hash: "2", state: "uploading", progress: 1, category: "movies", tags: ["a"], tracker: "tracker2.example" },
  { hash: "3", state: "stoppedDL", progress: 0.3, category: "", tags: [], tracker: "" },
  { hash: "4", state: "checkingDL", progress: 0.4, category: "tv", tags: ["b"], tracker: "tracker1.example" },
  { hash: "5", state: "missingFiles", progress: 0, category: "", tags: [], tracker: "tracker2.example" },
  { hash: "6", state: "moving", progress: 0.6, category: "tv", tags: [], tracker: "" }
];

test("statusGroup carves checking/moving out of downloading/seeding", () => {
  assert.equal(Model.statusGroup({ state: "downloading", progress: 0.2 }), "downloading");
  assert.equal(Model.statusGroup({ state: "uploading", progress: 1 }), "seeding");
  assert.equal(Model.statusGroup({ state: "checkingDL", progress: 0.2 }), "checking");
  assert.equal(Model.statusGroup({ state: "checkingUP", progress: 1 }), "checking");
  assert.equal(Model.statusGroup({ state: "checkingResumeData", progress: 0.5 }), "checking");
  assert.equal(Model.statusGroup({ state: "moving", progress: 0.9 }), "checking");
  assert.equal(Model.statusGroup({ state: "stoppedDL", progress: 0.3 }), "stopped");
  assert.equal(Model.statusGroup({ state: "stoppedUP", progress: 1 }), "stopped");
  assert.equal(Model.statusGroup({ state: "missingFiles", progress: 0 }), "errored");
  assert.equal(Model.statusGroup({ state: "error", progress: 0 }), "errored");
});

test("filterGroups Status counts partition all rows and All equals the total", () => {
  const groups = Model.filterGroups(filterRows, [], []);
  const status = groups.find((g) => g.group === "status");
  const byLabel = {};
  status.items.forEach((item) => { byLabel[item.label] = item.count; });
  assert.equal(byLabel.All, filterRows.length);
  assert.equal(byLabel.Downloading + byLabel.Seeding + byLabel.Stopped + byLabel.Errored + byLabel.Checking, filterRows.length);
  assert.equal(byLabel.Active, byLabel.Downloading + byLabel.Seeding);
  assert.equal(byLabel.Downloading, 1);
  assert.equal(byLabel.Seeding, 1);
  assert.equal(byLabel.Stopped, 1);
  assert.equal(byLabel.Errored, 1);
  assert.equal(byLabel.Checking, 2);
});

test("filterGroups category includes Uncategorized and zero-count known categories", () => {
  const groups = Model.filterGroups(filterRows, ["movies", "tv", "books"], []);
  const category = groups.find((g) => g.group === "category");
  const byLabel = {};
  category.items.forEach((item) => { byLabel[item.label] = item; });
  assert.equal(byLabel.Uncategorized.count, 2);
  assert.equal(byLabel.Uncategorized.value, "");
  assert.equal(byLabel.movies.count, 2);
  assert.equal(byLabel.tv.count, 2);
  assert.equal(byLabel.books.count, 0);
  assert.equal(byLabel.books.zero, true);
  category.items.forEach((item) => assert.equal(item.group, "category"));
});

test("filterGroups tag includes Untagged and counts multi-valued tags", () => {
  const groups = Model.filterGroups(filterRows, [], ["a", "b", "c"]);
  const tag = groups.find((g) => g.group === "tag");
  const byLabel = {};
  tag.items.forEach((item) => { byLabel[item.label] = item; });
  assert.equal(byLabel.Untagged.count, 3);
  assert.equal(byLabel.a.count, 2);
  assert.equal(byLabel.b.count, 2);
  assert.equal(byLabel.c.count, 0);
  assert.equal(byLabel.c.zero, true);
  tag.items.forEach((item) => assert.equal(item.group, "tag"));
});

test("filterGroups tracker includes Trackerless and hosts from rows", () => {
  const groups = Model.filterGroups(filterRows, [], []);
  const tracker = groups.find((g) => g.group === "tracker");
  const byLabel = {};
  tracker.items.forEach((item) => { byLabel[item.label] = item; });
  assert.equal(byLabel.Trackerless.count, 2);
  assert.equal(byLabel["tracker1.example"].count, 2);
  assert.equal(byLabel["tracker2.example"].count, 2);
  tracker.items.forEach((item) => assert.equal(item.group, "tracker"));
});

test("matchFilter status All matches every row", () => {
  filterRows.forEach((row) => assert.equal(Model.matchFilter(row, { group: "status", value: "All" }), true));
});

test("matchFilter status matches statusGroup buckets", () => {
  assert.equal(Model.matchFilter(filterRows[3], { group: "status", value: "Checking" }), true);
  assert.equal(Model.matchFilter(filterRows[3], { group: "status", value: "Downloading" }), false);
  assert.equal(Model.matchFilter(filterRows[0], { group: "status", value: "Active" }), true);
});

test("matchFilter category/tag/tracker use value:'' as the sentinel, not the label", () => {
  assert.equal(Model.matchFilter(filterRows[2], { group: "category", value: "" }), true);
  assert.equal(Model.matchFilter(filterRows[0], { group: "category", value: "" }), false);
  assert.equal(Model.matchFilter(filterRows[0], { group: "category", value: "movies" }), true);
  assert.equal(Model.matchFilter(filterRows[2], { group: "tag", value: "" }), true);
  assert.equal(Model.matchFilter(filterRows[0], { group: "tag", value: "b" }), true);
  assert.equal(Model.matchFilter(filterRows[0], { group: "tag", value: "z" }), false);
  assert.equal(Model.matchFilter(filterRows[2], { group: "tracker", value: "" }), true);
  assert.equal(Model.matchFilter(filterRows[0], { group: "tracker", value: "tracker1.example" }), true);
});

test("matchFilter category excludes a row whose category doesn't match", () => {
  // filterRows[0].category === "movies"; a filter for a different category
  // must exclude it, not just fail to include the right one.
  const row = { hash: "x", category: "x", tags: [], tracker: "" };
  assert.equal(Model.matchFilter(row, { group: "category", value: "movies" }), false);
});

test("matchFilter fails closed: an unknown group matches nothing", () => {
  assert.equal(Model.matchFilter(filterRows[0], { group: "bogus", value: "whatever" }), false);
  assert.equal(Model.matchFilter(filterRows[0], null), false);
  assert.equal(Model.matchFilter(filterRows[0], {}), false);
  assert.equal(Model.matchFilter(filterRows[0], { group: undefined, value: "All" }), false);
});

test("matchFilter fails closed: an unrecognized status value matches nothing", () => {
  assert.equal(Model.matchFilter(filterRows[0], { group: "status", value: "Bogus" }), false);
  assert.equal(Model.matchFilter(filterRows[0], { group: "status", value: undefined }), false);
});

// --- parseViewState / serializeViewState ------------------------------------

const DEFAULT_VIEW_STATE = {
  filter: { group: "status", value: "All" },
  sort: "added",
  desc: true,
  cursorHash: "",
  pane: "table",
  paletteMru: []
};

test("parseViewState of null/undefined/missing input returns full defaults", () => {
  assert.deepEqual(Model.parseViewState(null), DEFAULT_VIEW_STATE);
  assert.deepEqual(Model.parseViewState(undefined), DEFAULT_VIEW_STATE);
  assert.deepEqual(Model.parseViewState(""), DEFAULT_VIEW_STATE);
});

test("parseViewState of corrupt JSON returns defaults", () => {
  assert.deepEqual(Model.parseViewState("{not json"), DEFAULT_VIEW_STATE);
  assert.deepEqual(Model.parseViewState("[1,2,3]"), DEFAULT_VIEW_STATE);
  assert.deepEqual(Model.parseViewState("42"), DEFAULT_VIEW_STATE);
  assert.deepEqual(Model.parseViewState('"just a string"'), DEFAULT_VIEW_STATE);
});

test("parseViewState accepts a plain object as well as a JSON string", () => {
  const state = { filter: { group: "tag", value: "linux" }, sort: "size", desc: false, cursorHash: "abc123", pane: "inspector", paletteMru: ["torrent.remove", "sort.next"] };
  assert.deepEqual(Model.parseViewState(state), state);
  assert.deepEqual(Model.parseViewState(JSON.stringify(state)), state);
});

test("parseViewState fills in missing keys with defaults, field by field", () => {
  assert.deepEqual(Model.parseViewState("{}"), DEFAULT_VIEW_STATE);
  assert.deepEqual(Model.parseViewState('{"sort":"size"}'), Object.assign({}, DEFAULT_VIEW_STATE, { sort: "size" }));
  assert.deepEqual(
    Model.parseViewState('{"filter":{"group":"category"}}'),
    Object.assign({}, DEFAULT_VIEW_STATE, { filter: { group: "category", value: "All" } })
  );
});

test("parseViewState rejects an unknown filter group, falling back to status/All", () => {
  const result = Model.parseViewState('{"filter":{"group":"bogus","value":"x"}}');
  assert.deepEqual(result.filter, { group: "status", value: "All" });
});

test("parseViewState rejects an unknown status value, falling back to the default filter", () => {
  assert.deepEqual(Model.parseViewState('{"filter":{"group":"status","value":"Bogus"}}').filter, { group: "status", value: "All" });
  assert.deepEqual(Model.parseViewState({ filter: { group: "status", value: "seeding" } }).filter, { group: "status", value: "All" }, "labels are case-sensitive");
  assert.deepEqual(Model.parseViewState({ filter: { group: "status", value: "" } }).filter, { group: "status", value: "All" });
  const kept = Model.parseViewState({ filter: { group: "status", value: "Bogus" }, sort: "size", pane: "filters" });
  assert.equal(kept.sort, "size", "other fields keep their own values");
  assert.equal(kept.pane, "filters");
});

test("parseViewState accepts every status label", () => {
  for (const label of ["All", "Active", "Downloading", "Seeding", "Stopped", "Errored", "Checking"]) {
    assert.deepEqual(Model.parseViewState({ filter: { group: "status", value: label } }).filter, { group: "status", value: label }, label);
  }
});

test("parseViewState keeps any string value for category, tag and tracker", () => {
  for (const group of ["category", "tag", "tracker"]) {
    assert.deepEqual(Model.parseViewState({ filter: { group, value: "Bogus" } }).filter, { group, value: "Bogus" }, group);
  }
});

test("parseViewState rejects a non-string filter value, falling back to All", () => {
  const result = Model.parseViewState('{"filter":{"group":"tracker","value":42}}');
  assert.deepEqual(result.filter, { group: "tracker", value: "All" });
});

test("parseViewState rejects an unknown sort mode, falling back to added", () => {
  assert.equal(Model.parseViewState('{"sort":"bogus"}').sort, "added");
  assert.equal(Model.parseViewState('{"sort":"speed"}').sort, "added");
  assert.equal(Model.parseViewState('{"sort":null}').sort, "added");
});

test("parseViewState accepts every documented sort mode", () => {
  for (const mode of ["added", "name", "size", "progress", "dl", "ul", "eta", "ratio"]) {
    assert.equal(Model.parseViewState({ sort: mode }).sort, mode, mode);
  }
});

test("parseViewState rejects a non-boolean desc, falling back to true", () => {
  assert.equal(Model.parseViewState('{"desc":"no"}').desc, true);
  assert.equal(Model.parseViewState('{"desc":0}').desc, true);
  assert.equal(Model.parseViewState({ desc: false }).desc, false);
});

test("parseViewState rejects a non-string cursorHash, falling back to empty", () => {
  assert.equal(Model.parseViewState('{"cursorHash":123}').cursorHash, "");
  assert.equal(Model.parseViewState('{"cursorHash":null}').cursorHash, "");
  assert.equal(Model.parseViewState({ cursorHash: "deadbeef" }).cursorHash, "deadbeef");
});

test("parseViewState rejects an unknown pane, falling back to table", () => {
  assert.equal(Model.parseViewState('{"pane":"bogus"}').pane, "table");
  assert.equal(Model.parseViewState('{"pane":"filters"}').pane, "filters");
  assert.equal(Model.parseViewState('{"pane":"inspector"}').pane, "inspector");
});

test("parseViewState treats a non-object filter as missing", () => {
  assert.deepEqual(Model.parseViewState('{"filter":"bogus"}').filter, { group: "status", value: "All" });
  assert.deepEqual(Model.parseViewState('{"filter":null}').filter, { group: "status", value: "All" });
  assert.deepEqual(Model.parseViewState('{"filter":[1,2]}').filter, { group: "status", value: "All" });
});

test("serializeViewState round-trips through parseViewState", () => {
  const state = { filter: { group: "category", value: "movies" }, sort: "ratio", desc: false, cursorHash: "deadbeef", pane: "filters", paletteMru: ["torrent.move"] };
  const text = Model.serializeViewState(state);
  assert.equal(typeof text, "string");
  assert.deepEqual(JSON.parse(text), state);
  assert.deepEqual(Model.parseViewState(text), state);
});

test("serializeViewState normalizes garbage input the same way parseViewState does", () => {
  const text = Model.serializeViewState({ sort: "bogus", pane: "nope" });
  assert.deepEqual(JSON.parse(text), DEFAULT_VIEW_STATE);
});

// --- parseViewState: paletteMru ---------------------------------------------

test("parseViewState defaults paletteMru to an empty array", () => {
  assert.deepEqual(Model.parseViewState({}).paletteMru, []);
  assert.deepEqual(Model.parseViewState({ paletteMru: null }).paletteMru, []);
  assert.deepEqual(Model.parseViewState({ paletteMru: "not an array" }).paletteMru, []);
  assert.deepEqual(Model.parseViewState({ paletteMru: 42 }).paletteMru, []);
});

test("parseViewState keeps a valid array of strings, in order", () => {
  const mru = ["torrent.remove", "sort.next", "torrent.move"];
  assert.deepEqual(Model.parseViewState({ paletteMru: mru }).paletteMru, mru);
});

test("parseViewState drops non-string entries from paletteMru", () => {
  const result = Model.parseViewState({ paletteMru: ["a", 1, null, undefined, {}, [], "b", true] });
  assert.deepEqual(result.paletteMru, ["a", "b"]);
});

test("parseViewState removes duplicate ids from paletteMru, keeping the first occurrence", () => {
  const result = Model.parseViewState({ paletteMru: ["a", "b", "a", "c", "b"] });
  assert.deepEqual(result.paletteMru, ["a", "b", "c"]);
});

test("parseViewState caps paletteMru at 20 entries", () => {
  const long = [];
  for (let i = 0; i < 30; i++) long.push("cmd" + i);
  const result = Model.parseViewState({ paletteMru: long });
  assert.equal(result.paletteMru.length, 20);
  assert.deepEqual(result.paletteMru, long.slice(0, 20));
});

// --- files load origin (Service's quiet map) --------------------------------

test("filesQuietAfterLoad sets a window load, clears a widget load, keeps others", () => {
  const a = "a".repeat(40), b = "b".repeat(40);
  let q = Model.filesQuietAfterLoad({}, a, true);
  assert.deepEqual(q, { [a]: true });
  q = Model.filesQuietAfterLoad(q, b, true);
  assert.deepEqual(q, { [a]: true, [b]: true });
  q = Model.filesQuietAfterLoad(q, a, false);
  assert.deepEqual(q, { [b]: true });
});

test("filesReplayOpts keeps a replayed load's origin", () => {
  const a = "a".repeat(40);
  assert.deepEqual(Model.filesReplayOpts({ [a]: true }, a), { origin: "window" });
  assert.equal(Model.filesReplayOpts({}, a), undefined);
  // replaying with those opts leaves the hash quiet, so its failure
  // stays out of lastError
  const q = Model.filesQuietAfterLoad({ [a]: true }, a, Model.filesReplayOpts({ [a]: true }, a) !== undefined);
  assert.equal(Model.filesFailureWritesLastError(q, a), false);
  assert.equal(Model.filesFailureWritesLastError({}, a), true);
});

// --- chunkHashes / toggleAllTargets ------------------------------------------

function hx(i) {
  return i.toString(16).padStart(40, "0");
}

test("chunkHashes splits in order into chunks of at most size", () => {
  const list = Array.from({ length: 5000 }, (_, i) => hx(i));
  const chunks = Model.chunkHashes(list, 1000);
  assert.equal(chunks.length, 5);
  for (const c of chunks) assert.equal(c.length, 1000);
  assert.deepEqual([].concat(...chunks), list);
  assert.deepEqual(Model.chunkHashes(["a", "b", "c"], 2), [["a", "b"], ["c"]]);
  assert.deepEqual(Model.chunkHashes(Array.from({ length: 1001 }, (_, i) => hx(i)), 1000).map((c) => c.length), [1000, 1]);
});

test("chunkHashes handles empty input, drops empty entries and defaults the size", () => {
  assert.deepEqual(Model.chunkHashes([], 1000), []);
  assert.deepEqual(Model.chunkHashes(null, 1000), []);
  assert.deepEqual(Model.chunkHashes(["a", "", null, "b"], 5), [["a", "b"]]);
  assert.equal(Model.HASH_CHUNK, 1000);
  assert.equal(Model.chunkHashes(Array.from({ length: 2500 }, (_, i) => hx(i))).length, 3, "default size is HASH_CHUNK");
  assert.equal(Model.chunkHashes(["a", "b"], 0).length, 1);
});

test("a chunk of 1000 v2 hashes stays under Linux's 131072-byte argv limit", () => {
  const v2 = Array.from({ length: 1000 }, (_, i) => i.toString(16).padStart(64, "0"));
  const arg = Model.chunkHashes(v2, Model.HASH_CHUNK)[0].join("|");
  assert.ok(Buffer.byteLength("hashes=" + arg) < 131072);
});

test("toggleAllTargets sends all only when nothing is pending and the inbox is empty", () => {
  const rows = Array.from({ length: 5000 }, (_, i) => ({ hash: hx(i) }));
  assert.deepEqual(Model.toggleAllTargets(rows, [], 1000), ["all"]);
  assert.deepEqual(Model.toggleAllTargets(rows, [], 1000, 0), ["all"]);
  assert.deepEqual(Model.toggleAllTargets(rows, null, 1000), ["all"], "missing pending counts as empty");
  assert.deepEqual(Model.toggleAllTargets([], [], 1000), []);
});

test("toggleAllTargets sends explicit chunks, not all, when a pending magnet isn't in torrents yet", () => {
  const rows = Array.from({ length: 5000 }, (_, i) => ({ hash: hx(i) }));
  const args = Model.toggleAllTargets(rows, [hx(99999)], 1000);
  assert.equal(args.length, 5, "still chunked, even though every row is live");
  assert.deepEqual(
    [].concat(...args.map((a) => a.split("|"))),
    rows.map((r) => r.hash),
    "every live row is included; 'all' would have wrongly touched the not-yet-listed pending magnet too"
  );
});

test("toggleAllTargets sends explicit chunks, not all, when the inbox has an item waiting", () => {
  const rows = Array.from({ length: 5000 }, (_, i) => ({ hash: hx(i) }));
  const args = Model.toggleAllTargets(rows, [], 1000, 1);
  assert.equal(args.length, 5, "inboxCount > 0 forces the explicit-hash path");
  assert.deepEqual([].concat(...args.map((a) => a.split("|"))), rows.map((r) => r.hash));
});

test("toggleAllTargets chunks the live hashes when a pending magnet is in torrents", () => {
  const rows = Array.from({ length: 5001 }, (_, i) => ({ hash: hx(i) }));
  const args = Model.toggleAllTargets(rows, [hx(5000).toUpperCase()], 1000);
  assert.equal(args.length, 5, "5000 live hashes make 5 calls");
  for (const a of args) assert.equal(a.split("|").length, 1000);
  assert.ok(!args.join("|").includes(hx(5000)), "the pending hash is left out");
  assert.deepEqual(Model.toggleAllTargets([{ hash: hx(1) }], [hx(1)], 1000), [], "nothing live");
});
