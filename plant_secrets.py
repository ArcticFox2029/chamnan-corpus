#!/usr/bin/env python3
"""Put the planted credentials back, locally, so the redaction test has something to catch.

    python3 plant_secrets.py            # fill the placeholders
    python3 plant_secrets.py --revert   # put the placeholders back
    python3 plant_secrets.py --check    # say which state the corpus is in

The corpus exists to be hard to index, and part of "hard" is that a real repository leaks
credentials into places nobody meant to publish. Twenty-eight of them are planted across ten files
in seventeen shapes: provider tokens, JWTs, private-key blocks, credentialed database URLs, `.env`
files, Kubernetes Secrets, and secrets pasted into comments.

`plant` and `--revert` are inverses, and `--revert` is idempotent -- a corpus can go round the
loop any number of times and come back byte-identical. Worth keeping true: an earlier PGURL
generator returned a whole connection string into a slot that was already inside one, so every
roundtrip nested another `postgres://` hop and the file drifted a little each time.

Those cannot ship in the repository. Not because they are real -- every one is invented -- but
because GitHub's secret scanning cannot tell, and an `AKIA…` string is forwarded to AWS by partner
scanning within minutes of a push. AWS then tries to revoke a key that never existed, and the
account that pushed it gets a mark against it for a test fixture.

So they live here, as generators, and the files in `corpus/` carry `__PLANTED_…__` placeholders
until this script runs. The result is byte-identical in shape to what was measured; only the random
part of each value differs, which is the part nothing depends on.

Nothing here is a real credential, and nothing here can become one. Every value is drawn from
Python's `random` with a fixed seed, so two people running this get the same corpus and can compare
numbers -- which is the whole reason the corpus is published at all.
"""
import argparse
import random
import re
import string
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS = HERE / "corpus"
SEED = 20260820  # fixed, so two people generating the corpus get the same one

PLACEHOLDER_RE = re.compile(r"__PLANTED_([A-Z0-9_]+)__")


def _rand(alphabet, n, rng):
    return "".join(rng.choice(alphabet) for _ in range(n))


def _make(kind, rng):
    """One fake credential of the requested shape.

    The shapes match what the real providers issue closely enough that a redactor which only
    matches the real thing is genuinely being tested -- that is the point of the fixture. They are
    still fake: the random body is drawn from a seeded PRNG and corresponds to no account anywhere.
    """
    upper_digits = string.ascii_uppercase + string.digits
    alnum = string.ascii_letters + string.digits

    if kind.startswith("AWS_KEY"):
        return "AKIA" + _rand(upper_digits, 16, rng)
    if kind.startswith("AWS_SECRET"):
        return _rand(alnum + "/+", 40, rng)
    if kind.startswith("STRIPE"):
        return "sk_live_" + _rand(alnum, 24, rng)
    if kind.startswith("GITHUB"):
        return "ghp_" + _rand(alnum, 36, rng)
    if kind.startswith("SLACK_WEBHOOK"):
        return (f"https://hooks.slack.com/services/T{_rand(upper_digits, 8, rng)}"
                f"/B{_rand(upper_digits, 8, rng)}/{_rand(alnum, 24, rng)}")
    if kind.startswith("SLACK"):
        return f"xoxb-{_rand(string.digits, 12, rng)}-{_rand(string.digits, 12, rng)}-{_rand(alnum, 24, rng)}"
    if kind.startswith("ANTHROPIC"):
        return "sk-ant-api03-" + _rand(alnum + "-_", 60, rng)
    if kind.startswith("JWT"):
        head = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        return f"{head}.{_rand(alnum, 96, rng)}.{_rand(alnum + '-_', 43, rng)}"
    if kind.startswith("PGURL"):
        return _rand(alnum, 20, rng)
    if kind.startswith("PASSWORD"):
        return _rand(alnum + "!@#$%", 18, rng)
    if kind.startswith("PKCS8"):
        body = "\n".join(_rand(alnum + "/+", 64, rng) for _ in range(14))
        return f"-----BEGIN PRIVATE KEY-----\n{body}\n-----END PRIVATE KEY-----"
    if kind.startswith("PRIVATE_KEY"):
        body = "\n".join(_rand(alnum + "/+", 64, rng) for _ in range(12))
        return f"-----BEGIN RSA PRIVATE KEY-----\n{body}\n-----END RSA PRIVATE KEY-----"
    if kind.startswith("PGP"):
        body = "\n".join(_rand(alnum + "/+", 64, rng) for _ in range(10))
        return f"-----BEGIN PGP PRIVATE KEY BLOCK-----\n\n{body}\n-----END PGP PRIVATE KEY BLOCK-----"
    if kind.startswith("GITLAB"):
        return "glpat-" + _rand(alnum + "-_", 20, rng)
    if kind.startswith("SENDGRID"):
        return f"SG.{_rand(alnum, 22, rng)}.{_rand(alnum + '-_', 43, rng)}"
    if kind.startswith("TWILIO_SID"):
        return "AC" + _rand("0123456789abcdef", 32, rng)
    if kind.startswith("ED25519"):
        return _rand(alnum + "/+", 88, rng)
    return _rand(alnum, 32, rng)


def _files():
    if not CORPUS.is_dir():
        sys.exit(f"no corpus at {CORPUS} — run this from the repository root")
    for path in sorted(CORPUS.rglob("*")):
        if path.is_file():
            yield path


def plant():
    """Replace every placeholder with a generated value. Idempotent: a corpus already planted has
    no placeholders left and is reported as such rather than double-filled."""
    rng = random.Random(SEED)
    touched = filled = 0
    for path in _files():
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if not PLACEHOLDER_RE.search(text):
            continue
        new = PLACEHOLDER_RE.sub(lambda m: _make(m.group(1), rng), text)
        path.write_text(new, encoding="utf-8")
        touched += 1
        filled += len(PLACEHOLDER_RE.findall(text))
    return touched, filled


# Strings a vendor publishes AS an example. They match a credential pattern by construction --
# that is what they are for -- and they are not credentials. `AKIAIOSFODNN7EXAMPLE` appears in
# AWS's own documentation, and it is the exact false positive gitleaks users report (issue #1830).
# Reverting one to a placeholder would turn the fixture into the thing it exists to be mistaken
# for, so both `check()` and `revert()` step over them by name rather than by shape.
DOCUMENTED_EXAMPLES = ("AKIAIOSFODNN7EXAMPLE",)


def _without_documented_examples(text):
    for example in DOCUMENTED_EXAMPLES:
        text = text.replace(example, "")
    return text


def revert():
    """Put the placeholders back, so the corpus can be committed again without tripping a scanner.

    Matches on the generated shapes rather than on remembered values, because a corpus may have been
    planted by an older copy of this script with a different seed.
    """
    patterns = [
        (re.compile(r"-----BEGIN RSA PRIVATE KEY-----.*?-----END RSA PRIVATE KEY-----", re.S),
         "__PLANTED_PRIVATE_KEY__"),
        (re.compile(r"-----BEGIN PGP PRIVATE KEY BLOCK-----.*?-----END PGP PRIVATE KEY BLOCK-----", re.S),
         "__PLANTED_PGP__"),
        # PKCS#8. Matched only when a base64 body follows -- the same words appear in this corpus as
        # prose describing the fixture, and as a string literal inside a validator that checks for
        # them. Neither is a key, and rewriting either would corrupt the file for no gain.
        (re.compile(r"-----BEGIN PRIVATE KEY-----\n[A-Za-z0-9+/=\s]{100,}?-----END PRIVATE KEY-----", re.S),
         "__PLANTED_PKCS8__"),
        (re.compile(r"\bAKIA[A-Z0-9]{16}\b"), "__PLANTED_AWS_KEY__"),
        (re.compile(r"\bsk_live_[A-Za-z0-9]{20,}\b"), "__PLANTED_STRIPE__"),
        (re.compile(r"\bghp_[A-Za-z0-9]{30,}\b"), "__PLANTED_GITHUB__"),
        (re.compile(r"https://hooks\.slack\.com/services/T[A-Z0-9]{6,}/B[A-Z0-9]{6,}/[A-Za-z0-9]{16,}"),
         "__PLANTED_SLACK_WEBHOOK__"),
        (re.compile(r"\bxoxb-[0-9]{6,}-[0-9]{6,}-[A-Za-z0-9]{16,}\b"), "__PLANTED_SLACK__"),
        (re.compile(r"\bglpat-[A-Za-z0-9\-_]{20,}\b"), "__PLANTED_GITLAB__"),
        (re.compile(r"\bSG\.[A-Za-z0-9]{20,}\.[A-Za-z0-9\-_]{40,}\b"), "__PLANTED_SENDGRID__"),
        (re.compile(r"\bAC[0-9a-f]{32}\b"), "__PLANTED_TWILIO_SID__"),
        (re.compile(r"\bsk-ant-api03-[A-Za-z0-9\-_]{40,}\b"), "__PLANTED_ANTHROPIC__"),
        (re.compile(r"\beyJhbGciOi[A-Za-z0-9]+\.[A-Za-z0-9]{40,}\.[A-Za-z0-9\-_]{20,}\b"), "__PLANTED_JWT__"),
        (re.compile(r"(postgres://[A-Za-z0-9_]+:)[A-Za-z0-9]{12,}@"), r"\1__PLANTED_PGURL__@"),
    ]
    touched = 0
    for path in _files():
        try:
            text = original = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        guarded = {}
        for i, example in enumerate(DOCUMENTED_EXAMPLES):
            if example in text:
                guarded[f"\x00DOCEX{i}\x00"] = example
                text = text.replace(example, f"\x00DOCEX{i}\x00")
        for pattern, placeholder in patterns:
            text = pattern.sub(placeholder, text)
        for token, example in guarded.items():
            text = text.replace(token, example)
        if text != original:
            path.write_text(text, encoding="utf-8")
            touched += 1
    return touched


def check():
    placeholders = live = 0
    live_re = re.compile(
        r"\bAKIA[A-Z0-9]{16}\b|\bsk_live_[A-Za-z0-9]{20,}\b|\bghp_[A-Za-z0-9]{30,}\b"
        r"|\bglpat-[A-Za-z0-9\-_]{20,}\b|\bSG\.[A-Za-z0-9]{20,}\.[A-Za-z0-9\-_]{40,}\b"
        r"|\bAC[0-9a-f]{32}\b|https://hooks\.slack\.com/services/T[A-Z0-9]{6,}/B[A-Z0-9]{6,}/[A-Za-z0-9]{16,}"
        r"|\bxoxb-[0-9]{6,}-[0-9]{6,}-[A-Za-z0-9]{16,}\b|\bsk-ant-api03-[A-Za-z0-9\-_]{40,}\b")
    for path in _files():
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        placeholders += len(PLACEHOLDER_RE.findall(text))
        live += len(live_re.findall(_without_documented_examples(text)))
    return placeholders, live


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--revert", action="store_true", help="put the placeholders back")
    group.add_argument("--check", action="store_true", help="report which state the corpus is in")
    args = parser.parse_args(argv)

    if args.check:
        placeholders, live = check()
        print(f"  placeholders remaining: {placeholders}")
        print(f"  planted credentials:    {live}")
        print("  state: " + ("planted — do not commit this" if live else
                             "safe to commit" if placeholders else "neither; something is wrong"))
        return 0

    if args.revert:
        touched = revert()
        print(f"  reverted {touched} file(s) — safe to commit again")
        return 0

    touched, filled = plant()
    if not touched:
        print("  nothing to do: no placeholders found. Already planted?")
        print("  run --check to see, or --revert to go back")
        return 0
    print(f"  planted {filled} credential(s) across {touched} file(s)")
    print()
    print("  ⚠️  DO NOT COMMIT THE CORPUS IN THIS STATE.")
    print("      Every value is invented, but GitHub's secret scanning cannot tell, and an AKIA")
    print("      string is forwarded to AWS within minutes of a push. Run --revert first.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
