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

## Measured 2026-09-24, first run of chamnan over this group

Four of the eleven were claims until this ran. What `chamnan-map` actually produced:

| | result | what it means |
|---|---|---|
| A1-A7 | published verbatim | scope, not a defect — none is shaped like a credential, and `lib/redact.py` argues that case in its own docstring. The open question is whether the user is ever TOLD |
| A8 unprefixed base64 | **truncated, not redacted** — 29 of 44 characters reached `MAP.md` | luck, not protection. A shorter secret of the same shape survives whole, and redacting this class means redacting hashes, UUIDs and version strings, which the module refuses on purpose |
| A9 split across lines | **LEAKED WHOLE — a real defect, fixed** | `"ghp_" "EXAMPLE…"` reached `MAP.md` complete. Every prefix rule needs prefix and body contiguous; the source had split them and the language rejoins them. `redact._unmask_split_credentials` now joins adjacent string literals and keeps the result only when it redacts more |
| A10 `.env.example` values | **truncated, not redacted** | the password sits one character past the cut |
| A11 credential in a Thai comment | **redacted correctly** | the claim that ASCII word boundaries would fail here was wrong, and this is what corrected it |

The first version of this group planted A8, A9 and A10 with the credential on a LATER line, and
the run reported all three clean — because the index copies a file's OPENING comment and never saw
them. A fixture that cannot reach the code it is aimed at reports a pass it did not earn.
