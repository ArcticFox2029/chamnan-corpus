#!/usr/bin/env python3
"""Plant the rule-trailer attack surface into .chamnan/memory/rules/.

A `**Check:**` trailer in a rule file is a regular expression that ARRIVES WITH A CLONE and runs
at every session start. A repository somebody else wrote can therefore hang the reader's session
before they have typed anything. `lib/rulecheck.py` in the plugin is the guard against that.

This script writes one rule file per pattern across seven groups, so that cloning this corpus
exercises the real path rather than a unit fixture:

  1 nested       a quantified group under another quantifier -- the (x+)+ shape
  2 equal        alternation branches that match the same text -- the (a|a)* shape
  3 overlap      alternation branches that merely overlap -- (a|ab)+, (\\w|\\d)*
  4 chain        a long run of independent quantifiers in one pattern
  5 evasion      shapes built to slip PAST the guard's own regexes, not past the engine
  6 benign       patterns that MUST be accepted -- a guard that refuses these is worse than none
  7 malformed    trailers that break at COMPILE time rather than at match time

Groups 1-4 are expected REFUSED, 6 accepted; 5 and 7 are the open questions this corpus exists to
ask. The guard's verdict is recorded per file at plant time so a later run can diff against it.

Usage: python3 plant_rule_patterns.py [--dry-run]
"""
import importlib.util
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
RULES = HERE / ".chamnan" / "memory" / "rules"
GUARD = HERE.parent / "chamnan" / "lib" / "rulecheck.py"


def _load_guard():
    """Load the real guard if the plugin is beside this corpus; otherwise record 'unknown'."""
    if not GUARD.exists():
        return None
    sys.path.insert(0, str(GUARD.parent))  # rulecheck imports its siblings by bare name
    spec = importlib.util.spec_from_file_location("_rulecheck_probe", GUARD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _verdict(rc, pattern):
    """What the guard says today: 'refused', 'through', or 'unknown'."""
    if rc is None:
        return "unknown"
    try:
        hit = (rc._quantified_group_over_quantifier(pattern)
               or rc._ambiguous(pattern)
               or rc._overlapping_alternations(pattern)
               or rc._too_many_quantifiers(pattern))
    except Exception:
        return "guard-raised"
    return "refused" if hit else "through"


# ---- group 1: a quantified group under another quantifier ----------------------------------
_ATOMS = [
    ("a", "a"), ("[a-z]", "az"), (r"\w", "w"), (r"\d", "d"), (r"\s", "s"),
    (".", "dot"), ("[0-9]", "09"), ("(?:ab)", "ab"), ("[A-Za-z0-9_]", "word"), (r"\S", "S"),
]
_INNER = ["+", "*"]
_OUTER = ["+", "*"]


def _nested():
    out = []
    for atom, tag in _ATOMS:
        for i in _INNER:
            for o in _OUTER:
                out.append((f"({atom}{i}){o}", f"nested-{tag}-{'plus' if i=='+' else 'star'}-"
                                               f"{'plus' if o=='+' else 'star'}"))
    # counted quantifiers on either side -- the same family wearing {n,m}
    out += [
        (r"(a{1,}){2,}", "nested-counted-both"),
        (r"(a+){2,5}", "nested-counted-outer"),
        (r"(a{2,})+", "nested-counted-inner"),
        (r"([a-z]{1,3})+", "nested-counted-class"),
        (r"(\d{1,}){1,}", "nested-counted-digit"),
        (r"(?:(\w+)+)", "nested-noncapturing-wrapper"),
        (r"(?P<x>a+)+", "nested-named-group"),
        (r"^(a+)+$", "nested-anchored"),
        (r"prefix-(a+)+-suffix", "nested-with-literals"),
        (r"(( a+ )+)", "nested-double-wrapped"),
    ]
    return out


# ---- group 2: alternation branches that match the same text --------------------------------
def _equal():
    return [
        (r"(a|a)*", "equal-literal"),
        (r"(a|a)+", "equal-literal-plus"),
        (r"(ab|ab)*", "equal-two-char"),
        (r"(a|a|a)*", "equal-three-branches"),
        (r"(GET|GET)+x", "equal-word"),
        (r"(\d|\d)*", "equal-class-escape"),
        (r"([0-9]|[0-9])*", "equal-class-literal"),
        (r"(\s|\s)+", "equal-space"),
        (r"(a|a)*b", "equal-with-tail"),
        (r"^(a|a)*$", "equal-anchored"),
        (r"(x|x){2,}", "equal-counted"),
        (r"((a|a)*)*", "equal-under-nested"),
        (r"(?:a|a)*", "equal-noncapturing"),
        (r"(?P<dup>a|a)*", "equal-named"),
        (r"(foo|foo)+bar", "equal-word-with-tail"),
        (r"(\.|\.)*", "equal-escaped-dot"),
        (r"(-|-)+", "equal-dash"),
        (r"(a|a)*(b|b)*", "equal-two-groups"),
        (r"(\t|\t)+", "equal-tab"),
        (r"(TODO|TODO)*", "equal-marker"),
    ]


# ---- group 3: branches that merely overlap -------------------------------------------------
def _overlap():
    return [
        (r"(a|ab)+", "overlap-prefix"),
        (r"(ab|a)+", "overlap-prefix-reversed"),
        (r"(\w|\d)*", "overlap-word-digit"),
        (r"(\w|a)*", "overlap-word-literal"),
        (r"(\S|\w)+", "overlap-nonspace-word"),
        (r"(.|a)*", "overlap-dot-literal"),
        (r"([a-z]|[a-c])*", "overlap-class-subset"),
        (r"([0-9]|\d)+", "overlap-digit-two-ways"),
        (r"(ab|abc)+", "overlap-longer-prefix"),
        (r"(a+|aa)+", "overlap-quantified-branch"),
        (r"(GET|G)+", "overlap-verb-initial"),
        (r"(https|http)://\S+", "overlap-scheme"),
        (r"(\d+|\d+\.\d+)*", "overlap-number-shapes"),
        (r"([A-Z]|[A-Za-z])+", "overlap-case-classes"),
        (r"(\s|\s\s)+", "overlap-one-or-two-spaces"),
        (r"(x|xy|xyz)*", "overlap-three-prefixes"),
        (r"(a|[ab])*", "overlap-literal-in-class"),
        (r"(\.|\w)*", "overlap-dot-word"),
    ]


# ---- group 4: a long run of independent quantifiers ----------------------------------------
def _chain():
    out = []
    letters = "abcdefghij"
    for n in range(4, 11):
        body = "".join(f"{c}+" for c in letters[:n])
        out.append((body, f"chain-{n}-plus"))
    out += [
        (r"\s*\S*\s*\S*\s*\S*\s*", "chain-space-nonspace"),
        (r"\d+-\d+-\d+-\d+-\d+-\d+", "chain-dashed-numbers"),
        (r".*a.*b.*c.*d.*e.*", "chain-dot-star"),
        (r"[a-z]+[0-9]+[a-z]+[0-9]+[a-z]+[0-9]+", "chain-alternating-classes"),
        (r"(\w+)\s+(\w+)\s+(\w+)\s+(\w+)\s+(\w+)", "chain-five-words"),
    ]
    return out


# ---- group 5: shapes built to slip past the guard's own regexes ----------------------------
# The guard reads a pattern with regexes of its own; those regexes have edges. `[^()]*` cannot see
# through a nested group, and the inner quantifier class is not the same as the outer one. These
# are aimed at the READER, not at the engine -- several are expected to be harmless once measured,
# and that is itself the finding.
def _evasion():
    return [
        (r"(?i)(a|A)*", "evade-case-insensitive-branches"),
        (r"(a|\x61)*", "evade-hex-escape-branch"),
        (r"(a|[a])*", "evade-one-char-class"),
        (r"(a|[a-b])*", "evade-range-overlap"),
        (r"(a)\1*", "evade-quantified-backreference"),
        (r"((a)|(a))*", "evade-branches-in-groups"),
        (r"(a|a)*", "evade-unicode-escape-branch"),
        (r"(((a+)))+", "evade-triple-nesting"),
        (r"(?x)( a | a )*", "evade-verbose-flag"),
        (r"(a{2,})+", "evade-counted-inner"),
        (r"(a{2,}){3,}", "evade-counted-both"),
        (r"(a+)++", "evade-possessive-lookalike"),
        (r"((?=a)a+)+", "evade-lookahead-wrapper"),
        (r"(?:(?:a+)+)", "evade-noncapturing-both"),
        (r"(a+(?#comment))+", "evade-inline-comment"),
        (r"(a+ )+", "evade-trailing-space-in-group"),
        (r"( a+)+", "evade-leading-space-in-group"),
        (r"(a+\b)+", "evade-word-boundary-in-group"),
        (r"(?:a|a)*?", "evade-lazy-outer"),
        (r"(a*?)+", "evade-lazy-inner"),
        (r"(\Qa+\E)+", "evade-quote-escape-unsupported"),
        (r"(?P<g>a+)(?P=g)*", "evade-named-backreference"),
        (r"[(]a+[)]+", "evade-bracketed-parens"),
        (r"(a+)|(a+)|(a+)|(a+)|(a+)", "evade-repeated-alternatives"),
        (r"(?:a+){2}{2}", "evade-stacked-counts"),
    ]


# ---- group 6: patterns that MUST be accepted -----------------------------------------------
# A guard is judged on both directions. Every one of these is an ordinary thing a real rule would
# check for, and a refusal here is a false positive that costs the user a working rule.
def _benign():
    return [
        (r"\bTODO\b", "ok-todo"),
        (r"^## ", "ok-heading"),
        (r"[0-9]{4}-[0-9]{2}-[0-9]{2}", "ok-iso-date"),
        (r"(?:foo|bar)", "ok-two-words"),
        (r"https?://\S+", "ok-url"),
        (r"^from\s+\w+\s+import\s+", "ok-python-import"),
        (r"def\s+\w+\(", "ok-function-def"),
        (r"#\s*noqa", "ok-noqa"),
        (r"[A-Z][a-z]+", "ok-capitalised-word"),
        (r"\d+\.\d+\.\d+", "ok-semver"),
        (r"^\s*$", "ok-blank-line"),
        (r"[^\s]+@[^\s]+\.[a-z]{2,}", "ok-email-ish"),
        (r"password\s*=", "ok-password-assignment"),
        (r"(?m)^import ", "ok-multiline-flag"),
        (r"\$\{[A-Z_]+\}", "ok-shell-variable"),
        (r"<!--.*?-->", "ok-html-comment-lazy"),
        (r"^\| .* \|$", "ok-table-row"),
        (r"\bFIXME\b|\bXXX\b", "ok-two-markers"),
        (r"[a-f0-9]{40}", "ok-sha1"),
        (r"^\s{4}", "ok-indent"),
        (r"\.(py|md|js)$", "ok-extension"),
        (r"(?i)license", "ok-case-insensitive-word"),
        (r"\n\n+", "ok-blank-run"),
        (r"^- \[[ x]\] ", "ok-checkbox"),
        (r"\b(GET|POST|PUT|DELETE)\b", "ok-http-verbs"),
        (r"chamnan-[a-z]+", "ok-command-name"),
        (r"^\d+\. ", "ok-ordered-list"),
        (r"`[^`]+`", "ok-inline-code"),
        (r"[{][^{}]*[}]", "ok-braces"),
        (r"\s+$", "ok-trailing-space"),
    ]


# ---- group 7: trailers that break at COMPILE time ------------------------------------------
# A guard that only thinks about match time still has to survive these. Each is a trailer a real
# clone could carry: a typo, a pattern written for a different engine, or a pattern large enough
# that compiling it is the cost.
def _malformed():
    return [
        (r"(", "bad-unclosed-group"),
        (r")", "bad-stray-close"),
        (r"[a-", "bad-unclosed-class"),
        (r"a{2,1}", "bad-reversed-range"),
        (r"*", "bad-leading-quantifier"),
        (r"a**", "bad-double-quantifier"),
        (r"(?P<1bad>a)", "bad-group-name"),
        (r"(?P<x>a)(?P<x>b)", "bad-duplicate-group-name"),
        (r"\\", "bad-trailing-backslash-escaped"),
        (r"(?R)", "bad-recursion-unsupported"),
        (r"\p{L}+", "bad-unicode-property-unsupported"),
        (r"(?<=a+)b", "bad-variable-width-lookbehind"),
        (r"[[:alpha:]]+", "bad-posix-class"),
        (r"(?'name'a)", "bad-dotnet-group-syntax"),
        (r"a{99999}{99999}", "bad-astronomical-repeat"),
        ("(" * 120 + "a" + ")" * 120, "bad-deep-nesting"),
        ("a" * 8000, "bad-very-long-literal"),
        ("(a|" * 60 + "a" + ")" * 60, "bad-deep-alternation"),
        (r"\k<undefined>", "bad-undefined-backreference"),
        (r"", "bad-empty-pattern"),
        (r"   ", "bad-whitespace-only"),
        (r"(?# unterminated comment", "bad-unterminated-comment"),
    ]


GROUPS = [
    ("nested", "a quantified group under another quantifier", "refused", _nested),
    ("equal", "alternation branches that match the same text", "refused", _equal),
    ("overlap", "alternation branches that merely overlap", "refused", _overlap),
    ("chain", "a long run of independent quantifiers", "refused", _chain),
    ("evasion", "built to slip past the guard's own regexes", "open", _evasion),
    ("benign", "an ordinary rule that MUST keep working", "accepted", _benign),
    ("malformed", "breaks at compile time, not at match time", "open", _malformed),
]

_HEADLINE = {
    "refused": "This rule exists to be **REFUSED**.",
    "accepted": "This rule exists to be **ACCEPTED**.",
    "open": "What this rule should do is the **open question** this corpus asks.",
}

_BODY = {
    "refused": (
        "Its trailer carries a pattern from a catastrophic-backtracking family the guard already\n"
        "knows. If a session starts normally over this corpus, the guard held. If it hangs, this\n"
        "file is the one that did it."
    ),
    "accepted": (
        "Its trailer is an ordinary thing a real rule would look for. A guard is judged in both\n"
        "directions: refusing this costs a user a working rule, which is the failure mode nobody\n"
        "reports because it looks like the rule was simply never written."
    ),
    "open": (
        "Its trailer was written against the guard's own regexes rather than against the matching\n"
        "engine, so passing the guard is not the same as being safe, and being refused is not the\n"
        "same as being dangerous. Either verdict here is a finding, not a pass."
    ),
}


def _slug(tag):
    return re.sub(r"[^a-z0-9-]+", "-", tag.lower()).strip("-")


def main():
    dry = "--dry-run" in sys.argv
    rc = _load_guard()
    rows = []
    n = 0
    for group, blurb, expect, fn in GROUPS:
        for pattern, tag in fn():
            n += 1
            try:
                re.compile(pattern)
                compiles = True
            except re.error:
                compiles = False
            rows.append({
                "file": f"{n:03d}-{_slug(tag)}.md",
                "group": group,
                "expect": expect,
                "compiles": compiles,
                "pattern": pattern,
                "guard_said": _verdict(rc, pattern),
            })

    if dry:
        seen = {}
        for r in rows:
            seen.setdefault((r["group"], r["guard_said"]), 0)
            seen[(r["group"], r["guard_said"])] += 1
        for k in sorted(seen):
            print(f"  {k[0]:<10} {k[1]:<12} {seen[k]:>4}")
        print(f"  {'total':<10} {'':<12} {len(rows):>4}")
        return

    for old in RULES.glob("*.md"):
        old.unlink()
    for r in rows:
        group = r["group"]
        blurb = next(b for g, b, _, _ in GROUPS if g == group)
        title = r["pattern"] if len(r["pattern"]) <= 40 else r["pattern"][:37] + "..."
        (RULES / r["file"]).write_text(
            f"# {group}: {blurb}\n\n"
            f"{_HEADLINE[r['expect']]}\n\n"
            f"{_BODY[r['expect']]}\n\n"
            f"**Check:** present `{title}` in `corpus/SPEC.md`\n",
            encoding="utf-8",
        )
    counts = {}
    for r in rows:
        counts.setdefault(r["group"], {}).setdefault(r["guard_said"], 0)
        counts[r["group"]][r["guard_said"]] += 1
    table = "\n".join(
        f"| `{g}` | {b} | {e} | "
        + ", ".join(f"{k} {v}" for k, v in sorted(counts.get(g, {}).items())) + " |"
        for g, b, e, _ in GROUPS
    )
    (RULES / "README.md").write_text(
        "# The rule-trailer attack surface, written down as files\n\n"
        "These are not rules. A `**Check:**` trailer is a regular expression that **arrives with a\n"
        "clone and runs at every session start** -- so a repository somebody else wrote can hang the\n"
        "reader's session before they have typed anything. `lib/rulecheck.py` is the guard against\n"
        "that, and this directory is what it has to survive.\n\n"
        f"{len(rows)} files in seven groups. Generated by `plant_rule_patterns.py`; edit that, not\n"
        "these, or a fixture drifts away from the thing it tests.\n\n"
        "| group | what it is | expected | the guard said, at plant time |\n"
        "| --- | --- | --- | --- |\n"
        f"{table}\n\n"
        "`MANIFEST.json` carries the pattern, the group, the expectation and the verdict for every\n"
        "file, so a later run can diff against what was true when they were planted rather than\n"
        "re-deriving it. The two columns disagreeing is the point: `expected` is the judgement,\n"
        "`the guard said` is the measurement, and a row where they differ is either a gap in the\n"
        "guard or a wrong expectation -- both worth finding, neither assumed.\n",
        encoding="utf-8",
    )
    (RULES / "MANIFEST.json").write_text(json.dumps(rows, indent=1) + "\n", encoding="utf-8")
    print(f"  planted {len(rows)} rule file(s) in {RULES.relative_to(HERE)}")


if __name__ == "__main__":
    main()
