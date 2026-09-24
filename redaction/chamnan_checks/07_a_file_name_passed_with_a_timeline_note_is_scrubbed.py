# ------------------ a file NAME passed with a timeline note is scrubbed, like the note itself
# Moved from chamnan's suite on 2026-09-24: this check needs a key SHAPE, and key-shaped data
# lives in chamnan-corpus. Run by the release's corpus step through `suite_slice.py --file`.
import tempfile as _tf07, subprocess as _sp07
import timeline as _tl07
_root07 = Path(_tf07.mkdtemp(prefix="chamnan_writescrub_"))
_sp07.run(["git", "init", "-q"], cwd=_root07, check=True)
(_root07 / "app.py").write_text("x = 1\n", encoding="utf-8")
ws.ensure(str(_root07))
_tl07.create(str(_root07), "Deploy notes", "2026-09-08")
_p07 = _tl07.append(str(_root07), "deploy-notes", "2026-09-08", "rotated the key and deployed",
                    files=[f"config/{AKIA_FIXTURE}.env"])
_t07 = Path(_p07).read_text(encoding="utf-8")
check("A FILE NAME PASSED WITH A TIMELINE NOTE IS SCRUBBED BEFORE IT REACHES THE FILE",
      AKIA_FIXTURE not in _t07 and redact.PLACEHOLDER in _t07, saw=_t07[-200:])
_rmtree(_root07, ignore_errors=True)
