# ------------------ a private-key header as a file's first body line is redacted, not de-dashed
# Moved from chamnan's suite on 2026-09-24 (the plugin carries no key-shaped data). `describe` cleans
# markdown by stripping leading dashes, and a PEM header is five dashes -- redacting after the
# cleanup would hand the scrub a header it can no longer recognise.
import tempfile as _tf02
_hook02 = import_hook_module("chamnan_session_start.py")
_dir02 = Path(_tf02.mkdtemp(prefix="chamnan-describe-key-"))
_key02 = _dir02 / "key-first.md"
_key02.write_text("# Title\n\n" + fake("-----BEGIN", " OPENSSH PRIVATE KEY-----") + "\nb3BlbnNzaC1rZXktdjEAAAAA\n",
                  encoding="utf-8")
_desc02 = _hook02.describe(_key02)
check("a private-key header as the first body line is redacted, not de-dashed",
      "PRIVATE KEY" not in _desc02 and "BEGIN OPENSSH" not in _desc02)
check("and what replaces it is the redaction marker", "<REDACTED>" in _desc02)
_rmtree(_dir02, ignore_errors=True)
