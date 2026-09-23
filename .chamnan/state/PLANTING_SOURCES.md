# Where each planted group came from

Nothing in this corpus is a failure somebody imagined. Every group traces to one of three sources,
and this file is the checklist that says which — so "we covered the report" is a claim that can be
checked rather than asserted.

## Source 1 — the four-plugin comparison (`four_plugins_2026-09-22.pdf`)

Fourteen topics in the summary table and nine failure classes in section 2. Eleven of them describe
a state a REPOSITORY can be in, so eleven are planted; three are properties of a tool and cannot be.

| topic in the report | planted as | where |
| --- | --- | --- |
| ReDoS | 177 rule trailers in seven groups | `plant_rule_patterns.py` |
| concurrent read-modify-write | a contended file and a harness that loses updates on demand | `plant_failure_classes.py` → `concurrent` |
| silent write failure | a directory and a file a writer cannot write | → `silentwrite` |
| clock jump | mtimes and records from the future, a log running backwards | → `clockjump` |
| BOM / reserved device names | BOM, UTF-16, CP874, invalid UTF-8; `CON`/`NUL`/`PRN`/`AUX`/`LPTn` | → `encodings`, `windows` |
| multi-OS (Windows) | names and line endings legal here and fatal there, a path past MAX_PATH | → `windows`; `plant_reported_issues.py` → `longpath` |
| many hosts / LLMs | eighteen adapter marker files at once, contradicting each other | `plant_situations.py` → `hosts` |
| known extensions (113) | twenty suffixes outside the list, plus a file that is only a suffix | `plant_failure_classes.py` → `extensions` |
| multi-language comments (97.2%) | the Perl and Python 2 shapes the missing 2.8% is made of | → `unreadable` |
| pattern coverage (147-case fixture) | confusables and high-entropy non-secrets extend it | `plant_reported_issues.py` → `confusable`, `entropy` |
| session continuity — count vs byte cap | ten ordinary records of ~500 KB each | `plant_failure_classes.py` → `countcap` |
| **the report's own named blind spot** — patterns assembled from a runtime variable | four constructions, none visible to extraction or to execution | → `runtimeregex` |
| answer quality, stance on detection, how each vendor claims numbers | *not a repository state* — cannot be planted | — |

## Source 2 — issues real users filed against real tools

Collected in `chamnan_research_backlog.md` with their URLs; planted by
`plant_reported_issues.py`, each file carrying its citation in the manifest.

gitleaks#1432 (a large file reported clean, secret at line 62,190) · semgrep's 1 MB default ·
ripgrep#863 and #2861 (a permission-denied directory returns zero and cannot say why) ·
openai/codex#13095 (Unicode confusables walk past a matcher that compares code points) ·
gitleaks#1830 and #1578 (dictionary words and digests outscore real credentials) ·
pytest#291 with Windows MAX_PATH · claude-code#72616 and #31941, pnpm#3840, pip#5412 (four tools
whose success or currency their own files denied).

## Source 3 — gaps chamnan's own research named and did not close

`plant_named_gaps.py`, each group citing the backlog or dead-end line it came from.

Arabic under-counted by 39% and Hebrew by 44% against real token counts · `carry_forward()` reads
one same-day record so a second session's Remaining is lost · `milestones.md` is one append-only
file and conflicts the first time two people ship on one day · a source file with a future mtime
silences the staleness warning, and the dead-end entry records that clamping does not fix it ·
`HUGE_BYTES`, `WINDOW_HOURS` and chamnan-context's CEILING override have no coverage at all.

## Source 4 — the question asked from the user's side

The three sources above all ask *can a tool read this repository*. Source 4 asks what a tool costs
the person who installed it, which is a different list: a repository that is merely hard to index
produces a worse index, while a repository in one of these states produces a published customer
name, a merge conflict in a file nobody edits by hand, or a confident answer about files deleted
last month.

Derived from what chamnan actually does to a repository rather than from a threat model — it
commits `MAP.md`, it injects a budgeted block at every session start, its workspace arrives with
the clone, it sweeps its own logs, and `chamnan-setup` exists because four installs at four
versions were found on one laptop. A hundred cases are enumerated with their disposition in
`USER_IMPACT_CASES.md`; `plant_user_impact.py` writes the plantable ones.

| group | what it is | cases |
| --- | --- | --- |
| `published` | private content that is not shaped like a credential, in files the index copies verbatim | A1-A11 |
| `collides` | the repository already had a CLAUDE.md, its own hook, and a tuned `.gitignore` | B1-B8 |
| `shapes` | spaces, Thai and an emoji in a path; a default branch called `trunk` | C7, C8, C10 |
| `team` | the workspace arrives with the clone, so two people conflict in generated files | D1-D10 |
| `cost` | the budget from the side of the person paying for it | E1, E2, E4, E8-E10 |
| `noop` | installed, registered, and silently producing nothing | F1, F3, F5-F7 |
| `loss` | what the sweeps take that a rebuild cannot give back | G1-G4, G6 |
| `wrong` | it answered, the answer looked fine, and it was false | H1, H2, H4-H6, H8 |
| `mistaken` | the user's own content, read as if addressed to the tool | I1, I3-I7 |
| `install` | eight states git cannot track, shipped as documents that say how to build them | B9, B10, C1-C3, C5, C9, F2 |

Counted off the table rather than from memory: **67 planted, 12 already carried by an earlier
planter at a path each row names, and 21 that no corpus can hold** — a duration, a host behaviour,
an OS, a decision, or a state git refuses to track. The 21 are listed with their reason so that
"we covered the report" stays checkable.

## What is deliberately NOT here

A planted credential exists in this repository and nowhere else, at placeholder fidelity in the
tracked form. Three groups cannot ship under their real names for three different reasons — git
refuses a `.git` path component, a Windows checkout refuses `NUL` and trailing dots, and git
tracks no directory mode so a 000 directory arrives readable. All three install locally.
