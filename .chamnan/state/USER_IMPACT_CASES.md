# A hundred ways a context tool can cost the person who installed it

Every other planter in this corpus asks *can the tool read this repository*. This one asks the
question from the other side: **somebody installed chamnan in a codebase they care about — what
does it cost them?** The two are not the same list. A repository that is merely hard to index
produces a worse index. A repository in one of the states below produces a published secret, a
broken build, a merge conflict in a file nobody edits by hand, or a confident answer about files
that were deleted last month.

The cases are derived from what chamnan actually does to a repository, not from a threat model:
it writes `MAP.md` and **encourages committing it**, it injects a budgeted block at every session
start, it reads a workspace that **arrives with the clone**, it sweeps its own logs on a retention
policy, and `chamnan-setup` exists because four copies at four versions were found installed on
one laptop at once.

**Disposition is the point of this file.** `PLANT` means a repository can be put in that state and
this corpus does it. `NO` means the case is real and a corpus cannot carry it — it is a duration,
a host behaviour, an OS, a decision, or a state git refuses to track — and it is listed so that
"we covered the report" stays a checkable claim rather than an impression. `ALREADY IN CORPUS` means a planter written earlier put it here — it is IN this corpus, at the
path named in the row, and planting it twice would only inflate a count. Every one of those paths
was checked against the manifest that owns it rather than remembered.

| # | case | what it costs the user | disposition |
|---|---|---|---|

## A — what chamnan PUBLISHES about them

`MAP.md` is committed on purpose: that is how a team shares one index. It is assembled from the
opening comments of their source files, verbatim. `lib/redact.py` strips **credential shapes** and
says so in its own docstring — narrow on purpose, because an index full of `<REDACTED>` is not an
index. Everything in a comment that is private but is not shaped like a token therefore travels.

| A1 | a comment naming a customer and a deadline | the customer's name is pushed to a public remote in a file nobody re-reads | PLANT |
| A2 | a comment naming a colleague and their email | a person's contact details in a published artefact | PLANT |
| A3 | a comment naming an internal hostname and port | infrastructure disclosure with no credential in it | PLANT |
| A4 | a comment linking a private ticket | the tracker URL says what the company is building | PLANT |
| A5 | a path naming a client (`clients/<name>/pricing.py`) | the *path* is published even when the file is never read | PLANT |
| A6 | a directory named for an unannounced product | the tree alone leaks the roadmap | PLANT |
| A7 | a comment with a national ID / phone number | PII in a committed index | PLANT |
| A8 | a credential in a shape the redactor does not know | the case the narrow-pattern choice accepts | PLANT |
| A9 | a secret split across two physical lines | a line-oriented matcher sees two harmless halves | PLANT |
| A10 | `.env.example` whose values are real | the file that exists to be safe, and is not | PLANT |
| A11 | a credential inside a non-Latin comment | the pattern's word boundaries were written for ASCII | PLANT |
| A12 | a branch name that names the unannounced thing | the block reports the branch | NO — a branch is not a tracked file; `--install` creates it |

## B — the repository already had its own arrangements

Installing into an empty repository is the easy case. Installing into one that already has a
`CLAUDE.md`, its own hooks, and a `.gitignore` somebody tuned is the ordinary one.

| B1 | `.gitignore` already ignores `.chamnan/` | the workspace is never shared, and every tool assumes it is | PLANT |
| B2 | `.gitignore` ignores `*.md` | `MAP.md` is built on every run and committed never | PLANT |
| B3 | the user's own SessionStart hook is already registered | two blocks, unknown order, one budget | PLANT |
| B4 | `.claude/settings.json` is already invalid JSON | the install has nowhere to write and may say nothing | PLANT |
| B5 | settings deny the Bash permission chamnan's tools need | every command fails for a reason that is not chamnan's | PLANT |
| B6 | an existing 40 KB `CLAUDE.md` | block plus CLAUDE.md, and the budget was set against neither | PLANT |
| B7 | an `AGENTS.md` stating the opposite rule | the session is handed two instructions and no precedence | PLANT |
| B8 | a `.chamnan/` written by a much older release | artefacts and reader from different builds | PLANT |
| B9 | `.chamnan` exists as a FILE | every path under it is a `NotADirectoryError` | PLANT (install-only) |
| B10 | `.chamnan` is a symlink out of the repository | the workspace is not where the tools think it is | PLANT (install-only) |
| B11 | `core.hooksPath` points elsewhere | the commit guard never runs and never says so | NO — git config is not a tracked file |
| B12 | `.git/info/exclude` hides files git ignores and the map does not | the index describes files the repository denies | NO — lives inside `.git` |

## C — the repository is not the shape the tool assumes

| C1 | `git init` and no commit yet (unborn HEAD) | every git answer is an error path on day one | PLANT (install-only) |
| C2 | detached HEAD | "which branch" has no answer | PLANT (install-only) |
| C3 | a shallow clone | history-derived numbers are computed from a truncated history | PLANT (install-only) |
| C4 | a bare repository | there is no working tree to index | NO — a bare repo cannot contain this corpus |
| C5 | not a git repository at all | the root walk finds the user's *parent* repo instead | PLANT (install-only) |
| C6 | the repository root is the home directory | the map indexes a life, not a project | NO — cannot be planted anywhere but a home directory |
| C7 | the path contains spaces | every unquoted command substitution splits | PLANT |
| C8 | the path contains non-ASCII and emoji | encoding and width assumptions in every printed path | PLANT |
| C9 | a read-only checkout (CI, a nix store path) | the tool's first write fails and the session still starts | PLANT (install-only) |
| C10 | the default branch is neither `main` nor `master` | comparisons against a branch that does not exist | PLANT |
| C11 | a worktree, submodule or nested repository | `.git` is a file, not a directory | ALREADY IN CORPUS — `corpus/edge/many-hosts/`, `plant_situations.py` → `git` |
| C12 | two files differing only in case | one overwrites the other on a macOS checkout | NO — this filesystem cannot hold both |

## D — the team case: the workspace arrived with the clone

The workspace is committed so that a team shares one accumulated memory. That is the design, and
it is also the reason two people can now conflict inside files neither of them edits by hand.

| D1 | merge markers left inside `STATE.md` | the session block quotes both sides as if they were text | PLANT |
| D2 | `state/*.json` conflicting on every merge | a machine-generated file in everyone's diff | PLANT |
| D3 | a teammate's absolute home path inside state | their username travels to everyone who clones | PLANT |
| D4 | `.version` disagreeing between two installs | the measured case `chamnan-setup` was built for | PLANT |
| D5 | a workspace written by a NEWER release | unknown keys read by an older parser | PLANT |
| D6 | a workspace written by an OLDER release | required keys absent, defaults invented silently | PLANT |
| D7 | a colleague's rule file that instructs the reader | injection with no attacker in it | ALREADY IN CORPUS — `.chamnan/memory/decisions/talks-to-the-reader.md` |
| D8 | CI runs the hook and dirties the tree | the build fails on files the tool wrote | PLANT |
| D9 | `logs/*.jsonl` committed | the repository grows for nobody's benefit | PLANT |
| D10 | two machines in different timezones writing dated records | same-day logic on two different days | PLANT |

## E — what it costs in context, which is what the user is actually paying for

| E1 | an index too large to fit, truncated with a notice | the notice is the only signal, and it scrolls past | PLANT |
| E2 | `MAP.md` past the read ceiling | the file the tool tells you to read cannot be read | PLANT |
| E3 | the block at its ceiling on every single start | measured here at 65% of starts; a steady state, not an event | ALREADY IN CORPUS — `.chamnan/logs/block_shape.jsonl` |
| E4 | a `CLAUDE.md` that already spends the budget | two budgets, one context, neither aware of the other | PLANT |
| E5 | 1,200 files in one directory | listing bounds | ALREADY IN CORPUS — `corpus/edge/scale/wide/` (1,205 entries) |
| E6 | every file generated | an index of machine output, described as if written | ALREADY IN CORPUS — `corpus/edge/generated/` |
| E7 | one enormous file | a ceiling decides, and the user is told which | ALREADY IN CORPUS — `.chamnan/state/over-the-read-ceiling.json`, `skills/enormous.md` |
| E8 | more skills than the block can name | the section saturates and the newest never appear | PLANT |
| E9 | a monorepo of twelve sub-projects | one index, no locality, advice from the wrong sub-project | PLANT |
| E10 | ninety percent vendored dependencies | the index describes somebody else's code | PLANT |

## F — installed, and silently doing nothing

| F1 | the plugin present, the hook not registered | nothing happens and nothing says so | PLANT |
| F2 | four installs at four versions on one machine | the measured origin of `chamnan-setup` | PLANT (install-only) |
| F3 | `.version` current, code old | the one signal that would have caught F2, lying | PLANT |
| F4 | `python3` absent or shadowed | every hook is a non-zero exit the host swallows | NO — a PATH is not a file |
| F5 | `hooks.json` pointing at a path that moved | registered, unrunnable | PLANT |
| F6 | the map built once and never rebuilt | confident answers about a tree that moved on | PLANT |
| F7 | a `config.json` that disables everything | installed, configured off, indistinguishable from broken | PLANT |
| F8 | the host truncating the block itself | the tool's own accounting cannot see it | NO — a host behaviour |

## G — data loss, by the tool's own hand

| G1 | a log the sweeper deletes on age while it is being read | the evidence for a bug, gone before the bug is filed | PLANT |
| G2 | a state section aged out while still in flight | the work survives, the memory of it does not | PLANT |
| G3 | a hand-written skill in a workspace that gets reverted | the only copy was in the directory the tool owns | PLANT |
| G4 | a skill removed as unused that was seasonal | "unused" measured over a window shorter than the work | PLANT |
| G5 | a record reachable only through a symlink | the sweep follows or does not, and both lose something | ALREADY IN CORPUS — `.chamnan/memory/rules/via-a-symlink.md` |
| G6 | two sweepers with different retention on one file | whichever runs last decides, and neither is wrong | PLANT |
| G7 | an atomic replace under a file the user has open | their editor's buffer is now the only copy | NO — a race, not a state |
| G8 | state aged out because the clock jumped | | ALREADY IN CORPUS — `.chamnan/logs/runs-backwards.jsonl`, `state/timestamps-from-the-future.json` |

## H — confident, and wrong

The failure this corpus exists for: the tool answered, the answer looked fine, and it was false.

| H1 | the index names files that no longer exist | every path in the answer is a guess | PLANT |
| H2 | a skill describing a stack the repository dropped | a procedure followed into a wall | PLANT |
| H3 | two rules that contradict each other | | ALREADY IN CORPUS — `.chamnan/memory/decisions/contradicts-a.md` and `-b.md` |
| H4 | a recorded decision from a different project | somebody else's constraint, applied here | PLANT |
| H5 | a tool index naming archived tools | the index says a script exists; it was archived | PLANT |
| H6 | a coverage map citing deleted tests | coverage that reads as proof and is a memory | PLANT |
| H7 | a milestone dated in the future | | ALREADY IN CORPUS — `.chamnan/logs/dated-in-the-future.jsonl` |
| H8 | a gotcha recorded against a path that was renamed | the warning never fires again and still reads as active | PLANT |

## I — the user's own content, mistaken for the tool's

| I1 | a documentation repository whose files ARE rule files | every file looks like an instruction | PLANT |
| I2 | a legitimate `.cursor/rules` the user maintains | two tools, one repository, both correct | ALREADY IN CORPUS — `corpus/edge/many-hosts/.amazonq/rules/chamnan.md` and 19 more |
| I3 | the repository IS a chamnan fork | the tool indexes its own source and quotes itself | PLANT |
| I4 | a file containing the block's own fence syntax | a repository file speaking in the wrapper's voice | PLANT |
| I5 | `**Check:**` written legitimately in prose | documentation about a feature, executed as one | PLANT |
| I6 | a `CLAUDE.md` that documents prompt injection | correct prose, flagged as the thing it describes | PLANT |
| I7 | a redaction tool's own fixtures | a repository of fake secrets, every one a true positive | PLANT |
| I8 | comments entirely in one non-Latin script | | ALREADY IN CORPUS — `corpus/edge/named-gaps/non-english/` (9 scripts) |

## J — real, and no corpus can carry it

Listed so the gap is named rather than absent. Each needs a measurement, not a file.

| J1 | hook latency at session start | a duration | NO |
| J2 | whether the model USES what the block carried | an answer's quality | NO |
| J3 | the host dropping or reordering hook output | a host behaviour | NO |
| J4 | two hosts open on one repository at once | a runtime arrangement | NO |
| J5 | the trust dialog and OS permission prompts | outside the repository | NO |
| J6 | no network | an environment | NO |
| J7 | a Windows or Linux checkout | an OS | NO — partially reachable through `--install` |
| J8 | another account's permissions | outside the repository | NO |
| J9 | the marketplace and update path | outside the repository | NO |
| J10 | token cost against a no-block control | a measurement with no fixture | NO |
| J11 | a repository too large to clone | cannot be published | NO |
| J12 | what remains after uninstall | a transition, not a state | NO |

---

## Counts

Counted off the table above rather than from memory: **100 cases — 67 PLANT** (8 of them
install-only, because git cannot track the state), **12 ALREADY IN CORPUS**, carried by an earlier
planter at the path each row names, and **21 NO** with the reason named. The planted ones are written by
`plant_user_impact.py`, which puts a `README.md` beside each group saying what the group is and
what a correct answer would look like.

Re-derive these before quoting them — a hand-written count in this file was wrong on the first
draft by five in one column and three in another, which is the same failure the corpus plants in
group H.
