# malformed: breaks at compile time, not at match time

What this rule should do is the **open question** this corpus asks.

Its trailer was written against the guard's own regexes rather than against the matching
engine, so passing the guard is not the same as being safe, and being refused is not the
same as being dangerous. Either verdict here is a finding, not a pass.

**Check:** present `[[:alpha:]]+` in `corpus/SPEC.md`
