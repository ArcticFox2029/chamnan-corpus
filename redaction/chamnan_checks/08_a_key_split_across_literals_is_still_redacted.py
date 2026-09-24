# ------------------ a credential the SOURCE split in half is still redacted
# Moved from chamnan's suite on 2026-09-24: these need provider prefixes, and key-shaped data lives
# in chamnan-corpus. Prefixes are assembled so no whole shape sits in this file either.
_GHP08 = fake("ghp", "_")
_SKL08 = fake("sk_", "live_")
_sj_split = ('The deploy key, wrapped by the formatter: "' + _GHP08 + '" '
             '"EXAMPLEEXAMPLEEXAMPLEEXAMPLE1234" -- one value, two lines.')
check("A CREDENTIAL SPLIT ACROSS TWO STRING LITERALS IS STILL REDACTED",
      "EXAMPLEEXAMPLEEXAMPLEEXAMPLE1234" not in redact.scrub(_sj_split),
      saw=redact.scrub(_sj_split))
check("...across a newline, which is where a formatter actually leaves it",
      "AAAABBBBCCCCDDDD1234" not in redact.scrub('TOKEN = ("' + _SKL08 + '"\n         "AAAABBBBCCCCDDDD1234")'),
      saw=redact.scrub('TOKEN = ("' + _SKL08 + '"\n         "AAAABBBBCCCCDDDD1234")'))
check("...and with an explicit + between the halves",
      "AAAABBBBCCCCDDDD1234" not in redact.scrub('T = "' + _SKL08 + '" + "AAAABBBBCCCCDDDD1234"'),
      saw=redact.scrub('T = "' + _SKL08 + '" + "AAAABBBBCCCCDDDD1234"'))
check("...and a contiguous token is still caught, which is what this must not regress",
      "EXAMPLEEXAMPLEEXAMPLEEXAMPLE1234" not in
      redact.scrub("token = " + _GHP08 + "EXAMPLEEXAMPLEEXAMPLEEXAMPLE1234"))
