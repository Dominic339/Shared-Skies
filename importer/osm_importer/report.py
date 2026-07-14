"""
A human-readable summary for a single import run. Deliberately not a
database table — this is a run report, not persistent state, and belongs
in the importer's output (stdout, or later a log file) rather than
another row to maintain.
"""

from dataclasses import dataclass

from .normalize import Candidate

LIFECYCLE_BY_ROUTE = {
    "high_priority_review": "candidate",
    "needs_review": "candidate",
    "stays_rumor": "rumor",
}


@dataclass
class ImportSummary:
    batch_id: str
    total_fetched: int
    skipped_unmatched: int
    duplicates_flagged: int
    candidate_count: int
    rumor_count: int
    average_confidence: float
    distinct_communities: int
    written: int | None  # None in dry-run mode (no Supabase write attempted)
    write_errors: int

    def render(self) -> str:
        lines = [
            f"{self.batch_id}",
            "",
            f"  Fetched            {self.total_fetched}",
            f"  Skipped (unmatched) {self.skipped_unmatched}",
            f"  Duplicates flagged  {self.duplicates_flagged}",
            f"  -> Candidate        {self.candidate_count}",
            f"  -> Rumor            {self.rumor_count}",
            f"  Average confidence  {self.average_confidence:.1f}",
            f"  Communities touched {self.distinct_communities}",
        ]
        if self.written is not None:
            lines.append(f"  Written to Supabase {self.written}")
            lines.append(f"  Write errors        {self.write_errors}")
        else:
            lines.append("  Written to Supabase (dry run -- nothing written)")
        return "\n".join(lines)


def build_summary(
    candidates: list[Candidate], batch_id: str, written: int | None = None, write_errors: int = 0
) -> ImportSummary:
    scored = [c for c in candidates if c.confidence_score is not None]
    avg_confidence = sum(c.confidence_score for c in scored) / len(scored) if scored else 0.0

    return ImportSummary(
        batch_id=batch_id,
        total_fetched=len(candidates),
        skipped_unmatched=sum(1 for c in candidates if c.matched_community_id is None),
        duplicates_flagged=sum(1 for c in candidates if c.possible_duplicate_of is not None),
        candidate_count=sum(1 for c in candidates if LIFECYCLE_BY_ROUTE.get(c.routing_decision) == "candidate"),
        rumor_count=sum(1 for c in candidates if LIFECYCLE_BY_ROUTE.get(c.routing_decision) == "rumor"),
        average_confidence=avg_confidence,
        distinct_communities=len({c.matched_community_id for c in candidates if c.matched_community_id}),
        written=written,
        write_errors=write_errors,
    )
