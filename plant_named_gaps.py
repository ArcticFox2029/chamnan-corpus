#!/usr/bin/env python3
"""Plant the gaps chamnan's own research NAMED and did not close.

The backlog and the dead-end file are not a to-do list -- they are a record of things that were
measured, understood, and left. Several of them describe a state a REPOSITORY can be in, which
means the gap can be planted rather than remembered. Each group below cites the line it came from,
so a reader can check the claim against the record instead of against this docstring.

  nonenglish    tokens.py under-counts Arabic by 39% and Hebrew by 44% against real counts
                (backlog "agent 5, non-English repos" -- fixed the `。` split, did not act on this)
  sameday       `sessions.carry_forward()` reads ONE same-day record, so a second session that day
                loses its "Remaining" silently; `milestones.md` is one append-only file and
                conflicts the first time two people ship on the same day. Both reproduced, unfixed.
  staleness     a source file with a FUTURE mtime silences the staleness warning, and the dead-end
                entry records that clamping does not fix it -- mtime cannot answer the question
  thresholds    three constants with no coverage at all: HUGE_BYTES's "very large" wording has zero
                matches in the suite, WINDOW_HOURS has no fixture outside its 24h window, and
                chamnan-context's adapter-declared-CEILING override is untested
  conflicts     merge markers left in a tracked file, which is the ordinary end of all of the above

Usage: python3 plant_named_gaps.py [--dry-run]
"""
import datetime as dt
import json
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
WS = HERE / ".chamnan"
EDGE = HERE / "corpus" / "edge" / "named-gaps"
PLANTED = []
DRY = False


def _w(path, text, note, cite=""):
    PLANTED.append({"file": str(path.relative_to(HERE)), "hazard": note, "cite": cite,
                    "bytes": len(text.encode("utf-8"))})
    if DRY:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


_AGENT5 = "chamnan_research_backlog.md — agent 5, non-English repos"
_SAMEDAY = "chamnan_research_backlog.md — still open from agent 5"
_STALE = "chamnan_research_dead_ends.md — mtime cannot answer this question"
_AGENT3 = "chamnan_research_backlog.md — still open from agent 3"


def nonenglish():
    """Scripts whose token cost is not what a byte or character count says it is.

    The measured error is 39% low on Arabic and 44% low on Hebrew, so a budget computed from
    chamnan's own counter admits far more of these than it meant to. Every file here carries a
    docstring in one script, long enough for the difference to matter.
    """
    rows = [
        ("arabic.py", "ar",
         "هذا الملف يحتوي على وثائق مكتوبة بالعربية بالكامل. "
         "الغرض منه هو قياس عدد الرموز الحقيقي مقابل ما يحسبه العداد الداخلي. "),
        ("hebrew.py", "he",
         "הקובץ הזה מכיל תיעוד שנכתב כולו בעברית. "
         "מטרתו היא למדוד את מספר האסימונים האמיתי מול מה שהמונה הפנימי מחשב. "),
        ("japanese.py", "ja",
         "このファイルの説明文はすべて日本語で書かれている。"
         "文末は句点であり、英語の終止符ではない。"),
        ("chinese.py", "zh",
         "这个文件的文档完全用中文写成。句子以句号结束，而不是英文的句点。"),
        ("hindi.py", "hi",
         "इस फ़ाइल का दस्तावेज़ पूरी तरह हिंदी में लिखा गया है। वाक्य दंड से समाप्त होता है। "),
        ("thai.py", "th",
         "เอกสารประกอบของไฟล์นี้เขียนเป็นภาษาไทยทั้งหมด ภาษาไทยไม่มีเครื่องหมายจบประโยค "
         "และไม่มีช่องว่างระหว่างคำ จึงไม่มีอะไรให้ตัดประโยคเลย "),
        ("korean.py", "ko",
         "이 파일의 문서는 전부 한국어로 작성되었다. 문장은 마침표로 끝나지만 띄어쓰기 규칙이 다르다. "),
        ("russian.py", "ru",
         "Документация этого файла полностью написана по-русски. "
         "Предложение заканчивается точкой, как в английском, но алфавит другой. "),
    ]
    for name, tag, doc in rows:
        _w(EDGE / "non-english" / name,
           f'"""{doc * 20}"""\n\n\ndef main():\n    """{doc * 5}"""\n    return "{tag}"\n',
           f"a docstring entirely in one script ({tag}) -- long enough for a 39-44% "
           f"counting error to change a budget", _AGENT5)
    _w(EDGE / "non-english" / "mixed-scripts.py",
       '"""English opening sentence. ثم جملة بالعربية. そして日本語の文。And back to English."""\n\n'
       "# Four scripts in one docstring. Whichever sentence-splitter runs, it cuts in one\n"
       "# language's grammar and hands back a summary in another's.\n"
       "def f():\n    return 1\n",
       "four scripts inside one docstring", _AGENT5)


def sameday():
    """Two people, one day -- the case a single same-day read and a single append-only file lose.

    Both were reproduced by the agent that found them and neither was fixed. `carry_forward()`
    reads one same-day record, so the second session's Remaining work never reaches the next
    session; and `milestones.md` is one file, so two people shipping on the same day conflict.
    """
    for who, title in [("first", "the morning session"), ("second", "the afternoon session")]:
        _w(WS / "sessions" / f"2026-09-24-{who}.md",
           f"# 2026-09-24 — {title}\n\n"
           f"## What happened\n\nWork done in {title}.\n\n"
           f"## Remaining\n\n- A task left open by {title}, which the next session must see.\n",
           f"one of two same-day session records -- only one is read forward", _SAMEDAY)
    _w(WS / "milestones.md",
       "# Milestones\n\n"
       "## 2026-09-24\n\n- Shipped the thing the morning session was working on\n\n"
       "## 2026-09-24\n\n- Shipped the thing the afternoon session was working on\n",
       "two entries under one date in a single append-only file", _SAMEDAY)
    _w(EDGE / "same-day" / "README.md",
       "# Two sessions in one day\n\n"
       "Two session records share 2026-09-24 and each carries its own `## Remaining`. A reader\n"
       "that takes one same-day record forward drops the other, and neither file is malformed,\n"
       "so nothing announces the loss. `milestones.md` has the same shape from the other side:\n"
       "one append-only file, two people, one date.\n\n"
       f"Recorded in {_SAMEDAY}, reproduced there and not fixed.\n",
       "the note naming the pair", _SAMEDAY)


def staleness():
    """A source file dated in the future, which is how a staleness check stops working.

    The dead-end entry is explicit: clamping `built` to `now` was applied, tested and reverted
    because every real source file has an mtime in the past, so the comparison stays true either
    way. The conclusion recorded there is that mtime cannot answer the question at all -- so this
    plants the condition rather than a fix.
    """
    p = EDGE / "staleness" / "edited-but-dated-in-the-future.py"
    _w(p,
       "# This file was changed after the index was built, and its mtime says otherwise.\n"
       "# `newest <= built` stays true, so nothing reports the index as stale.\n"
       "def a_function_the_index_does_not_know_about():\n    return 1\n",
       "a changed source file whose mtime is in the future", _STALE)
    if not DRY:
        far = dt.datetime(2099, 12, 31).timestamp()
        os.utime(p, (far, far))
    _w(EDGE / "staleness" / "README.md",
       "# When \"the index is current\" and \"the timestamp is nonsense\" look identical\n\n"
       "`edited-but-dated-in-the-future.py` carries a function no index built before it can know\n"
       "about, and an mtime seventy years from now. Every mtime-based staleness test reads the\n"
       "index as current.\n\n"
       f"Recorded in {_STALE}: the clamp was applied, tested and reverted because it changes\n"
       "nothing, and the conclusion was that mtime cannot answer this question.\n",
       "the note naming why the fix was reverted", _STALE)


def thresholds():
    """Three constants with no coverage, each planted at the boundary it is supposed to hold.

    A fixture written as a literal beside a constant proves the mechanism and can never fail on
    the value -- measured: two ceilings were inflated 200x with the whole suite green. So these
    plant the CONDITION and leave the number to be read from the constant.
    """
    _w(EDGE / "thresholds" / "README.md",
       "# Three constants nothing exercises\n\n"
       "- `HUGE_BYTES` — its \"very large\" wording has zero matches in the suite\n"
       "- `chamnan_session_end.WINDOW_HOURS` — no fixture planted outside the 24h window\n"
       "- `bin/chamnan-context` — the adapter-declared-CEILING-overrides-default path is untested\n\n"
       f"Recorded in {_AGENT3}. A test written against these must read the constant rather than\n"
       "repeat its value: two ceilings here were once inflated two hundredfold with the whole\n"
       "suite still green, because every fixture had the number written into it by hand.\n",
       "the note naming the three untested constants", _AGENT3)
    filler = "# a line of an ordinary source file\n"
    for name, size in [("just-under-huge.py", 900_000), ("just-over-huge.py", 1_100_000)]:
        _w(EDGE / "thresholds" / name,
           "# Sized to sit either side of HUGE_BYTES, whatever HUGE_BYTES currently is.\n"
           + filler * (size // len(filler)),
           f"{size:,} bytes, for the 'very large' branch nothing reaches", _AGENT3)
    old = WS / "sessions" / "1990-01-01-outside-every-window.md"
    _w(old, "# A session record from 1990\n\nOlder than any window the tool contemplates.\n",
       "a session record far outside WINDOW_HOURS", _AGENT3)
    if not DRY:
        t = dt.datetime(1990, 1, 1).timestamp()
        os.utime(old, (t, t))
    _w(EDGE / "thresholds" / "adapter-with-its-own-ceiling" / ".cursor" / "rules" / "chamnan.mdc",
       "---\nglobs: [\"**/*.py\"]\nalwaysApply: false\nceiling: 400\n---\n\n"
       "# A rule file that declares its own ceiling and an Auto-Attached glob\n\n"
       "Cursor attaches this only when a matching file is in context. The `ceiling` here is\n"
       "smaller than the default, which is the override path nothing tests.\n",
       "an adapter file declaring both a glob activation and its own ceiling", _AGENT3)


def conflicts():
    """Merge markers in tracked files -- the ordinary end state of every gap above.

    Two people, one day, one append-only file. The markers are what the repository looks like
    afterwards, and a reader that does not notice them quotes both sides as if they were text.
    """
    _w(EDGE / "conflicts" / "unresolved.py",
       "def f():\n"
       "<<<<<<< HEAD\n"
       "    return 1\n"
       "=======\n"
       "    return 2\n"
       ">>>>>>> feature-branch\n",
       "merge markers in a tracked source file")
    _w(EDGE / "conflicts" / "unresolved.md",
       "# A document with both sides still in it\n\n"
       "<<<<<<< HEAD\nThe morning version of this paragraph.\n"
       "=======\nThe afternoon version of this paragraph.\n>>>>>>> other\n",
       "merge markers in prose, where they read as ordinary text")
    _w(EDGE / "conflicts" / "looks-like-a-conflict-but-is-not.md",
       "# Documentation ABOUT merge conflicts\n\n"
       "When git cannot merge, it writes `<<<<<<< HEAD` above your version and `>>>>>>> branch`\n"
       "below theirs. A detector that matches those strings anywhere flags this file, which is\n"
       "correct prose explaining the thing it is being mistaken for.\n",
       "prose that describes markers without containing a conflict")


GROUPS = [nonenglish, sameday, staleness, thresholds, conflicts]

if __name__ == "__main__":
    DRY = "--dry-run" in sys.argv
    for fn in GROUPS:
        fn()
    named = [p for p in PLANTED if p["hazard"]]
    if DRY:
        for p in named:
            print(f"  {p['bytes']:>9,}  {p['file'][:56]:<56} {p['hazard'][:56]}")
    else:
        out = WS / "state" / "PLANTED_NAMED_GAPS.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(PLANTED, indent=1) + "\n", encoding="utf-8")
    print(f"  {len(PLANTED)} file(s), {len(named)} hazard(s) across {len(GROUPS)} named gap(s)")
