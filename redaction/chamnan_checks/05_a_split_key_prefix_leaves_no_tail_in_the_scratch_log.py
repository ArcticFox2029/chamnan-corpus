# ------------------ the scratch log keeps no planted key, whole or as the tail after its prefix
# Moved from chamnan's suite on 2026-09-24: this check needs a key SHAPE, and key-shaped data
# lives in chamnan-corpus. Run by the release's corpus step through `suite_slice.py --file`.
import importlib.util as _ilu05
_sw_spec = _ilu05.spec_from_file_location("sw_probe", str(ROOT / "hooks" / "chamnan_scratch_watch.py"))
_sw = _ilu05.module_from_spec(_sw_spec)
_sw_spec.loader.exec_module(_sw)
_secrets = {
    "anthropic": fake("sk-", "ant-", "api03-", "PLANTEDSECRETVALUEXYZ123456789ABCDEFGH"),
    "slack": fake("xox", "b-", "1234567890-0987654321-AbCdEfGhIjKlMnOpQrStUvWx"),
    "gitlab": fake("glp", "at-", "ABCDEFGHIJKLMNOPQRST"),
    "github": fake("gh", "p_", "PLANTEDSECRETVALUEXYZ123456789ABCD"),
    "bare-hex-by-shape": "9f8e7d6c5b4a39281706f5e4d3c2b1a0",
}
# Real surrounding content, because MIN_TOKENS wants 8 distinct 4+ character identifiers and the
# assignments alone scrub down to seven -- a fixture under that threshold makes the hook return
# without writing anything, and every assertion below would then be about an empty file.
_planted_body = ("import requests\n" + "".join(
    f'{k.upper().replace("-", "_")}_SECRET_KEY = "{v}"\n' for k, v in _secrets.items()) +
    "def call_endpoint(session_object, timeout_seconds):\n"
    "    response_body = session_object.post(SLACK_SECRET_KEY, timeout=timeout_seconds)\n"
    "    return response_body.json()\n")
# 🐛 The first version of THIS check rebuilt the pipeline itself -- `scrubbable`, then
# `fingerprint`, then `headline` -- and mutation-testing it by restoring the old per-token filter
# left it green, because the test never went near `main()`. Seventeenth vacuous assertion here, and
# written in the same edit that quotes the rule against it. The hook is RUN, as a subprocess, on a
# real workspace, and the assertion reads the file that landed on disk.
_swdir = Path(tempfile.mkdtemp(prefix="chamnan-scratch-secrets-")).resolve()
(_swdir / ".git").mkdir()
ws.ensure(_swdir)
subprocess.run([sys.executable, str(ROOT / "hooks" / "chamnan_scratch_watch.py")],
               input=json.dumps({"tool_name": "Write",
                                 "tool_input": {"file_path": "/tmp/probe_secrets.py",
                                                "content": _planted_body}}),
               capture_output=True, text=True, encoding="utf-8", errors="replace", cwd=_swdir)
_swlog = _swdir / ".chamnan" / "logs" / "scratch.jsonl"
_landed = _swlog.read_text(encoding="utf-8") if _swlog.is_file() else ""
check("the hook wrote the entry this check is about", bool(_landed.strip()))
_stored_fp = sorted(json.loads(_landed.splitlines()[0])["fp"]) if _landed.strip() else []

_leaked = sorted(n for n, v in _secrets.items() if v.lower() in _landed.lower())
check("NO PLANTED SECRET REACHES THE SCRATCH LOG, WHOLE OR IN PART", not _leaked)
if _leaked:
    print("      leaked:", _leaked)
# A secret's random tail is the part worth having; the old hole shipped exactly that.
_tails = sorted(n for n, v in _secrets.items()
                if v.rsplit("-", 1)[-1].rsplit("_", 1)[-1].lower() in _landed.lower())
check("...and neither does the random tail left behind when the prefix is split off", not _tails)
if _tails:
    print("      tails leaked:", _tails)
check("...while the variable names that make the fingerprint useful are still there",
      "anthropic_secret_key" in _stored_fp and "requests" in _stored_fp)
_rmtree(_swdir, ignore_errors=True)
