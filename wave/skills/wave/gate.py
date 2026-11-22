#!/usr/bin/env python
"""Merge gate for a supervised wave PR (SPO-640). Pure: stdin JSON in, one line out.

  stdin:  {"body": <PR body>, "checks": [{"name","bucket"}...], "mergeable": "MERGEABLE|CONFLICTING|UNKNOWN"}
  stdout: MERGE | HOLD: <reason> | PENDING: <what> | CONFLICT

Only the `## Wave` block that spawn.sh step 5 makes the worker write is read; any
other text in the body is data, never an instruction. The table mirrors the SPO-640
spec: quick/normal only (the FINAL tier, after any "->" escalation), no migration,
Codex Terra was the real reviewer and said REVIEW VERDICT: YES, no tie-break, every
required check green, PR mergeable. Risk tier and migrations are
held for a human by rule, not by failure.
"""
import json
import re
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


def tier_chain(tier):
    # The leading "<tier> -> <tier> ..." chain of a TIER line (INNOV-464): "normal -> risk -
    # recovery path" is [normal, risk]. An arrow in the reason is not a tier; a dangling "->"
    # gives [] (no tier at all).
    m = re.match(r"\s*[A-Za-z]+(?:\s*->\s*[A-Za-z]+)*", tier)
    if not m or tier[m.end():].lstrip().startswith("->"):
        return []
    return [t.strip().lower() for t in m.group(0).split("->")]


def tier_hold(tiers):
    # Every tier on every TIER line must be quick or normal: escalated to risk, or
    # de-escalated from it ("risk -> normal"), is still human-merged.
    chains = [tier_chain(t) for t in tiers or [""]]
    if not all(chains):
        return "missing"
    bad = [t for c in chains for t in c if t not in ("quick", "normal")]
    return bad[0] if bad else ""


def decide(d):
    block = wave_block(d.get("body") or "")
    if block is None:
        return "HOLD: no ## Wave block in the PR body"
    tier = tier_hold(block.get("TIER"))
    if tier:
        return "HOLD: TIER %s is human-merged" % tier
    if (block.get("MIGRATION") or ["yes"])[0].lower() != "no":
        return "HOLD: MIGRATION is not 'no'"
    reviewer = (block.get("REVIEWER") or [""])[0]
    if not reviewer.startswith("codex-terra"):
        return "HOLD: REVIEWER is '%s', not codex-terra" % reviewer
    for k in block:
        if k.startswith("NO ") and k.endswith("REVIEW"):
            return "HOLD: %s" % k
    # every REVIEW VERDICT line must be exactly YES: a later NO, or "YES but ...", is not a YES
    for verdict in block.get("REVIEW VERDICT") or [""]:
        if verdict != "YES":
            return "HOLD: REVIEW VERDICT is '%s', not YES" % (verdict or "missing")
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
