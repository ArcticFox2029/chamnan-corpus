# ------------------ redaction catches each provider's key shape
# Moved from chamnan's suite on 2026-09-24 (owner: the plugin carries no fake keys; key-shaped test
# data and the checks that need it live in chamnan-corpus). Run by the release's corpus step through
# `suite_slice.py --file`, which supplies the suite's preamble -- `check`, `fake`, `redact`, `ROOT`.
SECRETS_PROVIDER = [
    ("stripe live key", 'STRIPE="' + fake("sk_", "live_", "51H8xKLMNOPQRSTUVWXYZabcdef") + '"', fake("sk_", "live_", "51H8x")),
    ("openai key", "# rotate " + fake("sk-", "proj-", "AbCdEf1234567890XyZwVuTsRqPoNmLk"), fake("sk-", "proj-", "AbCdEf")),
    ("github pat", "token: " + fake("ghp", "_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"), fake("ghp", "_", "ABCDEF")),
    ("aws access key", "uses " + fake("AKIA", "IOSFODNN7EXAMPLE") + " for s3", fake("AKIA", "IOSFODNN7EXAMPLE")),
    ("google api key", "key " + fake("AIza", "SyA1234567890abcdefghijklmnopqrstuvw") + " here", fake("AIza", "SyA123")),
    ("slack token", fake("xox", "b-", "123456789012-abcdefghijklmnop"), fake("xox", "b-", "1234")),
    ("gitlab pat", fake("glpat", "-", "ABCDEFGHIJKLMNOPQRST"), fake("glpat", "-", "ABCDEF")),
    ("jwt", "Bearer " + fake("eyJ", "hbGciOiJIUzI1.", "eyJ", "zdWIiOiIxMjM.SflKxwRJSMeKKF2QT"), fake("eyJ", "hbGciOiJIUzI1")),
    ("private key block", fake("-----BEGIN", " RSA PRIVATE KEY-----") + "\nMIIsecret\n"
     + fake("-----END", " RSA PRIVATE KEY-----"), "MIIsecret"),
]
for label, text, secret in SECRETS_PROVIDER:
    check(f"redact catches {label}", secret not in redact.scrub(text))
