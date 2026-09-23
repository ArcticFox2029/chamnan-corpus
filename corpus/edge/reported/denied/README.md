# A directory that cannot be listed

`unreadable/` is mode 000. A sweep across this tree finds nothing in it and, unless it
says so, is indistinguishable from a sweep that looked and found nothing.

Reported against ripgrep: https://github.com/BurntSushi/ripgrep/issues/863
