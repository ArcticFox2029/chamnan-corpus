# What chamnan actually did, case by case

`USER_IMPACT_CASES.md` is the hundred predictions. This is what happened when each one was put in
front of chamnan 1.31 on 2026-09-24 — every planted case as its own git repository, with the
SessionStart hook, `chamnan-map`, `chamnan-doctor` and `chamnan-context` run against it, and the
21 cases no corpus can hold answered by measurement instead.

**Six real defects were found, and five of them were fixed the same day.** Every "correct" row
below is a claim that was checked, not one that was assumed — two of the fixtures had to be
corrected first because they reported a pass the tool had not earned.

---

## Defects found

| | case | what was wrong | state |
|---|---|---|---|
| 1 | — | `chamnan-explain-context:104` read `sfull` as an int after its writer began writing `{whole, rank}`; two shortened sections crashed it | fixed `da4a1bf` |
| 2 | G1/G3 | `prune_sessions` deletes a person's committed handoff on the retention window with no notice, though the identical sweep over `logs/` names its files first | fixed `50a8299` |
| 3 | E1 | `_followers` absorbs the standalone notices `reorder` moved to the tail; **four warnings destroyed in one firing** with `dropped` reporting nothing | fixed `50a8299` |
| 4 | A9 | a credential the source split across two string literals reached `MAP.md` whole | fixed `b5697f2` |
| 5 | D2/D9 | three per-machine state files in every teammate's diff, one of them a per-user notice counter that silences itself for the whole team | fixed `504e25a` |
| 6 | — | the planter's own collision guard read its own manifest and refused all 131 of its paths on the second run | fixed in the corpus |

---

## A — what chamnan publishes about them

| | asked | answer | verdict |
|---|---|---|---|
| A1-A7 | does private-but-not-credential content reach `MAP.md`? | yes, verbatim: a customer name, a colleague's address, an internal hostname, a ticket, a client's path, a product directory, a national ID | **scope, stated** — `lib/redact.py` argues narrowness in its own docstring. The open question is whether the user is ever told |
| A8 | an unprefixed 44-char base64 secret | **truncated, not redacted** — 29 of 44 characters published | luck, not protection; a shorter one survives whole |
| A9 | a token split by a formatter | **LEAKED WHOLE** | defect, fixed |
| A10 | real values in `.env.example` | truncated, not redacted | same as A8 |
| A11 | a credential inside a Thai comment | **redacted correctly** | the prediction was wrong, in the user's favour |

## B — the repository already had its own arrangements

| | answer | verdict |
|---|---|---|
| B1 `.gitignore` ignores `.chamnan/` | the block says the workspace is not tracked | correct |
| B2 `.gitignore` ignores `*.md` | same notice names `MAP.md` among the untracked | correct |
| B3 the user's own SessionStart hook | **silent** | a real gap with no cheap fix: a hook cannot see its siblings. Recorded, not invented around |
| B4 `settings.json` already invalid | **silent** | a real gap — the install has nowhere to write and says nothing |
| B5 a deny rule on the Bash permission chamnan needs | **silent** | a real gap; every tool then fails for a reason that is not chamnan's |
| B6 a 40 KB `CLAUDE.md` | indexed, no warning | correct — the budget is chamnan's own, and it is kept |
| B7 `AGENTS.md` contradicting `CLAUDE.md` | both indexed, no precedence offered | out of scope: chamnan indexes, it does not arbitrate |
| B8 a workspace 15 releases old | `.version` rewritten 1.16.0 → 1.31.0 in silence | **documented design**, not a defect — `_newer_version_has_been_here` interrupts only on a DOWNGRADE, in as many words: *"an upgrade is silent … only going backwards is worth interrupting for"* |

## C — the repository is not the shape it assumes

| | answer | verdict |
|---|---|---|
| C7 spaces in the path | `module one.py` indexed and printed intact | correct |
| C8 Thai and emoji in the path | `โมดูล.py` and the emoji directory indexed and printed intact | correct |
| C10 a default branch called `trunk` | silent | the fixture cannot make the branch; it is an install-only state in practice |

## D — the team case

| | answer | verdict |
|---|---|---|
| D1 merge markers in `STATE.md` | *"This store is mid-merge … nothing from this section is injected"* | **correct**, and the best answer in the whole sweep |
| D2/D3 absolute home paths in committed state | not reproduced — asked of the REAL workspace: 0 `/Users/` paths and 0 occurrences of the username across `tool_usage.json`, `written_artefacts.json`, `gotcha_marks.json`, `MAP.md` and `STATE.md` | chamnan stores bare names |
| D4/D5/D6 version skew | the block reports what an older build would not understand | correct |
| D8 CI fails on the tool's own writes | three per-machine files were doing exactly this | **defect 5**, fixed |
| D9 committed `logs/*.jsonl` | already ignored by the workspace's own rules | correct |
| D10 two timezones, one instant | both records read, neither lost | correct |

## E — what it costs

| | answer | verdict |
|---|---|---|
| E1 truncation notice nobody reads | the notice existed and was **being deleted before emission** | **defect 3**, fixed |
| E2 `MAP.md` past the read ceiling | named and reported as partial | correct |
| E4 a `CLAUDE.md` that already spends the budget | chamnan keeps its own budget regardless | correct |
| E8 forty skills | the section names what fits and says how many there are | correct |
| E9 a monorepo of twelve sub-projects | one index, all three sub-projects named | correct, and the locality question stands as a design limit |
| E10 mostly vendored | indexed as written | correct; weighting is not a claim chamnan makes |

## F — installed and doing nothing

| | answer | verdict |
|---|---|---|
| F1 workspace, no hook registered | nothing can speak: the hook is what speaks | unfixable from inside; the install path is where this belongs |
| F3 `.version` current, code older | silent | correct by the same design as B8 |
| F5 a hook path from another machine | silent | same class as F1 |
| F6 an index never rebuilt | *"source has changed since this index was built"*, naming the file | correct |
| F7 every surface disabled | a 659-byte block and no explanation | a real gap: "configured off" and "broken" are indistinguishable |

## G — data loss

| | answer | verdict |
|---|---|---|
| G1 a log swept while it was still wanted | `expiring_logs` names it — and the notice was **being deleted on the way out** | **defect 3**, fixed |
| G2 a state section aged out while in flight | silent | the ageing pass has no in-flight signal to read; recorded |
| G3/G4 a hand-written skill in a workspace | offered in the block; nothing removes it automatically | correct |
| G6 one file, two retention policies | silent | a real gap, and the list is maintained in two places |

## H — confident and wrong

| | answer | verdict |
|---|---|---|
| H1 index names 25 deleted files | *"25 of 25 file(s) this index names no longer exist"* with three examples and the fix | **correct** |
| H2 a skill for a dropped stack | silent | nothing could produce this: a procedure cannot be checked against a stack |
| H4 a decision from another project | silent | same |
| H5 registry names archived tools | both dropped from the block; only the control is offered | **correct** |
| H6 coverage map cites deleted tests | silent | out of scope by construction — that file is written by the repository under test, not by chamnan |
| H8 a gotcha keyed to a renamed path | silent | a real gap |

## I — the user's own content, mistaken for the tool's

Every one of the six is indexed normally with **no false flag**, which is the correct answer:
I1 a documentation repository whose files are rule documents, I3 a fork of chamnan itself,
I4 a file containing the block's own fence syntax, I5 a `**Check:**` trailer quoted as an
example, I6 security documentation containing the phrases a detector looks for, and I7 a
redactor's own fixture pairs — both halves, the true positives and the strings a
high-entropy rule would destroy.

**A tool that flagged any of these would make the user's documentation the reason their repository
is unusable with it.** None did.

## The 8 install-only states, built by hand

Git tracks file contents, not an unborn HEAD or a read-only tree, so each of these was built from
its `.install-shape.md` in a scratch directory and run against.

| | case | what chamnan did |
|---|---|---|
| B9 | `.chamnan` is a regular file | every path under it is a `NotADirectoryError`, caught per command rather than once — the session still starts |
| B10 | `.chamnan` is a symlink out of the repository | followed; writes land outside the repository and nothing in the clone records it. **Recorded as an open question, not a defect**: a symlinked workspace is also a legitimate arrangement |
| C1 | `git init` and no commit yet | the block reports "nobody recorded it, so this is git's answer rather than anyone's" and continues |
| C2 | detached HEAD | the same path; no crash, no empty-string branch printed as if it were a name |
| C3 | a shallow clone | history-derived figures are computed from the truncated history and say nothing about the truncation. **A real limit**, recorded |
| C5 | a directory that is not a repository, inside one | the root walk climbs to the PARENT repository and indexes that — exactly what the corpus README warns about for a clone. Behaviour is documented and correct for the walk; the surprise is the user's |
| C9 | a read-only checkout | `ws.read_only()` exists and is checked before every write; the session starts and writes nothing |
| F2 | four installs at four versions | `chamnan-setup` was built for this and reports all four in one place |

---

## The 12 already in the corpus, carried by an earlier planter

These were not re-planted. Each was verified to be present and reached:

| | case | where it lives |
|---|---|---|
| C11 | worktree, submodule, nested repo | `corpus/edge/git-shapes/`, `plant_situations.py` |
| D7 | a rule file that instructs the reader | `.chamnan/memory/decisions/talks-to-the-reader.md` |
| E3 | the block at its ceiling every start | `.chamnan/logs/block_shape.jsonl` — and this is the log `chamnan-explain-context` reads, which is where defect 1 was found |
| E5 | 1,200 files in one directory | `corpus/edge/scale/wide/` |
| E6 | every file generated | `corpus/edge/generated/` |
| E7 | one enormous file | `.chamnan/state/over-the-read-ceiling.json`, `skills/enormous.md` |
| G5 | a record reachable only through a symlink | `.chamnan/memory/rules/via-a-symlink.md` |
| G8 | state aged out because the clock jumped | `.chamnan/logs/runs-backwards.jsonl`, `state/timestamps-from-the-future.json` |
| H3 | two rules that contradict | `.chamnan/memory/decisions/contradicts-a.md` and `-b.md` |
| H7 | a milestone dated in the future | `.chamnan/logs/dated-in-the-future.jsonl` |
| I2 | a legitimate `.cursor/rules` | `corpus/edge/many-hosts/` — 20 adapter files at once |
| I8 | comments entirely in one non-Latin script | `corpus/edge/named-gaps/non-english/` — 9 scripts |

Each path was checked against the manifest that owns it rather than remembered; two of the twelve
were first looked for under the wrong name and found under another, which is why they are listed
with their paths here.

---

## The 21 that no corpus can hold, and what answers them instead

A fixture cannot be a duration, a host, an operating system or a decision. Each of these is
answered by a measurement, a document, or an explicit refusal — never by silence.

| | case | how it is answered instead |
|---|---|---|
| A12 | a branch name that leaks the roadmap | `--install` creates the branch; the block reports what git reports |
| B11 | `core.hooksPath` points elsewhere | git config, not a tracked file. `chamnan-doctor` is where this belongs |
| B12 | `.git/info/exclude` hides what the map names | inside `.git`; same answer as B11 |
| C4 | a bare repository | cannot contain a working tree, so it cannot contain this corpus |
| C6 | the repository root is the home directory | cannot be planted anywhere but a home directory; the root walk's behaviour is documented in the corpus README |
| C12 | two files differing only in case | **this filesystem cannot hold both** — an honest absence, and it is why CI runs on Linux |
| F4 | `python3` absent or shadowed | a PATH, not a file. `install/chamnan-check.sh` already probes a candidate with `-V` before accepting it |
| F8 | the host truncates the block itself | a host behaviour. `logs/block_shape.jsonl` records what was SENT, which is the half chamnan can see, and `chamnan-explain-context` reads it |
| G7 | an atomic replace under an open editor buffer | a race, not a state |
| J1 | hook latency | `.chamnan/tools/time-the-hook.py` and `time-the-pieces.py` exist for exactly this |
| J2 | whether the model USES the block | an answer's quality. The block has never been measured against a no-block control, and `STATE.md` says so rather than claiming otherwise |
| J3 | the host dropping or reordering hook output | a host behaviour |
| J4 | two hosts open on one repository | a runtime arrangement; the eighteen-adapter collision fixture is as close as a corpus gets |
| J5 | the trust dialog and OS prompts | outside the repository |
| J6 | no network | an environment — and chamnan makes no network calls, which is the whole answer |
| J7 | a Windows or Linux checkout | an OS. CI runs all three, and the `windows` group ships as placeholders because a committed `NUL` stops a Windows clone outright |
| J8 | another account's permissions | outside the repository |
| J9 | the marketplace and update path | outside the repository; `chamnan-setup` is the measured answer to the four-installs case beside it |
| J10 | token cost against a no-block control | a measurement with no fixture, and it has not been done. Named here rather than implied |
| J11 | a repository too large to clone | cannot be published |
| J12 | what remains after uninstall | a transition, not a state |

**Three of these are open questions rather than closed ones** — J2, J10 and C12 — and they are
listed as open. A coverage claim that quietly drops what it cannot test is the failure this whole
corpus exists to make visible.
