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
