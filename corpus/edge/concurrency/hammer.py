#!/usr/bin/env python3
"""Race N processes on one JSON file and report what the file lost.

A writer that is atomic AND locked finishes with counter == N. A writer that is only
atomic finishes with a valid file and a counter BELOW N -- the lost update. A writer that
is neither can leave the file unparseable, which a reader that falls back to `{}` then
reports as an empty workspace rather than as damage.

Usage: python3 hammer.py <path.json> <writers> [--atomic] [--locked]
"""
import json, os, sys, tempfile
from multiprocessing import Process

def bump(path, atomic, locked):
    fh = open(path + ".lock", "w") if locked else None
    if fh:
        import fcntl; fcntl.flock(fh, fcntl.LOCK_EX)
    try:
        try:
            d = json.loads(open(path).read())
        except Exception:
            d = {}          # the fallback that turns damage into an empty workspace
        d["counter"] = d.get("counter", 0) + 1
        text = json.dumps(d)
        if atomic:
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
            os.write(fd, text.encode()); os.close(fd); os.replace(tmp, path)
        else:
            open(path, "w").write(text)
    finally:
        if fh:
            fh.close()

if __name__ == "__main__":
    path, n = sys.argv[1], int(sys.argv[2])
    atomic, locked = "--atomic" in sys.argv, "--locked" in sys.argv
    open(path, "w").write(json.dumps({"counter": 0}))
    ps = [Process(target=bump, args=(path, atomic, locked)) for _ in range(n)]
    [p.start() for p in ps]; [p.join() for p in ps]
    try:
        got = json.loads(open(path).read()).get("counter")
        print(f"  {got} of {n} writes survived" if got == n else
              f"  LOST UPDATE: {got} of {n} writes survived")
    except Exception as e:
        print(f"  TORN FILE: the result does not parse -- {e}")
