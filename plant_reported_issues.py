#!/usr/bin/env python3
"""Plant the conditions that real users reported against real tools.

Every group here names the issue it came from. None of these are invented: each is a filed,
reproduced report against a tool people actually run, collected while researching chamnan and
carried in `chamnan_research_backlog.md` with its URL. What they have in common is that the tool
answered, the answer looked fine, and the answer was wrong -- which is the only class of bug a
corpus can plant, because a crash announces itself and this does not.

Secrets follow this repository's convention: the tracked form is a `__PLANTED_…__` placeholder and
`plant_secrets.py` fills it locally, so the committed file carries no credential at any fidelity.

  boundary    gitleaks#1432 -- a large file reported clean in 187 ms; the secret was at line
              62,190, and moving it one line earlier found it. A size cap that admits a file does
              not promise the whole file was read.
  sizecap     semgrep's 1,000,000-byte default against chamnan's 2,000,000 -- files that one
              admits and the other silently drops.
  denied      ripgrep#863 and #2861 -- a permission-denied directory returns zero results and
              zero explanation. ripgrep's own message says it "probably applied a filter you
              didn't expect". Still open.
  confusable  openai/codex#13095 -- Cyrillic look-alikes walk past exec-policy matching because
              the matcher compares code points and the fold runs after the check.
  entropy     gitleaks#1830 and #1578 -- dictionary words, placeholders and commit hashes score
              above real generated credentials, so a threshold cannot separate them.
  longpath    Windows MAX_PATH 260 and pytest#291 -- paths that are fine until the prefix is long.
  install     claude-code#72616, claude-code#31941, pnpm#3840, pip#5412 -- four tools where an
              install or version command reported success or currency that its own files denied.

Usage: python3 plant_reported_issues.py [--dry-run]
"""
import json
import os
import pathlib
import stat
import sys

HERE = pathlib.Path(__file__).resolve().parent
EDGE = HERE / "corpus" / "edge" / "reported"
PLANTED = []
DRY = False
INSTALL = False


def _w(path, text, note, cite="", *, binary=False):
    PLANTED.append({"file": str(path.relative_to(HERE)), "hazard": note, "cite": cite,
                    "bytes": len(text if binary else text.encode("utf-8"))})
    if DRY:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text) if binary else path.write_text(text, encoding="utf-8")


_GL1432 = "https://github.com/gitleaks/gitleaks/issues/1432"
_RG863 = "https://github.com/BurntSushi/ripgrep/issues/863"
_CODEX = "https://github.com/openai/codex/issues/13095"
_GL1830 = "https://github.com/gitleaks/gitleaks/issues/1830"
_PYTEST = "https://github.com/pytest-dev/pytest/issues/291"
_CC72616 = "https://github.com/anthropics/claude-code/issues/72616"


def boundary():
    """A file under the cap, with the secret at the far end of it.

    The reported shape: 100 MB scanned in 187 ms reporting no leaks, the secret sitting at line
    62,190; put it one line earlier and the same scanner found it in 1.3 s. "Under the cap" and
    "read to the end" are two different promises, and only one of them was being made.
    """
    filler = "log line that is ordinary in every way and exists only to take up room\n"
    for tag, size, note in [("just-under-2mb", 1_900_000, "just under the 2 MB ceiling"),
                            ("just-over-2mb", 2_100_000, "just over the 2 MB ceiling")]:
        body = filler * (size // len(filler))
        _w(EDGE / "boundary" / f"secret-at-the-end-{tag}.log",
           body + "aws_access_key_id = __PLANTED_AWS_KEY__\n",
           f"a credential on the LAST line of a file {note}", _GL1432)
        _w(EDGE / "boundary" / f"secret-at-the-start-{tag}.log",
           "aws_access_key_id = __PLANTED_AWS_KEY__\n" + body,
           f"the same credential on the FIRST line, {note} -- the control", _GL1432)
    # One line, no newlines at all: every line-based bound sees a single line and every
    # offset-based one sees the whole file. The two disagree about what was scanned.
    _w(EDGE / "boundary" / "secret-in-one-enormous-line.log",
       "x" * 1_500_000 + " token=__PLANTED_GITHUB__ " + "y" * 400_000 + "\n",
       "a credential 1.5 MB into a file that has one line", _GL1432)


def sizecap():
    """Two shipped defaults, and the files that fall between them."""
    filler = "def f():\n    return 1\n"
    for name, size in [("under-semgrep-1mb.py", 900_000),
                       ("between-1mb-and-2mb.py", 1_500_000),
                       ("over-both-caps.py", 2_500_000)]:
        _w(EDGE / "sizecap" / name,
           "# A source file sized to fall on one side of a published default.\n"
           "# semgrep skips above 1,000,000 bytes; chamnan's mapper stops at 2,000,000.\n"
           + filler * (size // len(filler)),
           f"{size:,} bytes -- {'admitted by both' if size < 1_000_000 else 'admitted by one' if size < 2_000_000 else 'dropped by both'}",
           "https://semgrep.dev/docs/cli-reference#scan")


def denied():
    """A directory nothing can look inside, which reads as an empty directory.

    ripgrep's own message admits it: "No files were searched, which means ripgrep probably applied
    a filter you didn't expect." Eight years open, and #2861 asking for a flag is still open too.
    A sweep that returns zero has two causes and reports one.
    """
    root = EDGE / "denied"
    _w(root / "README.md",
       "# A directory that cannot be listed\n\n"
       "`unreadable/` is mode 000. A sweep across this tree finds nothing in it and, unless it\n"
       "says so, is indistinguishable from a sweep that looked and found nothing.\n\n"
       f"Reported against ripgrep: {_RG863}\n",
       "the note naming the ambiguity", _RG863)
    # The directory ships READABLE and `--install` takes the mode away. Committed at mode 000 its
    # contents cannot be added at all -- git says "Permission denied" and skips them, which is a
    # better answer than ripgrep gives but still leaves the fixture empty in the clone. Note that
    # git tracks no directory mode either way, so the hostile state can only ever be local.
    d = root / "unreadable"
    if not DRY:
        if d.exists():
            os.chmod(d, 0o700)
        d.mkdir(parents=True, exist_ok=True)
        (d / "has-a-secret.env").write_text(
            "GITHUB_TOKEN=__PLANTED_GITHUB__\n", encoding="utf-8")
        (d / "has-a-bug.py").write_text(
            "# A finding nothing will ever reach.\nx = 1 / 0\n", encoding="utf-8")
        if INSTALL:
            os.chmod(d, 0)
            print("  --install: corpus/edge/reported/denied/unreadable/ is now mode 000")
    PLANTED.append({"file": "corpus/edge/reported/denied/unreadable/", "bytes": 0, "cite": _RG863,
                    "hazard": "a mode-000 directory holding a credential and a bug"})


def confusable():
    """Look-alikes from another script, in the places a matcher looks.

    The codex issue is about an exec policy; the same fold problem reaches a redactor. The backlog
    records this reproduced against `redact.scrub` directly: a Cyrillic а in `password` and the
    line goes through untouched, while the plain-ASCII control redacts normally.
    """
    rows = [
        ("cyrillic-a-in-password.env", "pаssword=__PLANTED_GITHUB__\n",
         "Cyrillic а in the keyword a detector anchors on"),
        ("cyrillic-e-in-secret.env", "sеcret_key=__PLANTED_STRIPE__\n",
         "Cyrillic е in the keyword"),
        ("greek-omicron-in-token.env", "tοken=__PLANTED_GITHUB__\n",
         "Greek omicron in the keyword"),
        ("fullwidth-key.env", "ａpi＿key=__PLANTED_ANTHROPIC__\n",
         "full-width Latin in the keyword"),
        ("control-plain-ascii.env", "password=__PLANTED_GITHUB__\n",
         "the plain-ASCII control that must still be caught"),
        ("zero-width-inside-keyword.env", "pass​word=__PLANTED_GITHUB__\n",
         "a zero-width space inside the keyword"),
        ("combining-accent.env", "passwórd=__PLANTED_GITHUB__\n",
         "a combining accent inside the keyword"),
    ]
    for name, body, note in rows:
        _w(EDGE / "confusable" / name,
           "# Every line below assigns a credential. Only one of them is spelled in ASCII.\n" + body,
           note, _CODEX)


def entropy():
    """High-entropy strings that are not secrets, which is why a threshold cannot be the rule.

    Gitleaks users reported dictionary words, placeholders and commit hashes scoring above real
    generated credentials. Each line here is an ordinary thing a repository contains, and every
    one of them would survive a naive randomness cutoff.
    """
    import hashlib
    import uuid
    lines = ["# None of the strings below is a credential. All of them look like one."]
    for i in range(40):
        lines.append(f"uuid_{i} = \"{uuid.UUID(int=i * 0x9E3779B97F4A7C15 % (1 << 128))}\"")
    for i in range(40):
        lines.append(f"sha256_{i} = \"{hashlib.sha256(str(i).encode()).hexdigest()}\"")
    for i in range(20):
        lines.append(f"commit_{i} = \"{hashlib.sha1(str(i).encode()).hexdigest()}\"")
    lines += [
        'placeholder_1 = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"',
        'placeholder_2 = "YOUR_API_KEY_HERE_REPLACE_BEFORE_DEPLOYING"',
        'placeholder_3 = "AKIAIOSFODNN7EXAMPLE"      # AWS\'s own documentation example',
        'base64_asset = "' + ("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVph" * 6) + '"',
        'dictionary = "correcthorsebatterystaple"',
        'path_digest = "d41d8cd98f00b204e9800998ecf8427e"      # the empty-string MD5',
    ]
    _w(EDGE / "entropy" / "high-entropy-but-not-secret.py", "\n".join(lines) + "\n",
       "160 high-entropy strings, none of them a credential", _GL1830)
    _w(EDGE / "entropy" / "one-real-one-among-them.py",
       "\n".join(lines[:60]) + "\nreal = \"__PLANTED_STRIPE__\"\n" + "\n".join(lines[60:]) + "\n",
       "the same file with exactly one real credential hidden in it", _GL1830)


def longpath():
    """A path that is legal until the checkout prefix is long.

    Windows bounds most paths at 260 characters, and a relative path stays bounded even with long
    paths enabled. pytest hit this for real: descriptive test names made its temp paths arbitrarily
    long, and the fix was to shorten the names rather than to raise the limit.
    """
    seg = "a-descriptive-directory-name-of-the-kind-a-generator-produces"
    p = EDGE / "longpath"
    for _ in range(4):
        p = p / seg
    _w(p / ("a-descriptive-leaf-name-" + "x" * 60 + ".md"),
       "# The path to this file is past 260 characters from the repository root\n\n"
       "Nothing about the file is unusual. The path is.\n",
       "a path past the Windows MAX_PATH bound, measured from the repository root", _PYTEST)


def install():
    """Four tools, one shape: a command reported a state its own files denied.

    claude-code#72616 had three mutually inconsistent truths at once -- `lastUpdated` advanced, the
    cached manifest said 0.3.0, the installed record said 0.4.0. claude-code#31941 printed
    "Successfully installed" with no `installed_plugins.json` on disk. pnpm#3840 detected a
    modified package and then did nothing to repair it. pip#5412 said "already up-to-date" about a
    version that had been superseded three hours earlier.
    """
    root = EDGE / "install"
    _w(root / "cached-marketplace.json",
       json.dumps({"name": "example", "version": "0.3.0",
                   "lastUpdated": "2026-09-24T00:00:00Z"}, indent=1) + "\n",
       "a cached manifest that says 0.3.0", _CC72616)
    _w(root / "installed_record.json",
       json.dumps({"name": "example", "version": "0.4.0"}, indent=1) + "\n",
       "an install record that says 0.4.0 -- the same tool, the same moment", _CC72616)
    _w(root / "plugin.json",
       json.dumps({"name": "example", "version": "0.5.0"}, indent=1) + "\n",
       "the declaration on disk, which agrees with neither", _CC72616)
    _w(root / "success-with-nothing-behind-it.log",
       "Successfully installed example@0.4.0\n"
       "  (there is no installed_plugins.json in this directory, and the cache is empty)\n",
       "a success message with no postcondition behind it",
       "https://github.com/anthropics/claude-code/issues/31941")
    _w(root / "repair-that-did-nothing.log",
       "store status: 1 package is modified\n"
       "install: Already up to date. 0 packages refetched.\n"
       "store status: 1 package is modified\n",
       "detection and repair as separate postconditions, only one of them met",
       "https://github.com/pnpm/pnpm/issues/3840")
    _w(root / "README.md",
       "# Four tools that answered confidently and wrongly\n\n"
       "Every file here is a transcript or an artefact shape from a filed, reproduced issue. The\n"
       "three version files disagree with each other simultaneously, which is the condition\n"
       "claude-code#72616 describes: `lastUpdated` advanced while the cached manifest and the\n"
       "installed record named different versions, and the stale view survived until the file was\n"
       "overwritten by hand.\n\n"
       "The shared lesson is the one worth planting: a command's success string is not a\n"
       "postcondition. Only reading back what it claims to have written is.\n",
       "the note naming the shared shape", _CC72616)


GROUPS = [boundary, sizecap, denied, confusable, entropy, longpath, install]

if __name__ == "__main__":
    DRY = "--dry-run" in sys.argv
    INSTALL = "--install" in sys.argv
    for fn in GROUPS:
        fn()
    named = [p for p in PLANTED if p["hazard"]]
    if DRY:
        for p in named:
            print(f"  {p['bytes']:>9,}  {p['file'][20:]:<52} {p['hazard'][:58]}")
    else:
        out = HERE / ".chamnan" / "state" / "PLANTED_REPORTED_ISSUES.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(PLANTED, indent=1) + "\n", encoding="utf-8")
    cites = sorted({p["cite"] for p in PLANTED if p["cite"]})
    print(f"  {len(PLANTED)} file(s), {len(named)} hazard(s), {len(cites)} distinct issue(s) cited")
