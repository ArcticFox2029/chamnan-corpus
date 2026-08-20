# chamnan-corpus

A synthetic codebase built to be as hard to index as a real system gets — so you can measure a
context tool against something difficult without pointing it at your own code.

Drop it in a folder, run whatever you are testing, and compare numbers with anyone else who did the
same. That is the whole idea: **measurements nobody has to take your word for.**

```bash
git clone https://github.com/ArcticFox2029/chamnan-corpus.git
cd chamnan-corpus
python3 plant_secrets.py        # fills in the planted credentials, locally
```

---

## What is in it

A cross-border container logistics platform called ORBITALFREIGHT: IoT firmware on containers, edge
gateways at depots, fourteen backend services, mobile apps, a web console, an analytics pipeline,
and the infrastructure to deploy all of it.

| | |
|---|---|
| Files | **800** |
| File types | **72** extensions, plus a Gemfile, a Jenkinsfile, a Makefile and two extensionless shell tools |
| Source files an indexer would read | **528** |
| Size | **6.2 MB** |
| Comment languages | **8 writing systems** — Latin, Thai, Devanagari, Cyrillic, CJK, Hangul, Arabic, Hiragana |
| Databases | three SQL dialects, plus SQLAlchemy models and Android Room entities |
| API contracts | Protobuf/gRPC, GraphQL, OpenAPI |
| Infrastructure | Kubernetes, Ansible, Helm, Docker Compose, Terraform, CI pipelines |
| Planted credentials | **28 placeholders** in 17 shapes, filled by `plant_secrets.py` |

**Nothing in it is a placeholder.** Every service cross-references the others by real name against
`corpus/SPEC.md`, which is the single source of truth for every service name, table name, column,
endpoint path, event name and environment variable. One corner is deliberately careless code with no
comments at all, because real repositories have one of those too.

---

## What it is for

Any tool that claims to summarise, index or compress a codebase can be pointed at this and measured.
It was built for [chamnan](https://github.com/ArcticFox2029/chamnan), and those numbers are
reproducible from a clone:

```bash
python3 plant_secrets.py
cd corpus && chamnan-map
```

```
528 source file(s), 1,368,905 tokens of code
Quick Index    51,894 tokens  (3.8% of the source)
described    [###################.] 516/528 files (98%)

Over the 3,000-token session budget, so session start will roll this up by
directory: ~2,996 tokens injected per session instead of 51,894
```

The interesting test is not the ratio. It is whether **none of the planted credentials appear in the
generated index** — and whether the tool still says something useful about a repository whose
comments are in eight scripts.

---

## The credentials, and why they are not in this repository

A real codebase leaks credentials into places nobody meant to publish, so this one does too: provider
tokens, JWTs, private-key blocks, credentialed database URLs, `.env` files, Kubernetes Secrets, and
secrets pasted into comments.

They cannot ship here. **Not because they are real — every one is invented — but because GitHub's
secret scanning cannot tell.** An `AKIA…` string is forwarded to AWS by partner scanning within
minutes of a push; AWS then tries to revoke a key that never existed, and the account that pushed a
test fixture gets a mark against it.

So the files carry `__PLANTED_…__` placeholders, and `plant_secrets.py` fills them from a seeded
PRNG.

Only 28 of the corpus's planted credentials are templated this way — the ones whose shape a
provider's scanner recognises, which are the ones that would block a push. The rest are generic
passwords, connection strings and secrets pasted into comments; they look like nothing in
particular to a scanner and ship as they are. `secrets-and-config/` is complete either way, which
is what makes "did the tool leak any of them into its output" a real test. Two people running it get the same corpus and can compare results, and the two directions are
exact inverses — a working copy can go round the loop any number of times and come back
byte-identical.

```bash
python3 plant_secrets.py            # fill them in
python3 plant_secrets.py --check    # which state is this corpus in?
python3 plant_secrets.py --revert   # put the placeholders back
```

> **Do not commit the corpus while it is planted.** `--check` will tell you which state you are in,
> and `--revert` puts it back. The repository ships in the reverted state.

---

## What is deliberately missing

**The binary attachments.** The original corpus carried 1,192 of them — PDFs, spreadsheets,
archives, images, logs, a SQLite database — for testing tools that read a file's *shape* instead of
its contents. They are 12 MB of incompressible binary that git stores badly and nobody can diff, and
they can be generated rather than shipped.

**The bulk seed data.** Five SQL files of a million rows each, 8 MB in total, which tested nothing
the schema files do not already test.

Both are why this is 6.2 MB rather than 34 MB. The schema, the contracts, the manifests and every
line of source are here in full.

---

## Licence

MIT. It is a fixture — use it, break it, extend it, publish what you measure.
