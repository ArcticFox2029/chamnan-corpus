# A checkout at a commit rather than a branch.

**Case C2**, from `.chamnan/state/USER_IMPACT_CASES.md`.

Build it:

```sh
git checkout --detach HEAD
```

## What it costs the user

'Which branch' has no answer. A correct one says detached rather than printing an empty string into a report.

This ships as a document because git cannot track the state itself. Build it in a
scratch directory, run the tool there, and compare against the paragraph above.
