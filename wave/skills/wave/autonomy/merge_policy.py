"""Auto-merge policy for backlog-watch (Mason t28u).

Low/medium may auto-merge as karch4162 when ALL hold:
  - rating low or medium (risky never)
  - CI green (no pending/fail required checks)
  - primary agent review YES / APPROVE
  - challenge (Grok) has no unresolved blocker
  - MIGRATION: no (or additive allowed + annotated)
  - PR mergeable; at most one rebase already attempted

Pure function: decide(payload) -> MERGE | HOLD: … | PENDING: … | CONFLICT
"""
from __future__ import annotations

from typing import Any


def wave_block(body: str) -> dict[str, list[str]] | None:
    lines = (body or "").splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == "## Wave")
    except StopIteration:
        return None
    block: dict[str, list[str]] = {}
    for l in lines[start + 1 :]:
        if l.startswith("## "):
            break
        if ":" in l:
            k, v = l.split(":", 1)
            block.setdefault(k.strip(), []).append(v.strip())
    return block


def _first(block: dict[str, list[str]], key: str, default: str = "") -> str:
    vals = block.get(key) or []
    return vals[0] if vals else default


def decide(d: dict[str, Any]) -> str:
    """Return MERGE | HOLD: reason | PENDING: reason | CONFLICT."""
    rating = (d.get("rating") or "").lower().strip()
    if not rating:
        block = wave_block(d.get("body") or "") or {}
        rating = _first(block, "RATING", _first(block, "TIER")).lower()
        if rating.startswith("quick"):
            rating = "low"
        elif rating.startswith("normal"):
            rating = "medium"
        elif rating.startswith("risk"):
            rating = "risky"

    if rating in {"risky", "risk", "complex"}:
        return "HOLD: rating risky is human-merged"
    if rating not in {"low", "medium"}:
        return f"HOLD: rating '{rating or 'missing'}' not auto-merge eligible"

    block = wave_block(d.get("body") or "")
    if block is None:
        return "HOLD: no ## Wave block in the PR body"

    migration = _first(block, "MIGRATION", "yes").lower()
    if migration != "no":
        additive = _first(block, "MIGRATION_ADDITIVE", "").lower() in {"yes", "true", "1"}
        if not (migration.startswith("additive") or additive):
            return "HOLD: MIGRATION is not 'no'"

    primary = (d.get("primary_review") or _first(block, "REVIEWER")).strip()
    # spawn.sh step 5 writes "REVIEW VERDICT:" (space, like REVIEW ROUNDS); accept the
    # underscore spelling too for payloads built by hand.
    primary_verdict = (
        d.get("primary_verdict")
        or _first(block, "REVIEW VERDICT")
        or _first(block, "REVIEW_VERDICT")
        or ""
    ).upper()
    if not primary:
        return "HOLD: missing primary reviewer"
    if "fallback" in primary.lower() or "timeout" in primary.lower():
        return f"HOLD: primary reviewer was a fallback ({primary})"
    if "TIE-BREAKER" in block:
        return "HOLD: TIE-BREAKER ran; a human reads conflicting reviews"
    if primary_verdict not in {"YES", "APPROVE", "PASS"}:
        return (
            f"HOLD: primary review verdict '{primary_verdict or 'missing'}' "
            "(need YES/APPROVE/PASS)"
        )
    # Explicit NO markers in Wave block
    for k in block:
        if k.startswith("NO ") and k.endswith("REVIEW"):
            return f"HOLD: {k}"

    # Challenge reviewer (Grok): non-voting on round cap, but blockers hold merge.
    challenge = d.get("challenge") or {}
    if challenge.get("ran") is True:
        if challenge.get("worktree_modified"):
            return "HOLD: challenge reviewer modified the worktree"
        if challenge.get("timed_out") or (challenge.get("verdict") or "").upper() == "TIMEOUT":
            return "HOLD: challenge review timed out (incomplete)"
        if challenge.get("unresolved_blocker"):
            return f"HOLD: challenge blocker: {challenge.get('summary') or 'unresolved'}"
        verdict = (challenge.get("verdict") or "").upper()
        if verdict in {"FINDINGS", "NEEDS HUMAN", "NEEDS_HUMAN", "FAIL", "NO"}:
            if challenge.get("unresolved_blocker") is not False:
                return f"HOLD: challenge verdict {verdict}"
        elif d.get("require_challenge") and verdict != "PASS":
            return f"HOLD: challenge verdict {verdict or 'missing'}"
    elif d.get("require_challenge"):
        return "HOLD: challenge review required but did not run"

    checks = d.get("checks") or []
    if not checks:
        return "PENDING: no checks reported"
    for c in checks:
        b = c.get("bucket")
        if b in ("fail", "cancel"):
            return f"HOLD: check {c.get('name')} {b}"
        if b == "pending":
            return f"PENDING: check {c.get('name')} pending"

    rebase_attempts = int(d.get("rebase_attempts") or 0)
    if rebase_attempts > 1:
        return "HOLD: more than one rebase attempt"

    m = d.get("mergeable")
    if m == "CONFLICTING":
        if rebase_attempts >= 1:
            return "HOLD: second conflict after rebase"
        return "CONFLICT"
    if m != "MERGEABLE":
        return f"PENDING: mergeable {m}"

    return "MERGE"


if __name__ == "__main__":
    import json
    import sys

    print(decide(json.load(sys.stdin)))
