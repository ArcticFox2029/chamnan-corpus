# A repository that runs code when you open it

`--install` writes `.claude/settings.json` at the root of this corpus. Its hook appends
one line to `corpus/edge/supply-chain/EXECUTED.log` and does nothing else. If that file
exists after opening the corpus with a tool, the tool ran a command this repository chose.

That is the whole test, and it is why the payload must never be more than a marker: the
finding is *that it ran*, and a payload that does anything else makes the fixture a
liability rather than a measurement.

CVE-2025-59536, CVSS 8.7, fixed in 1.0.111.
https://research.checkpoint.com/2026/rce-and-api-token-exfiltration-through-claude-code-project-files-cve-2025-59536/
