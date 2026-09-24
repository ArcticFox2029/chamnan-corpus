# ------------------ a secret-shaped filename in the bulk-read notice is redacted
# Moved from chamnan's suite on 2026-09-24: this check needs a key SHAPE, and key-shaped data
# lives in chamnan-corpus. Run by the release's corpus step through `suite_slice.py --file`.
import json as _js04, tempfile as _tf04, subprocess as _sp04, sys as _sys04
_bh04 = ROOT / "hooks" / "chamnan_bulk_read_notice.py"
_hn04 = Path(_tf04.mkdtemp(prefix="chamnan-hostilename-"))
_f04 = _hn04 / ("dump_aws_secret_key=" + AKIA_FIXTURE + ".min.js")
_f04.write_bytes(b"x" * 90_000)
_r04 = _sp04.run([_sys04.executable, str(_bh04)], capture_output=True, text=True, encoding="utf-8",
                 errors="replace", input=_js04.dumps({"tool_name": "Read", "cwd": str(_hn04),
                                                      "tool_input": {"file_path": str(_f04)}}))
_sec04 = (_js04.loads(_r04.stdout)["hookSpecificOutput"]["additionalContext"]
          if _r04.stdout.strip() else "")
check("a secret-shaped filename is redacted, because the finished note is scrubbed",
      AKIA_FIXTURE not in _sec04 and "REDACTED" in _sec04, saw=_sec04[:160])
_rmtree(_hn04, ignore_errors=True)
