#!/usr/bin/env node
// Generates the two files derived from settings-schema.json:
// - SettingsSchema.js, the schema as a `.pragma library` JS module for the
//   Settings view (QML can't read a JSON file without I/O);
// - tests/fixtures/settings-cases.json, the value boundary cases that
//   qbt's bash tests (Task 2) and the window's node tests (Task 4) share.
//
// Usage: node tools/gen-settings-schema.js          write both files
//        node tools/gen-settings-schema.js --check  exit 1 if either is stale
//
// Both outputs are deterministic (key order follows the JSON), so they're
// committed and tests/settings-schema.test.js checks they match.
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const SCHEMA_FILE = path.join(ROOT, "settings-schema.json");
const MODULE_FILE = path.join(ROOT, "SettingsSchema.js");
const CASES_FILE = path.join(ROOT, "tests", "fixtures", "settings-cases.json");

const NUMERIC = ["int", "float", "speed"];

// --- SettingsSchema.js --------------------------------------------------------

function literal(value) {
  return JSON.stringify(value, null, 1);
}

function renderModule(schema) {
  return [
    ".pragma library",
    "",
    "// GENERATED from settings-schema.json by tools/gen-settings-schema.js.",
    "// Don't edit: change the JSON and run `node tools/gen-settings-schema.js`.",
    "//",
    "// The settings schema for qBittorrent " + schema.qbittorrent + "'s /app/preferences, the",
    "// same one qbt reads through jq. settings-schema.json's _doc describes the",
    "// entry fields. No I/O, no Qt objects; it imports nothing.",
    "//",
    "// The `.pragma library` line above is QML-only. The node tests strip it",
    "// and run this file in a vm context, like LimitsView.js.",
    "",
    "// Every known key -> its entry. Composite entries (a time written as two",
    "// hidden member keys) aren't real preference keys.",
    "var SCHEMA = " + literal(schema.keys) + ";",
    "",
    "// SCHEMA's keys in display order (numeric-looking keys would reorder).",
    "var KEY_ORDER = " + literal(Object.keys(schema.keys)) + ";",
    "",
    "// The sections, in order. Deferred (RSS) keys sit outside them.",
    "var SECTIONS = " + literal(schema.sections) + ";",
    "",
    "// Keys qbt refuses to write (eng D8), as globs where * is the only",
    "// wildcard. The same list is hardcoded in qbt.",
    "var LOCKED = " + literal(schema.locked) + ";",
    "",
    "// Unknown keys matching these globs are refused in the Other section.",
    "var OTHER_REFUSED_PATTERNS = " + literal(schema.otherRefusedPatterns) + ";",
    "",
    "// True when key matches any of patterns (globs: * matches any run of",
    "// characters, everything else is literal).",
    "function matchesAny(key, patterns) {",
    "  for (var i = 0; i < patterns.length; i++) {",
    "    var parts = patterns[i].split(\"*\");",
    "    var re = new RegExp(\"^\" + parts.map(function (p) {",
    "      return p.replace(/[.+?^${}()|[\\]\\\\]/g, \"\\\\$&\");",
    "    }).join(\".*\") + \"$\");",
    "    if (re.test(key)) return true;",
    "  }",
    "  return false;",
    "}",
    "",
    "if (typeof module !== \"undefined\") {",
    "  module.exports = {",
    "    SCHEMA: SCHEMA,",
    "    KEY_ORDER: KEY_ORDER,",
    "    SECTIONS: SECTIONS,",
    "    LOCKED: LOCKED,",
    "    OTHER_REFUSED_PATTERNS: OTHER_REFUSED_PATTERNS,",
    "    matchesAny: matchesAny",
    "  };",
    "}",
    ""
  ].join("\n");
}

// --- settings-cases.json ----------------------------------------------------------

const CASES_DOC = [
  "Settings value boundary cases, GENERATED from settings-schema.json by tools/gen-settings-schema.js (don't edit).",
  "Read by qbt's bash tests (Task 2) and the Settings view's node tests (Task 4); both must accept exactly the ok ones.",
  "Every case is {key, input, ok, why}, plus only: \"qbt\" on the cases the window doesn't consume. input is the text as passed",
  "to `qbt pref-set <key> -- <input>`, in the schema's wire units. Speed cases are all only: \"qbt\": they're argv bytes/s,",
  "while the window reads a bare number as KiB/s (LimitsView) and rounds to whole KiB for step-1024 keys (Ruling DE), so the",
  "step refusal (1536) is qbt's alone. numbers: each editable int/float/speed key's min, max and sentinels (ok),",
  "then the values just outside (below min unless that's a sentinel, below the lowest negative sentinel, above max), a",
  "non-number, a decimal (ok only for floats), a speed that isn't a multiple of its step, and empty. choices: each value",
  "(ok), then an int just past the list, -1 when it isn't a value, a non-number, or for string enums a wrong-case value,",
  "an unknown name and empty. times: HH:MM for each time composite; ok cases also carry the hour and min that are",
  "written together. paths: absolute and ~/ are ok, relative is not, empty only where \"\" is the path's sentinel.",
  "texts: one-line and multiline text that must survive argv, jq, URL-encoding and the read-back unchanged; a newline",
  "is refused in one-line text."
].join(" ");

function editable(e) {
  return !e.readOnly && !e.locked && !e.deferred && !e.hidden && !e.secret;
}

function numberCases(key, e) {
  const out = [];
  const seen = new Set();
  const push = (input, ok, why) => {
    if (seen.has(input)) return;
    seen.add(input);
    const c = { key, input, ok, why };
    // Speeds are argv bytes for qbt only: the window types K/M (a bare
    // number is KiB in LimitsView) and rounds to whole KiB (Ruling DE).
    if (e.type === "speed") c.only = "qbt";
    out.push(c);
  };
  const sentinels = e.sentinels || {};
  const isFloat = e.type === "float";
  const nudge = (v, d) => String(isFloat ? Math.round((v + d) * 100) / 100 : v + d);
  push(String(e.min), true, "min");
  push(String(e.max), true, "max");
  for (const [v, label] of Object.entries(sentinels)) push(v, true, "sentinel: " + label);
  const below = nudge(e.min, isFloat ? -0.01 : -1);
  if (!(below in sentinels)) push(below, false, "below min");
  const negatives = Object.keys(sentinels).map(Number).filter((v) => v < 0);
  if (negatives.length) push(String(Math.min(...negatives) - 1), false, "below the lowest sentinel");
  push(nudge(e.max, isFloat ? 0.01 : 1), false, "above max");
  push("abc", false, "not a number");
  push("1.5", isFloat, isFloat ? "a decimal" : "not a whole number");
  if (e.step) push(String(e.step + e.step / 2), false, "not a multiple of " + e.step);
  push("", false, "empty");
  return out;
}

function choiceCases(key, e) {
  const out = e.choices.map((c) => ({ key, input: String(c.value), ok: true, why: c.label }));
  const values = e.choices.map((c) => c.value);
  if (e.type === "choice-int") {
    out.push({ key, input: String(Math.max(...values) + 1), ok: false, why: "past the last value" });
    if (!values.includes(-1)) out.push({ key, input: "-1", ok: false, why: "not a value" });
    out.push({ key, input: "abc", ok: false, why: "not a number" });
  } else {
    const first = String(values[0]);
    const wrongCase = first.toLowerCase() !== first ? first.toLowerCase() : first.toUpperCase();
    out.push({ key, input: wrongCase, ok: false, why: "wrong case: enum names are case-sensitive" });
    out.push({ key, input: "Bogus", ok: false, why: "not a value" });
    out.push({ key, input: "", ok: false, why: "empty" });
  }
  return out;
}

function timeCases(key) {
  const ok = (input, hour, min, why) => ({ key, input, ok: true, hour, min, why });
  const no = (input, why) => ({ key, input, ok: false, why });
  return [
    ok("00:00", 0, 0, "midnight"),
    ok("08:00", 8, 0, "morning"),
    ok("23:59", 23, 59, "last minute"),
    no("24:00", "hour past 23"),
    no("12:60", "minute past 59"),
    no("8:00", "HH:MM needs two hour digits"),
    no("12:5", "HH:MM needs two minute digits"),
    no("-1:00", "negative hour"),
    no("ab:cd", "not a time"),
    no("", "empty")
  ];
}

function pathCases(key, e) {
  const emptyOk = !!(e.sentinels && "" in e.sentinels);
  return [
    { key, input: "/srv/torrents", ok: true, why: "absolute" },
    { key, input: "~/Downloads", ok: true, why: "home-relative" },
    { key, input: "relative/dir", ok: false, why: "relative" },
    { key, input: "", ok: emptyOk, why: emptyOk ? "sentinel: " + e.sentinels[""] : "empty" }
  ];
}

function fidelityCases(key, multiline) {
  const texts = [
    ["a&b=c", "ampersand and equals"],
    ["a+b", "plus"],
    ["100% 20%20", "percent and an encoded-looking escape"],
    ["say \"hi\" 'there'", "quotes"],
    ["-leading-dash", "leading dash, after --"],
    ["back\\slash", "backslash"],
    ["café \u{1F98A}", "accented and non-BMP characters"],
    ["$(true) `x` ${HOME}", "shell syntax, kept literal"]
  ];
  const out = texts.map(([input, why]) => ({ key, input, ok: true, why }));
  out.push({ key, input: "line one\nline two", ok: multiline, why: multiline ? "newline in multiline text" : "newline in one-line text" });
  return out;
}

function buildCases(schema) {
  const numbers = [];
  const choices = [];
  const times = [];
  const paths = [];
  for (const [key, e] of Object.entries(schema.keys)) {
    if (!editable(e)) continue;
    if (NUMERIC.includes(e.type)) numbers.push(...numberCases(key, e));
    else if (e.choices) choices.push(...choiceCases(key, e));
    else if (e.type === "time") times.push(...timeCases(key));
    else if (e.type === "path") paths.push(...pathCases(key, e));
  }
  const texts = [...fidelityCases("app_instance_name", false), ...fidelityCases("add_trackers", true)];
  return { _doc: CASES_DOC, numbers, choices, times, paths, texts };
}

function renderCases(schema) {
  return JSON.stringify(buildCases(schema), null, 1) + "\n";
}

// --- main -------------------------------------------------------------------------

function main(argv) {
  const schema = JSON.parse(fs.readFileSync(SCHEMA_FILE, "utf8"));
  const outputs = [[MODULE_FILE, renderModule(schema)], [CASES_FILE, renderCases(schema)]];
  const check = argv.includes("--check");
  let stale = 0;
  for (const [file, text] of outputs) {
    const rel = path.relative(ROOT, file);
    const current = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
    if (current === text) continue;
    if (check) {
      console.error(rel + " is stale: run node tools/gen-settings-schema.js");
      stale++;
    } else {
      fs.writeFileSync(file, text);
      console.log("wrote " + rel);
    }
  }
  return stale ? 1 : 0;
}

if (require.main === module) process.exit(main(process.argv.slice(2)));

module.exports = { renderModule, renderCases, buildCases };
