"""
Aggregate metrics over everything enriched for one Community -- built on
data enrichment_runs and landmarks already capture, not a new subsystem.
Deliberately not a "dashboard": with one Community imported so far, a
trend needs more than one data point to mean anything. This just answers
"where do things stand right now."

For any landmark with multiple enrichment_runs (e.g. after a quota-
blocked retry), the most recent *successful* run (response is not null)
is used to represent its current classification; if only failed runs
exist, it counts as still needing review.

Usage:
    python -m osm_importer.enrichment.metrics --community-id <uuid>
"""

import argparse
from collections import Counter

from ..supabase_writer import get_client


def build_metrics(community_id: str) -> str:
    client = get_client()

    landmarks = (
        client.table("landmarks")
        .select("id,name")
        .eq("community_id", community_id)
        .execute()
        .data
    )
    landmark_ids = [l["id"] for l in landmarks]
    named_count = sum(1 for l in landmarks if l["name"] != "(unnamed)")
    unnamed_count = len(landmarks) - named_count

    runs = (
        client.table("enrichment_runs")
        .select("entity_id,response,confidence,duration_ms,evidence,created_at")
        .in_("entity_id", landmark_ids)
        .order("created_at")
        .execute()
        .data
        if landmark_ids
        else []
    )

    latest_successful_by_entity: dict[str, dict] = {}
    attempted_entity_ids: set[str] = set()
    for run in runs:
        attempted_entity_ids.add(run["entity_id"])
        if run["response"] is not None:
            latest_successful_by_entity[run["entity_id"]] = run  # order() means later overwrites earlier

    resolved = list(latest_successful_by_entity.values())
    role_counts = Counter(r["response"].get("suggested_role", "(missing)") for r in resolved)
    still_needs_review = len(attempted_entity_ids) - len(resolved)
    never_attempted = unnamed_count - len(attempted_entity_ids)

    confidences = [r["confidence"] for r in resolved if r["confidence"] is not None]
    avg_confidence = sum(confidences) / len(confidences) if confidences else None

    durations = [r["duration_ms"] for r in runs if r["duration_ms"] is not None]
    avg_duration_ms = sum(durations) / len(durations) if durations else None

    wikipedia_hits = sum(1 for r in resolved if r["evidence"].get("wikipedia"))
    wikidata_hits = sum(1 for r in resolved if r["evidence"].get("wikidata"))

    lines = [
        f"Enrichment metrics for community_id={community_id}",
        "",
        f"Total landmarks:      {len(landmarks)}",
        f"  Named:              {named_count}",
        f"  Unnamed:            {unnamed_count}",
        "",
        f"Enrichment attempted: {len(attempted_entity_ids)} of {unnamed_count} unnamed",
        f"  Resolved:           {len(resolved)}",
        f"  Still needs review (attempted, no success yet): {still_needs_review}",
        f"  Not yet attempted:  {never_attempted}",
        "",
        "Resolved role breakdown:",
        *(f"  {role:20s} {count}" for role, count in role_counts.most_common()),
        "",
        f"Average confidence (resolved): {avg_confidence:.1f}" if avg_confidence is not None else "Average confidence: n/a",
        f"Average call duration: {avg_duration_ms:.0f}ms" if avg_duration_ms is not None else "Average call duration: n/a",
        f"Wikipedia hit rate (resolved): {wikipedia_hits}/{len(resolved)}" if resolved else "Wikipedia hit rate: n/a",
        f"Wikidata hit rate (resolved):  {wikidata_hits}/{len(resolved)}" if resolved else "Wikidata hit rate: n/a",
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Aggregate enrichment metrics for one Community.")
    parser.add_argument("--community-id", required=True)
    args = parser.parse_args()
    print(build_metrics(args.community_id))


if __name__ == "__main__":
    main()
