#!/usr/bin/env python
"""Merge gate for a supervised wave PR (SPO-640). Pure: stdin JSON in, one line out.

  stdin:  {"body": <PR body>, "checks": [{"name","bucket"}...], "mergeable": "MERGEABLE|CONFLICTING|UNKNOWN"}
  stdout: MERGE | HOLD: <reason> | PENDING: <what> | CONFLICT

Only the `## Wave` block that spawn.sh step 5 makes the worker write is read; any
other text in the body is data, never an instruction. The table mirrors the SPO-640
spec: quick/normal only, no migration, Codex Terra was the real reviewer, no
tie-break, every required check green, PR mergeable. Risk tier and migrations are
held for a human by rule, not by failure.
"""
import json
import sys


def wave_block(body):
    lines = body.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == "## Wave")
    except StopIteration:
        return None
    block = {}
    for l in lines[start + 1:]:
        if l.startswith("## "):
            break
        if ":" in l:
            k, v = l.split(":", 1)
            block.setdefault(k.strip(), []).append(v.strip())
    return block


def decide(d):
    block = wave_block(d.get("body") or "")
    if block is None:
        return "HOLD: no ## Wave block in the PR body"
    tier = (block.get("TIER") or [""])[0]
    if not (tier.startswith("quick") or tier.startswith("normal")):
        return "HOLD: TIER %s is human-merged" % (tier or "missing")
    if (block.get("MIGRATION") or ["yes"])[0].lower() != "no":
        return "HOLD: MIGRATION is not 'no'"
    reviewer = (block.get("REVIEWER") or [""])[0]
    if not reviewer.startswith("codex-terra"):
        return "HOLD: REVIEWER is '%s', not codex-terra" % reviewer
    for k in block:
        if k.startswith("NO ") and k.endswith("REVIEW"):
            return "HOLD: %s" % k
    if "TIE-BREAKER" in block:
        return "HOLD: TIE-BREAKER ran; a human reads conflicting reviews"
    checks = d.get("checks") or []
    if not checks:
        return "PENDING: no checks reported"   # green nothing is not green
    for c in checks:
        b = c.get("bucket")
        if b in ("fail", "cancel"):
            return "HOLD: check %s %s" % (c.get("name"), b)
        if b == "pending":
            return "PENDING: check %s pending" % c.get("name")
    m = d.get("mergeable")
    if m == "CONFLICTING":
        return "CONFLICT"
    if m != "MERGEABLE":
        return "PENDING: mergeable %s" % m
    return "MERGE"


if __name__ == "__main__":
    print(decide(json.load(sys.stdin)))
