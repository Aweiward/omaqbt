const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// LimitsView.js starts with a QML-only `.pragma library` line, which node
// can't parse. Strip it and run the rest as a function body in this realm
// (tests/library-view.test.js's loader, copied; LimitsView imports nothing).
function loadLimitsView() {
  const file = path.join(__dirname, "..", "LimitsView.js");
  const src = fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module"], { filename: file })(mod);
  return mod.exports;
}

const V = loadLimitsView();
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "validation-cases.json"), "utf8"));

// The wire shapes qbt accepts (tests/fixtures/validation-cases.json's
// _comment_limits), for checking that every parsed value is sendable.
function wireRatioOk(s) {
  if (s === "-2" || s === "-1") return true;
  const m = /^(0|[1-9][0-9]{0,3})(\.[0-9]{1,2})?$/.exec(s);
  return !!m && Number(s) <= 9998;
}
function wireSeedOk(s) {
  return s === "-2" || s === "-1" || (/^(0|[1-9][0-9]{0,5})$/.test(s) && Number(s) <= 525600);
}
function wireSpeedOk(s) {
  return /^(0|[1-9][0-9]{0,9})$/.test(s) && Number(s) <= 2147483647;
}

// A finished, seeding torrent with no limits of its own.
function row(overrides) {
  return Object.assign({
    hash: "a".repeat(40),
    name: "debian.iso",
    state: "stalledUP",
    progress: 1,
    ratio: 1,
    seedingTime: 3600,
    category: "",
    dlLimit: 0,
    upLimit: 0,
    seqDl: false,
    firstLast: false,
    ratioLimit: -2,
    seedingTimeLimit: -2,
    inactiveSeedingTimeLimit: -2,
    shareLimitAction: "Default",
    maxRatio: -1,
    maxSeedingTime: -1
  }, overrides || {});
}

function status(overrides) {
  return Object.assign({
    categoryLimits: {},
    shareDefaults: { ratio: -1, seedingTime: -1, action: "Stop" }
  }, overrides || {});
}

function cat(ratioLimit, seedingTimeLimit, shareLimitAction) {
  return { ratioLimit: ratioLimit, seedingTimeLimit: seedingTimeLimit, shareLimitAction: shareLimitAction };
}

// --- parseSpeed -------------------------------------------------------------

test("parseSpeed: K is KiB, M is MiB, a bare number is KiB, case-insensitive", () => {
  assert.deepEqual(V.parseSpeed("500K"), { bytes: 512000 });
  assert.deepEqual(V.parseSpeed("500k"), { bytes: 512000 });
  assert.deepEqual(V.parseSpeed("500"), { bytes: 512000 });
  assert.deepEqual(V.parseSpeed("2M"), { bytes: 2097152 });
  assert.deepEqual(V.parseSpeed("2m"), { bytes: 2097152 });
  assert.deepEqual(V.parseSpeed("1"), { bytes: 1024 });
});

test("parseSpeed: 0 and u mean unlimited (0), in any unit or case", () => {
  for (const s of ["0", "u", "U", "0K", "0m", "0.0", "0.00M"]) assert.deepEqual(V.parseSpeed(s), { bytes: 0 }, s);
});

test("parseSpeed: up to 2 decimals, rounded to a whole byte", () => {
  assert.deepEqual(V.parseSpeed("1.5M"), { bytes: 1572864 });
  assert.deepEqual(V.parseSpeed("1.5"), { bytes: 1536 });
  assert.deepEqual(V.parseSpeed("0.5K"), { bytes: 512 });
  assert.deepEqual(V.parseSpeed("0.01K"), { bytes: 10 }, "10.24 rounds to 10");
  assert.deepEqual(V.parseSpeed("0.3K"), { bytes: 307 }, "307.2 rounds to 307");
  assert.deepEqual(V.parseSpeed("1.25M"), { bytes: 1310720 });
  assert.equal(V.parseSpeed("1.234M").error, "Use at most 2 decimals.", "the same message as the ratio's");
  assert.equal(V.parseSpeed("0.001").error, "Use at most 2 decimals.");
  assert.equal(V.parseSpeed("1.").error, V.SPEED_ERROR);
});

test("parseSpeed: the cap is 2047 MiB/s, whatever the unit", () => {
  assert.deepEqual(V.parseSpeed("2047M"), { bytes: 2146435072 });
  assert.deepEqual(V.parseSpeed("2096128K"), { bytes: 2146435072 });
  assert.deepEqual(V.parseSpeed("2047.00M"), { bytes: 2146435072 });
  // Exactly 2047 MiB/s, as the message says, although qbt takes up to INT_MAX.
  for (const s of ["2047.01M", "2047.99M", "2096129K", "2097151K", "2048M", "3000M", "2097152K", "2097152", "99999999999", "18446744073709551617", "2047.999M"]) {
    const r = V.parseSpeed(s);
    assert.equal(r.error, s === "2047.999M" ? "Use at most 2 decimals." : "Use at most 2047 MiB/s.", s);
    assert.equal(r.bytes, undefined, s);
  }
  assert.equal(V.SPEED_CAP_ERROR, "Use at most 2047 MiB/s.");
});

test("parseSpeed: anything else is refused with the one message", () => {
  assert.equal(V.SPEED_ERROR, "Use a number with K or M, or 0.");
  for (const s of ["", "-1", "-1K", "+1", "01", "01K", "1e3", "1K/s", "1KB", "1 K", " 1", "1 ", "1\n", "∞", "inf",
    "１", "1,5", "1.", ".5", "1.5.0", "0x10", "K", "uu", "unlimited", "1G", "nan"]) {
    assert.deepEqual(V.parseSpeed(s), { error: V.SPEED_ERROR }, JSON.stringify(s));
  }
  assert.deepEqual(V.parseSpeed(null), { error: V.SPEED_ERROR });
  assert.deepEqual(V.parseSpeed(undefined), { error: V.SPEED_ERROR });
});

test("parseSpeed and the shared speed cases: every refused wire form is refused, except the two that are human forms", () => {
  assert.ok(CASES.speeds.length >= 19);
  // A bare number is KiB here and bytes on the wire, so only these two
  // wire refusals are accepted: they are the human forms "1.5 KiB" and "1 KiB".
  const humanOnly = { "1.5": 1536, "1K": 1024 };
  for (const c of CASES.speeds) {
    const r = V.parseSpeed(c.input);
    if (!c.ok && !(c.input in humanOnly)) {
      assert.ok(r.error, "refused: " + c.why);
      continue;
    }
    if (c.input in humanOnly) assert.equal(r.bytes, humanOnly[c.input], c.why);
    if (r.error === undefined) assert.ok(wireSpeedOk(String(r.bytes)), "sendable: " + c.why);
  }
});

test("parseSpeed and the shared speed cases: every ok byte count that is whole KiB round-trips through K", () => {
  let checked = 0;
  for (const c of CASES.speeds.filter((c) => c.ok)) {
    const b = Number(c.input);
    if (b % 1024 !== 0) continue;
    assert.deepEqual(V.parseSpeed(b / 1024 + "K"), { bytes: b }, c.why);
    checked++;
  }
  assert.ok(checked >= 4);
});

test("parseSpeed: every accepted value is a sendable whole byte count", () => {
  for (const s of ["0", "u", "1", "0.01K", "0.99K", "1.5", "999.99", "1.01M", "2046.99M", "2096128K", "2047M"]) {
    const r = V.parseSpeed(s);
    assert.ok(Number.isInteger(r.bytes), s);
    assert.ok(wireSpeedOk(String(r.bytes)), s);
  }
});

// --- parseRatio ---------------------------------------------------------------

test("parseRatio: exactly the shared fixture's ok cases, each giving a sendable value", () => {
  assert.ok(CASES.ratios.length >= 35);
  for (const c of CASES.ratios) {
    const r = V.parseRatio(c.input);
    assert.equal(r.error === undefined, c.ok, c.why + ": " + JSON.stringify(c.input));
    if (c.ok) {
      assert.equal(r.ratio, Number(c.input), c.why);
      assert.ok(wireRatioOk(String(r.ratio)), "sendable: " + c.why);
    } else {
      assert.equal(typeof r.error, "string");
      assert.ok(r.error.length > 0);
    }
  }
});

test("parseRatio: g is -2 (default) and n is -1 (none), case-insensitive", () => {
  assert.deepEqual(V.parseRatio("g"), { ratio: -2 });
  assert.deepEqual(V.parseRatio("G"), { ratio: -2 });
  assert.deepEqual(V.parseRatio("n"), { ratio: -1 });
  assert.deepEqual(V.parseRatio("N"), { ratio: -1 });
  assert.deepEqual(V.parseRatio("-2"), { ratio: -2 });
  assert.deepEqual(V.parseRatio("-1"), { ratio: -1 });
});

test("parseRatio: the canonical string is the shortest form", () => {
  assert.equal(String(V.parseRatio("1.50").ratio), "1.5");
  assert.equal(String(V.parseRatio("9998.00").ratio), "9998");
  assert.equal(String(V.parseRatio("0.07").ratio), "0.07");
  assert.equal(String(V.parseRatio("1.25").ratio), "1.25");
});

test("parseRatio: its messages name the fix", () => {
  assert.equal(V.parseRatio("1.234").error, "Use at most 2 decimals.");
  assert.equal(V.parseRatio("9998.01").error, "Use at most 9998.");
  assert.equal(V.parseRatio("9999").error, "Use at most 9998.");
  assert.equal(V.parseRatio("10000").error, "Use at most 9998.");
  assert.equal(V.parseRatio("18446744073709551617").error, "Use at most 9998.");
  for (const s of ["", "-3", "-0", "-1.5", "-2.0", "1.", ".5", "01", "1e3", "+1", "1,5", " 1", "1 ", "１",
    "0x1", "nan", "1.5.0", "1\n", "gg", "none", "x", "1.5x"]) {
    assert.equal(V.parseRatio(s).error, V.RATIO_ERROR, JSON.stringify(s));
  }
  assert.equal(V.RATIO_ERROR, "Use a ratio like 1.5, g for default or n for none.");
  assert.equal(V.parseRatio(null).error, V.RATIO_ERROR);
});

// --- parseSeedTime ------------------------------------------------------------

test("parseSeedTime: exactly the shared fixture's ok cases, except 90m which is a human form", () => {
  assert.ok(CASES.seedTimes.length >= 18);
  for (const c of CASES.seedTimes) {
    const r = V.parseSeedTime(c.input);
    if (c.input === "90m") {
      assert.deepEqual(r, { minutes: 90 });
      continue;
    }
    assert.equal(r.error === undefined, c.ok, c.why + ": " + JSON.stringify(c.input));
    if (c.ok) {
      assert.equal(r.minutes, Number(c.input), c.why);
      assert.ok(wireSeedOk(String(r.minutes)), "sendable: " + c.why);
    }
  }
});

test("parseSeedTime: m, h and d in minutes, a bare number is minutes, case-insensitive", () => {
  assert.deepEqual(V.parseSeedTime("90m"), { minutes: 90 });
  assert.deepEqual(V.parseSeedTime("90M"), { minutes: 90 });
  assert.deepEqual(V.parseSeedTime("90"), { minutes: 90 });
  assert.deepEqual(V.parseSeedTime("2h"), { minutes: 120 });
  assert.deepEqual(V.parseSeedTime("2H"), { minutes: 120 });
  assert.deepEqual(V.parseSeedTime("3d"), { minutes: 4320 });
  assert.deepEqual(V.parseSeedTime("3D"), { minutes: 4320 });
  assert.deepEqual(V.parseSeedTime("0h"), { minutes: 0 });
  assert.deepEqual(V.parseSeedTime("g"), { minutes: -2 });
  assert.deepEqual(V.parseSeedTime("G"), { minutes: -2 });
  assert.deepEqual(V.parseSeedTime("n"), { minutes: -1 });
  assert.deepEqual(V.parseSeedTime("N"), { minutes: -1 });
});

test("parseSeedTime: the cap is 365 days in any unit", () => {
  assert.deepEqual(V.parseSeedTime("365d"), { minutes: 525600 });
  assert.deepEqual(V.parseSeedTime("8760h"), { minutes: 525600 });
  assert.deepEqual(V.parseSeedTime("525600m"), { minutes: 525600 });
  for (const s of ["366d", "8761h", "525601", "525601m", "1000000", "18446744073709551617", "99999999999d"]) {
    assert.equal(V.parseSeedTime(s).error, "Use at most 365d.", s);
  }
});

test("parseSeedTime: anything else is refused with the one message", () => {
  assert.equal(V.SEED_ERROR, "Use a time like 90m, 2h or 3d, g for default or n for none.");
  for (const s of ["", "-3", "-0", "01", "01h", "1.5", "1.5h", "１０", " 1", "1 ", "+1", "1w", "1s", "h",
    "2h30m", "1\n", "-2h", "gg", "x"]) {
    assert.equal(V.parseSeedTime(s).error, V.SEED_ERROR, JSON.stringify(s));
  }
  assert.equal(V.parseSeedTime(undefined).error, V.SEED_ERROR);
});

// --- Formatting ---------------------------------------------------------------

test("formatMinutes: whole days, hours and minutes, dropping the zero parts", () => {
  assert.equal(V.formatMinutes(0), "0m");
  assert.equal(V.formatMinutes(90), "1h 30m");
  assert.equal(V.formatMinutes(120), "2h");
  assert.equal(V.formatMinutes(4320), "3d");
  assert.equal(V.formatMinutes(1501), "1d 1h 1m");
  assert.equal(V.formatMinutes(1441), "1d 1m");
  assert.equal(V.formatMinutes(525600), "365d");
});

test("formatSpeed: KiB/s below 1 MiB/s, MiB/s above, B/s below 1 KiB/s, unlimited for 0", () => {
  assert.equal(V.formatSpeed(0), "unlimited");
  assert.equal(V.formatSpeed(-5), "unlimited");
  assert.equal(V.formatSpeed(512000), "500 KiB/s");
  assert.equal(V.formatSpeed(1536), "1.5 KiB/s");
  assert.equal(V.formatSpeed(1048576), "1 MiB/s");
  assert.equal(V.formatSpeed(1572864), "1.5 MiB/s");
  assert.equal(V.formatSpeed(2146435072), "2047 MiB/s");
  assert.equal(V.formatSpeed(10), "10 B/s");
  assert.equal(V.formatSpeed(1000), "1000 B/s");
  assert.equal(V.formatSpeed(1025), "1 KiB/s");
});

test("formatRatio: two decimals, none for -1", () => {
  assert.equal(V.formatRatio(2), "2.00");
  assert.equal(V.formatRatio(1.5), "1.50");
  assert.equal(V.formatRatio(0), "0.00");
  assert.equal(V.formatRatio(-1), "none");
  assert.equal(V.formatRatio(NaN), "none");
});

// --- effective values -----------------------------------------------------------

test("effectiveRatio: the torrent's own value, else the category, each parent, then the global setting", () => {
  const st = status({
    categoryLimits: { "a": cat(3, -2, "Default"), "a/b": cat(-2, -2, "Default"), "a/b/c": cat(-2, -2, "Default"), "x": cat(-1, -2, "Default") },
    shareDefaults: { ratio: 2, seedingTime: 60, action: "Stop" }
  });
  assert.equal(V.effectiveRatio(row({ ratioLimit: 1.5 }), st), 1.5);
  assert.equal(V.effectiveRatio(row({ ratioLimit: -1 }), st), -1);
  assert.equal(V.effectiveRatio(row({ ratioLimit: 0 }), st), 0);
  assert.equal(V.effectiveRatio(row({ category: "" }), st), 2, "no category: global");
  assert.equal(V.effectiveRatio(row({ category: "a" }), st), 3);
  assert.equal(V.effectiveRatio(row({ category: "a/b/c" }), st), 3, "two parents up");
  assert.equal(V.effectiveRatio(row({ category: "x" }), st), -1, "the chain stops at -1");
  assert.equal(V.effectiveRatio(row({ category: "gone/child" }), st), 2, "a category missing from the map defers");
  assert.equal(V.effectiveRatio(row({ category: "a/zz" }), st), 3, "a missing child walks to its parent");
});

test("effectiveRatio: a new value overrides the torrent's own, and -2 resolves through the chain", () => {
  const st = status({ categoryLimits: { a: cat(3, -2, "Default") }, shareDefaults: { ratio: 2, seedingTime: -1, action: "Stop" } });
  assert.equal(V.effectiveRatio(row({ ratioLimit: 1, category: "a" }), st, -2), 3);
  assert.equal(V.effectiveRatio(row({ ratioLimit: -2, category: "a" }), st, 5), 5);
  assert.equal(V.effectiveRatio(row({ ratioLimit: 1 }), st, -2), 2);
  assert.equal(V.effectiveRatio(row({ ratioLimit: 1 }), st, undefined), 1, "undefined keeps the own value");
  assert.equal(V.effectiveRatio(row({ ratioLimit: 1 }), st, null), 1, "null keeps the own value");
});

test("effectiveRatio: a category 0 is a real limit, not a default", () => {
  const st = status({ categoryLimits: { a: cat(0, 0, "Default") }, shareDefaults: { ratio: 2, seedingTime: 60, action: "Stop" } });
  assert.equal(V.effectiveRatio(row({ category: "a" }), st), 0);
  assert.equal(V.effectiveSeedTime(row({ category: "a" }), st), 0);
  assert.equal(V.effectiveRatio(row(), status({ shareDefaults: { ratio: 0, seedingTime: 0, action: "Stop" } })), 0);
});

test("effectiveSeedTime: the same chain on seedingTimeLimit", () => {
  const st = status({
    categoryLimits: { "p": cat(-2, 120, "Default"), "p/c": cat(-2, -2, "Default") },
    shareDefaults: { ratio: -1, seedingTime: 60, action: "Stop" }
  });
  assert.equal(V.effectiveSeedTime(row({ seedingTimeLimit: 30 }), st), 30);
  assert.equal(V.effectiveSeedTime(row({ category: "p/c" }), st), 120);
  assert.equal(V.effectiveSeedTime(row(), st), 60);
  assert.equal(V.effectiveSeedTime(row({ category: "p/c", seedingTimeLimit: 5 }), st, -2), 120);
});

test("effectiveAction: the torrent's action, else the category chain's, else the global action", () => {
  const st = status({
    categoryLimits: { "p": cat(-2, -2, "RemoveWithContent"), "p/c": cat(-2, -2, "Default"), "p/s": cat(-2, -2, "Stop") },
    shareDefaults: { ratio: -1, seedingTime: -1, action: "Remove" }
  });
  assert.equal(V.effectiveAction(row({ shareLimitAction: "Stop", category: "p" }), st), "Stop");
  assert.equal(V.effectiveAction(row({ category: "p/c" }), st), "RemoveWithContent");
  assert.equal(V.effectiveAction(row({ category: "p/s" }), st), "Stop", "a child's Stop beats its parent");
  assert.equal(V.effectiveAction(row(), st), "Remove");
  assert.equal(V.effectiveAction(row({ shareLimitAction: "EnableSuperSeeding" }), st), "EnableSuperSeeding");
  assert.equal(V.effectiveAction(row({ shareLimitAction: "" }), st), "Remove", "an empty action defers");
});

test("effective values never throw on a status missing its share fields: none and Stop", () => {
  for (const st of [undefined, null, {}, { categoryLimits: null, shareDefaults: null }, { categoryLimits: [], shareDefaults: {} }]) {
    assert.equal(V.effectiveRatio(row({ category: "a" }), st), -1);
    assert.equal(V.effectiveSeedTime(row({ category: "a" }), st), -1);
    assert.equal(V.effectiveAction(row({ category: "a" }), st), "Stop");
  }
  const st = status({ categoryLimits: { a: null, b: { ratioLimit: "3", shareLimitAction: 3 } } });
  assert.equal(V.effectiveRatio(row({ category: "a" }), st), -1);
  assert.equal(V.effectiveRatio(row({ category: "b" }), st), -1, "a non-number defers");
  assert.equal(V.effectiveAction(row({ category: "b" }), st), "Stop", "a non-string defers");
});

// --- isFinished (Ruling CC) -------------------------------------------------------

test("isFinished: progress 1 or a seeding state, never forcedUP", () => {
  assert.equal(V.isFinished(row({ state: "stalledUP", progress: 1 })), true);
  assert.equal(V.isFinished(row({ state: "downloading", progress: 1 })), true);
  for (const st of ["uploading", "stalledUP", "queuedUP", "stoppedUP", "checkingUP"]) {
    assert.equal(V.isFinished(row({ state: st, progress: 0 })), true, st + " at progress 0 (every file unwanted)");
  }
  for (const st of ["UP", "downloading", "stalledDL", "stoppedDL", "metaDL", "error", ""]) {
    assert.equal(V.isFinished(row({ state: st, progress: 0.5 })), false, st);
  }
  assert.equal(V.isFinished(row({ state: "forcedUP", progress: 1 })), false);
  assert.equal(V.isFinished(null), false);
});

// --- limitRows ----------------------------------------------------------------------

test("limitRows: six rows in order, keyed by the status fields", () => {
  const rows = V.limitRows(row(), status());
  assert.deepEqual(rows.map((r) => r.key), ["dlLimit", "upLimit", "ratioLimit", "seedingTimeLimit", "seqDl", "firstLast"]);
  assert.deepEqual(rows.map((r) => r.label), ["↓ limit", "↑ limit", "Ratio limit", "Seed time", "Sequential", "First/last"]);
  assert.deepEqual(rows.map((r) => r.toggle), [false, false, false, false, true, true]);
  for (const r of rows) assert.deepEqual(Object.keys(r).sort(), ["key", "label", "muted", "toggle", "value"]);
});

test("limitRows: speeds read like the done notes (formatSpeed); unlimited is the word, muted (Ruling CH)", () => {
  const rows = V.limitRows(row({ dlLimit: 512000, upLimit: 0 }), status());
  assert.deepEqual([rows[0].value, rows[0].muted], ["500 KiB/s", false]);
  assert.deepEqual([rows[1].value, rows[1].muted], ["unlimited", true]);
  const speed = (b) => V.limitRows(row({ dlLimit: b }), status())[0].value;
  assert.equal(speed(1572864), "1.5 MiB/s");
  assert.equal(speed(10), "10 B/s", "not 0K/s");
  assert.equal(speed(2146435072), "2047 MiB/s", "not 2047.0M/s");
  assert.equal(speed(-1), "unlimited");
  for (const b of [0, 10, 1536, 512000, 1572864, 2146435072]) {
    assert.equal(speed(b), V.formatSpeed(b));
    assert.ok(!speed(b).includes("∞"));
    assert.equal(V.doneNote("dlLimit", b, row()), "↓ limit set to " + speed(b), "rows agree with doneNote");
  }
});

test("limitRows: own ratio and seed time show plainly; -1 is none", () => {
  const rows = V.limitRows(row({ ratioLimit: 1.5, seedingTimeLimit: 90 }), status());
  assert.deepEqual([rows[2].value, rows[2].muted], ["1.50", false]);
  assert.deepEqual([rows[3].value, rows[3].muted], ["1h 30m", false]);
  const none = V.limitRows(row({ ratioLimit: -1, seedingTimeLimit: -1 }), status());
  assert.deepEqual([none[2].value, none[2].muted], ["none", false]);
  assert.deepEqual([none[3].value, none[3].muted], ["none", false]);
  const zero = V.limitRows(row({ ratioLimit: 0, seedingTimeLimit: 0 }), status());
  assert.deepEqual([zero[2].value, zero[3].value], ["0.00", "0m"]);
});

test("limitRows: a deferred value reads default (…) from the row's own effective values, muted, never global", () => {
  const st = status({ shareDefaults: { ratio: 2, seedingTime: 120, action: "Stop" } });
  const rows = V.limitRows(row({ maxRatio: 2, maxSeedingTime: 120 }), st);
  assert.deepEqual([rows[2].value, rows[2].muted], ["default (2.00)", true]);
  assert.deepEqual([rows[3].value, rows[3].muted], ["default (2h)", true]);
  const none = V.limitRows(row({ maxRatio: -1, maxSeedingTime: -1 }), status());
  assert.deepEqual([none[2].value, none[3].value], ["default (none)", "default (none)"]);
  for (const r of rows.concat(none)) assert.ok(!/global/.test(r.value));
});

test("limitRows: for display qBittorrent's own maxRatio/maxSeedingTime win over the chain; the chain fills in when they're missing", () => {
  // The status's chain says 3 / 60, but qBittorrent's resolved values are 2 / 120: show those.
  const st = status({ shareDefaults: { ratio: 3, seedingTime: 60, action: "Stop" } });
  const shown = V.limitRows(row({ maxRatio: 2, maxSeedingTime: 120 }), st);
  assert.deepEqual([shown[2].value, shown[3].value], ["default (2.00)", "default (2h)"]);
  const bare = row();
  delete bare.maxRatio;
  delete bare.maxSeedingTime;
  const chained = V.limitRows(bare, st);
  assert.deepEqual([chained[2].value, chained[3].value], ["default (3.00)", "default (1h)"]);
});

test("limitRows: the toggles read on and off", () => {
  const on = V.limitRows(row({ seqDl: true, firstLast: true }), status());
  assert.deepEqual([on[4].value, on[5].value], ["on", "on"]);
  const off = V.limitRows(row(), status());
  assert.deepEqual([off[4].value, off[5].value, off[4].muted, off[5].muted], ["off", "off", false, false]);
});

test("limitRows: no row gives no rows; a missing status still gives six", () => {
  assert.deepEqual(V.limitRows(null, status()), []);
  assert.deepEqual(V.limitRows(undefined, status()), []);
  assert.equal(V.limitRows(row(), undefined).length, 6);
});

// --- editText -----------------------------------------------------------------------

test("editText: the current value in input form, which parses back to itself", () => {
  const r = row({ dlLimit: 512000, upLimit: 0, ratioLimit: 1.5, seedingTimeLimit: 120 });
  assert.equal(V.editText("dlLimit", r), "500K");
  assert.equal(V.editText("upLimit", r), "u");
  assert.equal(V.editText("ratioLimit", r), "1.5");
  assert.equal(V.editText("seedingTimeLimit", r), "2h");
  assert.equal(V.editText("ratioLimit", row({ ratioLimit: -2 })), "g");
  assert.equal(V.editText("ratioLimit", row({ ratioLimit: -1 })), "n");
  assert.equal(V.editText("seedingTimeLimit", row({ seedingTimeLimit: -2 })), "g");
  assert.equal(V.editText("seedingTimeLimit", row({ seedingTimeLimit: -1 })), "n");
  assert.equal(V.editText("seedingTimeLimit", row({ seedingTimeLimit: 4320 })), "3d");
  assert.equal(V.editText("seedingTimeLimit", row({ seedingTimeLimit: 90 })), "90m");
  assert.equal(V.editText("seedingTimeLimit", row({ seedingTimeLimit: 0 })), "0");
  assert.equal(V.editText("dlLimit", row({ dlLimit: 2097152 })), "2M");
  assert.equal(V.editText("dlLimit", row({ dlLimit: 1572864 })), "1.5M");
  assert.equal(V.editText("seqDl", r), "");
  assert.equal(V.editText("firstLast", r), "");
  assert.equal(V.editText("nope", r), "");
  assert.equal(V.editText("dlLimit", null), "");
  for (const [key, parse, field] of [["dlLimit", V.parseSpeed, "bytes"], ["ratioLimit", V.parseRatio, "ratio"], ["seedingTimeLimit", V.parseSeedTime, "minutes"]]) {
    for (const v of key === "dlLimit" ? [0, 1024, 512000, 1048576, 1572864, 2146435072] : key === "ratioLimit" ? [-2, -1, 0, 0.07, 1.5, 9998] : [-2, -1, 0, 1, 59, 60, 90, 1440, 525600]) {
      const text = V.editText(key, row({ [key]: v }));
      assert.equal(parse(text)[field], v, key + " " + v + " -> " + text);
    }
  }
});

test("editText: a byte count that isn't whole hundredths of a KiB comes back rounded, and still parses", () => {
  const text = V.editText("dlLimit", row({ dlLimit: 1000 }));
  assert.equal(text, "0.98K");
  assert.equal(V.parseSpeed(text).bytes, 1004);
  assert.equal(V.editText("dlLimit", row({ dlLimit: 2147483647 })), "2047M", "a value above the cap (set elsewhere) comes back as the cap");
  assert.equal(V.editText("dlLimit", row({ dlLimit: 2146435071 })), "2096128K", "rounds up to the cap, never past it");
  assert.equal(V.editText("dlLimit", row({ dlLimit: 5 })), "0.01K", "rounding down would read as unlimited");
  assert.equal(V.editText("dlLimit", row({ dlLimit: -3 })), "u");
});

// --- shareConfirm (D8; the same rule as qbt share-limits' guard) ------------------

test("shareConfirm: nothing met gives no line and no force", () => {
  assert.deepEqual(V.shareConfirm({ ratio: 5 }, [row({ ratio: 1 })], status()), { line: "", force: false });
  assert.deepEqual(V.shareConfirm({}, [row({ ratio: 1 })], status()), { line: "", force: false }, "no change");
  assert.deepEqual(V.shareConfirm({ ratio: 0 }, [], status()), { line: "", force: false });
  assert.deepEqual(V.shareConfirm({ ratio: 0 }, null, status()), { line: "", force: false });
});

test("shareConfirm: the brief's example line", () => {
  const rows = [row({ ratio: 1 }), row({ ratio: 2 }), row({ ratio: 0 })];
  assert.deepEqual(V.shareConfirm({ ratio: 0 }, rows, status()), {
    line: "Set the ratio limit to 0? 3 torrents already meet it and will be stopped.",
    force: false
  });
});

test("shareConfirm: singular, and each action's wording", () => {
  const one = (action) => V.shareConfirm({ ratio: 0.5 }, [row({ shareLimitAction: action })], status());
  assert.deepEqual(one("Stop"), { line: "Set the ratio limit to 0.5? 1 torrent already meets it and will be stopped.", force: false });
  assert.deepEqual(one("Remove"), { line: "Set the ratio limit to 0.5? 1 torrent already meets it and will be removed.", force: true });
  assert.deepEqual(one("RemoveWithContent"), { line: "Set the ratio limit to 0.5? 1 torrent already meets it and will be removed with its files.", force: true });
  assert.deepEqual(one("EnableSuperSeeding"), { line: "Set the ratio limit to 0.5? 1 torrent already meets it and will switch to super seeding.", force: false });
  const two = V.shareConfirm({ ratio: 0.5 }, [row({ shareLimitAction: "RemoveWithContent" }), row({ shareLimitAction: "RemoveWithContent" })], status());
  assert.equal(two.line, "Set the ratio limit to 0.5? 2 torrents already meet it and will be removed with their files.");
});

test("shareConfirm: a mix names every outcome, worst first, in one sentence (Ruling CI)", () => {
  const mix = (actions) => V.shareConfirm({ ratio: 0 }, actions.map((a) => row({ shareLimitAction: a })), status());
  assert.deepEqual(mix(["Stop", "RemoveWithContent"]), {
    line: "Set the ratio limit to 0? 2 torrents already meet it and will be removed with their files or stopped.",
    force: true
  });
  assert.equal(mix(["Remove", "RemoveWithContent", "Remove"]).line,
    "Set the ratio limit to 0? 3 torrents already meet it and will be removed with their files.", "qbt's precedent: any files means with their files");
  assert.equal(mix(["Stop", "Remove"]).line, "Set the ratio limit to 0? 2 torrents already meet it and will be removed or stopped.");
  assert.equal(mix(["EnableSuperSeeding", "Stop"]).line, "Set the ratio limit to 0? 2 torrents already meet it and will switch to super seeding or be stopped.");
  assert.equal(mix(["EnableSuperSeeding", "Remove"]).line, "Set the ratio limit to 0? 2 torrents already meet it and will be removed or switch to super seeding.");
  assert.equal(mix(["RemoveWithContent", "EnableSuperSeeding", "Stop"]).line,
    "Set the ratio limit to 0? 3 torrents already meet it and will be removed with their files, switch to super seeding or be stopped.");
  assert.equal(mix(["EnableSuperSeeding", "Stop"]).force, false);
  assert.equal(mix(["Stop", "Remove"]).force, true);
});

test("shareConfirm: the head names the new values", () => {
  const r = [row({ ratio: 1, seedingTime: 7200, shareLimitAction: "Stop" })];
  const st = status({ shareDefaults: { ratio: 0.5, seedingTime: 60, action: "Stop" } });
  assert.equal(V.shareConfirm({ seedingTime: 120 }, r, st).line, "Set the seed time limit to 2h? 1 torrent already meets it and will be stopped.");
  assert.equal(V.shareConfirm({ seedingTime: 90 }, r, status()).line, "Set the seed time limit to 1h 30m? 1 torrent already meets it and will be stopped.");
  assert.equal(V.shareConfirm({ ratio: -2 }, [row({ ratio: 1, ratioLimit: 5 })], st).line,
    "Set the ratio limit to default? 1 torrent already meets it and will be stopped.");
  assert.equal(V.shareConfirm({ ratio: 1, seedingTime: 120 }, r, status()).line,
    "Set the ratio limit to 1 and the seed time limit to 2h? 1 torrent already meets a share limit and will be stopped.");
});

test("shareConfirm: a kept limit that's already met counts, and says a share limit", () => {
  // qbt checks both new effective limits: the changed one and the kept one.
  const r = row({ ratio: 0.1, seedingTime: 7200, seedingTimeLimit: 60, shareLimitAction: "RemoveWithContent" });
  assert.deepEqual(V.shareConfirm({ ratio: 5 }, [r], status()), {
    line: "Set the ratio limit to 5? 1 torrent already meets a share limit and will be removed with its files.",
    force: true
  });
  assert.equal(V.shareConfirm({ ratio: -1 }, [r], status()).line,
    "Set the ratio limit to none? 1 torrent already meets a share limit and will be removed with its files.");
  // One meets the new ratio, one only its kept seed time: "a share limit".
  const mixed = [row({ ratio: 3 }), row({ ratio: 0.1, seedingTime: 7200, seedingTimeLimit: 60 })];
  assert.equal(V.shareConfirm({ ratio: 2 }, mixed, status()).line,
    "Set the ratio limit to 2? 2 torrents already meet a share limit and will be stopped.");
});

test("shareConfirm: equality counts; ratio 0 and seed time 0 are met at once; floor of seconds to minutes", () => {
  assert.ok(V.shareConfirm({ ratio: 1.5 }, [row({ ratio: 1.5 })], status()).line);
  assert.equal(V.shareConfirm({ ratio: 1.51 }, [row({ ratio: 1.5 })], status()).line, "");
  assert.ok(V.shareConfirm({ ratio: 0 }, [row({ ratio: 0 })], status()).line);
  assert.ok(V.shareConfirm({ seedingTime: 0 }, [row({ seedingTime: 0 })], status()).line);
  assert.ok(V.shareConfirm({ seedingTime: 60 }, [row({ seedingTime: 3600 })], status()).line);
  assert.equal(V.shareConfirm({ seedingTime: 60 }, [row({ seedingTime: 3599 })], status()).line, "", "59.98 minutes floors to 59");
});

test("shareConfirm: maindata's ratio -1 (above the maximum) meets any ratio limit >= 0", () => {
  assert.deepEqual(V.shareConfirm({ ratio: 5 }, [row({ ratio: -1, shareLimitAction: "RemoveWithContent" })], status()), {
    line: "Set the ratio limit to 5? 1 torrent already meets it and will be removed with its files.",
    force: true
  });
  assert.ok(V.shareConfirm({ ratio: 9998 }, [row({ ratio: -1 })], status()).line);
  assert.equal(V.shareConfirm({ ratio: -1 }, [row({ ratio: -1 })], status()).line, "", "no limit, nothing met");
});

test("shareConfirm: only finished targets count (Ruling CC)", () => {
  const act = { shareLimitAction: "RemoveWithContent" };
  const met = (o) => V.shareConfirm({ seedingTime: 60 }, [row(Object.assign({ seedingTime: 7200 }, act, o))], status());
  assert.equal(met({ state: "downloading", progress: 0.5 }).line, "");
  assert.equal(met({ state: "UP", progress: 0 }).line, "", "the substring trap");
  assert.equal(met({ state: "forcedUP", progress: 1 }).line, "");
  assert.equal(met({ state: "stalledUP", progress: 0 }).force, true, "every file unwanted");
  for (const st of ["uploading", "stalledUP", "queuedUP", "stoppedUP", "checkingUP"]) assert.equal(met({ state: st, progress: 0 }).force, true, st);
  assert.equal(met({ state: "downloading", progress: 1 }).force, true, "progress 1 is finished whatever the state");
});

test("shareConfirm: a VISUAL range counts only the finished, met targets", () => {
  const rows = [
    row({ ratio: 3, shareLimitAction: "Stop" }),
    row({ ratio: 3, state: "downloading", progress: 0.4, shareLimitAction: "RemoveWithContent" }),
    row({ ratio: 3, state: "forcedUP", shareLimitAction: "RemoveWithContent" }),
    row({ ratio: 0.1, shareLimitAction: "RemoveWithContent" }),
    row({ ratio: 2, shareLimitAction: "Remove" })
  ];
  assert.deepEqual(V.shareConfirm({ ratio: 2 }, rows, status()), {
    line: "Set the ratio limit to 2? 2 torrents already meet it and will be removed or stopped.",
    force: true
  });
});

test("shareConfirm: the matrix of where the limit and the action come from", () => {
  const cats = {
    "c": cat(1, -2, "RemoveWithContent"),
    "p": cat(1, 60, "Remove"),
    "p/k": cat(-2, -2, "Default"),
    "s": cat(-2, -2, "Default")
  };
  const global = { ratio: 1, seedingTime: 60, action: "RemoveWithContent" };
  const st = status({ categoryLimits: cats, shareDefaults: global });
  const finishedStates = [["finished", { state: "stalledUP", progress: 1 }, true], ["unfinished", { state: "downloading", progress: 0.2 }, false], ["forcedUP", { state: "forcedUP", progress: 1 }, false]];
  // Each source sets a ratio of 1 and a removing action; -2 on the torrent defers to it.
  const sources = [
    ["torrent", { ratioLimit: 1, shareLimitAction: "Remove", category: "" }, { ratio: 1 }],
    ["category", { category: "c" }, { ratio: -2 }],
    ["parent", { category: "p/k" }, { ratio: -2 }],
    ["global", { category: "s" }, { ratio: -2 }]
  ];
  for (const [src, own, action] of sources) {
    for (const [fname, fin, isFin] of finishedStates) {
      for (const [mname, ratio, isMet] of [["met", 1, true], ["unmet", 0.5, false]]) {
        const r = row(Object.assign({ ratio: ratio, seedingTime: 0 }, own, fin));
        const res = V.shareConfirm(action, [r], st);
        const expect = isFin && isMet;
        assert.equal(res.line !== "", expect, [src, fname, mname].join(" "));
        assert.equal(res.force, expect, [src, fname, mname, "force"].join(" "));
      }
    }
  }
});

test("shareConfirm: -2 resolves through the category, the parent, then the global setting", () => {
  const st = status({
    categoryLimits: { "p": cat(2, 30, "Default"), "p/k": cat(-2, -2, "Default") },
    shareDefaults: { ratio: 9, seedingTime: -1, action: "RemoveWithContent" }
  });
  assert.equal(V.shareConfirm({ ratio: -2 }, [row({ ratio: 2, category: "p/k", ratioLimit: 50 })], st).force, true, "parent ratio 2 met");
  assert.equal(V.shareConfirm({ seedingTime: -2 }, [row({ ratio: 0, seedingTime: 1800, category: "p/k", seedingTimeLimit: 500 })], st).force, true, "parent seed time 30 met");
  assert.equal(V.shareConfirm({ ratio: -2 }, [row({ ratio: 2, ratioLimit: 50 })], st).line, "", "global ratio 9 unmet");
  const off = status({ shareDefaults: { ratio: -1, seedingTime: -1, action: "RemoveWithContent" } });
  assert.equal(V.shareConfirm({ ratio: -2 }, [row({ ratio: 50, ratioLimit: 1 })], off).line, "", "a disabled global is none");
});

test("shareConfirm: the torrent's own Stop beats a removing category; a child's Stop beats its parent", () => {
  const st = status({ categoryLimits: { "p": cat(-2, -2, "RemoveWithContent"), "p/c": cat(-2, -2, "Stop") } });
  assert.deepEqual(V.shareConfirm({ ratio: 0 }, [row({ category: "p", shareLimitAction: "Stop" })], st).force, false);
  assert.deepEqual(V.shareConfirm({ ratio: 0 }, [row({ category: "p/c" })], st).force, false);
  assert.deepEqual(V.shareConfirm({ ratio: 0 }, [row({ category: "p" })], st).force, true);
});

test("shareConfirm: kept limits resolve through the chain, not the row's maxRatio (the same inputs as qbt's guard)", () => {
  // maxRatio says 0.5 (met), but the chain says none: qbt reads the chain, so no confirm.
  const r = row({ ratio: 1, maxRatio: 0.5, maxSeedingTime: 1 });
  assert.equal(V.shareConfirm({ seedingTime: -1 }, [r], status()).line, "");
});

test("shareConfirm: a status missing its share fields never throws; the caller gates on readiness", () => {
  for (const st of [undefined, null, {}, { categoryLimits: null }, { shareDefaults: null }]) {
    assert.deepEqual(V.shareConfirm({ ratio: 0 }, [row({ category: "a" })], st), {
      line: "Set the ratio limit to 0? 1 torrent already meets it and will be stopped.",
      force: false
    });
  }
  assert.deepEqual(V.shareConfirm(null, [row()], status()), { line: "", force: false });
  assert.deepEqual(V.shareConfirm({ ratio: 0 }, [null, undefined, row()], status()).line,
    "Set the ratio limit to 0? 1 torrent already meets it and will be stopped.");
});

test("shareConfirm: takes an array-like of rows (a QML sequence)", () => {
  const rows = { length: 2, 0: row(), 1: row() };
  assert.equal(V.shareConfirm({ ratio: 0 }, rows, status()).line, "Set the ratio limit to 0? 2 torrents already meet it and will be stopped.");
});

// --- doneNote -----------------------------------------------------------------------

test("doneNote: each key's note", () => {
  const r = row();
  assert.equal(V.doneNote("dlLimit", 512000, r), "↓ limit set to 500 KiB/s");
  assert.equal(V.doneNote("upLimit", 512000, r), "↑ limit set to 500 KiB/s");
  assert.equal(V.doneNote("upLimit", 0, r), "↑ limit set to unlimited");
  assert.equal(V.doneNote("dlLimit", 1572864, r), "↓ limit set to 1.5 MiB/s");
  assert.equal(V.doneNote("ratioLimit", 1.5, r), "Ratio limit set to 1.50");
  assert.equal(V.doneNote("ratioLimit", -2, r), "Ratio limit set to default");
  assert.equal(V.doneNote("ratioLimit", -1, r), "Ratio limit set to none");
  assert.equal(V.doneNote("seedingTimeLimit", 120, r), "Seed time limit set to 2h");
  assert.equal(V.doneNote("seedingTimeLimit", -2, r), "Seed time limit set to default");
  assert.equal(V.doneNote("seedingTimeLimit", -1, r), "Seed time limit set to none");
  assert.equal(V.doneNote("seqDl", true, r), "Sequential download on");
  assert.equal(V.doneNote("seqDl", false, r), "Sequential download off");
  assert.equal(V.doneNote("firstLast", true, r), "First and last pieces first on");
  assert.equal(V.doneNote("firstLast", false, r), "First and last pieces first off");
  assert.equal(V.doneNote("nope", 1, r), "");
});

test("doneNote: ratio and seed time on a torrent that isn't seeding yet apply once seeding", () => {
  const dl = row({ state: "downloading", progress: 0.3 });
  assert.equal(V.doneNote("ratioLimit", 2, dl), "Ratio limit set to 2.00 (applies once seeding)");
  assert.equal(V.doneNote("seedingTimeLimit", 60, dl), "Seed time limit set to 1h (applies once seeding)");
  assert.equal(V.doneNote("dlLimit", 1024, dl), "↓ limit set to 1 KiB/s", "speeds apply now");
  assert.equal(V.doneNote("seqDl", true, dl), "Sequential download on");
  assert.equal(V.doneNote("ratioLimit", 2, row({ state: "stalledUP", progress: 0 })), "Ratio limit set to 2.00", "seeding with every file unwanted");
  assert.equal(V.doneNote("ratioLimit", 2, row({ state: "forcedUP", progress: 1 })), "Ratio limit set to 2.00", "forcedUP is seeding");
  assert.equal(V.doneNote("ratioLimit", 2, null), "Ratio limit set to 2.00");
});
