# Eighteen tools, eighteen opinions

Every file in this directory is a real marker path read off `lib/adapters/*.py`. Each one
states a rule, and the rules contradict: run the tests / never run the tests, answer in
English / answer in Thai, commit always / never commit, main is protected / work on main.

This is not a malformed repository. Every file in it is well-formed, and a large system
really does accumulate them one tool at a time. The hazard is the arrangement.

One conflict could not be planted because it cannot exist: cline reads
`.clinerules/chamnan.md` and zed reads `.clinerules` as a file. One path, two types --
no filesystem holds both, so a repository can satisfy at most one of the two adapters,
and neither says which. The directory form is the one present here.
