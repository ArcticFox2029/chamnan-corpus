# The eight states a tracked file cannot be

Git tracks file contents. It does not track an unborn HEAD, a detached one, a
shallow clone, a read-only tree, a `.chamnan` that is a file or a symlink, a
directory that is not a repository, or four installs at four versions.

Each document below names the state, the command that produces it, and what a
correct answer would be. They are the honest half of this planter: listed rather
than silently absent.

Cases: B9, B10, C1, C2, C3, C5, C9, F2 — derived in `.chamnan/state/USER_IMPACT_CASES.md`.
