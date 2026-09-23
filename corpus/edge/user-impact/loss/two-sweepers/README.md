# One file, two retention policies

`logs/commands.jsonl` is bound by record on a ninety-day window and by mtime on a
five-day one. Whichever sweeper runs last decides, and neither is wrong on its own terms.
The list of files that are exempt from one sweeper and not the other is maintained in two
places, and they drifted once already.
