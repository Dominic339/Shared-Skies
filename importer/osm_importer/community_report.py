"""
A combined report over everything currently in the live database for one
Community — not scoped to a single import run. Distinct from report.py
(which summarizes one run's candidates in memory): this queries
landmarks + landmark_sources directly, so it reflects the accumulated
result of every batch that's ever touched this Community.

"Skipped (already imported)" and "write errors" are run-time events that,
by definition, never produced a row — they aren't queryable from the
database after the fact. Those numbers come from each run's own printed
summary (report.py), not from this report. This module says so rather
than silently omitting them.

Usage:
    python -m osm_importer.community_report --community-id <uuid>
"""

import argparse
import json
from collections import Counter

from .supabase_writer import get_client

CONFIDENCE_BUCKETS = [
    (95, 100, "95-100 (would auto-publish if that policy were ever enabled)"),
    (80, 95, "80-95 (needs_review)"),
    (0, 80, "0-80 (stays_rumor)"),
]


def bucket_for(score: float) -> str:
    for low, high, label in CONFIDENCE_BUCKETS:
        if low <= score <= high:
            return label
    return "unknown"


def build_report(community_id: str) -> str:
    client = get_client()

    landmarks = (
        client.table("landmarks")
        .select("id,code,name,category,lifecycle_state,source_confidence,description")
        .eq("community_id", community_id)
        .execute()
        .data
    )
    landmark_ids = [l["id"] for l in landmarks]

    sources = (
        client.table("landmark_sources")
        .select("landmark_id,source_type,external_ref,raw_payload")
        .in_("landmark_id", landmark_ids)
        .execute()
        .data
        if landmark_ids
        else []
    )

    duplicate_tickets = (
        client.table("submission_tickets")
        .select("subject_id")
        .eq("ticket_type", "duplicate_flag")
        .in_("subject_id", landmark_ids)
        .execute()
        .data
        if landmark_ids
        else []
    )

    lifecycle_counts = Counter(l["lifecycle_state"] for l in landmarks)
    category_counts = Counter(l["category"] for l in landmarks)
    confidence_counts = Counter(bucket_for(l["source_confidence"]) for l in landmarks)
    missing_name_count = sum(1 for l in landmarks if l["name"] == "(unnamed)")
    missing_description_count = sum(1 for l in landmarks if not l["description"])
    source_type_counts = Counter(s["source_type"] for s in sources)
    batch_id_counts = Counter(
        s["raw_payload"].get("_import_batch_id", "(no batch id)") for s in sources
    )

    lines = [
        f"Combined report for community_id={community_id}",
        "",
        f"Total unique landmarks: {len(landmarks)}",
        "",
        "By lifecycle state:",
        *(f"  {state:12s} {count}" for state, count in lifecycle_counts.most_common()),
        "",
        "By category:",
        *(f"  {cat:15s} {count}" for cat, count in category_counts.most_common()),
        "",
        "By confidence range:",
        *(f"  {label:55s} {count}" for label, count in confidence_counts.most_common()),
        "",
        f"Flagged as possible duplicates (submission_tickets): {len(duplicate_tickets)}",
        f"Missing name (stored as '(unnamed)'): {missing_name_count}",
        f"Missing description: {missing_description_count} "
        f"(expected -- descriptions are intentionally not generated in this pass)",
        "",
        "By source type:",
        *(f"  {st:15s} {count}" for st, count in source_type_counts.most_common()),
        "",
        "By import batch id:",
        *(f"  {bid:35s} {count}" for bid, count in batch_id_counts.most_common()),
        "",
        "Not shown here (these never produce a row, so they aren't queryable "
        "from the database -- see each run's own printed summary instead):",
        "  - candidates skipped for already having been imported",
        "  - candidates skipped for not matching any community",
        "  - candidates that failed to write",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Combined report over everything imported for one Community.")
    parser.add_argument("--community-id", required=True)
    args = parser.parse_args()
    print(build_report(args.community_id))


if __name__ == "__main__":
    main()
