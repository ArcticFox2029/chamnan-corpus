# A clone with `--depth 1`.

**Case C3**, from `.chamnan/state/USER_IMPACT_CASES.md`.

Build it:

```sh
git clone --depth 1 <url> shallow && cd shallow
```

## What it costs the user

Anything derived from history is computed from a truncated one. The number is produced confidently and is wrong by the depth.

This ships as a document because git cannot track the state itself. Build it in a
scratch directory, run the tool there, and compare against the paragraph above.
