# `.chamnan` exists as a regular file, not a directory.

**Case B9**, from `.chamnan/state/USER_IMPACT_CASES.md`.

Build it:

```sh
printf 'not a directory\n' > .chamnan
```

## What it costs the user

Every path under the workspace is a NotADirectoryError. A correct answer says which path and why, once, instead of one traceback per command.

This ships as a document because git cannot track the state itself. Build it in a
scratch directory, run the tool there, and compare against the paragraph above.
