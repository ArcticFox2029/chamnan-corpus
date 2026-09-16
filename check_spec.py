#!/usr/bin/env python3
"""Walk every claim in corpus/SPEC.md that a filesystem can settle, and say which ones resolve.

    python3 check_spec.py            # report, exit 1 if anything the spec asserts is not true
    python3 check_spec.py --quiet    # only the failures and the totals line

This corpus is a measuring instrument, and its whole value is that `corpus/SPEC.md` is a real answer
key: every service, table, endpoint, event and environment variable is supposed to be named there and
nowhere else, so a tool can be scored on whether it resolves a cross-reference correctly.

That stopped being true without anybody noticing. On 2026-09-16 the §1 service table named fourteen
directories and TWELVE of them did not exist, four directories that DO exist were named nowhere, and
five of the thirteen top-level directories in §6.1 were absent. Every one of those was a row someone
could have scored a tool against.

An answer key that is only prose decays in silence: nothing fails, nothing warns, and the document
goes on asserting what was true when it was written. So the derivable half of the specification is
checked by this script, the same way `plant_secrets.py --check` checks the credential state. It
asserts only what a filesystem can settle -- paths, service names, contract documents. It says
nothing about whether the prose is right, which is not a thing a script can know.

What it checks, and what each failure would mean:

  * every path in SPEC section 6.1 and 6.2 either exists or is declared unbuilt in 6.0
  * every service in section 1 has an OpenAPI document in contracts/openapi/
  * every directory under services/ is accounted for in 6.0
  * every top-level directory under corpus/ is accounted for in 6.1 or 6.0
  * section 6.0's own table matches the tree it claims to describe

Exit 0 means the map and the tree agree. Nothing here needs network, and nothing here writes.
"""
import io
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SPEC = ROOT / "corpus" / "SPEC.md"
CORPUS = ROOT / "corpus"

QUIET = "--quiet" in sys.argv


def say(*a):
    if not QUIET:
        print(*a)


def _section(text, start, end=None):
    i = text.find(start)
    if i < 0:
        return ""
    j = text.find(end, i) if end else len(text)
    return text[i:j if j > 0 else len(text)]


def main():
    if not SPEC.is_file():
        sys.exit(f"no spec at {SPEC}")
    text = io.open(SPEC, encoding="utf-8").read()
    problems, checked = [], 0

    # --- what 6.0 declares unbuilt, so a specified-but-absent path is a statement, not a lie ----
    s60 = _section(text, "### 6.0 What is actually in this repository", "### 6.1")
    if not s60:
        problems.append("SPEC has no section 6.0 -- nothing declares which paths are unbuilt")
    declared_unbuilt = set(re.findall(r"`([\w./-]+/)`", s60))

    # --- 6.1 and 6.2: every path either exists or is declared unbuilt ---------------------------
    for label, start, end in (("6.1", "### 6.1 Top-level", "### 6.2"),
                              ("6.2", "### 6.2 `services/`", "### 6.3")):
        sec = _section(text, start, end)
        paths = re.findall(r"^\| `([^`]+/)` \|", sec, re.M)
        if not paths:
            problems.append(f"section {label} lists no paths -- the table shape changed")
        for p in paths:
            checked += 1
            if (CORPUS / p.rstrip("/")).is_dir():
                continue
            if p in declared_unbuilt:
                continue
            problems.append(f"{label}: `{p}` does not exist and 6.0 does not say it is unbuilt")

    # --- section 1: every service has a contract, built or not ---------------------------------
    s1 = _section(text, "## 1. The fourteen backend services", "## 2.")
    services = re.findall(r"^\| *\d+ \| \*\*([\w-]+)\*\* \|", s1, re.M)
    if len(services) != 14:
        problems.append(f"section 1 names {len(services)} services, and its heading says fourteen")
    openapi = CORPUS / "contracts" / "openapi"
    have = {p.stem for p in openapi.glob("*.yaml")} | {p.stem for p in openapi.glob("*.yml")}
    for name in services:
        checked += 1
        if name not in have:
            problems.append(f"1: {name} has no document in contracts/openapi/")

    # --- every directory that EXISTS is accounted for somewhere ---------------------------------
    s61 = _section(text, "### 6.1 Top-level", "### 6.2")
    named_top = set(re.findall(r"`([\w.-]+)/`", s61)) | set(re.findall(r"`([\w.-]+)/`", s60))
    for d in sorted(p.name for p in CORPUS.iterdir() if p.is_dir()):
        checked += 1
        if d not in named_top:
            problems.append(f"6.1: corpus/{d}/ exists and is named in neither 6.1 nor 6.0")

    named_svc = set(re.findall(r"`services/([\w-]+)/`", s60 + _section(text, "### 6.2 `services/`", "### 6.3")))
    svc_dir = CORPUS / "services"
    for d in sorted(p.name for p in svc_dir.iterdir() if p.is_dir()) if svc_dir.is_dir() else []:
        checked += 1
        if d not in named_svc:
            problems.append(f"6.2: services/{d}/ exists and is named in neither 6.2 nor 6.0")

    # --- 6.0's own table must describe the tree it claims to -----------------------------------
    for p in re.findall(r"^\| `(services/[\w-]+/)` \| ", s60, re.M):
        checked += 1
        if not (CORPUS / p.rstrip("/")).is_dir():
            problems.append(f"6.0: its own table names `{p}`, which does not exist")

    say(f"checked {checked} claim(s) the filesystem can settle")
    if problems:
        print()
        for p in problems:
            print(f"  {p}")
        print(f"\n{len(problems)} of {checked} do not resolve. The answer key and the tree disagree.")
        return 1
    print(f"all {checked} resolve — SPEC.md and the tree agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
