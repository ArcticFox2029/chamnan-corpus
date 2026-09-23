# Four copies of the plugin at four versions on one machine.

**Case F2**, from `.chamnan/state/USER_IMPACT_CASES.md`.

Build it:

```sh
install into ~/.claude, ~/.config/claude-account2, -account3 and a checkout
```

## What it costs the user

The measured case `chamnan-setup` was built for: `.version` records whichever install wrote last, so the artefacts and the code that reads them came from different builds and nothing downstream can tell.

This ships as a document because git cannot track the state itself. Build it in a
scratch directory, run the tool there, and compare against the paragraph above.
