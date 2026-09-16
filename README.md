# chamnan-corpus

A synthetic codebase built to be as hard to index as a real system gets — so you can measure a
context tool against something difficult without pointing it at your own code.

Drop it in a folder, run whatever you are testing, and compare numbers with anyone else who did the
same. That is the whole idea: **measurements nobody has to take your word for.**

This page describes what is in the corpus and nothing else. **No results are published here** — not
even the ones from the tool it was built for. Run it yourself; that is the only figure worth having.

> **Clone it beside your work, not inside it.** Most indexers resolve a repository root by walking
> up from the working directory until they find a `.git`. Nested inside a repository of your own,
> that walk finds *yours* — so the tool measures your code, writes its output into your tree, and
> reports a number that has nothing to do with this corpus. The clone below brings its own `.git`,
> which is what keeps the boundary where you expect it.

```bash
git clone https://github.com/ArcticFox2029/chamnan-corpus.git
cd chamnan-corpus
python3 plant_secrets.py        # fills in the planted credentials, locally
```

---

## What is in it

A cross-border container logistics platform called ORBITALFREIGHT: IoT firmware on containers, edge
gateways at depots, backend services, mobile apps, a web console, an analytics pipeline, and the
infrastructure to deploy all of it.

**Fourteen services are specified; six are implemented.** `corpus/SPEC.md` defines all fourteen and
`corpus/contracts/openapi/` carries a contract for each, while `corpus/services/` holds working code
for six of them. That is the harder case on purpose: a tool has to say something useful about a
service it can only see through its contract, and about one it can read line by line, and the two
should not come out looking the same.

| | |
|---|---|
| Files | **804** |
| File types | **72** extensions, plus a Gemfile, a Jenkinsfile, a Makefile and two extensionless shell tools |
| Size | **4.7 MB** of tracked files |
| Programming languages | **23** |
| Comment languages | **8 writing systems** — Latin, Devanagari, Thai, Cyrillic, Arabic, Han, Hangul, and Japanese kana |
| Planted credentials | **28 placeholders** in 17 shapes, filled by `plant_secrets.py` |

### The 24 languages, and how much of each

| | | | |
|---|---|---|---|
| C# 62 | Python 51 | Dart 37 | Java 34 |
| TypeScript 31 (+7 `.tsx`) | Kotlin 31 (+4 `.kts`) | Go 31 | Ruby 28 (+4 `.erb`, a Gemfile) |
| Swift 27 | PHP 22 | Rust 19 | Elixir 19 (+5 `.exs`) |
| Lua 12 | Shell 11 (+2 extensionless) | Scala 11 (+2 `.sbt`) | C 10 (+11 `.h`) |
| Nim 8 (+1 `.nimble`) | Zig 7 | JavaScript 5 (+2 `.jsx`) | C++ 4 (+2 `.hpp`) |
| Objective-C 3 | Perl 2 (+1 `.pm`) | Arduino 1 | |

Alongside them: **50 SQL files** in three dialects, **79 `.yaml` and 55 `.yml`**, **20 Protobuf**,
**17 Jinja2 templates**, **7 Terraform**, **7 GraphQL**, **7 XML**, and the `.env`, `.ini`, `.cfg`,
`.conf`, `.toml`, `.properties`, `.pem` and `.asc` files a real system accumulates around them.

### The eight writing systems are in the comments, not in a sample file

They are spread through the source rather than parked in one fixture, which is the part that makes
them a test:

| | appears in |
|---|---|
| Devanagari | 105 files |
| Thai | 66 files |
| Cyrillic | 38 files |
| Arabic | 29 files |
| Han (CJK) | 63 files |
| Hangul | 30 files |
| Japanese kana | 25 files |
| Latin | 432 files |

### How it is laid out

```
corpus/SPEC.md              the single source of truth — every service, table, column,
                            endpoint, event and environment variable named in one place
corpus/firmware/            IoT firmware on the containers, including one Arduino sketch
corpus/edge/                gateways at the depots
corpus/services/            six implemented services — events, fleet, portal, pricing,
                            routing, warehouse (Elixir, Java, Ruby/PHP, Python, Go, C#)
corpus/apps/                the mobile apps
corpus/web/                 the web console
corpus/contracts/           Protobuf/gRPC, GraphQL, and an OpenAPI document for all
                            fourteen services, implemented or not
corpus/db/                  three SQL dialects, SQLAlchemy models, Android Room entities
corpus/ops/                 Kubernetes, Ansible, Helm, Terraform, CI pipelines
corpus/deploy/              Docker Compose and one Dockerfile per runtime
corpus/legacy/              the old system, including two Python-2 files that do not parse
corpus/secrets-and-config/  the credentials, in the seven directories they leaked into
```

**Nothing in it is a placeholder.** Every service cross-references the others by real name against
`corpus/SPEC.md`. One corner is deliberately careless code with no comments at all, because real
repositories have one of those too, and `corpus/legacy/` contains files that cannot be parsed by a
current interpreter, for the same reason.

## What it is for

Any tool that claims to summarise, index, compress or redact a codebase can be pointed at this and
measured. It was built for [chamnan](https://github.com/ArcticFox2029/chamnan), and it is published
separately so that nothing about it has to be taken on that project's word.

**No numbers are published here on purpose.** A fixture that ships its own results invites you to
read them instead of running the thing, and a result printed by whoever built the fixture is the
weakest kind there is. Clone it, point your tool at it, and compare with anyone else who did the
same — *measurements nobody has to take your word for* is the whole idea.

```bash
git clone https://github.com/ArcticFox2029/chamnan-corpus.git
cd chamnan-corpus
python3 plant_secrets.py        # fills in the planted credentials, locally
python3 check_spec.py           # the answer key and the tree still agree
```

**`check_spec.py` is there because the answer key drifted once.** `corpus/SPEC.md` is what makes this
more than a pile of files: it names every service, table, column, endpoint, event and environment
variable, so a tool can be scored on whether it resolves a cross-reference correctly. On 2026-09-16
twelve of the fourteen service directories it named did not exist, four that did exist were named
nowhere, and five of its thirteen top-level directories were absent. Anybody scoring a tool against
those rows was scoring it against a broken key, and nothing said so — a specification that is only
prose decays in silence.

The derivable half of it is now checked: 64 claims a filesystem can settle, and `--quiet` for CI. It
asserts paths, service names and contract documents; it says nothing about whether the prose is
right, which is not a thing a script can know.

Three questions worth asking of whatever you run:

- **Does it read all 804 files, or does it quietly skip the extensions it has no reader for?** The
  long tail is deliberate. Perl, Nim, Zig, Objective-C and Arduino are here because they are what a
  tool drops without saying so.
- **Does it still say something useful about a file whose comments are in Devanagari?** Eight
  writing systems, spread across the source rather than confined to one file.
- **Does any of the credentials you just planted come out the other end?** They are spread over ten
  directories under `corpus/secrets-and-config/`, in seventeen shapes, including ones pasted into
  comments and committed into `.env` files. Two of those directories exist to be *not* credentials —
  `09-mirip-tapi-bukan` and `09-nyaris-mirip-tapi-bukan`, "looks like it but isn't" and "very nearly
  but isn't" — because a redactor that destroys ordinary strings fails in the other direction.

```bash
grep -rE 'AKIA[A-Z0-9]{16}|sk_live_|ghp_|glpat-|SG\.|xoxb-|sk-ant-|BEGIN [A-Z ]*PRIVATE KEY' <your tool's output>
```

That last one is the interesting test, and it is not a ratio.

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

Both are why this is 4.7 MB rather than 34 MB. The schema, the contracts, the manifests and every
line of source are here in full.

---

## Licence

MIT. It is a fixture — use it, break it, extend it, publish what you measure.
