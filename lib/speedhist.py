"""In-memory per-torrent speed-history ring buffer for `qbt-serve`'s chart
tab (F9/OV3).

`SpeedHistory` has no clock of its own: every call takes `now` (wall-clock
seconds, `time.time()`) as an explicit argument, so a test drives time by
simply passing whatever `now` it likes -- no sleeping, no patched clock.
`qbt-serve` calls `record()` once per tick, right after a maindata fetch
actually lands (never on a tick that reused stale data), and `points()`
from the chart watch's read path.
"""
from array import array

# F9: at most 600 one-second slots per torrent (also the chart's window,
# InspectorView.CHART_SPAN_SECONDS), and at most 200 torrents tracked at
# once.
MAX_SLOTS = 600
MAX_BUFFERS = 200
STALE_SECONDS = 600.0


def _rate(value):
    """A maindata `dlspeed`/`upspeed` field as a non-negative float; any
    other value (missing, negative, non-numeric) is 0.0."""
    try:
        n = float(value)
    except (TypeError, ValueError):
        return 0.0
    return n if n > 0.0 else 0.0


class _Buffer:
    """One torrent's ring buffer: parallel `array` columns (F9 -- `t` is
    `array('d')` since epoch seconds don't fit `float32` precisely; `dl`
    and `up` are `array('f')`), plus the wall-clock time of its last
    non-zero sample, the buffer's own eviction clock."""

    __slots__ = ("t", "dl", "up", "last_nonzero_at")

    def __init__(self, now):
        self.t = array("d")
        self.dl = array("f")
        self.up = array("f")
        self.last_nonzero_at = now


class SpeedHistory:
    """The sidecar's whole speed-history state: one `_Buffer` per hash."""

    def __init__(self):
        self._buffers = {}

    def record(self, torrents, now):
        """One tick's worth of samples: `torrents` is the merged maindata
        map (hash -> torrent dict with `dlspeed`/`upspeed`), exactly
        `qbtsync.SyncState.torrents` after a successful fetch. Buckets
        each torrent's sample into whole-second slots, ages out buffers
        whose traffic stopped more than `STALE_SECONDS` ago or whose
        torrent is no longer present, and enforces the hard cap.

        Callers must only call this once maindata has actually been
        re-fetched this tick (`status["api"]` true in `qbt-serve`):
        `torrents` unchanged from the prior tick (a failed/skipped fetch)
        would otherwise replay the same speeds as fresh samples, or -- read
        as "every torrent left maindata" -- wipe every buffer.
        """
        torrents = torrents or {}
        bucket = float(int(now))

        for h, t in torrents.items():
            dl = _rate((t or {}).get("dlspeed"))
            up = _rate((t or {}).get("upspeed"))
            nonzero = dl > 0.0 or up > 0.0
            buf = self._buffers.get(h)
            if buf is None:
                if not nonzero:
                    continue
                buf = _Buffer(now)
                self._buffers[h] = buf
            if len(buf.t) and buf.t[-1] == bucket:
                buf.dl[-1] = dl
                buf.up[-1] = up
            else:
                buf.t.append(bucket)
                buf.dl.append(dl)
                buf.up.append(up)
                if len(buf.t) > MAX_SLOTS:
                    del buf.t[0]
                    del buf.dl[0]
                    del buf.up[0]
            if nonzero:
                buf.last_nonzero_at = now

        # The torrent left maindata entirely.
        for h in list(self._buffers):
            if h not in torrents:
                del self._buffers[h]

        # No non-zero sample in the last STALE_SECONDS.
        for h, buf in list(self._buffers.items()):
            if now - buf.last_nonzero_at > STALE_SECONDS:
                del self._buffers[h]

        # Hard cap: evict the least-recently-active buffer(s).
        while len(self._buffers) > MAX_BUFFERS:
            oldest = min(self._buffers, key=lambda k: self._buffers[k].last_nonzero_at)
            del self._buffers[oldest]

    def points(self, h):
        """The chart watch's `points` array for `h`: `[[t, dl, up], ...]`,
        oldest first; `[]` when `h` has no buffer (never sampled non-zero,
        aged out, or left maindata)."""
        buf = self._buffers.get(h)
        if buf is None:
            return []
        return [[buf.t[i], buf.dl[i], buf.up[i]] for i in range(len(buf.t))]
