# Two workspaces, one team

One was written by a newer release than the code reading it
and one by an older. Neither is malformed. The newer one carries keys the older parser
drops; the older one is missing keys the newer one fills in from defaults without saying
which. `.version` is the only thing that could tell them apart, and it records whichever
install wrote last.
