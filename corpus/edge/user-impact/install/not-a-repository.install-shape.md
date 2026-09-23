# A directory that is not a git repository, inside one that is.

**Case C5**, from `.chamnan/state/USER_IMPACT_CASES.md`.

Build it:

```sh
mkdir plain && cd plain
```

## What it costs the user

The root walk climbs until it finds a `.git` -- so it finds the PARENT repository, indexes that, and writes its workspace there. The README warns about this for a clone; it is the same walk here.

This ships as a document because git cannot track the state itself. Build it in a
scratch directory, run the tool there, and compare against the paragraph above.
