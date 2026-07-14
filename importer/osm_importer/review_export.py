"""
A practical, spreadsheet-based review workflow for everything imported
for one Community -- no custom moderation UI needed yet. Produces one CSV
row per landmark with cluster membership AND the latest AI enrichment
suggestion (if any) already joined in, plus a blank `decision` column.
Once reviewing through this spreadsheet becomes genuinely painful, this
same column list is the specification for the custom moderation
interface.

Fill in `decision` with "approve" or "reject" (leave blank to skip) and
optionally edit `ai_suggested_name` / `ai_suggested_description` directly
-- apply_enrichment.py applies whatever is in those columns at the time
you run it, so editing them IS how you correct an AI suggestion before
approving it; there's no separate "edit" mode to learn.

Usage:
    python -m osm_importer.review_export --community-id <uuid> --out nashua_review.csv
"""

import argparse
import csv
import json

from .clusters import find_clusters, load_landmarks_with_coords
from .supabase_writer import get_client

FIELDS = [
    "code",
    "name",
    "category",
    "import_confidence",
    "lifecycle_state",
    "lat",
    "lon",
    "external_ref",
    "source_type",
    "raw_tags",
    "nearby_candidate_count",
    "cluster_id",
    # AI enrichment suggestion (blank if this landmark wasn't enriched, or
    # wasn't unnamed to begin with -- enrichment only runs on unnamed records):
    "ai_suggested_name",
    "ai_suggested_role",
    "ai_suggested_parent_name",
    "ai_suggested_description",
    "ai_confidence",
    "ai_citations",
    # Blank, for a human to fill in:
    "decision",
    "revised_category",
    "parent_landmark_code",
    "notes",
]


def latest_successful_suggestions(client, landmark_ids: list[str]) -> dict[str, dict]:
    if not landmark_ids:
        return {}
    runs = (
        client.table("enrichment_runs")
        .select("entity_id,response,confidence,created_at")
        .in_("entity_id", landmark_ids)
        .not_.is_("response", "null")
        .order("created_at")
        .execute()
        .data
    )
    latest: dict[str, dict] = {}
    for run in runs:
        latest[run["entity_id"]] = run  # order() means later overwrites earlier
    return latest


def build_rows(community_id: str, cluster_radius_m: float = 40.0) -> list[dict]:
    client = get_client()

    landmarks = load_landmarks_with_coords(client, community_id)
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
    source_by_landmark = {s["landmark_id"]: s for s in sources}
    suggestions_by_landmark = latest_successful_suggestions(client, landmark_ids)

    clusters = find_clusters(landmarks, cluster_radius_m)
    cluster_id_by_landmark_id: dict[str, int] = {}
    nearby_count_by_landmark_id: dict[str, int] = {}
    for idx, cluster in enumerate(clusters, start=1):
        for member in cluster:
            cluster_id_by_landmark_id[member["id"]] = idx
            nearby_count_by_landmark_id[member["id"]] = len(cluster) - 1

    rows = []
    for l in landmarks:
        source = source_by_landmark.get(l["id"], {})
        raw_payload = dict(source.get("raw_payload") or {})
        raw_payload.pop("_import_batch_id", None)  # noise for a content reviewer, already in landmark_sources if needed

        suggestion_run = suggestions_by_landmark.get(l["id"])
        suggestion = suggestion_run["response"] if suggestion_run else {}

        rows.append(
            {
                "code": l["code"],
                "name": l["name"],
                "category": l["category"],
                "import_confidence": l["source_confidence"],
                "lifecycle_state": l["lifecycle_state"],
                "lat": l["lat"],
                "lon": l["lon"],
                "external_ref": source.get("external_ref", ""),
                "source_type": source.get("source_type", ""),
                "raw_tags": json.dumps(raw_payload, sort_keys=True),
                "nearby_candidate_count": nearby_count_by_landmark_id.get(l["id"], 0),
                "cluster_id": cluster_id_by_landmark_id.get(l["id"], ""),
                "ai_suggested_name": suggestion.get("suggested_name") or "",
                "ai_suggested_role": suggestion.get("suggested_role") or "",
                "ai_suggested_parent_name": suggestion.get("suggested_parent_name") or "",
                "ai_suggested_description": suggestion.get("description") or "",
                "ai_confidence": suggestion.get("confidence", ""),
                "ai_citations": "; ".join(suggestion.get("citations", [])),
                "decision": "",
                "revised_category": "",
                "parent_landmark_code": "",
                "notes": "",
            }
        )

    rows.sort(key=lambda r: (r["cluster_id"] == "", r["cluster_id"], -r["import_confidence"]))
    return rows


def main():
    parser = argparse.ArgumentParser(description="Export a spreadsheet-review CSV for one Community.")
    parser.add_argument("--community-id", required=True)
    parser.add_argument("--out", default="review.csv")
    parser.add_argument("--cluster-radius-m", type=float, default=40.0)
    args = parser.parse_args()

    rows = build_rows(args.community_id, args.cluster_radius_m)
    with open(args.out, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {len(rows)} rows to {args.out}")


if __name__ == "__main__":
    main()
