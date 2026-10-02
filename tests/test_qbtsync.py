#!/usr/bin/env python3
import http.cookiejar
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import qbtsync  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class SanitizeTests(unittest.TestCase):
    def test_redacts_sid(self):
        self.assertEqual(qbtsync.sanitize("set SID=abc123; other"), "set SID=<redacted>; other")

    def test_redacts_sid_case_insensitive(self):
        # Detection is case-insensitive; the replacement text is always the
        # fixed-case "SID=<redacted>", same as bash sanitize().
        self.assertEqual(qbtsync.sanitize("sid=ABC123 done"), "SID=<redacted> done")

    def test_redacts_password(self):
        # The value runs up to the next ";" or whitespace only -- "&" is not
        # a boundary, matching bash sanitize()'s [^;[:space:]]* class.
        self.assertEqual(qbtsync.sanitize("password=hunter2;x=1"), "password=<redacted>;x=1")

    def test_leaves_other_text_alone(self):
        self.assertEqual(qbtsync.sanitize("HTTP 404 not found"), "HTTP 404 not found")


class AssertLocalTests(unittest.TestCase):
    def test_accepts_127001(self):
        qbtsync.assert_local("http://127.0.0.1:8080")  # must not raise

    def test_rejects_lookalike_host(self):
        with self.assertRaises(ValueError) as ctx:
            qbtsync.assert_local("http://127.0.0.1.evil.com")
        self.assertIn("refusing non-localhost host: 127.0.0.1.evil.com", str(ctx.exception))

    def test_rejects_localhost(self):
        with self.assertRaises(ValueError) as ctx:
            qbtsync.assert_local("http://localhost")
        self.assertIn("refusing non-localhost host: localhost", str(ctx.exception))


class MergeMaindataTests(unittest.TestCase):
    def setUp(self):
        self.full = json.loads((FIXTURES / "maindata-full.json").read_text())
        self.delta = json.loads((FIXTURES / "maindata-delta.json").read_text())

    def test_full_update_replaces_cache(self):
        torrents, rows = qbtsync.merge_maindata(self.full, {"stale": {"name": "old"}})
        self.assertNotIn("stale", torrents)
        self.assertEqual(len(rows), 2)
        names = {r["name"] for r in rows}
        self.assertEqual(names, {"debian.iso", "arch.iso"})

    def test_v2_only_torrent_keyed_by_infohash_v2(self):
        raw = {
            "full_update": True,
            "torrents": {
                "somekey": {
                    "name": "v2only",
                    "infohash_v2": "deadbeef" * 8,
                }
            },
        }
        torrents, rows = qbtsync.merge_maindata(raw, {})
        self.assertIn("deadbeef" * 8, torrents)
        self.assertEqual(rows[0]["hash"], "deadbeef" * 8)

    def test_rows_carry_both_infohashes_as_strings(self):
        # Ruling FG: the window's library match (OV11) reads these; "" when
        # qBittorrent doesn't send one (or sends something that isn't a string).
        v1, v2 = "ab" * 20, "cd" * 32
        raw = {
            "full_update": True,
            "torrents": {
                v1: {"name": "hybrid", "infohash_v1": v1, "infohash_v2": v2},
                "v2key": {"name": "v2only", "infohash_v1": "", "infohash_v2": v2[:62] + "ef"},
                "ef" * 20: {"name": "v1only", "infohash_v1": "ef" * 20},
                "12" * 20: {"name": "odd", "infohash_v1": None, "infohash_v2": 5},
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        got = {r["name"]: (r["infohash_v1"], r["infohash_v2"]) for r in rows}
        self.assertEqual(got, {
            "hybrid": (v1, v2),
            "v2only": ("", v2[:62] + "ef"),
            "v1only": ("ef" * 20, ""),
            "odd": ("", ""),
        })

    def test_a_delta_keeps_the_infohashes(self):
        cache_map, _ = qbtsync.merge_maindata(self.full, {})
        _, rows = qbtsync.merge_maindata(self.delta, cache_map)
        row = next(r for r in rows if r["hash"] == "a" * 40)
        self.assertEqual((row["infohash_v1"], row["infohash_v2"]), ("a" * 40, ""))

    def test_delta_merges_and_keeps_unresent_fields(self):
        cache_map, _ = qbtsync.merge_maindata(self.full, {})
        torrents, rows = qbtsync.merge_maindata(self.delta, cache_map)
        debian_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        self.assertIn(debian_hash, torrents)
        row = next(r for r in rows if r["hash"] == debian_hash)
        # delta resent progress/dlspeed/eta only
        self.assertAlmostEqual(row["progress"], 0.5)
        self.assertEqual(row["dlSpeed"], 100)
        self.assertEqual(row["eta"], 600)
        # fields the delta didn't resend must survive from the cache
        self.assertEqual(row["savePath"], "/home/user/Downloads")
        self.assertEqual(row["numSeeds"], 14)
        self.assertEqual(row["addedOn"], 1755300000)
        self.assertEqual(row["category"], "linux")
        self.assertEqual(row["tags"], ["iso", "linux"])
        self.assertEqual(row["tracker"], "tracker.example.com")

    def test_torrents_removed_drops_keys(self):
        cache_map, _ = qbtsync.merge_maindata(self.full, {})
        torrents, rows = qbtsync.merge_maindata(self.delta, cache_map)
        self.assertNotIn("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", torrents)
        self.assertEqual({r["hash"] for r in rows}, {"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})

    def test_defaults_for_missing_fields(self):
        raw = {
            "full_update": True,
            "torrents": {
                "cccccccccccccccccccccccccccccccccccccccc": {
                    "name": "bare",
                }
            },
        }
        torrents, rows = qbtsync.merge_maindata(raw, {})
        row = rows[0]
        self.assertEqual(row["ratioLimit"], -2)
        self.assertIs(row["seqDl"], False)
        self.assertEqual(row["dlSpeed"], 0)
        self.assertEqual(row["upSpeed"], 0)
        self.assertEqual(row["dlLimit"], 0)
        self.assertEqual(row["upLimit"], 0)
        self.assertEqual(row["numSeeds"], 0)
        self.assertEqual(row["numLeechs"], 0)
        self.assertEqual(row["addedOn"], 0)
        self.assertEqual(row["savePath"], "")
        self.assertEqual(row["magnetUri"], "")
        self.assertEqual(row["contentPath"], "")

    def test_ratio_limit_zero_is_not_default(self):
        raw = {
            "full_update": True,
            "torrents": {
                "dddddddddddddddddddddddddddddddddddddddd": {
                    "name": "zero-ratio",
                    "ratio_limit": 0,
                }
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["ratioLimit"], 0)

    def test_camel_case_speed_fallback(self):
        raw = {
            "full_update": True,
            "torrents": {
                "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee": {
                    "name": "camel",
                    "dlSpeed": 55,
                    "upSpeed": 77,
                }
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["dlSpeed"], 55)
        self.assertEqual(rows[0]["upSpeed"], 77)

    def test_row_category_present_and_missing(self):
        raw = {
            "full_update": True,
            "torrents": {
                "f" * 40: {"name": "cat", "category": "linux"},
                "0" * 40: {"name": "nocat"},
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        by_name = {r["name"]: r for r in rows}
        self.assertEqual(by_name["cat"]["category"], "linux")
        self.assertEqual(by_name["nocat"]["category"], "")

    def test_row_tags_split_trimmed_and_sorted(self):
        raw = {
            "full_update": True,
            "torrents": {
                "1" * 40: {"name": "tagged", "tags": " beta ,  , alpha,beta"},
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        # spaces around each entry are trimmed, empties from ", ," are
        # dropped, and the survivors come back sorted.
        self.assertEqual(rows[0]["tags"], ["alpha", "beta", "beta"])

    def test_row_tags_missing_is_empty_list(self):
        raw = {
            "full_update": True,
            "torrents": {"2" * 40: {"name": "notags"}},
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["tags"], [])

    def test_row_tracker_hostname_lowercased(self):
        raw = {
            "full_update": True,
            "torrents": {
                "3" * 40: {
                    "name": "tracked",
                    "tracker": "https://TRACKER.Example.COM:6969/announce",
                },
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["tracker"], "tracker.example.com")

    def test_row_tracker_missing_is_empty(self):
        raw = {
            "full_update": True,
            "torrents": {"4" * 40: {"name": "untracked"}},
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["tracker"], "")

    def test_row_tracker_malformed_url_is_empty(self):
        raw = {
            "full_update": True,
            "torrents": {
                "5" * 40: {"name": "badtracker", "tracker": "http://[::1"},
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["tracker"], "")

    def test_row_auto_tmm_true(self):
        raw = {
            "full_update": True,
            "torrents": {
                "6" * 40: {"name": "managed", "auto_tmm": True},
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertIs(rows[0]["autoTmm"], True)

    def test_row_auto_tmm_missing_defaults_false(self):
        raw = {
            "full_update": True,
            "torrents": {"7" * 40: {"name": "unmanaged"}},
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertIs(rows[0]["autoTmm"], False)

    def test_row_auto_tmm_survives_delta_that_does_not_resend_it(self):
        cache_map, _ = qbtsync.merge_maindata(self.full, {})
        _, rows = qbtsync.merge_maindata(self.delta, cache_map)
        debian_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        row = next(r for r in rows if r["hash"] == debian_hash)
        self.assertIs(row["autoTmm"], True)

    # -- slice 3b, Task 2: per-torrent share/toggle fields ------------------

    def test_row_share_fields_present(self):
        raw = {
            "full_update": True,
            "torrents": {
                "f0" * 20: {
                    "name": "shared",
                    "progress": 0.42,
                    "ratio": 0.1,
                    "seeding_time": 3600,
                    "seeding_time_limit": -2,
                    "inactive_seeding_time_limit": -2,
                    "share_limit_action": "Stop",
                    "f_l_piece_prio": True,
                    "max_ratio": 1.5,
                    "max_seeding_time": 4320,
                }
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        row = rows[0]
        self.assertEqual(row["seedingTime"], 3600)
        self.assertEqual(row["seedingTimeLimit"], -2)
        self.assertEqual(row["inactiveSeedingTimeLimit"], -2)
        self.assertEqual(row["shareLimitAction"], "Stop")
        self.assertIs(row["firstLast"], True)
        self.assertEqual(row["maxRatio"], 1.5)
        self.assertEqual(row["maxSeedingTime"], 4320)
        # progress and ratio already existed; still there.
        self.assertAlmostEqual(row["progress"], 0.42)
        self.assertAlmostEqual(row["ratio"], 0.1)

    def test_row_share_fields_default_for_bare_torrent(self):
        raw = {
            "full_update": True,
            "torrents": {"a" * 40: {"name": "bare"}},
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        row = rows[0]
        self.assertEqual(row["seedingTime"], 0)
        self.assertEqual(row["seedingTimeLimit"], -2)
        self.assertEqual(row["inactiveSeedingTimeLimit"], -2)
        self.assertEqual(row["shareLimitAction"], "Default")
        self.assertIs(row["firstLast"], False)
        self.assertEqual(row["maxRatio"], -1)
        self.assertEqual(row["maxSeedingTime"], -1)

    def test_row_seeding_time_limit_zero_is_not_default(self):
        raw = {
            "full_update": True,
            "torrents": {"b" * 40: {"name": "zero-seed", "seeding_time_limit": 0}},
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["seedingTimeLimit"], 0)

    def test_row_inactive_seeding_time_limit_zero_is_not_default(self):
        raw = {
            "full_update": True,
            "torrents": {"c" * 40: {"name": "zero-inactive", "inactive_seeding_time_limit": 0}},
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["inactiveSeedingTimeLimit"], 0)

    def test_row_max_ratio_zero_is_not_none(self):
        raw = {
            "full_update": True,
            "torrents": {"d" * 40: {"name": "zero-ratio", "max_ratio": 0}},
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["maxRatio"], 0)

    def test_row_max_seeding_time_zero_is_not_none(self):
        raw = {
            "full_update": True,
            "torrents": {"e" * 40: {"name": "zero-seed-max", "max_seeding_time": 0}},
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["maxSeedingTime"], 0)

    def test_row_share_fields_survive_a_delta_that_does_not_resend_them(self):
        full = {
            "full_update": True,
            "torrents": {
                "f1" * 20: {
                    "name": "shared",
                    "seeding_time": 3600,
                    "share_limit_action": "Stop",
                    "f_l_piece_prio": True,
                    "max_ratio": 1.5,
                    "max_seeding_time": 4320,
                }
            },
        }
        delta = {
            "full_update": False,
            "torrents": {"f1" * 20: {"progress": 0.9}},
        }
        cache_map, _ = qbtsync.merge_maindata(full, {})
        _, rows = qbtsync.merge_maindata(delta, cache_map)
        row = next(r for r in rows if r["hash"] == "f1" * 20)
        self.assertEqual(row["seedingTime"], 3600)
        self.assertEqual(row["shareLimitAction"], "Stop")
        self.assertIs(row["firstLast"], True)
        self.assertEqual(row["maxRatio"], 1.5)
        self.assertEqual(row["maxSeedingTime"], 4320)


class MergeCategoriesTests(unittest.TestCase):
    def test_full_update_replaces_cache(self):
        raw = {"full_update": True, "categories": {"linux": {"name": "linux"}}}
        merged = qbtsync.merge_categories(raw, {"stale": {"name": "stale"}})
        self.assertEqual(merged, {"linux": {"name": "linux"}})

    def test_full_update_with_no_categories_key_is_empty(self):
        merged = qbtsync.merge_categories({"full_update": True}, {"linux": {}})
        self.assertEqual(merged, {})

    def test_delta_adds_and_keeps_existing(self):
        cache = {"linux": {"name": "linux"}}
        raw = {"full_update": False, "categories": {"os": {"name": "os"}}}
        merged = qbtsync.merge_categories(raw, cache)
        self.assertEqual(merged, {"linux": {"name": "linux"}, "os": {"name": "os"}})

    def test_categories_removed_drops_keys(self):
        cache = {"linux": {"name": "linux"}, "os": {"name": "os"}}
        raw = {"full_update": False, "categories_removed": ["os"]}
        merged = qbtsync.merge_categories(raw, cache)
        self.assertEqual(merged, {"linux": {"name": "linux"}})

    def test_delta_partial_category_keeps_untouched_fields(self):
        # qBittorrent's sync delta may resend a category as a partial object
        # (e.g. only savePath after an edit); a whole-object replace would
        # silently drop the other fields (like the download path) from the
        # merged cache, and so from categoryPaths.
        cache = {"os": {"name": "os", "savePath": "/data/os", "download_path": "/data/os-dl"}}
        raw = {"full_update": False, "categories": {"os": {"savePath": "/new"}}}
        merged = qbtsync.merge_categories(raw, cache)
        self.assertEqual(merged, {
            "os": {"name": "os", "savePath": "/new", "download_path": "/data/os-dl"},
        })

    def test_delta_changing_only_save_path_updates_just_that(self):
        cache = {"linux": {"name": "linux", "savePath": "/old", "download_path": "/dl"}}
        raw = {"full_update": False, "categories": {"linux": {"savePath": "/updated"}}}
        merged = qbtsync.merge_categories(raw, cache)
        self.assertEqual(merged["linux"]["savePath"], "/updated")
        self.assertEqual(merged["linux"]["download_path"], "/dl")
        self.assertEqual(merged["linux"]["name"], "linux")

    def test_delta_new_category_is_inserted_whole(self):
        cache = {"linux": {"name": "linux", "savePath": ""}}
        raw = {"full_update": False, "categories": {"os": {"name": "os", "savePath": "/data/os"}}}
        merged = qbtsync.merge_categories(raw, cache)
        self.assertEqual(merged["os"], {"name": "os", "savePath": "/data/os"})
        self.assertEqual(merged["linux"], {"name": "linux", "savePath": ""})

    def test_categories_removed_still_drops_entry_after_a_partial_update_elsewhere(self):
        cache = {
            "os": {"name": "os", "savePath": "/data/os", "download_path": "/data/os-dl"},
            "linux": {"name": "linux", "savePath": ""},
        }
        raw = {
            "full_update": False,
            "categories": {"os": {"savePath": "/new"}},
            "categories_removed": ["linux"],
        }
        merged = qbtsync.merge_categories(raw, cache)
        self.assertEqual(merged, {
            "os": {"name": "os", "savePath": "/new", "download_path": "/data/os-dl"},
        })


class CategoryPathsTests(unittest.TestCase):
    """category_paths() builds the status's `categoryPaths` map from the
    merged category cache. The download-path key name couldn't be probed
    live (the probing user has no categories), so both spellings are read."""

    def test_reads_save_path_and_snake_case_download_path(self):
        paths = qbtsync.category_paths({
            "os": {"name": "os", "savePath": "/data/os", "download_path": "/data/os-dl"},
        })
        self.assertEqual(paths, {"os": {"savePath": "/data/os", "downloadPath": "/data/os-dl"}})

    def test_reads_camel_case_download_path_fallback(self):
        paths = qbtsync.category_paths({
            "os": {"name": "os", "savePath": "/data/os", "downloadPath": "/data/os-dl2"},
        })
        self.assertEqual(paths["os"]["downloadPath"], "/data/os-dl2")

    def test_snake_case_download_path_wins_when_both_present(self):
        paths = qbtsync.category_paths({
            "os": {"savePath": "/data/os", "download_path": "/snake", "downloadPath": "/camel"},
        })
        self.assertEqual(paths["os"]["downloadPath"], "/snake")

    def test_missing_download_path_defaults_empty(self):
        paths = qbtsync.category_paths({"linux": {"name": "linux", "savePath": ""}})
        self.assertEqual(paths, {"linux": {"savePath": "", "downloadPath": ""}})

    def test_missing_save_path_defaults_empty(self):
        paths = qbtsync.category_paths({"linux": {"name": "linux"}})
        self.assertEqual(paths["linux"]["savePath"], "")

    def test_empty_categories_is_empty_map(self):
        self.assertEqual(qbtsync.category_paths({}), {})


class CategoryLimitsTests(unittest.TestCase):
    """category_limits() builds the status's `categoryLimits` map from the
    merged category cache: ratioLimit, seedingTimeLimit, shareLimitAction,
    defaulting to (-2, -2, "Default") when a category doesn't carry its
    own value."""

    def test_reads_explicit_values(self):
        limits = qbtsync.category_limits({
            "os": {"ratio_limit": 2.5, "seeding_time_limit": 10080, "share_limit_action": "Remove"},
        })
        self.assertEqual(limits, {"os": {"ratioLimit": 2.5, "seedingTimeLimit": 10080, "shareLimitAction": "Remove"}})

    def test_missing_values_default(self):
        limits = qbtsync.category_limits({"linux": {"name": "linux", "savePath": ""}})
        self.assertEqual(limits, {"linux": {"ratioLimit": -2, "seedingTimeLimit": -2, "shareLimitAction": "Default"}})

    def test_zero_ratio_limit_is_not_default(self):
        limits = qbtsync.category_limits({"os": {"ratio_limit": 0}})
        self.assertEqual(limits["os"]["ratioLimit"], 0)

    def test_zero_seeding_time_limit_is_not_default(self):
        limits = qbtsync.category_limits({"os": {"seeding_time_limit": 0}})
        self.assertEqual(limits["os"]["seedingTimeLimit"], 0)

    def test_empty_share_limit_action_defaults(self):
        limits = qbtsync.category_limits({"os": {"share_limit_action": ""}})
        self.assertEqual(limits["os"]["shareLimitAction"], "Default")

    def test_empty_categories_is_empty_map(self):
        self.assertEqual(qbtsync.category_limits({}), {})


class ShareActionLabelTests(unittest.TestCase):
    """share_action_label() maps app/preferences' max_ratio_act int to its
    string, the same way qBittorrent itself does: 0 Stop, 1 Remove,
    2 EnableSuperSeeding, 3 RemoveWithContent, anything else Stop."""

    def test_maps_each_known_int(self):
        self.assertEqual(qbtsync.share_action_label(0), "Stop")
        self.assertEqual(qbtsync.share_action_label(1), "Remove")
        self.assertEqual(qbtsync.share_action_label(2), "EnableSuperSeeding")
        self.assertEqual(qbtsync.share_action_label(3), "RemoveWithContent")

    def test_out_of_range_int_is_stop(self):
        self.assertEqual(qbtsync.share_action_label(7), "Stop")
        self.assertEqual(qbtsync.share_action_label(-1), "Stop")

    def test_wrong_type_is_stop(self):
        self.assertEqual(qbtsync.share_action_label("Remove"), "Stop")
        self.assertEqual(qbtsync.share_action_label(None), "Stop")
        self.assertEqual(qbtsync.share_action_label(1.0), "Stop")

    def test_bool_is_stop_even_though_true_equals_one(self):
        # True == 1 in Python, so a naive dict.get(value, "Stop") would map
        # True to "Remove". A bool isn't the int qBittorrent sends.
        self.assertEqual(qbtsync.share_action_label(True), "Stop")
        self.assertEqual(qbtsync.share_action_label(False), "Stop")


class MergeTagsTests(unittest.TestCase):
    def test_full_update_replaces_cache(self):
        raw = {"full_update": True, "tags": ["linux", "iso"]}
        merged = qbtsync.merge_tags(raw, ["stale"])
        self.assertEqual(merged, ["iso", "linux"])

    def test_full_update_with_no_tags_key_is_empty(self):
        merged = qbtsync.merge_tags({"full_update": True}, ["stale"])
        self.assertEqual(merged, [])

    def test_delta_adds_and_keeps_existing(self):
        cache = ["linux"]
        raw = {"full_update": False, "tags": ["iso"]}
        merged = qbtsync.merge_tags(raw, cache)
        self.assertEqual(merged, ["iso", "linux"])

    def test_delta_does_not_duplicate_an_already_cached_tag(self):
        cache = ["linux"]
        raw = {"full_update": False, "tags": ["linux"]}
        merged = qbtsync.merge_tags(raw, cache)
        self.assertEqual(merged, ["linux"])

    def test_tags_removed_drops_entries(self):
        cache = ["iso", "linux"]
        raw = {"full_update": False, "tags_removed": ["iso"]}
        merged = qbtsync.merge_tags(raw, cache)
        self.assertEqual(merged, ["linux"])


class SyncStateTests(unittest.TestCase):
    def test_load_missing_file_is_empty(self):
        state = qbtsync.SyncState.load("/no/such/path/rid.json")
        self.assertEqual(state.rid, 0)
        self.assertEqual(state.torrents, {})
        self.assertEqual(state.categories, {})
        self.assertEqual(state.tags, [])

    def test_load_corrupt_file_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rid.json")
            with open(path, "w") as f:
                f.write("{not json")
            state = qbtsync.SyncState.load(path)
            self.assertEqual(state.rid, 0)
            self.assertEqual(state.torrents, {})
            self.assertEqual(state.categories, {})
            self.assertEqual(state.tags, [])

    def test_load_old_rid_file_without_new_keys_is_empty(self):
        # A rid file written before this task shipped has no "categories"
        # or "tags" key at all.
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rid.json")
            with open(path, "w") as f:
                json.dump({"rid": 3, "torrents": {"h": {"name": "x"}}}, f)
            state = qbtsync.SyncState.load(path)
            self.assertEqual(state.rid, 3)
            self.assertEqual(state.torrents, {"h": {"name": "x"}})
            self.assertEqual(state.categories, {})
            self.assertEqual(state.tags, [])

    def test_load_wrong_typed_new_keys_is_empty(self):
        # A future/corrupt file with "categories"/"tags" of the wrong
        # shape must fall back the same way a missing key does.
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rid.json")
            with open(path, "w") as f:
                json.dump({"rid": 1, "categories": ["not", "a", "dict"], "tags": {"not": "a list"}}, f)
            state = qbtsync.SyncState.load(path)
            self.assertEqual(state.categories, {})
            self.assertEqual(state.tags, [])

    def test_save_and_load_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rid.json")
            state = qbtsync.SyncState(
                rid=5,
                torrents={"h": {"name": "x"}},
                categories={"linux": {"name": "linux"}},
                tags=["alpha", "beta"],
            )
            state.save(path)
            mode = oct(os.stat(path).st_mode & 0o777)
            self.assertEqual(mode, "0o600")
            loaded = qbtsync.SyncState.load(path)
            self.assertEqual(loaded.rid, 5)
            self.assertEqual(loaded.torrents, {"h": {"name": "x"}})
            self.assertEqual(loaded.categories, {"linux": {"name": "linux"}})
            self.assertEqual(loaded.tags, ["alpha", "beta"])

    def test_save_fixes_permissions_on_preexisting_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rid.json")
            with open(path, "w") as f:
                f.write("{}")
            os.chmod(path, 0o644)
            state = qbtsync.SyncState(rid=1, torrents={})
            state.save(path)
            mode = oct(os.stat(path).st_mode & 0o777)
            self.assertEqual(mode, "0o600")


class SlowCacheTests(unittest.TestCase):
    def test_due_when_never_fetched(self):
        cache = qbtsync.SlowCache(interval=30)
        self.assertTrue(cache.due(1000.0))

    def test_due_respects_interval(self):
        cache = qbtsync.SlowCache(interval=30, fetched_at=1000.0)
        self.assertFalse(cache.due(1010.0))
        self.assertTrue(cache.due(1030.0))

    def test_zero_interval_always_due(self):
        cache = qbtsync.SlowCache(interval=0, fetched_at=1000.0)
        self.assertTrue(cache.due(1000.0))
        self.assertTrue(cache.due(1000.5))


class CookieJarRoundTripTests(unittest.TestCase):
    def test_curl_httponly_session_cookie_survives_load_and_save(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cookies")
            with open(path, "w") as f:
                f.write("# Netscape HTTP Cookie File\n")
                f.write("#HttpOnly_127.0.0.1\tFALSE\t/\tFALSE\t0\tSID\tfixture-1\n")

            jar = qbtsync.CurlCookieJar(path)
            jar.load(ignore_discard=True, ignore_expires=True)

            cookies = list(jar)
            self.assertEqual(len(cookies), 1)
            self.assertEqual(cookies[0].value, "fixture-1")

            # The cookie must actually be attachable to a real request, not
            # merely survive as text. curl writes "0" as its no-expiry
            # marker; stock MozillaCookieJar treats that as the Unix epoch
            # and refuses to ever send it again.
            req = urllib.request.Request("http://127.0.0.1:8080/api/v2/sync/maindata")
            jar.add_cookie_header(req)
            self.assertEqual(req.get_header("Cookie"), "SID=fixture-1")

            jar.save(ignore_discard=True, ignore_expires=True)
            text = Path(path).read_text()
            self.assertIn("SID\tfixture-1", text)
            self.assertIn("#HttpOnly_127.0.0.1", text)
            # Re-saved file must still be sendable by curl: an empty
            # expires field is dropped by curl's parser, so it must come
            # back out as "0", not "".
            self.assertRegex(text, r"#HttpOnly_127\.0\.0\.1\tFALSE\t/\tFALSE\t0\tSID\tfixture-1")

            reloaded = qbtsync.CurlCookieJar(path)
            reloaded.load(ignore_discard=True, ignore_expires=True)
            req2 = urllib.request.Request("http://127.0.0.1:8080/api/v2/sync/maindata")
            reloaded.add_cookie_header(req2)
            self.assertEqual(req2.get_header("Cookie"), "SID=fixture-1")

    def test_new_cookie_from_response_is_saved_as_session(self):
        import email.message

        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cookies")
            jar = qbtsync.CurlCookieJar(path)
            # Simulate receiving a Set-Cookie header, as HTTPCookieProcessor would.
            headers = email.message.Message()
            headers["Set-Cookie"] = "SID=newsid; HttpOnly; Path=/"

            class FakeResponse:
                def info(self):
                    return headers

            req = urllib.request.Request("http://127.0.0.1:8080/api/v2/sync/maindata")
            jar.extract_cookies(FakeResponse(), req)
            jar.save(ignore_discard=True, ignore_expires=True)
            text = Path(path).read_text()
            self.assertIn("0\tSID\tnewsid", text)


class ApiErrorTests(unittest.TestCase):
    def test_carries_code_and_message(self):
        err = qbtsync.ApiError(404, "HTTP 404 not found")
        self.assertEqual(err.code, 404)
        self.assertEqual(err.message, "HTTP 404 not found")

    def test_code_can_be_none(self):
        err = qbtsync.ApiError(None, "connection refused")
        self.assertIsNone(err.code)


class ClientTests(unittest.TestCase):
    def test_refuses_non_local_base(self):
        jar = http.cookiejar.CookieJar()
        with self.assertRaises(ValueError):
            qbtsync.Client("http://example.com", jar)

    @staticmethod
    def _serve_once(handler):
        """Accept exactly one connection on a free localhost port, run
        `handler(conn)` against it, then close. Returns (srv_socket, port,
        thread) so the caller can shut everything down afterward."""
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]

        def run():
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            try:
                handler(conn)
            except OSError:
                pass
            finally:
                conn.close()

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return srv, port, thread

    def test_connection_closed_without_response_raises_api_error(self):
        # The server reads the request, then closes without ever writing a
        # status line: http.client raises RemoteDisconnected from
        # getresponse(), not urllib.error.URLError.
        def handler(conn):
            conn.recv(65536)
            conn.close()

        srv, port, thread = self._serve_once(handler)
        try:
            jar = http.cookiejar.CookieJar()
            client = qbtsync.Client(f"http://127.0.0.1:{port}", jar, timeout=2)
            with self.assertRaises(qbtsync.ApiError) as ctx:
                client.get("/api/v2/sync/maindata?rid=0")
            self.assertIsNone(ctx.exception.code)
            self.assertTrue(ctx.exception.message)
        finally:
            srv.close()
            thread.join(timeout=2)

    def test_connection_hang_past_timeout_raises_api_error(self):
        # The server accepts and reads the request but never responds:
        # resp.read()/getresponse() times out with a raw TimeoutError, not
        # urllib.error.URLError.
        release = threading.Event()

        def handler(conn):
            conn.recv(65536)
            release.wait(2)

        srv, port, thread = self._serve_once(handler)
        try:
            jar = http.cookiejar.CookieJar()
            client = qbtsync.Client(f"http://127.0.0.1:{port}", jar, timeout=0.2)
            with self.assertRaises(qbtsync.ApiError) as ctx:
                client.get("/api/v2/sync/maindata?rid=0")
            self.assertIsNone(ctx.exception.code)
            self.assertTrue(ctx.exception.message)
        finally:
            release.set()
            srv.close()
            thread.join(timeout=2)


KEY_A = "qbt_FixtureKey23456789abcdefghjk"
KEY_B = "qbt_RotatedKey3456789ABCDEFGHJKL"


def write_conf(path, body):
    Path(path).write_text(body)


class ReadApiKeyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.conf = os.path.join(self.tmp.name, "qBittorrent.conf")

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, body):
        Path(self.conf).write_text(body)
        return qbtsync.read_api_key(self.conf)

    def test_reads_the_key_from_preferences(self):
        self.assertEqual(self.read(f"[Preferences]\nWebUI\\APIKey={KEY_A}\nWebUI\\Port=8080\n"), KEY_A)

    def test_the_fixture_conf_holds_the_fixture_key(self):
        self.assertEqual(qbtsync.read_api_key(str(FIXTURES / "qBittorrent.conf")), KEY_A)

    def test_missing_file_is_none(self):
        self.assertIsNone(qbtsync.read_api_key(self.conf))
        self.assertIsNone(qbtsync.read_api_key(""))
        self.assertIsNone(qbtsync.read_api_key(None))

    def test_only_the_preferences_section_counts(self):
        self.assertIsNone(self.read(f"[BitTorrent]\nWebUI\\APIKey={KEY_A}\n"))
        self.assertIsNone(self.read(f"WebUI\\APIKey={KEY_A}\n[Preferences]\nWebUI\\Port=1\n"))
        self.assertIsNone(self.read(f"[Preferences]\n[Meta]\nWebUI\\APIKey={KEY_A}\n"))
        self.assertEqual(self.read(f"[BitTorrent]\nx=1\n[Preferences]  \nWebUI\\APIKey={KEY_A}\n"), KEY_A)

    def test_last_line_wins_and_crlf_is_stripped(self):
        self.assertEqual(self.read(f"[Preferences]\nWebUI\\APIKey={KEY_A}\nWebUI\\APIKey={KEY_B}\n"), KEY_B)
        self.assertEqual(self.read(f"[Preferences]\r\nWebUI\\APIKey={KEY_A}\r\n"), KEY_A)

    def test_malformed_keys_are_none(self):
        for key in ("", KEY_A[:-1], KEY_A + "x", "qbt-" + KEY_A[4:], "QBT_" + KEY_A[4:],
                    KEY_A[:-1] + "é", KEY_A[:-1] + "-", " " + KEY_A, KEY_A + " ", KEY_A[:-1] + "١"):
            with self.subTest(key=key):
                self.assertIsNone(self.read(f"[Preferences]\nWebUI\\APIKey={key}\n"))

    def test_a_prefixed_name_is_not_the_key(self):
        self.assertIsNone(self.read(f"[Preferences]\nXWebUI\\APIKey={KEY_A}\nWebUI\\APIKeyOld={KEY_A}\n"))


class ClientAuthTests(unittest.TestCase):
    """Client against a tiny threaded server that records each request's
    Authorization header and answers 403 unless it is `Bearer <self.key>`."""

    def setUp(self):
        import http.server

        test = self
        self.key = KEY_A
        self.seen = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                auth = self.headers.get("Authorization")
                test.seen.append((self.path, auth))
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/landing")
                    self.end_headers()
                    return
                if self.path != "/landing" and auth != f"Bearer {test.key}":
                    self.send_response(403)
                    self.end_headers()
                    self.wfile.write(b"Forbidden")
                    return
                body = b"ok"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.tmp = tempfile.TemporaryDirectory()
        self.conf = os.path.join(self.tmp.name, "qBittorrent.conf")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def client(self, conf):
        return qbtsync.Client(self.base, http.cookiejar.CookieJar(), timeout=2, conf=conf)

    def test_sends_the_conf_key_as_a_bearer_header(self):
        write_conf(self.conf, f"[Preferences]\nWebUI\\APIKey={KEY_A}\n")
        self.assertEqual(self.client(self.conf).get("/api/v2/app/version"), "ok")
        self.assertEqual(self.seen, [("/api/v2/app/version", f"Bearer {KEY_A}")])

    def test_rereads_the_key_after_the_conf_changes(self):
        write_conf(self.conf, f"[Preferences]\nWebUI\\APIKey={KEY_A}\n")
        client = self.client(self.conf)
        client.get("/a")
        self.key = KEY_B
        write_conf(self.conf, f"[Preferences]\nWebUI\\APIKey={KEY_B}\n")
        self.assertEqual(client.get("/b"), "ok")
        self.assertEqual([auth for _, auth in self.seen], [f"Bearer {KEY_A}", f"Bearer {KEY_B}"])

    def test_no_conf_or_no_valid_key_sends_no_header(self):
        write_conf(self.conf, "[Preferences]\nWebUI\\APIKey=qbt_short\n")
        for conf in (None, self.conf, os.path.join(self.tmp.name, "missing.conf")):
            with self.subTest(conf=conf):
                self.seen.clear()
                with self.assertRaises(qbtsync.ApiError):
                    self.client(conf).get("/x")
                self.assertEqual(self.seen, [("/x", None)])

    def test_a_403_is_the_api_key_message(self):
        write_conf(self.conf, f"[Preferences]\nWebUI\\APIKey={KEY_B}\n")
        with self.assertRaises(qbtsync.ApiError) as ctx:
            self.client(self.conf).get("/x")
        self.assertEqual(ctx.exception.code, 403)
        self.assertEqual(ctx.exception.message, "qBittorrent refused OmaqBT's API key")
        self.assertNotIn(KEY_B, str(ctx.exception))

    def test_a_redirect_does_not_carry_the_key(self):
        write_conf(self.conf, f"[Preferences]\nWebUI\\APIKey={KEY_A}\n")
        self.assertEqual(self.client(self.conf).get("/redirect"), "ok")
        self.assertEqual(self.seen, [("/redirect", f"Bearer {KEY_A}"), ("/landing", None)])


class BuildStatusTests(unittest.TestCase):
    """Exercises build_status against a fake Client so no network is used."""

    class FakeClient:
        def __init__(self, responses):
            # responses: dict path -> (str body) or ApiError instance to raise
            self.responses = responses
            self.calls = []

        def get(self, path):
            self.calls.append(path)
            resp = self.responses.get(path)
            if isinstance(resp, qbtsync.ApiError):
                raise resp
            if resp is None:
                raise qbtsync.ApiError(404, "HTTP 404 not found")
            return resp

    def base_probe(self, **overrides):
        probe = {
            "installed": True,
            "daemon": True,
            "lockHolder": "nox",
            "vpnIface": "",
        }
        probe.update(overrides)
        return probe

    def test_skips_maindata_when_not_installed(self):
        probe = self.base_probe(installed=False)
        client = self.FakeClient({})
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["api"], False)
        self.assertEqual(status["torrents"], [])
        self.assertEqual(status["categories"], [])
        self.assertEqual(status["tags"], [])
        self.assertEqual(status["categoryPaths"], {})
        self.assertEqual(status["defaultSavePath"], "")
        self.assertEqual(status["relocation"], {"torrentChanged": False, "categoryPathChanged": False})
        self.assertEqual(errors, [])
        self.assertEqual(client.calls, [])

    def test_skips_maindata_when_lock_holder_is_gui(self):
        probe = self.base_probe(lockHolder="gui")
        client = self.FakeClient({})
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["api"], False)
        self.assertEqual(client.calls, [])

    def test_successful_maindata_sets_api_true_and_speeds(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": json.dumps({
                "save_path": "/home/user/Downloads",
                "torrent_changed_tmm_enabled": True,
                "category_changed_tmm_enabled": False,
            }),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertTrue(status["api"])
        self.assertEqual(status["dlSpeed"], 2202009)
        self.assertEqual(len(status["torrents"]), 2)
        self.assertTrue(status["altSpeed"])
        self.assertEqual(errors, [])
        self.assertEqual(sync.rid, 1)
        # preferences is fetched on the slow timer even with no VPN iface
        # configured -- only the vpnIface/bindIface fields stay gated on it.
        self.assertIn("/api/v2/app/preferences", client.calls)
        self.assertEqual(status["vpnIface"], "")
        self.assertEqual(status["bindIface"], "")
        self.assertEqual(status["categories"], ["linux", "os"])
        self.assertEqual(status["tags"], ["extra", "iso", "linux"])
        self.assertEqual(status["categoryPaths"], {
            "linux": {"savePath": "", "downloadPath": ""},
            "os": {"savePath": "/data/os", "downloadPath": "/data/os-dl"},
        })
        self.assertEqual(status["defaultSavePath"], "/home/user/Downloads")
        self.assertEqual(status["relocation"], {"torrentChanged": True, "categoryPathChanged": False})

    def test_successful_maindata_builds_category_limits(self):
        full = {
            "full_update": True,
            "torrents": {},
            "categories": {
                "linux": {"name": "linux", "savePath": ""},
                "os": {"name": "os", "ratio_limit": 2.5, "seeding_time_limit": 10080, "share_limit_action": "Remove"},
            },
        }
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": "{}",
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(errors, [])
        self.assertEqual(status["categoryLimits"], {
            "linux": {"ratioLimit": -2, "seedingTimeLimit": -2, "shareLimitAction": "Default"},
            "os": {"ratioLimit": 2.5, "seedingTimeLimit": 10080, "shareLimitAction": "Remove"},
        })

    # -- slice 3b, Task 2: shareDefaults from preferences --------------------

    def test_share_defaults_read_from_preferences_when_enabled(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": json.dumps({
                "max_ratio_enabled": True,
                "max_ratio": 2.0,
                "max_seeding_time_enabled": True,
                "max_seeding_time": 4320,
                "max_ratio_act": 3,
            }),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(errors, [])
        self.assertEqual(status["shareDefaults"], {"ratio": 2.0, "seedingTime": 4320, "action": "RemoveWithContent"})

    def test_share_defaults_disabled_is_minus_one_and_unmapped_action_is_stop(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": json.dumps({
                "max_ratio_enabled": False,
                "max_ratio": 2.0,
                "max_seeding_time_enabled": False,
                "max_seeding_time": 4320,
                "max_ratio_act": 7,
            }),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["shareDefaults"], {"ratio": -1, "seedingTime": -1, "action": "Stop"})

    def test_share_defaults_action_map(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe()
        for act, name in ((0, "Stop"), (1, "Remove"), (2, "EnableSuperSeeding"), (3, "RemoveWithContent")):
            client = self.FakeClient({
                "/api/v2/sync/maindata?rid=0": json.dumps(full),
                "/api/v2/transfer/speedLimitsMode": "1",
                "/api/v2/app/preferences": json.dumps({"max_ratio_act": act}),
            })
            sync = qbtsync.SyncState()
            slow = qbtsync.SlowCache(interval=0)
            status, _ = qbtsync.build_status(probe, client, sync, slow, 1000.0)
            self.assertEqual(status["shareDefaults"]["action"], name)

    def test_share_defaults_kept_on_preferences_failure(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe()
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)

        client1 = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": json.dumps({
                "max_ratio_enabled": True, "max_ratio": 2.0,
                "max_seeding_time_enabled": True, "max_seeding_time": 4320,
                "max_ratio_act": 1,
            }),
        })
        first, _ = qbtsync.build_status(probe, client1, sync, slow, 1000.0)
        self.assertEqual(first["shareDefaults"], {"ratio": 2.0, "seedingTime": 4320, "action": "Remove"})

        client2 = self.FakeClient({
            "/api/v2/sync/maindata?rid=1": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": qbtsync.ApiError(None, "connection refused"),
        })
        second, errors = qbtsync.build_status(probe, client2, sync, slow, 1001.0)
        self.assertEqual(second["shareDefaults"], {"ratio": 2.0, "seedingTime": 4320, "action": "Remove"})
        self.assertIn("connection refused", errors)

    def test_share_defaults_default_before_any_fetch(self):
        probe = self.base_probe(installed=False)
        client = self.FakeClient({})
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, _ = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["shareDefaults"], {"ratio": -1, "seedingTime": -1, "action": "Stop"})
        self.assertEqual(status["categoryLimits"], {})

    def test_categories_and_tags_honour_delta_removed_semantics(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        delta = json.loads((FIXTURES / "maindata-delta.json").read_text())
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/sync/maindata?rid=1": json.dumps(delta),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": json.dumps({"save_path": "/home/user/Downloads"}),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        first, _ = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(first["categories"], ["linux", "os"])
        self.assertEqual(first["tags"], ["extra", "iso", "linux"])
        self.assertEqual(first["categoryPaths"], {
            "linux": {"savePath": "", "downloadPath": ""},
            "os": {"savePath": "/data/os", "downloadPath": "/data/os-dl"},
        })

        second, _ = qbtsync.build_status(probe, client, sync, slow, 1001.0)
        # the delta's categories_removed/tags_removed prune the survivors.
        self.assertEqual(second["categories"], ["linux"])
        self.assertEqual(second["tags"], ["iso", "linux"])
        self.assertEqual(second["categoryPaths"], {"linux": {"savePath": "", "downloadPath": ""}})

    def test_maindata_failure_leaves_api_false_and_reports_error(self):
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": qbtsync.ApiError(403, "qBittorrent refused OmaqBT's API key"),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertFalse(status["api"])
        self.assertEqual(status["dlSpeed"], 0)
        self.assertEqual(status["torrents"], [])
        self.assertEqual(errors, ["qBittorrent refused OmaqBT's API key"])
        # slow-poll calls never happen when maindata itself failed
        self.assertNotIn("/api/v2/transfer/speedLimitsMode", client.calls)

    def test_maindata_failure_does_not_reset_existing_rid(self):
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=7": qbtsync.ApiError(None, "connection refused"),
        })
        sync = qbtsync.SyncState(rid=7, torrents={"h": {"name": "x"}})
        slow = qbtsync.SlowCache(interval=0)
        qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(sync.rid, 7)
        self.assertEqual(sync.torrents, {"h": {"name": "x"}})

    def test_vpn_iface_reports_bind_iface_on_success(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="wg0-mullvad")
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "0",
            "/api/v2/app/preferences": json.dumps({"current_network_interface": "wg0-mullvad"}),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["vpnIface"], "wg0-mullvad")
        self.assertEqual(status["bindIface"], "wg0-mullvad")
        self.assertFalse(status["altSpeed"])
        self.assertEqual(errors, [])

    def test_vpn_iface_clears_on_preferences_failure(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="wg0-mullvad")
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": qbtsync.ApiError(None, "connection refused"),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["vpnIface"], "")
        self.assertEqual(status["bindIface"], "")
        self.assertIn("connection refused", errors)

    def test_first_ever_preferences_failure_yields_default_save_path_and_relocation_defaults(self):
        # Nothing has ever succeeded yet, so there is no "last known value"
        # to keep: defaultSavePath/relocation must come back at their
        # freshly-constructed SlowCache defaults, not stay unset/None.
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": qbtsync.ApiError(None, "connection refused"),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["defaultSavePath"], "")
        self.assertEqual(status["relocation"], {"torrentChanged": False, "categoryPathChanged": False})
        self.assertIn("connection refused", errors)

    def test_preferences_fetched_even_with_no_vpn_iface_configured(self):
        # Preferences now feeds defaultSavePath/relocation too, so it is
        # fetched on the slow timer regardless of whether a VPN interface
        # is configured; only vpnIface/bindIface stay gated on vpn_iface.
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="")
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": json.dumps({
                "save_path": "/home/user/Downloads",
                "torrent_changed_tmm_enabled": True,
                "category_changed_tmm_enabled": False,
            }),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertIn("/api/v2/app/preferences", client.calls)
        self.assertEqual(status["vpnIface"], "")
        self.assertEqual(status["bindIface"], "")
        self.assertEqual(status["defaultSavePath"], "/home/user/Downloads")
        self.assertEqual(status["relocation"], {"torrentChanged": True, "categoryPathChanged": False})
        self.assertEqual(errors, [])

    def test_preferences_failure_keeps_last_known_default_save_path_and_relocation(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="wg0-mullvad")
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)

        client1 = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": json.dumps({
                "current_network_interface": "wg0-mullvad",
                "save_path": "/home/user/Downloads",
                "torrent_changed_tmm_enabled": True,
                "category_changed_tmm_enabled": False,
            }),
        })
        first, _ = qbtsync.build_status(probe, client1, sync, slow, 1000.0)
        self.assertEqual(first["defaultSavePath"], "/home/user/Downloads")
        self.assertEqual(first["relocation"], {"torrentChanged": True, "categoryPathChanged": False})

        client2 = self.FakeClient({
            "/api/v2/sync/maindata?rid=1": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": qbtsync.ApiError(None, "connection refused"),
        })
        second, errors = qbtsync.build_status(probe, client2, sync, slow, 1001.0)
        # the API error is reported and vpnIface/bindIface reset (unchanged
        # behaviour), but the new fields keep their last known values rather
        # than resetting to empty/false.
        self.assertEqual(second["vpnIface"], "")
        self.assertEqual(second["bindIface"], "")
        self.assertEqual(second["defaultSavePath"], "/home/user/Downloads")
        self.assertEqual(second["relocation"], {"torrentChanged": True, "categoryPathChanged": False})
        self.assertIn("connection refused", errors)

    def test_maindata_non_json_body_is_treated_as_failed_call(self):
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": "<html",
        })
        sync = qbtsync.SyncState(rid=3, torrents={"h": {"name": "x"}})
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertFalse(status["api"])
        self.assertEqual(status["torrents"], [])
        # sync must stay exactly as it was: never partially applied.
        self.assertEqual(sync.rid, 3)
        self.assertEqual(sync.torrents, {"h": {"name": "x"}})
        self.assertTrue(errors)
        # the slow-poll calls are gated on api being True, so a malformed
        # maindata body must not trigger them either.
        self.assertNotIn("/api/v2/transfer/speedLimitsMode", client.calls)

    def test_maindata_non_object_json_is_treated_as_failed_call(self):
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": "[]",
        })
        sync = qbtsync.SyncState(rid=3, torrents={"h": {"name": "x"}})
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertFalse(status["api"])
        self.assertEqual(sync.rid, 3)
        self.assertEqual(sync.torrents, {"h": {"name": "x"}})
        self.assertTrue(errors)

    def test_preferences_non_json_body_clears_vpn_iface(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="wg0-mullvad")
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": "<html",
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertTrue(status["api"])
        self.assertEqual(status["vpnIface"], "")
        self.assertEqual(status["bindIface"], "")
        self.assertTrue(errors)

    def test_preferences_non_object_json_clears_vpn_iface(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="wg0-mullvad")
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": "[]",
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertTrue(status["api"])
        self.assertEqual(status["vpnIface"], "")
        self.assertEqual(status["bindIface"], "")
        self.assertTrue(errors)

    def test_key_order(self):
        probe = self.base_probe(installed=False)
        client = self.FakeClient({})
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, _ = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(
            list(status.keys()),
            ["installed", "daemon", "lockHolder", "api", "altSpeed", "dlSpeed",
             "upSpeed", "torrents", "vpnIface", "bindIface", "categories",
             "categoryPaths", "categoryLimits", "tags", "defaultSavePath",
             "relocation", "shareDefaults", "auth", "authRefused"],
        )

    def test_auth_passes_through_from_the_probe(self):
        for value in ("ok", "bypass", "nokey"):
            with self.subTest(auth=value):
                status, _ = qbtsync.build_status(
                    self.base_probe(auth=value), self.FakeClient({}), qbtsync.SyncState(),
                    qbtsync.SlowCache(interval=0), 1000.0)
                self.assertEqual(status["auth"], value)

    def test_auth_defaults_to_ok_without_a_probe_value(self):
        for probe in (self.base_probe(), self.base_probe(auth=""), self.base_probe(auth=None),
                      self.base_probe(auth=3)):
            with self.subTest(probe=probe):
                status, _ = qbtsync.build_status(
                    probe, self.FakeClient({}), qbtsync.SyncState(), qbtsync.SlowCache(interval=0), 1000.0)
                self.assertEqual(status["auth"], "ok")
                self.assertFalse(status["authRefused"])

    def test_a_maindata_403_sets_auth_refused(self):
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": qbtsync.ApiError(403, "qBittorrent refused OmaqBT's API key"),
        })
        status, errors = qbtsync.build_status(
            self.base_probe(), client, qbtsync.SyncState(), qbtsync.SlowCache(interval=0), 1000.0)
        self.assertTrue(status["authRefused"])
        self.assertFalse(status["api"])
        self.assertEqual(errors, ["qBittorrent refused OmaqBT's API key"])

    def test_a_preferences_403_sets_auth_refused(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "0",
            "/api/v2/app/preferences": qbtsync.ApiError(403, "qBittorrent refused OmaqBT's API key"),
        })
        status, _ = qbtsync.build_status(
            self.base_probe(), client, qbtsync.SyncState(), qbtsync.SlowCache(interval=0), 1000.0)
        self.assertTrue(status["api"])
        self.assertTrue(status["authRefused"])

    def test_other_failures_leave_auth_refused_false(self):
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": qbtsync.ApiError(None, "couldn't connect"),
        })
        status, _ = qbtsync.build_status(
            self.base_probe(), client, qbtsync.SyncState(), qbtsync.SlowCache(interval=0), 1000.0)
        self.assertFalse(status["authRefused"])


if __name__ == "__main__":
    unittest.main()
