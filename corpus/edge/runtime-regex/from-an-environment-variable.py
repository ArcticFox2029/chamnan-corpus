import os, re

# And the form that is not even in the repository: the pattern is in the environment.
RX = re.compile(os.environ.get('CORPUS_FILTER', '.*'))
