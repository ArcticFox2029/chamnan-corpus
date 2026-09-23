# Names this filesystem allows and a Windows checkout does not

Each `*.reserved-name` file here is a placeholder. Its real name -- the one in the file's
first line -- would make `git clone` fail on Windows, which would prove nothing except
that nobody on Windows can use this corpus.

`python3 plant_failure_classes.py --install` puts the real names down locally. They are
untracked by design; `.gitignore` keeps them that way.

- `CON.md` -- a reserved DOS device name
- `NUL.md` -- a reserved DOS device name
- `PRN.md` -- a reserved DOS device name
- `AUX.md` -- a reserved DOS device name
- `LPT1.md` -- a reserved DOS device name
- `COM1.md` -- a reserved DOS device name
- `trailing-dot.md.` -- a name ending in a dot
- `trailing-space.md ` -- a name ending in a space
- `colon:in:name.md` -- a colon in a name
- `pipe|in|name.md` -- a pipe in a name
- `question?.md` -- a question mark in a name
- `star*.md` -- an asterisk in a name
- `quote".md` -- a double quote in a name
- `less<greater>.md` -- angle brackets in a name
