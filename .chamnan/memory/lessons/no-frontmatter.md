kind: lesson
title: this looked like frontmatter but no fence opened it

A store entry whose header was never fenced. A parser that splits on `---` finds nothing
and a parser that reads the first lines finds a header, so the two disagree about what
this file is.
