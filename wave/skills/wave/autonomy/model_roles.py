"""Model role assignment for backlog-watch (Mason t27u/t28u).

- Opus implements medium tickets.
- Codex may implement low tickets only; otherwise Codex reviews.
- Opus reviews when Codex implements.
- Grok is challenge-only (and Codex-quota fallback), non-voting on caps.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

Agent = Literal["claude", "codex"]


@dataclass(frozen=True)
class RoleAssignment:
    implementer: Agent
    implementer_model: str | None  # opus / None for codex
    reviewer: Agent
    challenge: str  # "grok"
    reason: str

    def to_dict(self) -> dict:
        return {
            "implementer": self.implementer,
            "implementer_model": self.implementer_model,
            "reviewer": self.reviewer,
            "challenge": self.challenge,
            "reason": self.reason,
        }


def assign_roles(rating: str, *, codex_implement_low: bool = True) -> RoleAssignment:
    r = (rating or "").lower().strip()
    if r == "low" and codex_implement_low:
        return RoleAssignment(
            implementer="codex",
            implementer_model=None,
            reviewer="claude",
            challenge="grok",
            reason="low: Codex implements, Opus reviews, Grok challenges",
        )
    # medium (and low when Codex implement disabled)
    return RoleAssignment(
        implementer="claude",
        implementer_model="opus",
        reviewer="codex",
        challenge="grok",
        reason=f"{r or 'medium'}: Opus implements, Codex reviews, Grok challenges",
    )


def rating_from_tags(tags: list[str] | None) -> str | None:
    for t in tags or []:
        tl = t.lower()
        if tl in {"rating:low", "rating-low", "low"}:
            return "low"
        if tl in {"rating:medium", "rating-medium", "medium"}:
            return "medium"
        if tl in {"rating:risky", "rating-risky", "risky", "risk"}:
            return "risky"
    return None
