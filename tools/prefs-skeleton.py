#!/usr/bin/env python3
"""Print a settings-schema skeleton from a saved /app/preferences dump.

Usage: tools/prefs-skeleton.py PREFERENCES.json [SCHEMA.json]

For each key in the dump, prints its live JSON type ("bool", "int",
"float", "string", "object", "array", "null"), its value, and a guessed
schema type. With SCHEMA.json it prints only the keys the schema doesn't
know yet, which is how a qBittorrent upgrade's new preferences are found
(they'd otherwise land in the Settings view's Other section).

Secret values (passwords, the API key) are never printed. The output is
a starting point for hand-written entries in settings-schema.json; the
guesses carry no sections, labels, ranges or choices.
"""

import json
import sys

SECRET_MARKS = ("password", "api_key")


def json_type(value):
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "string"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    return "null"


def is_secret(key):
    return any(mark in key for mark in SECRET_MARKS)


def guess(key, jtype):
    if is_secret(key):
        return "secret"
    if jtype in ("bool", "int", "float"):
        return jtype
    if jtype == "string" and (key.endswith("_path") or key.endswith("_dir")):
        return "path"
    return "text"


def skeleton(prefs, known=()):
    out = {}
    for key in sorted(prefs):
        if key in known:
            continue
        jtype = json_type(prefs[key])
        entry = {"json": jtype, "type": guess(key, jtype)}
        if not is_secret(key):
            entry["value"] = prefs[key]
        out[key] = entry
    return out


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        prefs = json.load(f)
    known = ()
    if len(argv) == 3:
        with open(argv[2], encoding="utf-8") as f:
            known = set(json.load(f)["keys"])
    json.dump(skeleton(prefs, known), sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
