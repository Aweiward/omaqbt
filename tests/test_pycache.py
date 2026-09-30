#!/usr/bin/env python3
"""Python must never write bytecode into the plugin tree.

Omarchy watches the deployed plugin folder with `inotifywait -r` and reloads
the plugin (destroying the open window) on any file write under it, so a
.pyc landing in lib/__pycache__ closes OmaqBT. `qbt` exports
PYTHONPYCACHEPREFIX and `qbt-serve` sets sys.pycache_prefix, both to
<state dir>/pycache. This copies the runtime files into a clean temp tree,
runs python-backed commands and the sidecar, and asserts the tree is
byte-for-byte untouched while the bytecode appears under the state dir.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))
import harness  # noqa: E402

PREFS_DUMP = ROOT / "tests" / "fixtures" / "preferences-5.2.3.json"


def snapshot(tree):
    return sorted(str(p.relative_to(tree)) for p in tree.rglob("*"))


class PycacheTest(unittest.TestCase):
    def test_no_bytecode_is_written_into_the_plugin_tree(self):
        with tempfile.TemporaryDirectory(prefix="qbt-pycache-") as tmp:
            tree = Path(tmp) / "plugin"
            tree.mkdir()
            for name in ("qbt", "qbt-serve"):
                shutil.copy2(ROOT / name, tree / name)
            shutil.copytree(ROOT / "lib", tree / "lib", ignore=shutil.ignore_patterns("__pycache__"))
            before = snapshot(tree)
            self.assertFalse([p for p in before if "__pycache__" in p or p.endswith(".pyc")])
            state = Path(tmp) / "pycache-state"  # absent: Python must create it

            with harness.fixture_server(extra_env={"QBT_FIXTURE_PREFS": str(PREFS_DUMP)}) as (port, env):
                env = dict(env, QBT_STATE_DIR=str(state))
                for var in ("PYTHONDONTWRITEBYTECODE", "PYTHONPYCACHEPREFIX"):
                    env.pop(var, None)

                # python-backed helpers. A script run as __main__ is never
                # cached, only what it imports: `rss items` (rssitems, which
                # imports linkrules + rssrules), `rss rule-check` (rssautorules
                # imports rssitems), searchrules, and the status probe (qbtsync).
                commands = (["rss", "items"], ["rss", "rules"], ["rss", "rule-check"],
                            ["search-plugin", "install", "not-a-url"], ["status"])
                for argv in commands:
                    subprocess.run([str(tree / "qbt"), *argv], env=env, input=b"",
                                   capture_output=True, timeout=60)

                proc = subprocess.Popen([str(tree / "qbt-serve")], cwd=str(tree), env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
                try:
                    self.assertTrue(proc.stdout.readline())
                    proc.stdin.write(json.dumps({"cmd": "refresh"}) + "\n")
                    proc.stdin.flush()
                    self.assertTrue(proc.stdout.readline())
                finally:
                    proc.stdin.close()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    proc.stdout.close()
                    proc.stderr.close()

            self.assertEqual(snapshot(tree), before, "the plugin tree must not change")
            pycs = {p.name.split(".")[0] for p in (state / "pycache").rglob("*.pyc")}
            for mod in ("rssitems", "linkrules", "rssrules", "qbtsync", "speedhist"):
                self.assertIn(mod, pycs)


if __name__ == "__main__":
    unittest.main()
