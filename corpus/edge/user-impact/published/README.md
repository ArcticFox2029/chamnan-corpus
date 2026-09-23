# What reaches MAP.md, and what the redactor was never asked to catch

`MAP.md` is built from the opening comment of each file and this plugin encourages
committing it. `lib/redact.py` strips credential SHAPES and says in its own docstring
that the patterns are narrow on purpose.

**A correct answer is not "none of this appears".** A1-A7 are private and are not
credentials; a tool that redacted them would produce an unusable index, and the
docstring already argues that case. What this group asks is whether the user is ever
TOLD. A8-A11 are different: those are credentials, and each one is a shape the
pattern list does not carry -- an unprefixed base64 block, a token split by a
formatter, a working value in `.env.example`, and a key inside a Thai comment where
there is no ASCII word boundary to anchor on. Those four are misses, not scope.

Cases: A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11 — derived in `.chamnan/state/USER_IMPACT_CASES.md`.
