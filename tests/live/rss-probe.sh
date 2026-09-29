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
#     for the magnet, that markAsRead on a missing path answers 200 through
#     the raw API, and that a GET on rss/addFolder answers 405 (its path is
#     inside omaqbt-probe, so if it ever made a folder, cleanup removes it);
#   - removes omaqbt-probe and stops the http server, on every exit (trap).
# It refuses to start when a feed or folder called omaqbt-probe exists.
#
# Env: QBT (default: the repo's qbt), RSS_PROBE_PORT (default: a free port),
# RSS_PROBE_WAIT (seconds, default 20). QBT_BASE and the other qbt
# variables pass through, so it can be dry-run against the test fixture.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
QBT=${QBT:-$HERE/../../qbt}
FOLDER=omaqbt-probe
FEED="$FOLDER\\feed"
WAIT=${RSS_PROBE_WAIT:-20}
fails=0
server_pid=""
added=0

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
[[ $code == 200 ]] && pass "markAsRead on a missing path answers 200" || fail "markAsRead on a missing path: $code"
code=$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "$base/api/v2/rss/addFolder?path=omaqbt-probe%5Cget" || true)
[[ $code == 405 ]] && pass "GET rss/addFolder answers 405" || fail "GET rss/addFolder: $code"

out=$(rss remove "$FOLDER") && added=0
[[ $added == 0 && $out == '{"ok":true}' ]] && pass "remove $FOLDER" || fail "remove answered ${out:-nothing}"

if (( fails )); then
  printf '%d check(s) failed\n' "$fails"
  exit 1
fi
printf 'rss-probe ok\n'
