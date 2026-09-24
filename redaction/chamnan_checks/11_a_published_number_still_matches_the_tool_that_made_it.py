# ------------------ R2 RQ7: a number the README asks a reader to TRUST must still be true
# 🎯 [owner 2026-09-24] Moved from chamnan's surgical pool with the benchmark it measures: the
# recall tool and its key-shaped tables now live in chamnan-corpus `redaction/recall.py`.
# Banked 2026-09-12 as "design waits until anyone proposes publishing a second metric". That gate
# closed on 2026-09-15, when a second redactor metric was added to the same table — the touch rate
# on real content, beside the recall figure that was already there. Nobody proposed it; it was
# simply published, which is how the gate would always have closed.
#
# RQ7 asked for a machine-readable evidence ledger: claim_id, value, numerator, denominator, corpus
# manifest hash, class counts, and a release verifier that fails when a cited value changes without
# its denominator changing. That is a design for a repository publishing many metrics. This one
# publishes three, in one table, from one tool — so the ledger is answered by asking the TOOL.
#
# The lesson underneath is already recorded here: a number written into a pinned file decays. The
# README's redaction figures are the ones a reader is asked to trust the most, and until now nothing
# re-derived them. They were true when checked by hand on 2026-09-16; this is what keeps them true.
import re as _re164
import subprocess as _sp164
import sys as _sys164
from pathlib import Path as _P164
import importlib as _im164

_PKG164 = _P164(_im164.import_module("redact").__file__).resolve().parent.parent
_TOOL164 = _PKG164.parent / "chamnan-corpus" / "redaction" / "recall.py"

check("THE TOOL THE README CREDITS ITS FIGURES TO IS IN chamnan-corpus", _TOOL164.is_file(), saw=str(_TOOL164))

if _TOOL164.is_file():
    try:
        # encoding named explicitly: text mode without it decodes with the machine's codec, which
        # is cp1252 on the Windows runner, and a stray byte kills the reader thread rather than
        # the call.
        _run164 = _sp164.run([_sys164.executable, str(_TOOL164), "--chamnan", str(_PKG164)], capture_output=True, text=True,
                             encoding="utf-8", errors="replace",
                             timeout=300, cwd=str(_PKG164))
        _out164 = _run164.stdout or ""
    except (OSError, _sp164.SubprocessError) as _e164:
        _out164 = ""
        print("      DETAIL  the tool did not run: %s" % type(_e164).__name__)

    # What the tool says now. Parsed from its own output rather than recomputed here, because a
    # second implementation of the measurement would drift from the one the README names.
    def _pair164(label):
        m = _re164.search(r"%s\s+([\d.]+)%%\s+\((\d+)/(\d+)" % label, _out164)
        return (m.group(1), int(m.group(2)), int(m.group(3))) if m else None

    _recall164 = _pair164("recall")
    _bare164 = _re164.search(r"bare\s+([\d.]+)%\s+\((\d+)/(\d+)\)", _out164)
    _damaged164 = _re164.search(r"(\d+)/(\d+) ordinary strings damaged", _out164)
    print("      DETAIL  tool now reports recall=%s bare=%s damaged=%s"
          % (_recall164, _bare164.groups() if _bare164 else None,
             _damaged164.groups() if _damaged164 else None))

    check("...and it still produces the three figures the README quotes",
          bool(_recall164 and _bare164 and _damaged164),
          saw="the tool's output shape changed; the README's figures cannot be verified from it")

    _readme164 = (_PKG164 / "README.md").read_text(encoding="utf-8", errors="replace")
    _claims164 = []
    if _recall164:
        _claims164.append(("recall", "%s%%" % _recall164[0],
                           "%d of %d" % (_recall164[1], _recall164[2])))
    if _bare164:
        _claims164.append(("weakest class", "%s%%" % _bare164.group(1),
                           "%s of %s" % (_bare164.group(2), _bare164.group(3))))
    if _damaged164:
        _claims164.append(("decoys damaged", None,
                           "%s of %s ordinary strings damaged"
                           % (_damaged164.group(1), _damaged164.group(2))))

    # \U0001f41b Twice wrong before this worked, and both bugs had the same shape: a test that
    # cannot fail. First an `if`/`elif`, so the percentage was only examined once the fraction had
    # already failed. Then a bare substring search over the WHOLE README — and `99.0%` also appears
    # in the FAQ, so a drifted table still "found" it somewhere else in the file.
    #
    # A claim is a percentage AND its fraction, standing together on ONE line. That is what is
    # checked, and it is why the mutation test now bites.
    _stale164 = []
    _lines164 = _readme164.split("\n")
    for _name164, _pct164, _frac164 in _claims164:
        _where164 = [l for l in _lines164 if _frac164 in l]
        if not _where164:
            _stale164.append("%s: the tool says %r and no line of the README says it"
                             % (_name164, _frac164))
            continue
        if _pct164 and not any(_pct164 in l for l in _where164):
            _stale164.append("%s: the tool says %s beside %r, and the README's own line does not"
                             % (_name164, _pct164, _frac164))
    for _x164 in _stale164:
        print("      DETAIL  %s" % _x164)

    check("EVERY REDACTION FIGURE THE README PUBLISHES IS WHAT THE TOOL PRODUCES TODAY",
          not _stale164,
          saw="a number a reader is asked to trust has drifted from the tool it is credited to — "
              "re-run tools/redactor_recall.py and update the table, or explain the difference")
    check("...and there were claims to check, so that is not a pass over an empty list",
          len(_claims164) >= 3, saw="%d claim(s) parsed from the tool" % len(_claims164))

    # 🐛 A denominator is what makes a percentage checkable at all. RQ7's own example was a blended
    # metric published while the class that actually leaked had zero test cases behind it — the
    # percentage looked fine because nothing said what it was a percentage OF.
    _bare_pct164 = _re164.findall(r"\*\*(\d+(?:\.\d+)?%)\*\* — (?!\d+ of \d+)", _readme164)
    _table164 = _readme164[_readme164.find("| recall |"):][:1800] if "| recall |" in _readme164 else ""
    _nodenom164 = [p for p in _re164.findall(r"\*\*(\d+(?:\.\d+)?%)\*\*", _table164)
                   if not _re164.search(r"\*\*%s\*\* — \d+ of \d+" % _re164.escape(p), _table164)]
    print("      DETAIL  figures in the redaction table without a denominator beside them: %d"
          % len(_nodenom164))
    check("...and every percentage in that table says what it is a percentage OF",
          not _nodenom164,
          saw="%s — a percentage with no denominator cannot be checked, which is the failure RQ7 "
              "was written about" % ", ".join(_nodenom164))
