#!/usr/bin/env python3
"""Pure unit tests for lib/speedhist.py: every case drives `now` directly
(no sleeping, no patched clock -- SpeedHistory takes it as a plain
argument), so these run in well under a second."""
import sys
import unittest
from array import array
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import speedhist  # noqa: E402

H = "a" * 40


def torrents(**by_hash):
    """{"h1": (dl, up), ...} -> the maindata-shaped map record() expects."""
    return {h: {"dlspeed": dl, "upspeed": up} for h, (dl, up) in by_hash.items()}


class BucketingTests(unittest.TestCase):
    def test_two_samples_in_one_second_keep_one_slot(self):
        sh = speedhist.SpeedHistory()
        sh.record(torrents(**{H: (100, 0)}), 1000.1)
        sh.record(torrents(**{H: (200, 0)}), 1000.9)
        pts = sh.points(H)
        self.assertEqual(len(pts), 1)
        self.assertEqual(pts[0], [1000.0, 200.0, 0.0])

    def test_a_new_second_appends_a_new_slot(self):
        sh = speedhist.SpeedHistory()
        sh.record(torrents(**{H: (100, 0)}), 1000)
        sh.record(torrents(**{H: (200, 0)}), 1001)
        pts = sh.points(H)
        self.assertEqual([p[0] for p in pts], [1000.0, 1001.0])
        self.assertEqual([p[1] for p in pts], [100.0, 200.0])


class SlotCapTests(unittest.TestCase):
    def test_600_slot_cap_drops_the_oldest(self):
        sh = speedhist.SpeedHistory()
        for i in range(601):
            sh.record(torrents(**{H: (i + 1, 0)}), 1000 + i)
        pts = sh.points(H)
        self.assertEqual(len(pts), speedhist.MAX_SLOTS)
        # The oldest second (1000, dl=1) was dropped; the newest (1600,
        # dl=601) survives.
        self.assertEqual(pts[0][0], 1001.0)
        self.assertEqual(pts[0][1], 2.0)
        self.assertEqual(pts[-1][0], 1600.0)
        self.assertEqual(pts[-1][1], 601.0)

    def test_a_slow_cadence_is_still_trimmed_to_a_600s_window_by_age(self):
        # One sample every 60s for 16 ticks (900s of wall-clock span): far
        # under the 600-slot count cap (only 16 slots), but the window
        # itself must still be capped at 600s -- 600 slots only mean 10
        # minutes when sampling is at least once a second; at any slower
        # cadence the count cap alone would let the buffer span hours.
        sh = speedhist.SpeedHistory()
        for i in range(16):
            sh.record(torrents(**{H: (5, 0)}), 60 * i)
        pts = sh.points(H)
        # t=0..900 in steps of 60; only 300..900 (the last 600s) survive.
        self.assertEqual([p[0] for p in pts], [60.0 * i for i in range(5, 16)])


class CreationTests(unittest.TestCase):
    def test_a_zero_sample_never_creates_a_buffer(self):
        sh = speedhist.SpeedHistory()
        sh.record(torrents(**{H: (0, 0)}), 1000)
        self.assertEqual(sh.points(H), [])

    def test_a_non_zero_sample_creates_it(self):
        sh = speedhist.SpeedHistory()
        sh.record(torrents(**{H: (0, 0)}), 1000)
        sh.record(torrents(**{H: (5, 0)}), 1001)
        self.assertEqual(sh.points(H), [[1001.0, 5.0, 0.0]])


class StaleTests(unittest.TestCase):
    def test_dropped_once_600s_pass_with_no_non_zero_sample(self):
        sh = speedhist.SpeedHistory()
        sh.record(torrents(**{H: (5, 0)}), 1000)
        # Still present, still zero, but not yet 600s since the last
        # non-zero sample: kept.
        sh.record(torrents(**{H: (0, 0)}), 1000 + speedhist.STALE_SECONDS)
        self.assertNotEqual(sh.points(H), [])
        # One tick further: now strictly more than 600s since 1000 -> gone.
        sh.record(torrents(**{H: (0, 0)}), 1000 + speedhist.STALE_SECONDS + 1)
        self.assertEqual(sh.points(H), [])


class LeavesMaindataTests(unittest.TestCase):
    def test_dropped_when_absent_from_the_next_record_call(self):
        sh = speedhist.SpeedHistory()
        sh.record(torrents(**{H: (5, 0)}), 1000)
        self.assertNotEqual(sh.points(H), [])
        sh.record({}, 1001)
        self.assertEqual(sh.points(H), [])


class HardCapTests(unittest.TestCase):
    def test_200_cap_evicts_the_least_recently_active(self):
        sh = speedhist.SpeedHistory()
        hashes = [format(i, "040x") for i in range(1, 202)]
        # Tick i keeps every earlier hash alive (present, zero speed --
        # never touching their own last_nonzero_at) and gives exactly the
        # new hash a non-zero sample, so each buffer's last_nonzero_at is
        # its own creation tick, strictly increasing in creation order.
        for i, h in enumerate(hashes, start=1):
            row = {prev: (0, 0) for prev in hashes[: i - 1]}
            row[h] = (5, 0)
            sh.record(torrents(**row), i)
        self.assertEqual(sh.points(hashes[0]), [], "the oldest buffer was evicted")
        for h in hashes[1:]:
            self.assertNotEqual(sh.points(h), [], h)


class SamplesShapeTests(unittest.TestCase):
    def test_points_is_a_plain_list_of_float_triples(self):
        sh = speedhist.SpeedHistory()
        sh.record(torrents(**{H: (1887436, 0)}), 1000)
        pts = sh.points(H)
        self.assertEqual(pts, [[1000.0, 1887436.0, 0.0]])
        for row in pts:
            self.assertEqual(len(row), 3)

    def test_negative_or_non_numeric_speeds_read_as_zero(self):
        sh = speedhist.SpeedHistory()
        sh.record({H: {"dlspeed": -5, "upspeed": "nope"}}, 1000)
        self.assertEqual(sh.points(H), [])

    def test_missing_speed_fields_read_as_zero(self):
        sh = speedhist.SpeedHistory()
        sh.record({H: {}}, 1000)
        self.assertEqual(sh.points(H), [])


class RingBufferInternalsTests(unittest.TestCase):
    """The array module types F9 requires."""

    def test_time_column_is_double_speed_columns_are_float(self):
        sh = speedhist.SpeedHistory()
        sh.record(torrents(**{H: (5, 0)}), 1000)
        buf = sh._buffers[H]
        self.assertEqual(buf.t.typecode, "d")
        self.assertEqual(buf.dl.typecode, "f")
        self.assertEqual(buf.up.typecode, "f")


if __name__ == "__main__":
    unittest.main()
