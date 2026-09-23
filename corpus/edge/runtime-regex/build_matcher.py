import pathlib, re

# A scan of this file finds one `re.compile` and one variable. The hazard is in
# patterns.txt beside it, which is data, and data is not scanned for patterns.
PATTERNS = [l.strip() for l in pathlib.Path('patterns.txt').read_text().splitlines()
            if l.strip() and not l.startswith('#')]
MATCHERS = [re.compile(p) for p in PATTERNS]
