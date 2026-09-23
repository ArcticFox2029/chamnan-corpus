# It answered, the answer looked fine, and it was false

An index naming twenty-five deleted files, a procedure for a deployment system
dropped two years ago, a decision imported from another project and contradicted by
the code beside it, a tool index pointing at archived scripts, a coverage map citing
deleted tests, and a warning keyed to a renamed path.

Every one of these is well-formed, parses cleanly, and is read out with the same
confidence as a true one. A crash announces itself; this does not. A correct answer
checks its own records against the tree before quoting them, and says which of the
two it is trusting when they disagree.

Cases: H1, H2, H4, H5, H6, H8 — derived in `.chamnan/state/USER_IMPACT_CASES.md`.

## Measured 2026-09-24, first run of chamnan over this group

| | result |
|---|---|
| H1 index names deleted files | **caught** — *"25 of 25 file(s) this index names no longer exist"*, with three examples and the rebuild command |
| H5 registry names archived tools | **caught** — the two archived entries are dropped from the block; only the control, `still_here.py`, is offered |
| H2 skill for a dropped stack | no warning. There is nothing that could produce one: a procedure cannot be checked against a stack |
| H4 decision from another project | no warning, and the same applies |
| H6 coverage map cites deleted tests | no warning — and `state/test_coverage_map.md` is written by the repository under test, not by chamnan, so it is out of scope by construction |
| H8 gotcha keyed to a renamed path | no warning |

Two fixtures had to be corrected before they measured anything. H1 was a bare list of `## \`path\``
headings with no `## Full Detail`, and chamnan answered *"this index is truncated or hand-edited"* —
correct, and it meant the dead-entry check was never reached. H5 wrapped the registry in
`{"tools": [...]}` when its real shape is a flat list, so `tools_index.load` dropped the whole file
and the case tested a reader's tolerance for a malformed one instead of the staleness it names.

**A fixture has to be well-formed before its defect is the thing under test.** Both of those
reported a pass the tool had not earned, in the direction that flatters it.
