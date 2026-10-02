const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const Registry = require("../CommandRegistry.js");

const root = path.join(__dirname, "..");
const readme = fs.readFileSync(path.join(root, "README.md"), "utf8");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"));

// The text under a heading, up to the next heading of the same or a higher level.
function section(heading) {
  const level = heading.match(/^#+/)[0].length;
  const lines = readme.split("\n");
  const start = lines.indexOf(heading);
  assert.notEqual(start, -1, "README has the heading " + heading);
  const out = [];
  for (let i = start + 1; i < lines.length; i++) {
    const m = lines[i].match(/^(#+) /);
    if (m && m[1].length <= level) break;
    out.push(lines[i]);
  }
  return out.join("\n");
}

test("README splits Usage into the popup and the window", () => {
  const usage = section("## Usage");
  assert.ok(usage.includes("### The popup"), "### The popup is under ## Usage");
  assert.ok(usage.includes("### The window"), "### The window is under ## Usage");
});

test("the window section has the toggle command and the exact Hyprland bind line", () => {
  const windowText = section("### The window");
  assert.ok(windowText.includes("omarchy-shell shell toggle aweiward.omaqbt"), "the toggle command is in the window section");
  const bindLine = "bindd = SUPER SHIFT, Q, OmaqBT window, exec, omarchy-shell shell toggle aweiward.omaqbt";
  const conf = windowText.indexOf("~/.config/hypr/bindings.conf");
  const bind = windowText.indexOf(bindLine);
  assert.notEqual(conf, -1, "the window section names ~/.config/hypr/bindings.conf");
  assert.notEqual(bind, -1, "the bind line is exact and in the window section");
  assert.ok(bind > conf && bind - conf < 200, "the bind line follows the bindings.conf mention");
});

test("each documented window opener maps to its registry id", () => {
  const windowText = section("### The window");
  const openers = [
    { key: "F", id: "search.open", pane: "table" },
    { key: "N", id: "rss.open", pane: "table" },
    { key: ",", id: "settings.open", pane: "table" },
    { key: ":", id: "palette.open", pane: "table" },
    { key: "?", id: "help.toggle", pane: "table" },
    { key: "R", id: "rss.rules", pane: "rssFeeds" }
  ];
  for (const o of openers) {
    assert.ok(windowText.includes("`" + o.key + "`"), "README documents `" + o.key + "`");
    const row = Registry.commands.find((c) => c.id === o.id && c.keys.includes(o.key) && c.modes.includes("NORMAL"));
    assert.ok(row, o.id + " is bound to " + o.key + " in NORMAL mode");
    const reaches = row.panes.includes(o.pane) || row.panes.includes("*");
    assert.ok(reaches, o.id + " works from the " + o.pane + " pane");
  }
  assert.ok(windowText.includes("`?` lists each view's keys"));
});

test("each window key sits on a line with its label", () => {
  const windowText = section("### The window");
  const pairs = [
    /`F`[^\n]*Search/,
    /`N`[^\n]*RSS/,
    /`,`[^\n]*Settings/,
    /`:`[^\n]*palette/,
    /`\?`[^\n]*(keys|help)/,
    /`R`[^\n]*[Rr]ules/
  ];
  for (const re of pairs) assert.match(windowText, re);
});

test("the popup section documents the Open the window row and its keys", () => {
  const popup = section("### The popup");
  assert.ok(popup.includes("**Open the window**"), "the row label is documented");
  const line = popup.split("\n").find((l) => l.includes("**Open the window**")) || "";
  assert.ok(line.includes("`w`"), "w is documented on the row's line");
  assert.match(line, /Enter/, "Enter on the row is documented");
  assert.match(line, /click/, "a click on the row is documented");
});

test("user-facing README prose never says panel", () => {
  // The one allowed sentence explains Omarchy's manifest kind.
  const prose = readme
    .split("\n")
    .filter((l) => !/manifest kind/i.test(l))
    .join("\n");
  assert.equal(/\bpanels?\b/i.test(prose), false, "found: " + (prose.match(/.*\bpanels?\b.*/i) || [""])[0]);
});

test("manifest is 2.1.2 and both descriptions name the window", () => {
  assert.equal(manifest.version, "2.1.2");
  assert.match(manifest.description, /window/);
  assert.match(manifest.barWidget.description, /window/);
});
