# evasion: built to slip past the guard's own regexes

What this rule should do is the **open question** this corpus asks.

Its trailer was written against the guard's own regexes rather than against the matching
engine, so passing the guard is not the same as being safe, and being refused is not the
same as being dangerous. Either verdict here is a finding, not a pass.

**Check:** present `(?x)( a | a )*` in `corpus/SPEC.md`
