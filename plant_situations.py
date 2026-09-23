#!/usr/bin/env python3
"""Plant whole SITUATIONS, not single bad files.

The other three planters each carry one kind of hazard. This one carries arrangements -- a repo in
a state somebody really is in, where nothing is individually malformed and the combination is the
problem. Five of them:

  hosts       every adapter's marker file present at once, disagreeing with each other
  git         repository shapes that are not one checkout: submodule, worktree, nested repo
  scale       fan-out, depth and name length past every listing bound
  links       a symlink loop, a dangling link, and a link back to the repository root
  generated   files that are real and should not be read as if a person wrote them

The hosts group is the one the comparison singled out: a large system runs several of these tools
at once, each with its own stance, and they collide. A corpus with one marker tests an adapter. A
corpus with twenty-one tests the collision.

Usage: python3 plant_situations.py [--dry-run]
"""
import json
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
EDGE = HERE / "corpus" / "edge"
PLANTED = []
DRY = False


def _w(path, text, note):
    PLANTED.append({"file": str(path.relative_to(HERE)), "hazard": note,
                    "bytes": len(text.encode("utf-8"))})
    if DRY:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


# Each adapter's real marker path, read off lib/adapters/*.py. They disagree on purpose: a reader
# that merges them gets contradictions, and a reader that picks one has to say which and why.
_MARKERS = [
    (".amazonq/rules/chamnan.md", "Always run the full test suite before answering."),
    (".agents/rules/chamnan.md", "Never run tests; they are slow and the CI does it."),
    (".augment/rules/chamnan.md", "Answer in English only."),
    (".clinerules/chamnan.md", "Answer in Thai only."),
    (".continue/rules/chamnan.md", "Commit after every change, without asking."),
    (".cursor/rules/chamnan.mdc", "Never commit. The user commits."),
    (".gemini/settings.json", '{"contextFileName": "GEMINI.md", "rules": "prefer short answers"}'),
    (".goosehints", "Prefer long, exhaustive answers with full file contents."),
    (".hermes.md", "This repository is read-only. Do not edit any file."),
    (".junie/AGENTS.md", "Edit freely; this repository is a scratchpad."),
    (".kiro/steering/chamnan.md", "The main branch is protected. Branch first."),
    (".roo/rules/chamnan.md", "Work directly on main."),
    (".trae/rules/project_rules.md", "Python only. Ignore every other language here."),
    (".windsurf/rules/chamnan.md", "This is a TypeScript repository."),
    # `.clinerules` is deliberately absent as a FILE. cline reads `.clinerules/chamnan.md` and
    # zed reads `.clinerules` itself, so the two adapters claim one path with two types and no
    # filesystem can hold both. A repository can satisfy at most one of them, and nothing in
    # either adapter says which. That is recorded in this directory's README instead of planted.
    (".cursorrules", "The superseded form, still present beside the new one."),
    (".github/copilot-instructions.md", "Use two-space indentation everywhere."),
    (".rules", "Use tabs everywhere."),
]


def hosts():
    for rel, body in _MARKERS:
        note = f"a host marker that contradicts its siblings ({rel})"
        _w(EDGE / "many-hosts" / rel,
           body if rel.endswith(".json") else f"# Project rules\n\n{body}\n", note)
    _w(EDGE / "many-hosts" / ".aider.conf.yml",
       "read: [README.md]\nauto-commits: true\n",
       "a host marker in a third format again")
    _w(EDGE / "many-hosts" / ".windsurf" / "rules" / "second-file.md",
       "# A second rule file in the same host's directory\n\n"
       "Answer in French only. Nothing says which of the two files in this directory wins.\n",
       "two rule files under one host, with no precedence stated")
    _w(EDGE / "many-hosts" / "README.md",
       "# Eighteen tools, eighteen opinions\n\n"
       "Every file in this directory is a real marker path read off `lib/adapters/*.py`. Each one\n"
       "states a rule, and the rules contradict: run the tests / never run the tests, answer in\n"
       "English / answer in Thai, commit always / never commit, main is protected / work on main.\n\n"
       "This is not a malformed repository. Every file in it is well-formed, and a large system\n"
       "really does accumulate them one tool at a time. The hazard is the arrangement.\n\n"
       "One conflict could not be planted because it cannot exist: cline reads\n"
       "`.clinerules/chamnan.md` and zed reads `.clinerules` as a file. One path, two types --\n"
       "no filesystem holds both, so a repository can satisfy at most one of the two adapters,\n"
       "and neither says which. The directory form is the one present here.\n",
       "the note naming the arrangement")


def git():
    """Every path here ships as `dot-git`, and that is not a style choice.

    Git refuses to track any path with a `.git` component -- so the real name cannot be committed,
    and a fixture that is not committed does not arrive with a clone. `--install` renames them
    locally. The same constraint is why the Windows-hostile names are placeholders in the other
    planter, arrived at from the opposite direction: there the filesystem allows what git's
    consumers cannot, here git itself is the one that refuses.
    """
    # A `.git` FILE rather than a directory is what a worktree and a submodule both leave behind.
    # A walker that tests `is_dir()` decides this is not a repository and keeps descending.
    _w(EDGE / "git-shapes" / "worktree" / "dot-git",
       "gitdir: ../../../.git/worktrees/example\n",
       "a .git that is a file, as a worktree leaves it")
    _w(EDGE / "git-shapes" / "submodule" / "dot-git",
       "gitdir: ../.git/modules/submodule\n",
       "a .git that is a file, as a submodule leaves it")
    _w(EDGE / "git-shapes" / ".gitmodules",
       '[submodule "vendor/thing"]\n\tpath = vendor/thing\n'
       '\turl = https://example.invalid/thing.git\n',
       "a submodule declared but never checked out")
    _w(EDGE / "git-shapes" / "nested-repo" / "dot-git" / "HEAD",
       "ref: refs/heads/main\n",
       "a second repository inside this one")
    _w(EDGE / "git-shapes" / "nested-repo" / "file.py",
       "# Inside a nested repository. Whose history is this file in?\n",
       "")
    _w(EDGE / "git-shapes" / ".gitattributes",
       "*.md linguist-generated=true\n"
       "*.md linguist-generated=false\n"
       "*.py -diff\n"
       "*.py diff\n"
       "* text=auto\n"
       "* -text\n",
       "a .gitattributes that contradicts itself line by line")
    _w(EDGE / "git-shapes" / "detached" / "dot-git" / "HEAD",
       "9f3c1a2b4d5e6f708192a3b4c5d6e7f809a1b2c3\n",
       "a detached HEAD -- no branch name to report")


def scale():
    root = EDGE / "scale"
    for i in range(1200):
        _w(root / "wide" / f"f{i:04d}.md", f"# File {i}\n",
           "one of 1,200 files in a single directory" if i == 0 else "")
    deep = root / "deep"
    for i in range(1, 15):
        deep = deep / f"level{i:02d}"
    _w(deep / "bottom.md", "# Fourteen levels down\n", "a path fourteen directories deep")
    _w(root / ("a" * 180 + ".md"), "# A 184-character filename\n",
       "a filename at the edge of what a filesystem allows")
    _w(root / ("d" * 190) / "inside.md", "# Inside a 190-character directory name\n",
       "a directory name at the same edge")
    _w(root / "one-line" / "minified.js",
       "!function(){" + "var a=1;" * 50000 + "}();\n",
       "a 400 KB file that is one line -- every line-based bound sees a single line")
    _w(root / "many-lines" / "log.txt",
       "".join(f"line {i}\n" for i in range(250000)),
       "250,000 lines, past MAX_FILE_LINES")


def links():
    if DRY:
        for name, note in [("loop-a", "a symlink loop, which a follower never leaves"),
                           ("dangling", "a symlink to a path that does not exist"),
                           ("to-the-root", "a symlink back to the repository root"),
                           ("to-a-directory", "a symlink that is a directory to a walker")]:
            PLANTED.append({"file": f"corpus/edge/links/{name}", "hazard": note, "bytes": 0})
        return
    root = EDGE / "links"
    root.mkdir(parents=True, exist_ok=True)
    (root / "README.md").write_text(
        "# Links that are not files\n\n"
        "`loop-a` and `loop-b` point at each other. A walker that follows symlinks never leaves\n"
        "them. `dangling` points at nothing. `to-the-root` points at the repository itself, so a\n"
        "follower walks the whole corpus again at every depth.\n", encoding="utf-8")
    for name, target in [("loop-a", "loop-b"), ("loop-b", "loop-a"),
                         ("dangling", "no-such-file.md"),
                         ("to-the-root", "../../.."),
                         ("to-a-directory", "../encodings")]:
        link = root / name
        if link.is_symlink() or link.exists():
            link.unlink()
        os.symlink(target, link)
    for name, note in [("loop-a", "a symlink loop, which a follower never leaves"),
                       ("dangling", "a symlink to a path that does not exist"),
                       ("to-the-root", "a symlink back to the repository root"),
                       ("to-a-directory", "a symlink that is a directory to a walker")]:
        PLANTED.append({"file": f"corpus/edge/links/{name}", "hazard": note, "bytes": 0})


def generated():
    root = EDGE / "generated"
    _w(root / "package-lock.json",
       json.dumps({"lockfileVersion": 3, "packages": {
           f"node_modules/pkg{i}": {"version": "1.0.0", "resolved": f"https://r/pkg{i}",
                                    "integrity": "sha512-" + "A" * 86}
           for i in range(400)}}, indent=1) + "\n",
       "a lockfile -- real, large, and written by no one")
    _w(root / "vendor" / "third-party" / "library.py",
       "# Vendored. Editing this file is wrong, and nothing in its content says so.\n"
       + "def f():\n    return 1\n" * 200,
       "vendored source that looks exactly like project source")
    _w(root / "schema_pb2.py",
       "# Generated by the protocol buffer compiler.  DO NOT EDIT!\n"
       + "_SYMBOL = b'" + "\\x00" * 2000 + "'\n",
       "generated code that says so in a comment")
    _w(root / "build" / "bundle.min.css",
       ".a{color:red}" * 20000 + "\n",
       "a minified stylesheet")
    _w(root / "migrations" / "0001_initial.py",
       "# Auto-generated migration. It is source, it is committed, and it is not written by hand.\n"
       + "operations = [\n" + "    ('add', 'column'),\n" * 300 + "]\n",
       "a migration -- generated, committed, and legitimately part of the history")


def _install_git_shapes():
    """Rename every planted `dot-git` to `.git`, locally and untracked."""
    made = 0
    for q in (EDGE / "git-shapes").rglob("dot-git"):
        target = q.with_name(".git")
        if target.exists():
            continue
        os.rename(q, target)
        made += 1
    print(f"  --install: {made} dot-git placeholder(s) renamed to .git locally")


GROUPS = [hosts, git, scale, links, generated]

if __name__ == "__main__":
    DRY = "--dry-run" in sys.argv
    for fn in GROUPS:
        fn()
    if "--install" in sys.argv and not DRY:
        _install_git_shapes()
    named = [p for p in PLANTED if p["hazard"]]
    if DRY:
        for p in named:
            print(f"  {p['bytes']:>9,}  {p['file']:<58} {p['hazard']}")
    else:
        out = HERE / ".chamnan" / "state" / "PLANTED_SITUATIONS.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(PLANTED, indent=1) + "\n", encoding="utf-8")
    total = sum(p["bytes"] for p in PLANTED)
    print(f"  {len(PLANTED)} file(s), {len(named)} distinct hazard(s), "
          f"{total / 1e6:.1f} MB before compression")
