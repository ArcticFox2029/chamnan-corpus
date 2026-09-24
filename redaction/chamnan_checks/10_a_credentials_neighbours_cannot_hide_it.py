# ------------------ a credential's NEIGHBOURS cannot decide whether it is one
# 🎯 [owner 2026-09-24] Moved from chamnan's surgical pool with the benchmark it measures: the
# recall tool and its key-shaped tables now live in chamnan-corpus `redaction/recall.py`.
# R3.1, measured 2026-09-15. A boundary-mutation study across ten credential types measured
# detection of at least 0.9976 in ten ordinary contexts and only 0.5233 when the credential ended
# in a hyphen -- the same secret, the same rule, one different neighbouring character. A corpus of
# fixed examples cannot see that axis at all: every fixture in `tools/redactor_recall.py` sits in
# exactly one context, so it measures one cell of a grid.
#
# Run for the first time, the grid found two families, and both were the-set-not-the-member:
#
#   * LEFT edge. Every provider-prefix rule guarded with `(?<![A-Za-z0-9_-])`, which is correct for
#     a rule anchored on an ordinary WORD (`Bearer`, a URL scheme) and wrong for one anchored on
#     `ghp_` or `AKIA`. 14 of 47 labelled positives passed through WHOLE behind a `-` or `_`, and a
#     diff hunk begins every removed line with `-`.
#   * RIGHT edge. The AWS key-ID rule ended in `\b`, and `_` is a word character, so
#     `AWS_KEY_AKIA…EXAMPLE_backup` carried a complete valid 20-character key ID untouched.
#
# Neither cost anything: 1,193 real files scrub byte-identically before and after, and no labelled
# decoy changed. The asymmetry is the lesson -- a provider prefix is proof on its own, so nothing
# adjacent to it can make it not-a-credential, while a rule anchored on an English word needs the
# wider guard precisely because the word occurs inside ordinary text.
import importlib as _importlib130
import importlib.util as _ilu130

_t_redact130 = _importlib130.import_module("redact")
_t_rr_path130 = ROOT.parent / "chamnan-corpus" / "redaction" / "recall.py"
os.environ["CHAMNAN_PLUGIN"] = str(ROOT)
_t_spec130 = _ilu130.spec_from_file_location("_rr130", str(_t_rr_path130))
_t_rr130 = _ilu130.module_from_spec(_t_spec130)
# The tool's main() is guarded by __name__, so importing it runs only the corpus definitions.
_t_spec130.loader.exec_module(_t_rr130)

# The battery lives in the tool, not here, so the published number and the gate cannot drift apart.
check("the recall tool exposes the boundary battery this block gates on",
      hasattr(_t_rr130, "boundary_leaks") and hasattr(_t_rr130, "BOUNDARIES_LEFT"),
      saw=sorted(n for n in dir(_t_rr130) if n.isupper() or n.startswith("boundary")))

# R5.6: a derived sweep whose population is empty asserts nothing while looking green. The
# battery below is 47 x 22 x 17; if the corpus or either boundary table were ever emptied, "no
# credential leaks" would pass on having tested none.
_t_cells130 = (len(_t_rr130.POSITIVES) * len(_t_rr130.BOUNDARIES_LEFT)
               * len(_t_rr130.BOUNDARIES_RIGHT))
check(f"the boundary grid is populated before anything is concluded from it: {_t_cells130} cell(s)",
      _t_cells130 >= 1000 and len(_t_rr130.POSITIVES) >= 40,
      saw=f"{len(_t_rr130.POSITIVES)} positives x {len(_t_rr130.BOUNDARIES_LEFT)} left x "
          f"{len(_t_rr130.BOUNDARIES_RIGHT)} right")

_t_leaks130 = _t_rr130.boundary_leaks()

# The population a boundary leak is measured AGAINST is derived, not written down: a fixture that
# already survives with no neighbours at all is not a boundary failure, it is a known recall gap,
# and hard-coding its name here would let a real regression hide behind the same name later.
_t_baseline130 = {
    _lab130 for _lab130, _txt130, _sec130 in _t_rr130.POSITIVES
    if _sec130 in _t_redact130.scrub(_txt130 + "\n")
}
_t_boundary_only130 = sorted({
    (_lab130, _ln130, _rn130) for _lab130, _ln130, _rn130 in _t_leaks130
    if _lab130 not in _t_baseline130
})
check(f"no credential survives because of what sits NEXT to it "
      f"({len(_t_rr130.POSITIVES)} positives x {len(_t_rr130.BOUNDARIES_LEFT)} left x "
      f"{len(_t_rr130.BOUNDARIES_RIGHT)} right contexts)",
      not _t_boundary_only130,
      saw=f"{_t_boundary_only130[:8]} -- these are redacted with no neighbours and leak with them, "
          f"which is a boundary defect rather than a recall gap. "
          f"Known recall gaps, excluded on purpose: {sorted(_t_baseline130)}")

# The set, asserted rather than the members. A rule anchored on a fixed provider prefix must not
# use the word-anchored guard; the two rules that ARE anchored on a word must keep it.
_t_src130 = __import__("pathlib").Path(_t_redact130.__file__).read_text(encoding="utf-8")
_t_wide130 = r"(?<![A-Za-z0-9_-])"
_t_word_anchored130 = ("(?:Bearer|Basic|Token)", "([a-zA-Z][a-zA-Z0-9+.-]*")
_t_misguarded130 = []
for _t_i130, _t_line130 in enumerate(_t_src130.splitlines(), 1):
    if _t_wide130 not in _t_line130:
        continue
    _t_after130 = _t_line130.split(_t_wide130, 1)[1]
    if not any(_t_after130.startswith(_w130) for _w130 in _t_word_anchored130):
        _t_misguarded130.append(f"{_t_i130}: {_t_after130[:52]}")
check("only a rule anchored on an ordinary WORD excludes `-` and `_` from its left edge",
      not _t_misguarded130,
      saw=f"{_t_misguarded130} -- a rule anchored on a fixed provider prefix should use "
          f"`(?<![A-Za-z0-9])`: nothing adjacent to `ghp_` or `AKIA` makes it not a credential, "
          f"and a leading `-` is what every removed line of a diff starts with.")

# The right edge of the one fixed-length key rule, stated as behaviour rather than as pattern text.
_t_akia130 = "AKIA" + "IOSFODNN7EXAMPLE"
for _t_suffix130, _t_want130 in ((("_backup"), True), (("foo"), True),
                                 (("EXTRACHARS"), False), (("."), True)):
    _t_out130 = _t_redact130.scrub(_t_akia130 + _t_suffix130)
    check(f"a 20-character AWS key ID followed by {_t_suffix130!r} is "
          f"{'redacted' if _t_want130 else 'left alone'}",
          (_t_akia130 not in _t_out130) is _t_want130,
          saw=_t_out130)
