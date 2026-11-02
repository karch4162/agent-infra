"""Conditional plan step for thin / PLAN_NEEDED tickets.

Adapted from loomwright's Supervisor-Ready Brief + plan-reviewer (read-only),
and agent-infra plan-review.sh (planner + other-model reviewer, cap 2 rounds).

Sportify plan is intentionally smaller than loomwright's 21-criterion brief:
  ## Files
  ## Approach
  ## Tests
  ## Risks (optional)

Reviewer returns PLAN_REVIEW_RESULT with decision PASS | FAIL | NEEDS_HUMAN.
Orchestrator posts the approved plan on the ClickUp ticket before any code.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

PLAN_SECTIONS = ("Files", "Approach", "Tests")
VERDICT_RE = re.compile(
    r"PLAN_REVIEW_RESULT:.*?decision:\s*(PASS|FAIL|NEEDS_HUMAN)",
    re.I | re.S,
)
SIMPLE_VERDICT_RE = re.compile(r"PLAN VERDICT:\s*(APPROVE|REVISE|NEEDS HUMAN)", re.I)


PLAN_TEMPLATE = """# Wave plan for {ticket_id}

## Goal
{title}

## Files
- (list paths to modify/create; cite file:line premises)

## Approach
- (bounded steps; no product-judgment forks)

## Tests
- (behavior assertions to add or extend)

## Risks
- (auth/RLS/payments/migrations → escalate as risky)
"""


@dataclass
class PlanRound:
    round: int
    plan_md: str
    review_text: str
    decision: str  # PASS | FAIL | NEEDS_HUMAN | APPROVE | REVISE


@dataclass
class PlanOutcome:
    needed: bool
    approved: bool
    plan_md: str | None
    rounds: list[PlanRound] = field(default_factory=list)
    hold_reason: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "needed": self.needed,
            "approved": self.approved,
            "plan_md": self.plan_md,
            "hold_reason": self.hold_reason,
            "rounds": [
                {
                    "round": r.round,
                    "decision": r.decision,
                    "plan_chars": len(r.plan_md or ""),
                    "review_chars": len(r.review_text or ""),
                }
                for r in self.rounds
            ],
        }


def parse_plan_decision(text: str) -> str | None:
    m = VERDICT_RE.search(text or "")
    if m:
        return m.group(1).upper().replace(" ", "_")
    m = SIMPLE_VERDICT_RE.search(text or "")
    if not m:
        return None
    raw = m.group(1).upper()
    return {"APPROVE": "PASS", "REVISE": "FAIL", "NEEDS HUMAN": "NEEDS_HUMAN"}.get(raw, raw)


def plan_has_required_sections(plan_md: str) -> tuple[bool, list[str]]:
    missing = []
    for sec in PLAN_SECTIONS:
        if not re.search(rf"^##\s+{sec}\s*$", plan_md or "", re.M | re.I):
            missing.append(sec)
    return (not missing), missing


def scaffold_plan(ticket_id: str, title: str, body: str = "") -> str:
    base = PLAN_TEMPLATE.format(ticket_id=ticket_id, title=title.strip() or ticket_id)
    if body.strip():
        base += f"\n## Ticket body (context)\n\n{body.strip()[:4000]}\n"
    return base


PlannerFn = Callable[[str], str]  # plan_md in context -> new plan_md
ReviewerFn = Callable[[str], str]  # plan_md -> review text with verdict


def run_plan_loop(
    *,
    ticket_id: str,
    title: str,
    body: str,
    plan_needed: bool,
    max_rounds: int = 2,
    planner: PlannerFn | None = None,
    reviewer: ReviewerFn | None = None,
    seed_plan: str | None = None,
) -> PlanOutcome:
    """Run up to max_rounds of plan/review. Skip entirely when plan_needed is False."""
    if not plan_needed:
        return PlanOutcome(needed=False, approved=True, plan_md=None)

    if planner is None or reviewer is None:
        # Without live model callables the orchestrator must supply them.
        # Dry-run / tests inject fakes; production wires WorkerRuntime CLIs.
        raise ValueError("planner and reviewer callables required when plan_needed")

    # Hard ceiling: never more than 2 plan rounds (WAVE_PLAN_ROUNDS_CAP).
    max_rounds = max(1, min(int(max_rounds), 2))

    plan_md = seed_plan or scaffold_plan(ticket_id, title, body)
    rounds: list[PlanRound] = []

    for i in range(1, max_rounds + 1):
        if i > 1 or seed_plan is None:
            plan_md = planner(plan_md)
        ok_sections, missing = plan_has_required_sections(plan_md)
        review = reviewer(plan_md)
        decision = parse_plan_decision(review) or "FAIL"
        if not ok_sections and decision == "PASS":
            # Fail-closed: a PASS that skipped required sections is a FAIL.
            decision = "FAIL"
            review = (
                review
                + f"\n\nPLAN_REVIEW_RESULT:\n  decision: FAIL\n  summary: missing sections {missing}\n"
            )
        rounds.append(PlanRound(i, plan_md, review, decision))
        if decision == "PASS":
            return PlanOutcome(needed=True, approved=True, plan_md=plan_md, rounds=rounds)
        if decision == "NEEDS_HUMAN":
            return PlanOutcome(
                needed=True,
                approved=False,
                plan_md=plan_md,
                rounds=rounds,
                hold_reason="plan NEEDS_HUMAN",
            )

    return PlanOutcome(
        needed=True,
        approved=False,
        plan_md=plan_md,
        rounds=rounds,
        hold_reason=f"plan revise cap ({max_rounds}) exceeded",
    )


def write_plan_artifacts(run_dir: Path, outcome: PlanOutcome) -> dict[str, str]:
    run_dir.mkdir(parents=True, exist_ok=True)
    paths: dict[str, str] = {}
    if outcome.plan_md:
        p = run_dir / "wave-plan.md"
        p.write_text(outcome.plan_md, encoding="utf-8")
        paths["plan"] = str(p)
    meta = run_dir / "plan-outcome.json"
    meta.write_text(json.dumps(outcome.to_dict(), indent=2) + "\n", encoding="utf-8")
    paths["outcome"] = str(meta)
    for r in outcome.rounds:
        rp = run_dir / f"plan-review-r{r.round}.md"
        rp.write_text(r.review_text, encoding="utf-8")
        paths[f"review_r{r.round}"] = str(rp)
    return paths
