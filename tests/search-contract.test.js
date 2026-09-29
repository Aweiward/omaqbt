// Slice 5a (Task 1): the shared Search contract's own consistency. The
// lanes test their code against tests/fixtures/search-rules-cases.json;
// this pins the file's shape, and that every sentence the contract quotes
// is the case file's (so neither can drift from the other).
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const FIX = path.join(__dirname, "fixtures");
const data = JSON.parse(fs.readFileSync(path.join(FIX, "search-rules-cases.json"), "utf8"));
// The pageLink and magnetHash rows moved to link-rules-cases.json (slice 5b0).
data.cases = data.cases.concat(JSON.parse(fs.readFileSync(path.join(FIX, "link-rules-cases.json"), "utf8")).cases);
const contract = fs.readFileSync(path.join(FIX, "search-contract.md"), "utf8");

const KINDS = ["pluginUrl", "pageLink", "addLink", "magnetHash", "row", "pluginName", "pattern", "category", "searchId", "installReadback"];

test("search cases: every case has the documented shape", () => {
  assert.equal(typeof data._doc, "string");
  assert.ok(Array.isArray(data.cases) && data.cases.length > 100);
  for (const c of data.cases) {
    const label = c.kind + " " + JSON.stringify(c.input);
    assert.ok(KINDS.includes(c.kind), label);
    assert.ok("input" in c, label);
    assert.equal(typeof c.ok, "boolean", label);
    assert.equal(typeof c.why, "string", label);
    assert.equal("message" in c, c.ok === false && c.kind !== "magnetHash", label + ": a message exactly when refused");
    if ("message" in c) assert.match(c.message, /^\S.*[.)]$/, label);
    if (c.ok !== true) assert.ok(!("normalised" in c) && !("host" in c), label);
    for (const k of Object.keys(c)) assert.ok(["kind", "input", "ok", "normalised", "host", "message", "why"].includes(k), label + " " + k);
  }
  for (const kind of KINDS) {
    const of = data.cases.filter((c) => c.kind === kind);
    assert.ok(of.some((c) => c.ok), kind + " has an ok case");
    // A row is never refused: sanitising always shows something.
    if (kind === "row") assert.ok(of.every((c) => c.ok), "rows are always shown");
    else assert.ok(of.some((c) => !c.ok), kind + " has a refused case");
  }
});

test("search cases: the brief's required cases are there", () => {
  const has = (kind, pred) => data.cases.some((c) => c.kind === kind && pred(c));
  assert.ok(has("pluginUrl", (c) => /^HTTPS:/.test(c.input) && c.ok), "an uppercase scheme");
  assert.ok(has("pluginUrl", (c) => c.input.includes("@") && !c.ok), "userinfo");
  assert.ok(has("pluginUrl", (c) => c.host && c.host.startsWith("xn--")), "an IDN host as punycode");
  assert.ok(has("pluginUrl", (c) => c.input.includes("|") && !c.ok), "|");
  assert.ok(has("pluginUrl", (c) => / /.test(c.input) && !c.ok), "whitespace");
  assert.ok(has("pluginUrl", (c) => c.input.includes("%20") && !c.ok), "%20");
  assert.ok(has("pluginUrl", (c) => c.input.endsWith(".PY") && c.ok && c.normalised === "Jackett"), ".PY");
  assert.ok(has("pluginUrl", (c) => c.input.endsWith("?x=1") && c.normalised === "jackett"), "?x=1");
  for (const s of ["javascript:", "file:", "data:"]) assert.ok(has("pageLink", (c) => c.input.startsWith(s) && c.message === "That page link isn't http or https."), s);
  assert.ok(has("addLink", (c) => c.normalised === "plugin"));
  assert.ok(has("addLink", (c) => c.normalised === "add" && c.input.length === 1 && /\.torrent$/.test(c.input[0])));
  assert.ok(has("addLink", (c) => c.message === "That result has no usable link."));
  assert.ok(has("magnetHash", (c) => c.ok && c.normalised.v1 && /[A-Z2-7]{32}$/i.test(c.input) && !/[0-9a-f]{40}/i.test(c.input)), "base32");
  assert.ok(has("magnetHash", (c) => c.ok && c.normalised.v2 && c.input.includes("btmh:1220")), "btmh");
  assert.ok(has("row", (c) => c.normalised.size === "—" && c.normalised.seeds === "—"));
  assert.ok(has("row", (c) => /[‪-‮⁦-⁩]/.test(c.input.fileName) && !/[‪-‮⁦-⁩]/.test(c.normalised.name)));
  assert.ok(has("row", (c) => c.normalised.name.endsWith("…")));
  assert.ok(has("installReadback", (c) => c.message === "jackett v4.0 is already installed."), "a same-version reinstall");
});

test("search cases: every sentence and every window line is quoted in the contract exactly", () => {
  for (const group of ["sentences", "window"]) {
    for (const [k, s] of Object.entries(data[group])) assert.ok(contract.includes(s), group + "." + k + ": " + s);
  }
  // The rules' messages the contract names by sentence.
  for (const s of ["That result has no usable link.", "Plugin names use only letters, digits and _.", "That isn't a search id."]) {
    assert.ok(data.cases.some((c) => c.message === s), s);
  }
  assert.ok(contract.includes("That result has no usable link."));
});

test("search cases: the 409 sentences and the done notes are the brief's", () => {
  assert.equal(data.sentences.cap, "qBittorrent is running 5 searches; stop one first.");
  assert.equal(data.sentences.noPython, "Search needs Python on this machine.");
  assert.equal(data.sentences.installUnconfirmed, "Couldn't confirm the install of <name>.");
  assert.equal(data.window.added, "Added <name>.");
  assert.equal(data.window.sent, "Sent <name> to qBittorrent · it appears when its download finishes.");
  assert.equal(data.window.gone, "The search ended when qBittorrent restarted.");
});

test("search cases, Ruling FB: a backslash is refused in every URL kind, and the host rule is pinned", () => {
  const find = (kind, input) => data.cases.find((c) => c.kind === kind && JSON.stringify(c.input) === JSON.stringify(input));
  for (const kind of ["pluginUrl", "pageLink", "addLink"]) {
    assert.ok(data.cases.some((c) => c.kind === kind && JSON.stringify(c.input).includes("\\\\") && !c.ok), kind + " refuses a backslash");
  }
  const want = [
    ["pluginUrl", "https://exa%6dple.org/jackett.py", false],
    ["pluginUrl", "https://example.org./jackett.py", false],
    ["pluginUrl", "https://192.0.2.10/jackett.py", true],
    ["pluginUrl", "https://nas/jackett.py", true],
    ["pluginUrl", "https://example.org:8443/eztv_v2.py", true],
    ["pluginUrl", "https://example.org:65535/jackett.py", true],
    ["pluginUrl", "https://example.org:65536/jackett.py", false],
    ["pluginUrl", "https://example.org:0/jackett.py", false],
    ["pluginUrl", "https://example.org:/jackett.py", false],
    ["pageLink", "https://exa%6dple.org/t/1", false],
    ["pageLink", "https://example.org./t/1", false],
    ["pageLink", "http://192.0.2.10:8080/t/1", true],
    ["pageLink", "http://localhost/t/1", true],
    ["addLink", ["https://exa%6dple.org/dl/debian.torrent"], false],
    ["addLink", ["https://example.org:8443/dl/debian.torrent"], true]
  ];
  for (const [kind, input, ok] of want) {
    const c = find(kind, input);
    assert.ok(c, kind + " " + JSON.stringify(input) + " is a case");
    assert.equal(c.ok, ok, kind + " " + JSON.stringify(input));
  }
  // The length limit, pinned at the boundary.
  const long = data.cases.filter((c) => c.kind === "pluginUrl" && c.input.length > 2000);
  assert.deepEqual(long.map((c) => [c.input.length, c.ok]).sort(), [[2048, true], [2049, false]]);
  assert.match(data._doc, /never by a URL library/);
});

test("search contract, Ruling FB: the final reply, total's source, and no Service-start cleanup are written down", () => {
  assert.ok(contract.includes("A reply is **final** when `status` is `\"Stopped\"` AND `offset + rows.length == min(total, 2000)`"));
  assert.ok(contract.includes("The sidecar always sends the final reply, even with zero rows, and then drops the watch."));
  assert.ok(contract.includes("`reply.offset` is the offset before the reply's rows"));
  assert.ok(contract.includes("then deletes the job with `qbt search delete <id>`"));
  assert.ok(contract.includes("The reply's `status`, `total` and `rows` all come from that one `results` response"));
  assert.ok(contract.includes("A crash leftover is deleted by the next `qbt search start`"));
  assert.ok(contract.includes("Nothing reads `search.id` when Service starts"));
  assert.ok(contract.includes("never by a URL library"));
  assert.ok(contract.includes("**`c`** (`search.category`"));
});
