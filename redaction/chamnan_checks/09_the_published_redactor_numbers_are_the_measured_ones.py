# ------------------------------- two documents, one measurement, and nothing made them agree
# 🎯 [owner 2026-09-24] Moved from chamnan's surgical pool with the benchmark it measures: the
# recall tool and its key-shaped tables now live in chamnan-corpus `redaction/recall.py`.
# 🐛 [2026-09-10] SECURITY.md and README.md stated different corpus sizes and different recall
# figures for the SAME measurement, and the live tool agreed with only one of them. The corpus had
# grown twice since SECURITY.md was last touched. The suite already had redactor tests; what they
# asserted was that one unrelated substring appears in README.md, so a number could drift in the
# one document whose entire job is "trust this before you commit anything" and nothing fired
# (R12 agent 5, 2026-09-10, finding 1).
#
# The figures are deliberately NOT written out anywhere below. This file is folded into the suite
# it scans, so a stale number quoted in a comment here would be found by its own check -- the trap
# this workspace has recorded as "a check that reads its own source matches itself".
#
# The fix is not to pin the numbers -- they are supposed to move as the corpus grows. It is to make
# the DOCUMENTS agree with the TOOL: whatever `redactor_recall.py` prints today is what the prose
# must say. Deriving it from the run is the difference between a check that survives the next corpus
# addition and one that has to be edited every time, which is how the first pair drifted apart.
import re as _re44
import subprocess as _sp44

_t_rr44 = ROOT.parent / "chamnan-corpus" / "redaction" / "recall.py"
if _t_rr44.is_file():
    _t_env44 = dict(os.environ, CHAMNAN_READ_ONLY="1")
    with open(os.devnull, "rb") as _t_null44:
        _t_out44 = subprocess.run([sys.executable, str(_t_rr44), "--chamnan", str(ROOT)], cwd=str(ROOT), stdin=_t_null44,
                                  capture_output=True, text=True, encoding="utf-8",
                                  errors="replace", env=_t_env44, timeout=300).stdout

    # The tool prints a recall line as "recall <pct>% (<hit>/<all> ...)" and a decoy line as
    # "<damaged>/<decoys> ordinary strings damaged". Written as shapes rather than as an example,
    # because this file is folded into the suite it scans and an example carrying digits is a
    # stale published number by its own definition — which is exactly how it failed once.
    _t_rec44 = _re44.search(r"recall\s+([\d.]+)%\s+\((\d+)/(\d+)", _t_out44)
    _t_dec44 = _re44.search(r"(\d+)/(\d+)\s+ordinary strings damaged", _t_out44)
    check("the recall tool still prints a recall figure this check can read",
          bool(_t_rec44), saw=_t_out44[:200] or None)
    check("...and a decoy-corpus figure alongside it", bool(_t_dec44), saw=_t_out44[:200] or None)

    if _t_rec44 and _t_dec44:
        _t_pct44, _t_hit44, _t_all44 = _t_rec44.group(1), _t_rec44.group(2), _t_rec44.group(3)
        _t_decoys44 = _t_dec44.group(2)
        _t_stale44 = []
        for _t_doc44 in ("README.md", "SECURITY.md", "tests/run_tests.py"):
            _t_p44 = ROOT / _t_doc44
            if not _t_p44.is_file():
                continue
            _t_txt44 = _t_p44.read_text(encoding="utf-8", errors="replace")
            # Any "<n>-string decoy corpus" or "<n> ordinary strings" must name the live corpus.
            for _t_m44 in _re44.finditer(r"(\d+)[- ]string decoy corpus|(\d+) ordinary strings",
                                         _t_txt44):
                _t_n44 = _t_m44.group(1) or _t_m44.group(2)
                if _t_n44 != _t_decoys44:
                    _t_stale44.append(f"{_t_doc44}: says {_t_n44} decoys, tool measures {_t_decoys44}")
            # ...and wherever a document states the corpus as "<hit> of <all>", those are the
            # live counts. The percentage itself is asserted separately, below: this page also
            # quotes OTHER scanners' recall in a comparison table and says "that is not 100%
            # recall" about this very figure in prose, so a bare "<n>% recall" cannot be matched
            # positionally without reporting both of those as drift -- the first version did.
            for _t_m44 in _re44.finditer(r"(\d+) of (\d+) secret", _t_txt44):
                if (_t_m44.group(1), _t_m44.group(2)) != (_t_hit44, _t_all44):
                    _t_stale44.append(f"{_t_doc44}: says {_t_m44.group(0)}, tool measures "
                                      f"{_t_hit44} of {_t_all44}")

            # 🐛 [2026-09-14] The three patterns above assert the DECOY count in two
            # spellings and the recall pair in one, and never assert the SECRET-corpus size at all
            # -- which is the number that went stale. Five places drifted for three days across
            # README.md and SECURITY.md and not one matched: a number joined to `secret` by a
            # hyphen is not `<n>-string decoy corpus`; a number introducing `secret shapes` is not
            # `<n> ordinary strings`; a recall pair inside brackets is not `<n> of <n> secret`,
            # because nothing follows the closing bracket. The commit that corrected the table row
            # left every one of them, and SECURITY.md -- the document whose whole job is "trust
            # this before you commit anything" -- published a three-day-old pair.
            # The-set-not-the-member, inside the check written to stop exactly this.
            #
            # No digits in this comment, for the reason the header gives: this file is folded into
            # the suite it scans, so an example carrying a stale figure is found by its own check.
            # Not hypothetical -- the first version of this paragraph listed all five and the fold
            # reported the comment itself as drift.
            #
            # Two changes. The corpus size is asserted wherever a number introduces one of the
            # nouns this project uses for it, kept apart from the decoy count, which is a different
            # number wearing a similar noun. And each guarded document must YIELD at least one
            # claim: a reword that escapes every pattern FAILS here rather than passing silently,
            # which is the failure mode above.
            _t_claims44 = 0
            # 🐛 [2026-09-21] (owner) The number had no LEFT boundary, so `base64 secret` read as a
            # corpus of 64 — the failure fired on prose that says nothing about the corpus at all,
            # the moment a release note mentioned base64. A digit run is only a count when a word
            # character does not run into it, which is the same boundary the right-hand side
            # already had.
            for _t_m44 in _re44.finditer(
                    r"(?<![A-Za-z0-9])(\d+)[- ]secret\b(?![ -]key)"
                    r"|(?<![A-Za-z0-9])(\d+) secret(?:s)? (?:shapes|and personal-data)",
                    _t_txt44):
                _t_claims44 += 1
                _t_n44 = _t_m44.group(1) or _t_m44.group(2)
                if _t_n44 != _t_all44:
                    _t_stale44.append(f"{_t_doc44}: {_t_m44.group(0)!r} states the corpus size, "
                                      f"tool measures {_t_all44}")
            # The recall PAIR wherever it sits beside the word, brackets included -- the spelling
            # that slipped. A sentence recording a MOVE from one pair to another carries no
            # "recall" within reach of the bracket, so a dated fact is left alone.
            for _t_m44 in _re44.finditer(r"recall[^.\n]{0,40}?\((\d+) of (\d+)\)", _t_txt44):
                _t_claims44 += 1
                if (_t_m44.group(1), _t_m44.group(2)) != (_t_hit44, _t_all44):
                    _t_stale44.append(f"{_t_doc44}: states recall ({_t_m44.group(1)} of "
                                      f"{_t_m44.group(2)}), tool measures {_t_hit44} of {_t_all44}")
            # A document stating no claim at all has been reworded past every pattern or has lost
            # the figures. Both are what this block exists to catch. The suite file is exempt: it
            # carries this check's own prose, not a published claim.
            if _t_doc44 != "tests/run_tests.py":
                check(f"{_t_doc44} still states the corpus in a shape this check can read: "
                      f"{_t_claims44} claim(s)",
                      _t_claims44 >= 1,
                      saw=f"no corpus-size or recall-pair claim found in {_t_doc44} — reworded "
                          f"past every pattern, or the figures are gone")
        check("EVERY PUBLISHED REDACTOR NUMBER IS THE ONE THE TOOL ACTUALLY MEASURES",
              not _t_stale44, saw="\n".join(sorted(set(_t_stale44))) or None)

        # Both documents must carry the LIVE percentage. Agreeing by both going silent is not
        # agreement, and SECURITY.md drifting quiet is the failure this cannot afford to miss --
        # it is the one document whose whole job is to be read before pointing this at a private
        # repository. Presence is asserted rather than position, because the two files state the
        # same measurement in four different prose shapes between them.
        # \U0001f41b [2026-09-11] The `is_file()` guard below used to be the whole population filter,
        # so the day both documents went missing the list came back empty and this reported a PASS
        # for "both documents state the figure" while reading neither. That is the exact failure the
        # paragraph above says it cannot afford, arriving through the check meant to catch it
        # (R2 agent 8, 2026-09-11). The presence of the files is now asserted FIRST, and the silence check runs
        # over the ones that are there.
        _t_absent44 = [d for d in ("README.md", "SECURITY.md") if not (ROOT / d).is_file()]
        check("both published documents are on disk for this check to read",
              not _t_absent44,
              saw="%s missing — with neither present the silence check below has nothing to judge "
                  "and passes while measuring nothing" % ", ".join(_t_absent44))
        _t_silent44 = [d for d in ("README.md", "SECURITY.md")
                       if (ROOT / d).is_file()
                       and f"{_t_pct44}%" not in (ROOT / d).read_text(encoding="utf-8",
                                                                     errors="replace")]
        check("...and both documents state the live recall figure rather than going quiet",
              not _t_silent44, saw=", ".join(_t_silent44) or None)
else:
    skip("  · no redactor_recall.py — the published-number check is skipped, not passed")
