#!/usr/bin/env bash
# tests/live/rss-probe.sh: a MANUAL probe of `qbt rss` against the real
# qBittorrent 5.2.3 (slice 5b1). It is never run in CI or by the test
# suites; the controller runs it by hand, on a machine whose qBittorrent may
# be changed for a minute.
#
# What it does, and undoes:
#   - checks `qbt probe` names a localhost base and qBittorrent answers;
#   - stops (exit 1) when rss_processing_enabled is on, since a real addFeed
#     then refreshes every feed the user has (rss_session.cpp:166-167);
#   - reads proxy_rss and proxy_type: when a proxy applies to RSS, the fetch
#     checks are skipped with the reason (OV12), since qBittorrent would
#     fetch the local feed through the proxy;
#   - serves tests/live/rss-feed.xml (a magnet item and a news item with no
#     enclosure) with `python3 -m http.server` on 127.0.0.1 and a random port;
#   - `qbt rss add-folder omaqbt-probe`, then `add-feed` under it (add-feed
#     refreshes the new feed, so this works while RSS processing is off);
#   - waits up to 20 s for both articles, then checks that the news item's
#     torrentURL equals its link, that hasTorrent is false for it and true
#     for the magnet, that markAsRead on a missing path answers 200 or 204 through
#     the raw API, and that a GET on rss/addFolder answers 405 (its path is
#     inside omaqbt-probe, so if it ever made a folder, cleanup removes it);
#   - slice 5b2's rules pass, on the same throwaway feed (auto-download must
#     be off; the probe stops otherwise, and never turns a rule on):
#     `rule-create omaqbt-probe-rule` (disabled, on the probe feed);
#     `rule-set` mustContain to the magnet item's title; `rule-preview` has
#     the magnet in will and nothing in noTorrent (matchingArticles through
#     qbt); a torrentParams round trip (tags set through the raw setRule
#     survive a qbt save, and every other key reads back as it was);
#     `rule-rename` onto a second rule's name is refused with ruleExists;
#     the raw renameRule onto it answers 200 and changes nothing;
#     `rule-remove` both;
#   - removes omaqbt-probe and both rules and stops the http server, on
#     every exit (trap).
# It refuses to start when a feed or folder called omaqbt-probe, or a rule
# called omaqbt-probe-rule or omaqbt-probe-rule-2, exists.
#
# Env: QBT (default: the repo's qbt), RSS_PROBE_PORT (default: a free port),
# RSS_PROBE_WAIT (seconds, default 20). QBT_BASE and the other qbt
# variables pass through, so it can be dry-run against the test fixture.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
QBT=${QBT:-$HERE/../../qbt}
FOLDER=omaqbt-probe
FEED="$FOLDER\\feed"
RULE=omaqbt-probe-rule
RULE2=omaqbt-probe-rule-2
WAIT=${RSS_PROBE_WAIT:-20}
fails=0
server_pid=""
added=0
rules_added=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf 'skip - %s\n' "$1"; }
stop() { printf 'rss-probe: %s\n' "$1" >&2; exit 1; }

# `qbt rss <sub>` with its values NUL-joined on stdin.
rss() {
  local sub=$1
  shift
  if (( $# == 0 )); then
    "$QBT" rss "$sub" </dev/null
    return
  fi
  local IFS=
  { printf '%s' "$1"; shift; (( $# == 0 )) || printf '\0%s' "$@"; } | "$QBT" rss "$sub"
}

cleanup() {
  local rc=$?
  if (( rules_added )); then
    local r
    for r in "$RULE" "$RULE2"; do
      if rss rule-remove "$r" >/dev/null 2>&1; then
        printf 'cleanup: removed rule %s\n' "$r"
      elif rss rules 2>/dev/null | jq -e --arg r "$r" 'all(.rules[]; .name != $r)' >/dev/null 2>&1; then
        :
      else
        printf 'cleanup: could not remove rule %s; remove it in qBittorrent by hand\n' "$r" >&2
      fi
    done
  fi
  if (( added )); then
    # added is set before add-folder, so the folder may never have landed.
    if rss remove "$FOLDER" >/dev/null 2>&1; then
      printf 'cleanup: removed %s\n' "$FOLDER"
    elif rss items 2>/dev/null | jq -e --arg f "$FOLDER" 'all(.feeds[]; .path != $f)' >/dev/null 2>&1; then
      printf 'cleanup: %s is already gone\n' "$FOLDER"
    else
      printf 'cleanup: could not remove %s; remove it in qBittorrent by hand\n' "$FOLDER" >&2
    fi
  fi
  if [[ -n $server_pid ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

probe=$("$QBT" probe) || stop "qbt probe failed"
base=$(printf '%s' "$probe" | jq -r '.base')
[[ $base =~ ^http://127\.0\.0\.1:[[:digit:]]{1,5}$ ]] || stop "qbt's base isn't http://127.0.0.1:<port>"
items=$(rss items) || stop "qBittorrent isn't answering qbt rss items"
pass "qbt probe is localhost ($base) and qBittorrent answers"
if printf '%s' "$items" | jq -e --arg f "$FOLDER" 'any(.feeds[]; .path == $f)' >/dev/null; then
  stop "a feed or folder called $FOLDER already exists; remove it first"
fi

prefs=$("$QBT" prefs) || stop "qbt prefs failed"
proxy_rss=$(printf '%s' "$prefs" | jq -r '.proxy_rss')
proxy_type=$(printf '%s' "$prefs" | jq -r '.proxy_type')
if [[ $(printf '%s' "$prefs" | jq -r '.rss_processing_enabled') == true ]]; then
  stop "RSS processing is on; turn it off (Settings → RSS) before running the probe, or it refreshes every feed."
fi
if [[ $(printf '%s' "$prefs" | jq -r '.rss_auto_downloading_enabled') != false ]]; then
  stop "RSS auto-downloading is on; turn it off (Settings → RSS) before running the probe, or its rules pass could download."
fi
rules=$(rss rules) || stop "qbt rss rules failed"
if printf '%s' "$rules" | jq -e --arg a "$RULE" --arg b "$RULE2" 'any(.rules[]; .name == $a or .name == $b)' >/dev/null; then
  stop "a rule called $RULE or $RULE2 already exists; remove it first"
fi
skip_fetch=""
if [[ $proxy_rss == true && $proxy_type != None ]]; then
  skip_fetch="RSS goes through the $proxy_type proxy (proxy_rss), which can't reach 127.0.0.1 (OV12)"
fi

port=${RSS_PROBE_PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$HERE" >/dev/null 2>&1 &
server_pid=$!
feed_url="http://127.0.0.1:$port/rss-feed.xml"
for _ in $(seq 50); do
  curl -sf --noproxy '*' -o /dev/null "$feed_url" && break
  sleep 0.1
done
curl -sf --noproxy '*' -o /dev/null "$feed_url" || stop "the local feed server didn't start"
pass "serving $feed_url"

# Set before the call: the pre-check above proved omaqbt-probe didn't exist,
# so whatever add-folder leaves behind (a POST that landed before a timeout
# or a read-back miss) is ours to remove.
added=1
out=$(rss add-folder "$FOLDER") || stop "add-folder failed"
[[ $(printf '%s' "$out" | jq -c .) == "{\"ok\":true,\"path\":\"$FOLDER\"}" ]] && pass "add-folder $FOLDER" \
  || fail "add-folder answered $out"
out=$(rss add-feed "$feed_url" "$FEED") || stop "add-feed failed"
[[ $(printf '%s' "$out" | jq -r .path) == "$FEED" ]] && pass "add-feed under $FOLDER" || fail "add-feed answered $out"

if [[ -n $skip_fetch ]]; then
  skip "the fetch checks: $skip_fetch"
else
  got=0
  for _ in $(seq $(( WAIT * 2 ))); do
    items=$(rss items)
    got=$(printf '%s' "$items" | jq --arg p "$FEED" '[.articles[] | select(.feedPath == $p)] | length')
    (( got >= 2 )) && break
    sleep 0.5
  done
  if (( got >= 2 )); then
    pass "both articles arrived within ${WAIT} s"
    art() { printf '%s' "$items" | jq -c --arg p "$FEED" --arg g "$1" '.articles[] | select(.feedPath == $p and .guid == $g)'; }
    news=$(art omaqbt-probe-news)
    magnet=$(art omaqbt-probe-magnet)
    [[ $(printf '%s' "$news" | jq '.torrentURL == .link and .link != ""') == true ]] \
      && pass "the news item's torrentURL falls back to its link" || fail "news item: $news"
    [[ $(printf '%s' "$news" | jq '.hasTorrent') == false ]] && pass "hasTorrent is false for the news item" \
      || fail "news item hasTorrent: $news"
    [[ $(printf '%s' "$magnet" | jq '.hasTorrent and (.torrentURL | startswith("magnet:?"))') == true ]] \
      && pass "hasTorrent is true for the magnet" || fail "magnet item: $magnet"
    [[ $(printf '%s' "$news" | jq '.date != null') == true && $(printf '%s' "$magnet" | jq '.date != null') == true ]] \
      && pass "both articles have a date (qBittorrent's dates carry no weekday)" \
      || fail "an article has no date: $news $magnet"
  else
    fail "the articles didn't arrive within ${WAIT} s (got $got)"
  fi
fi

code=$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode "itemPath=$FOLDER\\no-such-feed" "$base/api/v2/rss/markAsRead" || true)
[[ $code == 200 || $code == 204 ]] && pass "markAsRead on a missing path answers $code (200 or 204)" || fail "markAsRead on a missing path: $code"
code=$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "$base/api/v2/rss/addFolder?path=omaqbt-probe%5Cget" || true)
[[ $code == 405 ]] && pass "GET rss/addFolder answers 405" || fail "GET rss/addFolder: $code"

# ---- slice 5b2: the rules pass --------------------------------------------------
rule_of() { rss rules | jq -c --arg r "$1" '.rules[] | select(.name == $r)'; }
rules_added=1
out=$(rss rule-create "$RULE" "$feed_url") || stop "rule-create failed"
[[ $(printf '%s' "$out" | jq -c .) == "{\"ok\":true,\"name\":\"$RULE\"}" ]] && pass "rule-create $RULE" \
  || fail "rule-create answered $out"
rule=$(rule_of "$RULE")
[[ $(printf '%s' "$rule" | jq --arg u "$feed_url" '.enabled == false and .fields.affectedFeeds == [$u]') == true ]] \
  && pass "the new rule is disabled, on the probe feed" || fail "new rule: $rule"
out=$(rss rule-set "$RULE" '{"mustContain":"OmaqBT probe magnet"}' '{"mustContain":"","enabled":false}' keep) \
  && [[ $out == '{"ok":true}' ]] && pass "rule-set mustContain" || fail "rule-set answered ${out:-nothing}"
if [[ -n $skip_fetch ]]; then
  skip "the rule preview: $skip_fetch"
else
  preview=$(rss rule-preview "$RULE") || preview=""
  if [[ $(printf '%s' "$preview" | jq '[.will[].guid] == ["omaqbt-probe-magnet"]') == true ]] \
    && [[ $(printf '%s' "$preview" | jq '.noTorrent == [] or [.noTorrent[].guid] == ["omaqbt-probe-news"]') == true ]]; then
    pass "rule-preview: the magnet would download, and nothing without a torrent link does"
  else
    fail "rule-preview answered ${preview:-nothing}"
  fi
fi
# A torrentParams round trip: tags set through the raw setRule (qbt never
# edits them) survive a qbt save, and every other key reads back as it was.
before=$(rule_of "$RULE" | jq -c '.raw | .torrentParams.tags = ["omaqbt-probe"]')
code=$(printf '%s' "$before" | curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode "ruleName=$RULE" --data-urlencode "ruleDef@-" "$base/api/v2/rss/setRule" || true)
[[ $code == 200 ]] || fail "raw setRule with tags: $code"
before=$(rule_of "$RULE" | jq -c '.raw')
out=$(rss rule-set "$RULE" '{"ignoreDays":1}' '{"ignoreDays":0,"enabled":false}' keep) || out=""
after=$(rule_of "$RULE" | jq -c '.raw')
if [[ $out == '{"ok":true}' ]] && [[ $(printf '%s' "$after" | jq '.torrentParams.tags == ["omaqbt-probe"] and .ignoreDays == 1') == true ]] \
  && [[ $(printf '%s\n%s' "$before" "$after" | jq -s '(.[0] | del(.ignoreDays)) == (.[1] | del(.ignoreDays))') == true ]]; then
  pass "a torrentParams round trip: the tags and every other key survive a save"
else
  fail "torrentParams round trip: before $before after $after (${out:-no answer})"
fi
out=$(rss rule-create "$RULE2" "") || fail "rule-create $RULE2 failed"
err=$(rss rule-rename "$RULE" "$RULE2" 2>&1 >/dev/null) && fail "rule-rename onto $RULE2 was taken" \
  || { [[ $err == "There's already a rule called $RULE2." ]] && pass "rule-rename onto an existing name is refused" \
    || fail "rule-rename onto $RULE2: $err"; }
code=$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode "ruleName=$RULE" --data-urlencode "newRuleName=$RULE2" "$base/api/v2/rss/renameRule" || true)
names=$(rss rules | jq -c --arg a "$RULE" --arg b "$RULE2" '[.rules[].name | select(. == $a or . == $b)]')
[[ $code == 200 && $names == "[\"$RULE\",\"$RULE2\"]" ]] \
  && pass "the raw renameRule onto an existing name answers 200 and changes nothing" \
  || fail "raw renameRule clash: $code, rules $names"
out=$(rss rule-remove "$RULE") && out2=$(rss rule-remove "$RULE2") \
  && [[ $out == '{"ok":true}' && $out2 == '{"ok":true}' ]] && rules_added=0
(( rules_added == 0 )) && pass "rule-remove both rules" || fail "rule-remove answered ${out:-nothing} ${out2:-}"

out=$(rss remove "$FOLDER") && added=0
[[ $added == 0 && $out == '{"ok":true}' ]] && pass "remove $FOLDER" || fail "remove answered ${out:-nothing}"

if (( fails )); then
  printf '%d check(s) failed\n' "$fails"
  exit 1
fi
printf 'rss-probe ok\n'
