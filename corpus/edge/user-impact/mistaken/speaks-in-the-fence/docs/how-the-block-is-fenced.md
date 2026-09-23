# How the block is fenced

The session block wraps repository text in a marker so the
reader can tell quoted files from instructions:

    [repo:ab12cd] ... [/repo:ab12cd]

The id is different every session, which is what stops a repository file from forging
one. This document contains the syntax because it is documentation about the syntax.
