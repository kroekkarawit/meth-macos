#!/usr/bin/env python3
"""Builds Meth/Resources/Localizable.xcstrings (en, th, zh-Hans) from translations.py.

With --check BUILD_DIR it also verifies every key the compiler extracted (.stringsdata)
has a translation, so CI fails if a new UI string is added without Thai/Chinese text.
"""
import glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from translations import T

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "Meth", "Resources", "Localizable.xcstrings")

def specifiers(s):
    return sorted(re.findall(r"%(?:\d+\$)?(?:lld|@|d)", s))

strings = {}
for key, (th, zh) in sorted(T.items()):
    for lang, val in (("th", th), ("zh-Hans", zh)):
        if specifiers(key) != specifiers(val):
            sys.exit(f"Format specifier mismatch for {lang}: {key!r} -> {val!r}")
    strings[key] = {
        "extractionState": "manual",
        "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": key}},
            "th": {"stringUnit": {"state": "translated", "value": th}},
            "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
        },
    }

with open(OUT, "w", encoding="utf-8") as f:
    json.dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
print(f"Wrote {len(strings)} strings to {os.path.relpath(OUT, ROOT)}")

if len(sys.argv) == 3 and sys.argv[1] == "--check":
    found = set()
    for path in glob.glob(os.path.join(sys.argv[2], "**", "Meth.build", "**", "*.stringsdata"), recursive=True):
        if "/MethTests.build/" in path or "/MethUITests.build/" in path:
            continue
        for entries in json.load(open(path)).get("tables", {}).values():
            found.update(e["key"] for e in entries)
    missing = sorted(found - set(T))
    if missing:
        print("Untranslated keys:", *missing, sep="\n  ")
        sys.exit(1)
    print(f"All {len(found)} extracted keys are translated.")
