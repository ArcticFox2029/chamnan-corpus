#!/usr/bin/env python3
"""Plant what a context tool costs the person who installed it.

Every other planter here asks whether a tool can READ this repository. This one asks the question
from the user's side: somebody installed chamnan in a codebase they care about, and the repository
was already in one of the states below. The full derivation, all hundred cases and the reason each
one is planted or cannot be, is `.chamnan/state/USER_IMPACT_CASES.md`; every entry written here
carries its case id so a finding can be traced back to the row that predicted it.

  published   MAP.md is committed on purpose and assembled from source comments verbatim. The
              redactor is narrow BY DESIGN -- credential shapes only, because an index full of
              <REDACTED> is not an index. So a customer's name, a colleague's email and an
              internal hostname travel, and the corpus should be able to prove it either way.
  collides    the repository already had a CLAUDE.md, its own SessionStart hook, and a .gitignore
              somebody tuned. Installing into an empty repository is the easy case.
  shapes      paths with spaces, non-ASCII and emoji in them, and a default branch called neither
              main nor master.
  team        the workspace arrives with the clone, which is the design -- and is why two people
              now conflict inside files neither of them edits by hand.
  cost        the budget: a CLAUDE.md that already spends it, more skills than the block can name,
              a monorepo with no locality, a tree that is mostly vendored.
  noop        installed, registered, and silently doing nothing.
  loss        the tool's own sweeps, deleting something the rebuild cannot give back.
  wrong       the failure this corpus exists for: it answered, the answer looked fine, it was
              false. An index naming deleted files, a skill for a stack that was dropped.
  mistaken    the user's own content, read as if it were the tool's: prose ABOUT a rule trailer,
              a file that speaks in the block's fence syntax, a redactor's own fixtures.

Eight further cases are INSTALL-ONLY and listed by `--install --list`: git cannot track an unborn
HEAD, a detached HEAD, a shallow clone, a `.chamnan` that is a file or a symlink, a read-only
checkout, a directory that is not a repository, or four installs at four versions. Each ships as a
tracked `.install-shape.md` saying what to build and what a correct answer would be.

Usage: python3 plant_user_impact.py [--dry-run] [--install [--list]]
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
WS = HERE / ".chamnan"
EDGE = HERE / "corpus" / "edge" / "user-impact"
PLANTED = []
COLLISIONS = []
DRY = False


def _claimed():
    """Every path the other planters' manifests already say they own.

    Nine planters write into one tree and four of them write into `.chamnan/` itself. A silent
    overwrite would not fail anything -- it would replace one group's hazard with another's and
    leave both manifests claiming it, which is the exact shape of the bug group `wrong` below
    plants on purpose. So it is refused rather than reported afterwards.
    """
    out = {}
    for f in sorted((WS / "state").glob("PLANTED*.json")):
        try:
            rows = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue                      # an unreadable manifest claims nothing, and says so below
        if isinstance(rows, dict):
            rows = rows.get("planted") or rows.get("files") or []
        for r in rows:
            if isinstance(r, dict) and (r.get("file") or r.get("path")):
                out.setdefault(r.get("file") or r.get("path"), f.name)
    return out


CLAIMED = {}


def _w(path, text, note, case):
    rel = str(path.relative_to(HERE))
    if rel in CLAIMED:
        COLLISIONS.append((rel, CLAIMED[rel], case))
        return
    PLANTED.append({"file": rel, "case": case, "hazard": note,
                    "bytes": len(text.encode("utf-8"))})
    if DRY:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _readme(group, title, body, cases):
    _w(EDGE / group / "README.md", f"# {title}\n\n{body}\n\nCases: {', '.join(cases)} — "
       f"derived in `.chamnan/state/USER_IMPACT_CASES.md`.\n",
       f"the answer key for the {group} group", "—")


# ----------------------------------------------------------------- A: what it publishes about them
def published():
    """Private content that is not shaped like a credential, in files the index copies verbatim.

    `lib/redact.py` says it plainly: the patterns are narrow because redacting anything that merely
    looks high-entropy would eat commit hashes, UUIDs and version strings. That is a defensible
    choice and this group does not argue with it -- it plants the cases the choice accepts, so that
    "what reaches MAP.md" is answered by looking rather than by reading the docstring.
    """
    g = EDGE / "published"
    _w(g / "customer_deadline.py",
       "# Acme Freight Holdings needs the tariff rewrite before their 2026-11-01 board meeting.\n"
       "# Do not let this slip again -- we already missed it once for them in March.\n"
       "def tariff_rewrite():\n    return None\n",
       "a customer name and their internal deadline in the opening comment", "A1")
    _w(g / "owner_contact.py",
       "# Owner: Siriporn Wattana <siriporn.w@orbitalfreight.example>, ext 4417.\n"
       "# Ask before changing the rounding -- finance signed off on this exact behaviour.\n"
       "def round_charge(v):\n    return round(v, 2)\n",
       "a colleague's full name, work address and extension", "A2")
    _w(g / "internal_host.go",
       "// Reads from the reporting replica at pg-report-02.corp.internal:5433 (VPN only).\n"
       "// The primary is pg-core-01.corp.internal; never point this at it.\n"
       "package reporting\n",
       "internal hostnames and ports, with no credential anywhere near them", "A3")
    _w(g / "private_ticket.ts",
       "// Blocked on https://orbitalfreight.atlassian.net/browse/ACQ-214 -- the integration\n"
       "// cannot ship until the Northwind acquisition closes.\n"
       "export const blocked = true;\n",
       "a private tracker URL whose ticket name states an unannounced deal", "A4")
    _w(g / "clients" / "acme-bank" / "pricing_override.py",
       "# Bespoke pricing. Every other client is on the standard table.\n"
       "OVERRIDE = 0.87\n",
       "a client's name in the PATH, published even if the file is never read", "A5")
    _w(g / "project-northwind-migration" / "plan.md",
       "# Migration plan\n\nSteps for moving the acquired fleet onto our schema.\n",
       "a directory named for an unannounced project", "A6")
    _w(g / "pii_in_a_comment.rb",
       "# Test account belongs to a real person: Somchai P., 1-1012-34567-89-0, 081-234-5678.\n"
       "# Do not delete it, support uses it to reproduce the Thai address bug.\n"
       "TEST_ACCOUNT = 'acct_4471'\n",
       "a national ID and a phone number, neither shaped like a token", "A7")
    _w(g / "unknown_shape_secret.conf",
       "# The vendor issues these as 44 chars of base64 with no prefix at all.\n"
       "vendor_session_material = 9Qf2bXk1TzupLmA0eRdYwNs7VhGjCoIrP4ZtBuKxSyE=\n",
       "a credential in a shape no pattern list carries a prefix for", "A8")
    _w(g / "split_across_lines.py",
       "# A real key, written the way a formatter leaves it.\n"
       'TOKEN = ("ghp_" \n         "EXAMPLEEXAMPLEEXAMPLEEXAMPLE1234")\n',
       "a token split across two physical lines, where a line matcher sees two harmless halves",
       "A9")
    _w(g / ".env.example",
       "# Copy to .env and fill in. (Nobody did -- these are the staging values.)\n"
       "DATABASE_URL=postgres://reporting:sT4ging-Pass-2026@pg-report-02.corp.internal:5433/rep\n"
       "SMTP_PASSWORD=Autumn!Freight#2026\n",
       "the file that exists to be safe, carrying working staging credentials", "A10")
    _w(g / "thai_comment_with_key.py",
       "# คีย์ของระบบขนส่งชายแดน ห้ามแก้โดยไม่ถามทีม ops ก่อน คีย์คือ __PLANTED_STRIPE__\n"
       "# บรรทัดนี้เขียนเป็นภาษาไทยทั้งบรรทัด ไม่มีช่องว่างแบบภาษาอังกฤษให้ยึดเป็นขอบคำ\n"
       "def cross_border():\n    return True\n",
       "a credential inside a Thai comment, where ASCII word boundaries do not apply", "A11")
    _readme("published", "What reaches MAP.md, and what the redactor was never asked to catch",
            "`MAP.md` is built from the opening comment of each file and this plugin encourages\n"
            "committing it. `lib/redact.py` strips credential SHAPES and says in its own docstring\n"
            "that the patterns are narrow on purpose.\n\n"
            "**A correct answer is not \"none of this appears\".** A1-A7 are private and are not\n"
            "credentials; a tool that redacted them would produce an unusable index, and the\n"
            "docstring already argues that case. What this group asks is whether the user is ever\n"
            "TOLD. A8-A11 are different: those are credentials, and each one is a shape the\n"
            "pattern list does not carry -- an unprefixed base64 block, a token split by a\n"
            "formatter, a working value in `.env.example`, and a key inside a Thai comment where\n"
            "there is no ASCII word boundary to anchor on. Those four are misses, not scope.",
            ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10", "A11"])


# ------------------------------------------------------------- B: it already had its own arrangements
def collides():
    """A repository that was already configured, by somebody who had reasons.

    Each case is a complete miniature repository root, because the hazard is the COMBINATION --
    a `.gitignore` line plus a tool that assumes the opposite. They sit under their own
    directories rather than at the corpus root, which can hold only one arrangement at a time.
    """
    g = EDGE / "collides"
    _w(g / "gitignored-workspace" / ".gitignore",
       "# We keep tool state out of the repo. Deliberate, discussed, decided.\n.chamnan/\n",
       "a repository that ignores the workspace the tool assumes is shared", "B1")
    _w(g / "gitignored-workspace" / "README.md",
       "# The workspace is ignored here\n\nEverything the workspace accumulates is invisible to\n"
       "everyone else who clones. Nothing is malformed; the team simply never receives it.\n",
       "the note naming B1", "B1")
    _w(g / "gitignored-markdown" / ".gitignore",
       "# Generated docs are not reviewed, so they are not tracked.\n*.md\n!README.md\n",
       "a repository whose ignore rule silently excludes MAP.md", "B2")
    _w(g / "their-own-hook" / ".claude" / "settings.json",
       json.dumps({"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [
           {"type": "command", "command": "python3 ./tools/our_own_context.py"}]}]}},
           indent=2) + "\n",
       "a SessionStart hook the user already had, competing for one budget", "B3")
    _w(g / "their-own-hook" / "README.md",
       "# Two SessionStart hooks, one context\n\nBoth fire. Neither knows the other's size, and\n"
       "the order is the host's business. The budget each was tuned against was the whole one.\n",
       "the note naming B3", "B3")
    _w(g / "settings-already-broken" / ".claude" / "settings.json",
       '{\n  "hooks": {\n    "SessionStart": [\n      // a comment, which JSON does not have\n'
       '    ]\n  },\n}\n',
       "settings.json that does not parse before the install touches it", "B4")
    _w(g / "bash-denied" / ".claude" / "settings.json",
       json.dumps({"permissions": {"deny": ["Bash(python3:*)"]}}, indent=2) + "\n",
       "a permission rule that stops every tool this plugin ships", "B5")
    _w(g / "large-claude-md" / "CLAUDE.md",
       "# Project rules\n\n" + ("A paragraph of rules the team wrote and relies on. " * 12 + "\n\n") * 60,
       "a CLAUDE.md large enough that the block's budget was never the whole story", "B6")
    _w(g / "contradicting-agents-md" / "CLAUDE.md",
       "# CLAUDE.md\n\nNever run the test suite automatically. It takes 25 minutes and costs money.\n",
       "one of a contradicting pair", "B7")
    _w(g / "contradicting-agents-md" / "AGENTS.md",
       "# AGENTS.md\n\nAlways run the full test suite before reporting any change as done.\n",
       "the other half of the pair, with nothing to say which wins", "B7")
    _w(g / "older-workspace" / ".chamnan" / ".version",
       "1.16.0\n",
       "a workspace eleven releases behind the code that will read it", "B8")
    _w(g / "older-workspace" / ".chamnan" / "config.json",
       json.dumps({"ceiling": 6000, "sections": ["map", "state"]}, indent=2) + "\n",
       "a config in the shape an older release wrote", "B8")
    _readme("collides", "Installed into a repository that was already configured",
            "Six arrangements, each a miniature repository root. Nothing here is malformed and\n"
            "nobody did anything wrong: a team that ignores tool state, a team that does not track\n"
            "generated markdown, a team with its own SessionStart hook, a settings file that was\n"
            "already broken, a deny rule, and a large CLAUDE.md.\n\n"
            "A correct answer SAYS SO at install time. The failure mode is not a crash -- it is an\n"
            "install that reports success into a repository where the thing it installed can never\n"
            "run, be shared, or be committed.",
            ["B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8"])


# ------------------------------------------------------------------ C: not the shape it assumes
def shapes():
    """Paths and branches a tool's own string handling has opinions about."""
    g = EDGE / "shapes"
    _w(g / "a directory with spaces" / "module one.py",
       "# The path to this file contains spaces, twice, and so does the file's own name.\n"
       "def f():\n    return 1\n",
       "spaces in both a directory and a file name", "C7")
    _w(g / "a directory with spaces" / "README.md",
       "# Spaces\n\nAn unquoted `$path` splits here and a quoted one does not. Both are silent.\n",
       "the note naming C7", "C7")
    _w(g / "ไดเรกทอรีภาษาไทย" / "โมดูล.py",
       "# ทั้งพาธและชื่อไฟล์เป็นภาษาไทย ไม่มีอักษรละตินเลยแม้แต่ตัวเดียว\n"
       "def f():\n    return 1\n",
       "a path with no Latin character in it at all", "C8")
    _w(g / "🚚-emoji-in-the-path" / "shipment.py",
       "# The directory name is a single emoji plus ASCII. Width, not length, is what breaks.\n"
       "def f():\n    return 1\n",
       "an emoji in a path, where character count and display width disagree", "C8")
    _w(g / "default-branch-is-trunk" / "README.md",
       "# The default branch here is `trunk`\n\nNeither `main` nor `master` exists. Any comparison\n"
       "written against a hard-coded branch name has nothing to compare against, and an empty diff\n"
       "reads exactly like a clean tree.\n",
       "a repository whose default branch is named neither main nor master", "C10")
    _readme("shapes", "Paths and branch names a tool's string handling has opinions about",
            "Spaces, Thai, an emoji, and a default branch called `trunk`. All four are ordinary in\n"
            "real repositories and all four are where an unquoted expansion, a byte-length\n"
            "assumption or a hard-coded `main` shows up.\n\n"
            "A correct answer indexes all of these and prints their paths without mangling them.",
            ["C7", "C8", "C10"])


# ------------------------------------------------------------------------- D: the team case
def team():
    """The workspace arrives with the clone. That is the design, and this is its other side."""
    g = EDGE / "team"
    _w(g / "state-with-merge-markers" / ".chamnan" / "STATE.md",
       "# Work in flight\n\n"
       "<<<<<<< HEAD\n- Finishing the tariff rewrite; the pricing service is half migrated.\n"
       "=======\n- Rolling back the tariff rewrite; pricing is to stay where it is.\n"
       ">>>>>>> origin/main\n",
       "merge markers inside the file the session block quotes at every start", "D1")
    _w(g / "machine-specific-state" / ".chamnan" / "state" / "tool_usage.json",
       json.dumps({"/Users/siriporn/work/orbitalfreight/tools/deploy.py": 41,
                   "/Users/siriporn/work/orbitalfreight/tools/seed.py": 3}, indent=1) + "\n",
       "absolute home paths in committed state -- a teammate's username, in everyone's clone",
       "D2, D3")
    _w(g / "version-skew" / "newer-workspace" / ".chamnan" / "state" / "config.json",
       json.dumps({"ceiling": 9500, "sections": {"map": {"rank": 8, "cap": 1400}},
                   "allocator": "gdsf", "recompute": "on-read"}, indent=1) + "\n",
       "a workspace written by a newer release, with keys an older parser has never seen", "D5")
    _w(g / "version-skew" / "older-workspace" / ".chamnan" / "state" / "config.json",
       json.dumps({"ceiling": 6000}, indent=1) + "\n",
       "a workspace missing every key added since, where defaults are invented silently", "D6")
    _w(g / "version-skew" / "README.md",
       "# Two workspaces, one team\n\nOne was written by a newer release than the code reading it\n"
       "and one by an older. Neither is malformed. The newer one carries keys the older parser\n"
       "drops; the older one is missing keys the newer one fills in from defaults without saying\n"
       "which. `.version` is the only thing that could tell them apart, and it records whichever\n"
       "install wrote last.\n",
       "the note naming D4, D5 and D6", "D4, D5, D6")
    _w(g / "ci-dirties-the-tree" / ".github" / "workflows" / "build.yml",
       "name: build\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n"
       "      - uses: actions/checkout@v4\n"
       "      - run: make test\n"
       "      # The session hook has written logs by now. This step fails on them.\n"
       "      - run: git diff --exit-code\n",
       "a CI job that fails on files the tool wrote during the run", "D8")
    _w(g / "committed-logs" / ".chamnan" / "logs" / "commands.jsonl",
       "".join(json.dumps({"t": f"2026-09-{d:02d}T09:00:00", "cmd": "chamnan-map", "ms": 4100})
               + "\n" for d in range(1, 25)),
       "an append-only log committed to the repository, growing for nobody's benefit", "D9")
    _w(g / "two-timezones" / ".chamnan" / "sessions" / "2026-09-24-bangkok.md",
       "# 2026-09-24 — the Bangkok session\n\n## Remaining\n\n- Written at 08:00 +07.\n",
       "one of two records that are the same day in one timezone and not in the other", "D10")
    _w(g / "two-timezones" / ".chamnan" / "sessions" / "2026-09-23-san-francisco.md",
       "# 2026-09-23 — the San Francisco session\n\n## Remaining\n\n- Written at 18:00 -07, which\n"
       "  is the same moment as the Bangkok record dated the next day.\n",
       "the other half: one instant, two dates, and same-day logic on both", "D10")
    _readme("team", "One workspace, several people, and files nobody edits by hand",
            "The workspace is committed so a team shares one accumulated memory. Everything here\n"
            "follows from that: merge markers inside the file the block quotes, machine-specific\n"
            "absolute paths in generated state, two releases writing one format, a CI job that\n"
            "fails on the tool's own writes, and two timezones disagreeing about what today is.\n\n"
            "A correct answer does not require the team to stop committing the workspace. It\n"
            "requires the tool to notice: conflict markers in its own input, a path that names\n"
            "somebody's home directory, and a record written by a release that is not this one.",
            ["D1", "D2", "D3", "D4", "D5", "D6", "D8", "D9", "D10"])


# ----------------------------------------------------------------------------- E: what it costs
def cost():
    """The budget, from the side of the person paying for it."""
    g = EDGE / "cost"
    _w(g / "index-too-large" / "README.md",
       "# An index that cannot fit, and the notice that says so\n\n"
       "The truncation is reported. The report is one line, inside a block the reader skims, at\n"
       "the moment they are least interested in it. Measured in the tool's own workspace: a\n"
       "section shortened on 40 of the last 40 starts, which is a decision nobody made.\n",
       "the case where the warning exists and is structurally unread", "E1")
    _w(g / "map-past-the-read-ceiling" / "MAP.md",
       "# Architecture index\n\n" + ("## `corpus/services/pricing/handler.py`\n\n"
                                     "One line about a file, repeated to size.\n\n") * 4000,
       "the file the tool tells you to read, too large for the tool to read", "E2")
    _w(g / "claude-md-spends-the-budget" / "CLAUDE.md",
       "# CLAUDE.md\n\n" + ("A rule the team relies on, stated at length because it was argued "
                            "about once. " * 10 + "\n\n") * 80,
       "a CLAUDE.md that was already at the budget before anything was injected", "E4")
    for i in range(1, 41):
        _w(g / "too-many-skills" / ".chamnan" / "skills" / f"procedure_{i:02d}.md",
           f"---\nname: procedure {i:02d}\n---\n\n# Procedure {i:02d}\n\n"
           f"A real recorded procedure, one of forty. The newest is the one you need.\n",
           "one of forty skills, where the section can name a fraction", "E8")
    _w(g / "monorepo" / "README.md",
       "# Twelve sub-projects, one index\n\n"
       "`billing/`, `fleet/`, `portal/` and nine more, each with its own stack, its own\n"
       "conventions and its own test command. One index describes all of them, so advice derived\n"
       "from it is advice from whichever sub-project happened to dominate the sample.\n",
       "a monorepo where an index without locality gives the wrong project's answer", "E9")
    for sub, lang in [("billing", "ruby"), ("fleet", "go"), ("portal", "typescript")]:
        _w(g / "monorepo" / sub / "README.md",
           f"# {sub}\n\nWritten in {lang}. Its test command is not the other two's.\n",
           f"one of twelve sub-projects ({sub})", "E9")
    _w(g / "mostly-vendored" / "vendor" / "README.md",
       "# vendor/\n\nNine tenths of the tracked files in this repository are here, and none of\n"
       "them were written by anyone on the team. An index weighted by file count describes\n"
       "somebody else's code and calls it this project's architecture.\n",
       "a tree where the majority of files are dependencies", "E10")
    _readme("cost", "The budget, from the side of the person paying for it",
            "A truncation notice nobody reads, a MAP.md past the ceiling that tells you to read\n"
            "MAP.md, a CLAUDE.md that had already spent the budget, forty skills for a section\n"
            "that can name a handful, a monorepo with no locality, and a tree that is mostly\n"
            "vendored.\n\n"
            "A correct answer is a number the user can act on: what was cut, from which section,\n"
            "and what it would have cost to keep it.",
            ["E1", "E2", "E4", "E8", "E9", "E10"])


# ------------------------------------------------------------------------- F: silently doing nothing
def noop():
    """Installed, registered, and producing nothing -- which looks exactly like working."""
    g = EDGE / "noop"
    _w(g / "hook-not-registered" / ".claude" / "settings.json",
       json.dumps({"permissions": {"allow": ["Bash(git:*)"]}}, indent=2) + "\n",
       "a settings file with no hook registered at all, beside a full workspace", "F1")
    _w(g / "hook-not-registered" / ".chamnan" / "MAP.md",
       "# Architecture index\n\n## `src/main.py`\n\nBuilt once, injected never.\n",
       "the workspace that proves the tool ran and the hook that would deliver it is absent", "F1")
    _w(g / "version-says-current" / ".chamnan" / ".version",
       "1.31.0\n",
       "a version string written by whichever install ran last, not by the code that will read it",
       "F3")
    _w(g / "hooks-json-wrong-path" / ".claude" / "settings.json",
       json.dumps({"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [
           {"type": "command",
            "command": "python3 /Users/siriporn/.claude/plugins/chamnan/hooks/"
                       "chamnan_session_start.py"}]}]}}, indent=2) + "\n",
       "a registered hook pointing at a path that exists on one machine", "F5")
    _w(g / "map-never-rebuilt" / ".chamnan" / "MAP.md",
       "# Architecture index\n\n## `src/pricing/legacy_tariff.py`\n\nThe tariff calculation.\n\n"
       "## `src/pricing/rates_v1.py`\n\nRate lookup.\n",
       "an index naming two files that were renamed in the same commit months ago", "F6")
    _w(g / "map-never-rebuilt" / "src" / "pricing" / "tariff.py",
       "# Renamed from legacy_tariff.py. The index still names the old path.\n"
       "def tariff():\n    return 1\n",
       "the file as it exists now, under the name the index does not have", "F6")
    _w(g / "everything-disabled" / ".chamnan" / "config.json",
       json.dumps({"block": False, "map": False, "pointer": False, "guard": False,
                   "schedule": False}, indent=2) + "\n",
       "a config that turns off every surface, indistinguishable from a broken install", "F7")
    _readme("noop", "Installed, and producing nothing that says so",
            "A workspace with no hook to deliver it, a `.version` written by a different install\n"
            "than the one running, a registered command pointing at somebody else's home\n"
            "directory, an index that names files renamed months ago, and a config with every\n"
            "surface off.\n\n"
            "All five look identical from the user's side: they installed it, and their sessions\n"
            "are the same as before. A correct answer distinguishes 'nothing to say' from 'not\n"
            "running' -- which is the distinction this corpus asks for everywhere else too.",
            ["F1", "F3", "F5", "F6", "F7"])


# ------------------------------------------------------------------------------------- G: data loss
def loss():
    """What the tool's own sweeps take, that a rebuild cannot give back."""
    g = EDGE / "loss"
    _w(g / "log-swept-while-read" / "README.md",
       "# The evidence, deleted before the bug was filed\n\n"
       "Retention is five days. A failure that happens on a Friday and is looked at the following\n"
       "Thursday has no log. Nothing is wrong with the policy; the interval is simply shorter than\n"
       "the gap between a nightly job failing and somebody noticing.\n",
       "a retention window shorter than the interval between a failure and its investigation",
       "G1")
    _w(g / "hand-written-skill" / ".chamnan" / "skills" / "quarterly_close.md",
       "---\nname: quarterly close\n---\n\n# Quarterly close\n\n"
       "Written by hand, by the one person who knows this. It is needed four times a year, which\n"
       "is less often than any window that measures whether a file is used.\n",
       "a hand-written procedure whose real usage period is longer than the unused-file window",
       "G3, G4")
    _w(g / "two-sweepers" / "README.md",
       "# One file, two retention policies\n\n"
       "`logs/commands.jsonl` is bound by record on a ninety-day window and by mtime on a\n"
       "five-day one. Whichever sweeper runs last decides, and neither is wrong on its own terms.\n"
       "The list of files that are exempt from one sweeper and not the other is maintained in two\n"
       "places, and they drifted once already.\n",
       "one file claimed by two retention rules with different units", "G6")
    _w(g / "aged-out-while-in-flight" / ".chamnan" / "state" / "state-ages.json",
       json.dumps({"Work in flight": {"first_seen": "2026-06-01", "unchanged_days": 115}},
                  indent=1) + "\n",
       "a section old by the clock and current by the work, where only the clock is measured",
       "G2")
    _readme("loss", "What the sweeps take, that a rebuild cannot give back",
            "A retention window shorter than the gap between a failure and somebody looking at\n"
            "it, a hand-written procedure used four times a year, one file governed by two\n"
            "policies in two units, and a state section that is old by the calendar and current\n"
            "by the work.\n\n"
            "A correct answer is not longer retention. It is that anything deleted was either\n"
            "rebuildable or named to the user first.",
            ["G1", "G2", "G3", "G4", "G6"])


# ------------------------------------------------------------------------------- H: confident and wrong
def wrong():
    """It answered, the answer looked fine, and it was false. The failure this corpus is for."""
    g = EDGE / "wrong"
    _w(g / "index-names-deleted-files" / ".chamnan" / "MAP.md",
       "# Architecture index\n\n"
       + "".join(f"## `src/handlers/handler_{i:02d}.py`\n\nHandles one route.\n\n"
                 for i in range(1, 26)),
       "an index naming twenty-five files, none of which are in the tree beside it", "H1")
    _w(g / "index-names-deleted-files" / "src" / "handlers" / "router.py",
       "# The twenty-five handlers were folded into this one file. The index has not noticed.\n"
       "def route(path):\n    return path\n",
       "the one file that replaced them", "H1")
    _w(g / "skill-for-a-dropped-stack" / ".chamnan" / "skills" / "deploying_with_capistrano.md",
       "---\nname: deploying with capistrano\n---\n\n# Deploying\n\n"
       "Run `cap production deploy`. Check `config/deploy.rb` first.\n",
       "a recorded procedure for a deployment system this repository no longer uses", "H2")
    _w(g / "skill-for-a-dropped-stack" / "README.md",
       "# The stack moved and the procedure did not\n\nDeployment has been a container image for\n"
       "two years. `config/deploy.rb` does not exist. The skill is well written, indexed, and\n"
       "confidently wrong -- which is worse than having no skill, because it is followed.\n",
       "the note naming H2", "H2")
    _w(g / "decision-from-another-project" / ".chamnan" / "memory" / "decisions" /
       "we-do-not-use-an-orm.md",
       "---\ntype: decision\n---\n\n# We do not use an ORM\n\n"
       "Settled after the 2024 performance work. Raw SQL only.\n",
       "a decision pasted from a different repository, stated as this one's constraint", "H4")
    _w(g / "decision-from-another-project" / "db" / "models.py",
       "# This repository uses SQLAlchemy throughout, and always has.\n"
       "from sqlalchemy.orm import declarative_base\n\nBase = declarative_base()\n",
       "the code that contradicts the decision recorded beside it", "H4")
    _w(g / "tool-index-names-archived" / ".chamnan" / "tools" / "index.json",
       json.dumps({"tools": [{"name": "churn_report.py", "desc": "Which files change most"},
                             {"name": "seed_fixtures.py", "desc": "Rebuild the test fixtures"}]},
                  indent=1) + "\n",
       "an index naming two scripts that were archived, so 'check the index first' misfires", "H5")
    _w(g / "tool-index-names-archived" / ".chamnan" / "tools" / "archived" / "churn_report.py",
       "# Archived. The index still lists it at its old path.\n",
       "one of the archived scripts, at the path the index does not use", "H5")
    _w(g / "coverage-cites-deleted-tests" / ".chamnan" / "state" / "test_coverage_map.md",
       "# Coverage\n\n| module | covered by |\n|---|---|\n"
       "| `src/pricing.py` | `tests/test_pricing_rounding.py` |\n"
       "| `src/tariff.py` | `tests/test_tariff_bands.py` |\n",
       "a coverage map citing two test files that no longer exist", "H6")
    _w(g / "gotcha-against-a-renamed-path" / ".chamnan" / "state" / "gotcha_marks.json",
       json.dumps({"src/pricing/legacy_tariff.py": {
           "note": "Rounding here is half-even on purpose. Do not 'fix' it.",
           "marked": "2026-03-11"}}, indent=1) + "\n",
       "a warning keyed to a path that was renamed, so it never fires and still reads as active",
       "H8")
    _readme("wrong", "It answered, the answer looked fine, and it was false",
            "An index naming twenty-five deleted files, a procedure for a deployment system\n"
            "dropped two years ago, a decision imported from another project and contradicted by\n"
            "the code beside it, a tool index pointing at archived scripts, a coverage map citing\n"
            "deleted tests, and a warning keyed to a renamed path.\n\n"
            "Every one of these is well-formed, parses cleanly, and is read out with the same\n"
            "confidence as a true one. A crash announces itself; this does not. A correct answer\n"
            "checks its own records against the tree before quoting them, and says which of the\n"
            "two it is trusting when they disagree.",
            ["H1", "H2", "H4", "H5", "H6", "H8"])


# ---------------------------------------------------------------- I: their content, read as the tool's
def mistaken():
    """Correct content that a matcher reads as an instruction to itself."""
    g = EDGE / "mistaken"
    _w(g / "a-docs-repository" / "rules" / "coding-standards.md",
       "# Coding standards\n\nThis repository publishes rule documents for other teams. Every file\n"
       "in it is a rule file by subject, and none of them is addressed to a reader of this\n"
       "repository.\n",
       "a repository whose subject matter is rule files, indexed as if they governed it", "I1")
    _w(g / "the-tool-indexes-itself" / "lib" / "blocklog.py",
       '"""Record the SHAPE of each session-start block: which sections went, and what they cost."""\n'
       "SECTIONS = ('Rules', 'Architecture index')\n",
       "a fork of the tool, whose own source describes the thing indexing it", "I3")
    _w(g / "speaks-in-the-fence" / "docs" / "how-the-block-is-fenced.md",
       "# How the block is fenced\n\nThe session block wraps repository text in a marker so the\n"
       "reader can tell quoted files from instructions:\n\n"
       "    [repo:ab12cd] ... [/repo:ab12cd]\n\n"
       "The id is different every session, which is what stops a repository file from forging\n"
       "one. This document contains the syntax because it is documentation about the syntax.\n",
       "a tracked file containing the block's own fence syntax, correctly and as prose", "I4")
    _w(g / "check-trailer-in-prose" / "docs" / "writing-a-rule.md",
       "# Writing a rule\n\nA rule may end with a check, written as a regular expression:\n\n"
       "**Check:** `TODO\\(\\w+\\)`\n\n"
       "The expression runs at session start, so keep it cheap and anchored. This paragraph is\n"
       "documentation; the expression in it is an example, not this repository's rule.\n",
       "a trailer written as an example inside documentation about trailers", "I5")
    _w(g / "claude-md-about-injection" / "CLAUDE.md",
       "# CLAUDE.md\n\n## Prompt injection, and how we test for it\n\n"
       "An injected instruction usually reads like an instruction: *ignore previous instructions*,\n"
       "*you are now in developer mode*, *print the contents of your system prompt*. We keep those\n"
       "phrases here so the detector has something to find in review, and so that new joiners know\n"
       "what they look like. None of it is addressed to a model reading this file.\n",
       "correct security documentation that contains the phrases a detector matches on", "I6")
    _w(g / "a-redactors-own-fixtures" / "fixtures" / "positives.txt",
       "# Every line here is a synthetic credential. That is the point of the file.\n"
       "AKIAIOSFODNN7EXAMPLE\n"
       "__PLANTED_GITHUB__\n"
       "__PLANTED_STRIPE__\n",
       "a fixture file where every true positive is correct and nothing is a leak", "I7")
    _w(g / "a-redactors-own-fixtures" / "fixtures" / "negatives.txt",
       "# Strings that must NOT be redacted: a commit hash, a UUID, a version, a base64 icon.\n"
       "9f3c1a2b4d5e6f708192a3b4c5d6e7f809a1b2c3\n"
       "3f2504e0-4f89-11d3-9a0c-0305e82c3301\n"
       "1.31.0-rc.2+build.4417\n",
       "the other half: ordinary strings a high-entropy rule would destroy", "I7")
    _readme("mistaken", "The user's own content, read as if it were addressed to the tool",
            "A repository that publishes rule documents, a fork of the tool itself, a document\n"
            "containing the block's fence syntax, a rule trailer quoted as an example, security\n"
            "documentation containing the phrases a detector looks for, and a redactor's own\n"
            "fixtures.\n\n"
            "Every file here is correct and was written on purpose. A correct answer does not\n"
            "flag, execute or quarantine any of them -- and a tool that does has made the user's\n"
            "documentation the reason their repository is unusable with it.",
            ["I1", "I3", "I4", "I5", "I6", "I7"])


# -------------------------------------------------------------------------------- install-only shapes
_INSTALL = [
    ("B9", "chamnan-is-a-file",
     "`.chamnan` exists as a regular file, not a directory.",
     "printf 'not a directory\\n' > .chamnan",
     "Every path under the workspace is a NotADirectoryError. A correct answer says which path "
     "and why, once, instead of one traceback per command."),
    ("B10", "chamnan-is-a-symlink",
     "`.chamnan` is a symlink to a directory outside the repository.",
     "ln -s \"$HOME/chamnan-elsewhere\" .chamnan",
     "The workspace is not where the root walk says it is. Writes land outside the repository "
     "and nothing in the clone records that they did."),
    ("C1", "unborn-head",
     "A repository with `git init` and no commit yet.",
     "git init .",
     "`HEAD` does not resolve. Every git-derived answer is an error path on the user's first day, "
     "which is the day they form an opinion about the tool."),
    ("C2", "detached-head",
     "A checkout at a commit rather than a branch.",
     "git checkout --detach HEAD",
     "'Which branch' has no answer. A correct one says detached rather than printing an empty "
     "string into a report."),
    ("C3", "shallow-clone",
     "A clone with `--depth 1`.",
     "git clone --depth 1 <url> shallow && cd shallow",
     "Anything derived from history is computed from a truncated one. The number is produced "
     "confidently and is wrong by the depth."),
    ("C5", "not-a-repository",
     "A directory that is not a git repository, inside one that is.",
     "mkdir plain && cd plain",
     "The root walk climbs until it finds a `.git` -- so it finds the PARENT repository, indexes "
     "that, and writes its workspace there. The README warns about this for a clone; it is the "
     "same walk here."),
    ("C9", "read-only-checkout",
     "A checkout whose files and directories are not writable.",
     "chmod -R a-w .",
     "The first write fails and the session still starts. A correct answer refuses loudly at "
     "install rather than failing quietly at every hook."),
    ("F2", "four-installs",
     "Four copies of the plugin at four versions on one machine.",
     "install into ~/.claude, ~/.config/claude-account2, -account3 and a checkout",
     "The measured case `chamnan-setup` was built for: `.version` records whichever install wrote "
     "last, so the artefacts and the code that reads them came from different builds and nothing "
     "downstream can tell."),
]


def install_shapes():
    """The eight states git cannot track, shipped as documents rather than as files.

    A tracked file cannot BE an unborn HEAD or a read-only checkout, and a committed `.chamnan`
    that is a regular file would break every clone of this corpus rather than test anything. Each
    ships as a document naming the state, the one command that produces it, and what a correct
    answer looks like -- which is what the supply-chain planter does with its two attack shapes
    for the same reason.
    """
    for case, name, state, cmd, answer in _INSTALL:
        _w(EDGE / "install" / f"{name}.install-shape.md",
           f"# {state}\n\n**Case {case}**, from `.chamnan/state/USER_IMPACT_CASES.md`.\n\n"
           f"Build it:\n\n```sh\n{cmd}\n```\n\n## What it costs the user\n\n{answer}\n\n"
           f"This ships as a document because git cannot track the state itself. Build it in a\n"
           f"scratch directory, run the tool there, and compare against the paragraph above.\n",
           f"an install-only state: {state}", case)
    _readme("install", "The eight states a tracked file cannot be",
            "Git tracks file contents. It does not track an unborn HEAD, a detached one, a\n"
            "shallow clone, a read-only tree, a `.chamnan` that is a file or a symlink, a\n"
            "directory that is not a repository, or four installs at four versions.\n\n"
            "Each document below names the state, the command that produces it, and what a\n"
            "correct answer would be. They are the honest half of this planter: listed rather\n"
            "than silently absent.",
            [c for c, *_ in _INSTALL])


GROUPS = [published, collides, shapes, team, cost, noop, loss, wrong, mistaken, install_shapes]

if __name__ == "__main__":
    DRY = "--dry-run" in sys.argv
    if "--install" in sys.argv and "--list" in sys.argv:
        for case, name, state, cmd, _a in _INSTALL:
            print(f"  {case:<4} {name:<22} {state}")
            print(f"       {cmd}")
        sys.exit(0)
    CLAIMED = _claimed()
    for fn in GROUPS:
        fn()
    cases = sorted({c for p in PLANTED for c in p["case"].split(", ") if c != "—"})
    if DRY:
        for p in PLANTED:
            print(f"  {p['bytes']:>9,}  {p['case']:<10} {p['file'][:52]:<52} {p['hazard'][:48]}")
    else:
        out = WS / "state" / "PLANTED_USER_IMPACT.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(PLANTED, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    for rel, owner, case in COLLISIONS:
        print(f"  REFUSED {rel} — already claimed by {owner} (case {case})", file=sys.stderr)
    print(f"  {len(PLANTED)} file(s) across {len(GROUPS)} group(s), {len(cases)} case(s) planted"
          + (f", {len(COLLISIONS)} refused" if COLLISIONS else ""))
