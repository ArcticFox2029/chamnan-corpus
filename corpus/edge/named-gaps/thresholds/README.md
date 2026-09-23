# Three constants nothing exercises

- `HUGE_BYTES` — its "very large" wording has zero matches in the suite
- `chamnan_session_end.WINDOW_HOURS` — no fixture planted outside the 24h window
- `bin/chamnan-context` — the adapter-declared-CEILING-overrides-default path is untested

Recorded in chamnan_research_backlog.md — still open from agent 3. A test written against these must read the constant rather than
repeat its value: two ceilings here were once inflated two hundredfold with the whole
suite still green, because every fixture had the number written into it by hand.
