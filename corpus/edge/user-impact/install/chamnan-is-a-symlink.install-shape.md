# `.chamnan` is a symlink to a directory outside the repository.

**Case B10**, from `.chamnan/state/USER_IMPACT_CASES.md`.

Build it:

```sh
ln -s "$HOME/chamnan-elsewhere" .chamnan
```

## What it costs the user

The workspace is not where the root walk says it is. Writes land outside the repository and nothing in the clone records that they did.

This ships as a document because git cannot track the state itself. Build it in a
scratch directory, run the tool there, and compare against the paragraph above.
