# A checkout whose files and directories are not writable.

**Case C9**, from `.chamnan/state/USER_IMPACT_CASES.md`.

Build it:

```sh
chmod -R a-w .
```

## What it costs the user

The first write fails and the session still starts. A correct answer refuses loudly at install rather than failing quietly at every hook.

This ships as a document because git cannot track the state itself. Build it in a
scratch directory, run the tool there, and compare against the paragraph above.
