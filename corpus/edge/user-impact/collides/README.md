# Installed into a repository that was already configured

Six arrangements, each a miniature repository root. Nothing here is malformed and
nobody did anything wrong: a team that ignores tool state, a team that does not track
generated markdown, a team with its own SessionStart hook, a settings file that was
already broken, a deny rule, and a large CLAUDE.md.

A correct answer SAYS SO at install time. The failure mode is not a crash -- it is an
install that reports success into a repository where the thing it installed can never
run, be shared, or be committed.

Cases: B1, B2, B3, B4, B5, B6, B7, B8 — derived in `.chamnan/state/USER_IMPACT_CASES.md`.
