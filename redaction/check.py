#!/usr/bin/env python3
"""Check that redaction/cases.jsonl keeps the contract README.md sets out. Stdlib only.

    python3 redaction/check.py        # exit 0 and a summary, or exit 1 naming what broke

These rules used to run inside chamnan's own regression suite. They moved here with the cases on
2026-09-24: a plugin's suite that depends on another repository prints a [SKIP] nobody who clones
the plugin can explain, and the rules are about this file, so they belong beside it.
"""
import json
import sys
from pathlib import Path

CASES = Path(__file__).resolve().parent / "cases.jsonl"
SOURCES = ("synthetic", "sanitized", "fuzz")


def rows():
    """Every case, with a value stored as a list of parts joined back into the string it stands for."""
    out = []
    for line in CASES.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append({k: ("".join(v) if isinstance(v, list) else v)
                        for k, v in json.loads(line).items()})
    return out


def problems(cases):
    found = []
    if len(cases) < 4:
        found.append(f"only {len(cases)} case(s) parse")
    missing = [c.get("id") for c in cases if not {"id", "text", "source", "why"} <= set(c)]
    if missing:
        found.append(f"cases missing a required field: {missing}")
    ids = [c.get("id") for c in cases]
    if len(set(ids)) != len(ids):
        found.append("ids are not unique, and findings quote them")
    bad_source = sorted({c.get("source") for c in cases} - set(SOURCES))
    if bad_source:
        found.append(f"sources the README does not define: {bad_source}")
    # A corpus with no benign cases measures recall and cannot measure precision, which is how a
    # detector that destroys everything scores perfectly.
    if not any("secret" not in c for c in cases):
        found.append("no benign neighbour at all, so precision cannot be measured")
    known = set(ids)
    dangling = [c["near"] for c in cases if c.get("near") and c["near"] not in known]
    if dangling:
        found.append(f"`near` names cases that are not here: {dangling}")
    absent = [c["id"] for c in cases if c.get("secret") and c["secret"] not in c["text"]]
    if absent:
        found.append(f"a declared secret does not appear in its own text: {absent}")
    return found


def main():
    cases = rows()
    found = problems(cases)
    for p in found:
        print(f"  ✗ {p}")
    if found:
        print(f"redaction/check.py: {len(found)} problem(s) in {len(cases)} case(s)")
        return 1
    benign = sum(1 for c in cases if "secret" not in c)
    print(f"redaction/check.py: {len(cases)} case(s), {benign} benign, every rule in README.md holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
