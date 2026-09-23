# Ten records, and any count-based cap admits all of them

`slice(0, 10)` takes ten records. Ten of THESE records is 5 MB. Nothing here is malformed
and nothing is adversarial -- a long working day produces a long record.

A byte ceiling and a count cap agree on every ordinary input, which is why the difference
only ever shows up in production.
