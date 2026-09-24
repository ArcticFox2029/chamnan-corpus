# ------------------ a filename is repository content, and it reaches the block
# 🐛 [2026-09-08] Three copies of one warning went in together. The skills one wrapped its filenames
# in `redact.scrub`; the threads and sessions ones appended theirs AFTER the surrounding text had
# already been scrubbed, so the names went into the injected block untouched. A filename is written
# by whoever wrote the repository, so a key-shaped `.md` NAME rode in whole (R7 agent 2, 2026-09-06).
#
# Checked by DRIVING every store that can carry a filename into the block, not by reading the two
# lines that were wrong. Three identical features and one of them correct is exactly the shape that
# a check naming specific call sites fails to catch the fourth time.
_leak_root = Path(tempfile.mkdtemp(prefix="chamnan-fnleak-")) / "repo"
(_leak_root / "src").mkdir(parents=True)
(_leak_root / "src" / "a.py").write_text('"""A."""\n', encoding="utf-8")
subprocess.run(["git", "init", "-q", str(_leak_root)], capture_output=True)
subprocess.run([sys.executable, str(ROOT / "bin" / "chamnan-map")], cwd=str(_leak_root),
               capture_output=True)
_KEYLIKE = AKIA_FIXTURE
_ws_leak = _leak_root / ".chamnan"
for _sub, _fname, _body in (
        ("skills", f"{_KEYLIKE}.md", "# A skill\n\nordinary text.\n"),
        ("sessions", f"2026-09-08-{_KEYLIKE}.md", "# A session\n\n**Remaining:** something\n"),
        ("threads", f"{_KEYLIKE}.md", "# A thread\n\n**Status:** open\n**Started:** 2026-09-08\n"),
        ("candidates", f"{_KEYLIKE}.md", "# A habit\n\n**Sequence:** git, add\n**Observed:** 3\n")):
    (_ws_leak / _sub).mkdir(parents=True, exist_ok=True)
    (_ws_leak / _sub / _fname).write_text(_body, encoding="utf-8")
_leak_out = subprocess.run([sys.executable, str(ROOT / "hooks" / "chamnan_session_start.py")],
                           input="{}", capture_output=True, text=True,
                           encoding="utf-8", errors="replace", cwd=str(_leak_root)).stdout
check("A SECRET-SHAPED FILENAME NEVER REACHES THE INJECTED BLOCK, FROM ANY STORE",
      _KEYLIKE not in _leak_out)
if _KEYLIKE in _leak_out:
    _at = _leak_out.find(_KEYLIKE)
    print(f"      it arrived here: {_leak_out[max(0, _at - 90):_at + 40]!r}")
# The block must still SAY something about those files -- scrubbing the name is not the same as
# dropping the warning, and a silent scrub would pass the check above for the wrong reason.
check("...while the block still reports the files it found, with the name redacted",
      "<REDACTED>" in _leak_out and len(_leak_out) > 200)
_rmtree(_leak_root.parent, ignore_errors=True)
