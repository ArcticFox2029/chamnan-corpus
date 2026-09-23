# Patterns that do not exist until something is read

Every file here builds a regular expression from data rather than from source. The data is
in this repository, so whoever wrote the repository chose the pattern -- and a scan of the
SOURCE finds `re.compile(pattern)` with nothing to say about it.

This is the blind spot the four-plugin comparison named for all four tools: "a pattern
assembled from a variable at runtime is invisible to extraction and to execution alike".
