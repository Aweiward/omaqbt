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

