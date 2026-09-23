# Paths and branch names a tool's string handling has opinions about

Spaces, Thai, an emoji, and a default branch called `trunk`. All four are ordinary in
real repositories and all four are where an unquoted expansion, a byte-length
assumption or a hard-coded `main` shows up.

A correct answer indexes all of these and prints their paths without mangling them.

Cases: C7, C8, C10 — derived in `.chamnan/state/USER_IMPACT_CASES.md`.
