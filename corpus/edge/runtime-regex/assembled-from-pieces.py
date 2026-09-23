import re

# Worse than reading a file: no single string in this source is a pattern. Concatenation
# is what makes one, and the pieces are individually meaningless.
OPEN, ATOM, CLOSE, QUANT = '(', 'a+', ')', '+'
RX = re.compile(OPEN + ATOM + CLOSE + QUANT)
