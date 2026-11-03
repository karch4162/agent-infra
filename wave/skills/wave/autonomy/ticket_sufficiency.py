"""Decide whether a ticket already has enough detail to implement without a plan.

Mason (t28u): most tickets already have enough detail; only thin / PLAN_NEEDED
tickets get a plan step.

Enough detail means ALL of:
  - a non-empty body (or description)
  - at least one file:line (or path with extension) citation, OR an explicit
    copyable reference implementation named in the body
  - not tagged plan-needed / PLAN_NEEDED

An acceptance-criterion wording check used to be a fourth rule; it sent most
plain-prose tickets with good citations to the plan step, and the rating plus
the worker's test contract already cover that judgment.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable

# A citation is a path with a directory separator, or a bare filename with a code
# extension. The old "anything.word" form matched e.g., i.e., v2.0 and domains, so
# the plan step almost never fired.
CODE_EXT = (
    "ts|tsx|js|jsx|mjs|cjs|mts|cts|py|sql|sh|bash|ps1|md|json|yml|yaml|toml|css|scss|"
    "html|env|go|rs|rb|java|kt|swift|cs|c|h|cpp|hpp|prisma|graphql|gql|vue|svelte"
)
FILE_LINE_RE = re.compile(
    r"(?P<path>(?:[A-Za-z]:)?(?:[\w.-]+[/\\])+[\w.-]+\.\w{1,10}"
    r"|\b[\w-]+\.(?:" + CODE_EXT + r")\b)(?::(?P<line>\d+))?"
)
REF_IMPL_RE = re.compile(
    r"(?i)\b(copy(?:able)?\s+from|same\s+as|mirror|follow(?:s)?\s+(?:the\s+)?"
    r"pattern\s+in|reference\s+impl(?:ementation)?)\b"
)
PLAN_TAG_NAMES = {"plan-needed", "plan_needed", "planneeded", "PLAN_NEEDED"}


@dataclass(frozen=True)
class SufficiencyResult:
    enough: bool
    plan_needed: bool
    reasons: tuple[str, ...]
    file_hits: tuple[str, ...]

    def to_dict(self) -> dict:
        return {
            "enough": self.enough,
            "plan_needed": self.plan_needed,
            "reasons": list(self.reasons),
            "file_hits": list(self.file_hits),
        }


def _normalize_tags(tags: Iterable[str] | None) -> set[str]:
    return {t.strip() for t in (tags or []) if t and t.strip()}


def assess_ticket(
    *,
    title: str,
    body: str,
    tags: Iterable[str] | None = None,
) -> SufficiencyResult:
    text = f"{title or ''}\n{body or ''}".strip()
    tagset = _normalize_tags(tags)
    reasons: list[str] = []

    if any(t.lower() in {x.lower() for x in PLAN_TAG_NAMES} or t == "PLAN_NEEDED" for t in tagset):
        reasons.append("tagged PLAN_NEEDED")
        return SufficiencyResult(False, True, tuple(reasons), ())

    if len(text) < 80:
        reasons.append("body too short (<80 chars)")

    file_hits = tuple(sorted({m.group("path") for m in FILE_LINE_RE.finditer(text)}))
    has_file = bool(file_hits)
    has_ref = bool(REF_IMPL_RE.search(text))
    if not has_file and not has_ref:
        reasons.append("no file:line citation and no copyable reference")

    plan_needed = bool(reasons)
    return SufficiencyResult(
        enough=not plan_needed,
        plan_needed=plan_needed,
        reasons=tuple(reasons),
        file_hits=file_hits,
    )
