"""
A practical, spreadsheet-based review workflow for everything imported
for one Community -- no custom moderation UI needed yet. Produces one CSV
row per landmark with cluster membership already computed, plus blank
columns for a human to fill in. Once reviewing through this spreadsheet
becomes genuinely painful, this same column list is the specification
for the custom moderation interface.

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
    "confidence",
    "lifecycle_state",
    "lat",
    "lon",
    "external_ref",
    "source_type",
    "raw_tags",
    "nearby_candidate_count",
    "cluster_id",
    # Blank, for a human to fill in:
    "decision",
    "revised_name",
    "revised_category",
    "parent_landmark_code",
    "notes",
]


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
        rows.append(
            {
                "code": l["code"],
                "name": l["name"],
                "category": l["category"],
                "confidence": l["source_confidence"],
                "lifecycle_state": l["lifecycle_state"],
                "lat": l["lat"],
                "lon": l["lon"],
                "external_ref": source.get("external_ref", ""),
                "source_type": source.get("source_type", ""),
                "raw_tags": json.dumps(raw_payload, sort_keys=True),
                "nearby_candidate_count": nearby_count_by_landmark_id.get(l["id"], 0),
                "cluster_id": cluster_id_by_landmark_id.get(l["id"], ""),
                "decision": "",
                "revised_name": "",
                "revised_category": "",
                "parent_landmark_code": "",
                "notes": "",
            }
        )

    rows.sort(key=lambda r: (r["cluster_id"] == "", r["cluster_id"], -r["confidence"]))
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
