# When "the index is current" and "the timestamp is nonsense" look identical

`edited-but-dated-in-the-future.py` carries a function no index built before it can know
about, and an mtime seventy years from now. Every mtime-based staleness test reads the
index as current.

Recorded in chamnan_research_dead_ends.md — mtime cannot answer this question: the clamp was applied, tested and reverted because it changes
nothing, and the conclusion was that mtime cannot answer this question.
