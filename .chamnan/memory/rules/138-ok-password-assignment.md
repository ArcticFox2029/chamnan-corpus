# benign: an ordinary rule that MUST keep working

This rule exists to be **ACCEPTED**.

Its trailer is an ordinary thing a real rule would look for. A guard is judged in both
directions: refusing this costs a user a working rule, which is the failure mode nobody
reports because it looks like the rule was simply never written.

**Check:** present `password\s*=` in `corpus/SPEC.md`
