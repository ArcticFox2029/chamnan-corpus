#!/usr/bin/env python3
"""Plant the failure classes the four-plugin comparison measured, as conditions in this corpus.

`four_plugins_2026-09-22.pdf` compared chamnan against three shipped plugins across nine classes
that chamnan itself hit between 1.16 and 1.22. Eight of the nine are properties of a REPOSITORY,
not of a plugin -- which means a corpus can carry them, and a run over this corpus then exercises
the real path instead of a unit fixture. `plant_rule_patterns.py` already covers the ninth (ReDoS).

  concurrent    two writers on one file -- the class ponytail loses on, and chamnan's own index hit
  clockjump     mtimes and records from the future, and a log that runs backwards
  silentwrite   a path a writer CANNOT write, so a swallowed error has somewhere to show
  encodings     BOM, UTF-16, Latin-1, CP874, and bytes that are not valid UTF-8 at all
  unreadable    the two languages the 97.2% comment ceiling is actually made of
  extensions    suffixes outside the 113 the reader knows
  windows       names and line endings that are legal here and illegal on a Windows checkout

The `windows` group is INSTALL-ONLY. A file named `NUL`, or ending in a dot or a space, makes
`git clone` fail outright on Windows -- so committing one would not test a Windows reader, it
would stop anyone on Windows from ever reaching the corpus. They ship as placeholders and
`--install` renames them locally.

Usage: python3 plant_failure_classes.py [--dry-run] [--install]
"""
import datetime as dt
import json
import os
import pathlib
import stat
import sys

HERE = pathlib.Path(__file__).resolve().parent
WS = HERE / ".chamnan"
EDGE = HERE / "corpus" / "edge"

PLANTED = []
DRY = False
INSTALL = False


def _w(path, data, note, *, binary=False):
    rel = path.relative_to(HERE)
    PLANTED.append({"file": str(rel), "hazard": note,
                    "bytes": len(data if binary else data.encode("utf-8"))})
    if DRY:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if binary:
        path.write_bytes(data)
    else:
        path.write_text(data, encoding="utf-8")


# ---- concurrent read-modify-write ----------------------------------------------------------
def concurrent():
    """The shape, plus the harness that actually contends for it.

    The comparison read this at the write site rather than running it, and found ponytail reading,
    editing and writing a shared config with no lock, no tmp+rename, and a parse failure falling to
    `{}` in silence. chamnan hit the same shape on its own index. A corpus can carry the file both
    halves need: one that every writer wants to update, and a harness that makes them collide.
    """
    _w(WS / "state" / "contended.json",
       json.dumps({"counter": 0, "writers": {}}, indent=1) + "\n",
       "a shared state file for two writers to race over")
    _w(EDGE / "concurrency" / "hammer.py",
       '#!/usr/bin/env python3\n'
       '"""Race N processes on one JSON file and report what the file lost.\n\n'
       'A writer that is atomic AND locked finishes with counter == N. A writer that is only\n'
       'atomic finishes with a valid file and a counter BELOW N -- the lost update. A writer that\n'
       'is neither can leave the file unparseable, which a reader that falls back to `{}` then\n'
       'reports as an empty workspace rather than as damage.\n\n'
       'Usage: python3 hammer.py <path.json> <writers> [--atomic] [--locked]\n"""\n'
       'import json, os, sys, tempfile, time\n'
       'from multiprocessing import Process\n\n'
       'def bump(path, atomic, locked):\n'
       '    fh = open(path + ".lock", "w") if locked else None\n'
       '    if fh:\n'
       '        import fcntl; fcntl.flock(fh, fcntl.LOCK_EX)\n'
       '    try:\n'
       '        try:\n'
       '            d = json.loads(open(path).read())\n'
       '        except Exception:\n'
       '            d = {}          # the fallback that turns damage into an empty workspace\n'
       '        d["counter"] = d.get("counter", 0) + 1\n'
       '        time.sleep(0.02)   # the read-modify-write WINDOW. Without it the whole cycle is\n'
       '                           # faster than the scheduler can interleave, every arm reports\n'
       '                           # N of N, and the harness is a check that cannot fail.\n'
       '        text = json.dumps(d)\n'
       '        if atomic:\n'
       '            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")\n'
       '            os.write(fd, text.encode()); os.close(fd); os.replace(tmp, path)\n'
       '        else:\n'
       '            open(path, "w").write(text)\n'
       '    finally:\n'
       '        if fh:\n'
       '            fh.close()\n\n'
       'if __name__ == "__main__":\n'
       '    path, n = sys.argv[1], int(sys.argv[2])\n'
       '    atomic, locked = "--atomic" in sys.argv, "--locked" in sys.argv\n'
       '    open(path, "w").write(json.dumps({"counter": 0}))\n'
       '    ps = [Process(target=bump, args=(path, atomic, locked)) for _ in range(n)]\n'
       '    [p.start() for p in ps]; [p.join() for p in ps]\n'
       '    try:\n'
       '        got = json.loads(open(path).read()).get("counter")\n'
       '        print(f"  {got} of {n} writes survived" if got == n else\n'
       '              f"  LOST UPDATE: {got} of {n} writes survived")\n'
       '    except Exception as e:\n'
       '        print(f"  TORN FILE: the result does not parse -- {e}")\n',
       "a harness that produces a lost update on demand")
    _w(EDGE / "concurrency" / "parse-failure-is-an-empty-dict.json",
       '{"settings": {"retention": 5}, "truncated_here',
       "the config whose parse failure a reader is tempted to answer with {}")


# ---- a clock that jumps ---------------------------------------------------------------------
def clockjump():
    """Retention is the only feature a clock can hurt, and only chamnan has one.

    A clock that jumps forward retires everything at once; a clock that jumps back means nothing
    ever ages out. Both are ordinary on a laptop that sleeps, and neither shows up in a fixture
    whose files were all written in the same second.
    """
    far = dt.datetime(2099, 12, 31).timestamp()
    past = dt.datetime(1981, 1, 1).timestamp()
    rows = [
        ("logs/dated-in-the-future.jsonl", far,
         '{"t": "2099-12-31T00:00:00", "what": "written seventy years from now"}\n',
         "a log file whose mtime is in the future -- age is negative"),
        ("logs/dated-before-the-project.jsonl", past,
         '{"t": "1981-01-01T00:00:00", "what": "older than the tool reading it"}\n',
         "a log file older than anything the retention window contemplates"),
        ("state/timestamps-from-the-future.json", None,
         json.dumps({"written": "2099-12-31T23:59:59Z", "expires": "1981-01-01T00:00:00Z"},
                    indent=1) + "\n",
         "a record that expires before it was written"),
    ]
    for rel, mtime, text, note in rows:
        p = WS / rel
        _w(p, text, note)
        if not DRY and mtime is not None:
            os.utime(p, (mtime, mtime))
    _w(WS / "logs" / "runs-backwards.jsonl",
       "".join(json.dumps({"t": f"2026-09-{24 - i:02d}T00:00:00", "seq": i}) + "\n"
               for i in range(20)),
       "an append-only log whose records go backwards in time")


# ---- a write that cannot succeed -------------------------------------------------------------
def silentwrite():
    """A swallowed write error is invisible until something is missing, so give it a place to happen.

    A read-only directory inside the workspace is the cheapest reproduction: every writer that
    touches it either raises, warns, or returns as if it had worked -- and only the third is a bug.
    """
    d = WS / "state" / "read-only"
    if not DRY:
        if d.exists():
            os.chmod(d, 0o700)          # a previous run left it unwritable, which is the point
            for q in d.iterdir():
                os.chmod(q, 0o600)
        d.mkdir(parents=True, exist_ok=True)
        (d / "existing.json").write_text('{"ok": true}\n', encoding="utf-8")
        os.chmod(d / "existing.json", stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
        os.chmod(d, stat.S_IRUSR | stat.S_IXUSR)
    PLANTED.append({"file": ".chamnan/state/read-only/", "bytes": 0,
                    "hazard": "a directory a writer cannot write into"})
    PLANTED.append({"file": ".chamnan/state/read-only/existing.json", "bytes": 13,
                    "hazard": "a file a writer cannot overwrite"})


# ---- encodings -------------------------------------------------------------------------------
def encodings():
    """Everything the reader has to decode before it can decide anything at all."""
    text = "# หัวข้อ\n\nบรรทัดภาษาไทยที่ต้องอ่านออกไม่ว่าจะเข้ารหัสมาแบบไหน\n"
    _w(EDGE / "encodings" / "utf8-bom.md", "\ufeff" + text, "UTF-8 behind a byte-order mark")
    _w(EDGE / "encodings" / "utf16-le.md", text.encode("utf-16-le"),
       "UTF-16 LE with no BOM -- every other byte is NUL", binary=True)
    _w(EDGE / "encodings" / "utf16-bom.md", text.encode("utf-16"),
       "UTF-16 with a BOM", binary=True)
    _w(EDGE / "encodings" / "cp874-thai.md", text.encode("cp874", errors="replace"),
       "Thai in CP874, which UTF-8 decoding cannot read", binary=True)
    _w(EDGE / "encodings" / "latin1.md",
       "# R\u00e9sum\u00e9\n\nCaf\u00e9, na\u00efve, \u00fcber.\n".encode("latin-1"),
       "Latin-1 -- valid bytes, invalid UTF-8", binary=True)
    _w(EDGE / "encodings" / "not-valid-utf8.md",
       b"# heading\n\n\xff\xfe\x00\x80\x81 these bytes decode as nothing\n",
       "bytes that are not valid in any of the above", binary=True)
    _w(EDGE / "encodings" / "mixed-in-one-file.md",
       "# ASCII heading\n".encode("utf-8")
       + "caf\u00e9 in latin-1\n".encode("latin-1")
       + "\u0e44\u0e17\u0e22 in utf-8\n".encode("utf-8"),
       "three encodings inside one file", binary=True)
    _w(EDGE / "encodings" / "nul-in-the-middle.md",
       b"# heading\n\nbefore\x00after -- a text file with a NUL in it\n",
       "a NUL byte inside a text file", binary=True)
    _w(EDGE / "encodings" / "crlf.md", "# heading\r\n\r\nevery line ends CRLF\r\n",
       "CRLF line endings")
    _w(EDGE / "encodings" / "cr-only.md", "# heading\r\rclassic Mac line endings\r",
       "CR-only line endings, which split into one line")
    _w(EDGE / "encodings" / "no-final-newline.md", "# heading\n\nthe last line just stops",
       "no newline at end of file")


# ---- the two languages the comment ceiling is made of -----------------------------------------
def unreadable():
    """97.2% was measured, and the missing 2.8% was named: 3 Perl files and 2 Python 2 files.

    Naming a gap is worth more than a round number, and it only stays worth something if the gap is
    still reachable. These are the shapes that produced it.
    """
    _w(EDGE / "unreadable" / "no-reader.pl",
       "#!/usr/bin/perl\n# A POD block is the comment form here, and it is not a # line.\n\n"
       "=head1 DESCRIPTION\n\nThis is the documentation a reader would have to understand.\n\n=cut\n\n"
       "sub main { print \"hello\\n\"; }\n",
       "Perl POD -- the form with no reader")
    _w(EDGE / "unreadable" / "also-no-reader.pm",
       "package Corpus::Sample;\n=pod\n\nModule documentation, in POD again.\n\n=cut\n1;\n",
       "a Perl module, same form")
    _w(EDGE / "unreadable" / "python2-print.py",
       "# A Python 2 file. The ast module in 3 cannot parse it, so the comment above is\n"
       "# unreachable by the reader even though it is an ordinary # comment.\n"
       "print 'no parentheses'\n"
       "exec 'x = 1'\n"
       "raise ValueError, 'the old raise form'\n",
       "Python 2 -- an ordinary comment behind an unparseable file")
    _w(EDGE / "unreadable" / "python2-unicode.py",
       "# coding: utf-8\n# Another Python 2 shape.\n"
       "u = u'unicode literal'\nd = {1: 2}\nprint d.has_key(1)\n",
       "Python 2 again, a different unparseable construct")
    _w(EDGE / "unreadable" / "empty.py", "", "a source file with no bytes")
    _w(EDGE / "unreadable" / "comment-only.py",
       "# The whole file is a comment. There is nothing for a structure reader to attach it to.\n",
       "a source file that is only a comment")
    _w(EDGE / "unreadable" / "shebang-lies.py",
       "#!/bin/bash\n# The shebang says bash and the extension says Python. One of them is wrong,\n"
       "# and which one a reader believes changes how it reads the file.\n"
       "echo \"or is it\"\n",
       "a shebang that contradicts the extension")


# ---- suffixes outside the 113 -----------------------------------------------------------------
def extensions():
    """113 known suffixes is a count that can only be tested by exceeding it."""
    unknown = ["zig", "odin", "nim", "crystal", "hx", "v", "jai", "gleam", "roc", "grain",
               "wren", "janet", "carp", "pony", "chapel", "futhark", "idr", "lean", "agda", "elm"]
    for ext in unknown:
        _w(EDGE / "extensions" / f"sample.{ext}",
           f"// a {ext} source file\n// The comment above is in this language's comment form, and\n"
           f"// whether the reader knows that form is the whole question.\n"
           f"fn main() {{ }}\n",
           f"an unknown suffix (.{ext})" if ext == unknown[0] else "")
    _w(EDGE / "extensions" / "no-extension-at-all",
       "#!/usr/bin/env python3\n# The shebang is the only thing that says what this is.\n",
       "a file with no extension, identified only by its shebang")
    _w(EDGE / "extensions" / "archive.tar.gz.md",
       "# Not an archive\n\nThe name carries three suffixes and the last one is the true one.\n",
       "a name with three suffixes")
    _w(EDGE / "extensions" / ".md",
       "# A file whose entire name is an extension\n",
       "a file whose whole name is a suffix")


# ---- names that are legal here and fatal on Windows --------------------------------------------
_UNSAFE = __import__("re").compile(r'[:|?*"<>]')
_WINDOWS = [
    ("CON.md", "a reserved DOS device name"),
    ("NUL.md", "a reserved DOS device name"),
    ("PRN.md", "a reserved DOS device name"),
    ("AUX.md", "a reserved DOS device name"),
    ("LPT1.md", "a reserved DOS device name"),
    ("COM1.md", "a reserved DOS device name"),
    ("trailing-dot.md.", "a name ending in a dot"),
    ("trailing-space.md ", "a name ending in a space"),
    ("colon:in:name.md", "a colon in a name"),
    ("pipe|in|name.md", "a pipe in a name"),
    ("question?.md", "a question mark in a name"),
    ("star*.md", "an asterisk in a name"),
    ("quote\".md", "a double quote in a name"),
    ("less<greater>.md", "angle brackets in a name"),
]


def windows():
    """Install-only, and the reason is worth stating in the corpus rather than in a commit message.

    A committed file named `NUL` does not test a Windows reader. It makes `git clone` fail on
    Windows before any reader runs, so the only thing it would prove is that nobody on Windows can
    use this corpus. They ship as `.reserved-name` placeholders; `--install` puts the real names
    down locally, and they stay untracked.
    """
    root = EDGE / "windows-hostile"
    body = ("# A name that is legal on this filesystem and fatal on another\n\n"
            "Nothing about the CONTENT is the hazard. The name is.\n")
    for name, note in _WINDOWS:
        # The placeholder's OWN name has to survive a Windows checkout, or the group defeats
        # itself: `colon:in:name.md.reserved-name` fails to clone for exactly the reason the
        # real name does. Only the character that makes the hazard is escaped.
        safe = "".join(f"%{ord(c):02X}" for c in name) if _UNSAFE.search(name) else name
        _w(root / (safe + ".reserved-name"),
           body + f"\nreal-name: {name!r}\n", f"placeholder for {note}: `{name}`")
    if INSTALL and not DRY:
        made = 0
        for name, _ in _WINDOWS:
            try:
                (root / name).write_text(body, encoding="utf-8")
                made += 1
            except OSError:
                pass
        print(f"  --install: {made} of {len(_WINDOWS)} hostile names created locally")
    _w(root / "README.md",
       "# Names this filesystem allows and a Windows checkout does not\n\n"
       "Each `*.reserved-name` file here is a placeholder. Its real name -- the one in the file's\n"
       "first line -- would make `git clone` fail on Windows, which would prove nothing except\n"
       "that nobody on Windows can use this corpus.\n\n"
       "`python3 plant_failure_classes.py --install` puts the real names down locally. They are\n"
       "untracked by design; `.gitignore` keeps them that way.\n\n"
       + "\n".join(f"- `{n}` -- {note}" for n, note in _WINDOWS) + "\n",
       "the note explaining why the group is install-only")


# ---- patterns assembled at runtime, which no scan can see ---------------------------------------
def runtimeregex():
    """The comparison's own words for what it could not measure, in any of the four tools.

    Extracting regex literals from source finds the literals. Running them finds what runs. Neither
    sees a pattern that does not exist until a variable is read -- and a variable read from a
    repository is a pattern the repository's author chose. The 557 patterns fired in V8 were all
    literals plus 20 built with `new RegExp(string)` where the string was itself a literal; a string
    that arrives from a file is the case with no method behind it at all.
    """
    root = EDGE / "runtime-regex"
    _w(root / "README.md",
       "# Patterns that do not exist until something is read\n\n"
       "Every file here builds a regular expression from data rather than from source. The data is\n"
       "in this repository, so whoever wrote the repository chose the pattern -- and a scan of the\n"
       "SOURCE finds `re.compile(pattern)` with nothing to say about it.\n\n"
       "This is the blind spot the four-plugin comparison named for all four tools: \"a pattern\n"
       "assembled from a variable at runtime is invisible to extraction and to execution alike\".\n",
       "the note naming the blind spot")
    _w(root / "patterns.txt",
       "# One pattern per line. Read and compiled by build_matcher.py below.\n"
       "(a+)+$\n"
       "(x|x)*y\n"
       "^(\\w+\\s?)*$\n"
       "ordinary-and-harmless\n",
       "the DATA that becomes the pattern -- two of these four will not terminate")
    _w(root / "build_matcher.py",
       "import pathlib, re\n\n"
       "# A scan of this file finds one `re.compile` and one variable. The hazard is in\n"
       "# patterns.txt beside it, which is data, and data is not scanned for patterns.\n"
       "PATTERNS = [l.strip() for l in pathlib.Path('patterns.txt').read_text().splitlines()\n"
       "            if l.strip() and not l.startswith('#')]\n"
       "MATCHERS = [re.compile(p) for p in PATTERNS]\n",
       "source that compiles whatever the data file says")
    _w(root / "build_matcher.js",
       "const fs = require('fs');\n\n"
       "// The JavaScript form of the same thing. `new RegExp(string)` where the string came from\n"
       "// disk is what neither literal-extraction nor a worker fired at literals can reach.\n"
       "const patterns = fs.readFileSync('patterns.txt', 'utf8').split('\\n')\n"
       "  .filter(l => l && !l.startsWith('#'));\n"
       "const matchers = patterns.map(p => new RegExp(p));\n",
       "the same construction in the engine the comparison actually fired")
    _w(root / "assembled-from-pieces.py",
       "import re\n\n"
       "# Worse than reading a file: no single string in this source is a pattern. Concatenation\n"
       "# is what makes one, and the pieces are individually meaningless.\n"
       "OPEN, ATOM, CLOSE, QUANT = '(', 'a+', ')', '+'\n"
       "RX = re.compile(OPEN + ATOM + CLOSE + QUANT)\n",
       "a pattern that is not a string anywhere in the source")
    _w(root / "from-an-environment-variable.py",
       "import os, re\n\n"
       "# And the form that is not even in the repository: the pattern is in the environment.\n"
       "RX = re.compile(os.environ.get('CORPUS_FILTER', '.*'))\n",
       "a pattern that is not in the repository at all")


# ---- a cap that counts items when the cost is bytes ---------------------------------------------
def countcap():
    """N records of any length is not a bound, and the comparison put a name to it.

    One tool caps continuity at the first N observations (`slice(0, count)`); chamnan caps at a
    byte ceiling. The two behave identically until a record is large, and then only one of them is
    still a bound. These records are ordinary in every way except length.
    """
    root = EDGE / "count-vs-bytes"
    _w(root / "README.md",
       "# Ten records, and any count-based cap admits all of them\n\n"
       "`slice(0, 10)` takes ten records. Ten of THESE records is 5 MB. Nothing here is malformed\n"
       "and nothing is adversarial -- a long working day produces a long record.\n\n"
       "A byte ceiling and a count cap agree on every ordinary input, which is why the difference\n"
       "only ever shows up in production.\n",
       "the note naming the difference")
    for i in range(10):
        _w(root / f"observation-{i:02d}.md",
           f"# Observation {i}\n\n"
           + (f"A line of an ordinary working note, the {i}th of many, written by somebody who "
              f"had a lot to say about what they were doing.\n" * 4000),
           "one of ten records of ~500 KB each" if i == 0 else "")


GROUPS = [concurrent, clockjump, silentwrite, encodings,
          unreadable, extensions, windows, runtimeregex, countcap]

if __name__ == "__main__":
    DRY = "--dry-run" in sys.argv
    INSTALL = "--install" in sys.argv
    for fn in GROUPS:
        fn()
    named = [p for p in PLANTED if p["hazard"]]
    if DRY:
        for p in named:
            print(f"  {p['bytes']:>8,}  {p['file']:<56} {p['hazard']}")
    else:
        out = HERE / ".chamnan" / "state" / "PLANTED_FAILURE_CLASSES.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(PLANTED, indent=1) + "\n", encoding="utf-8")
    print(f"  {len(PLANTED)} file(s), {len(named)} distinct hazard(s) across {len(GROUPS)} class(es)")
