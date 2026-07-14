"""
End-to-end vertical slice: fetch a bounding box from OSM, normalize,
match each candidate to its nearest Community, score confidence, flag
in-batch duplicates, and write a CSV a human can review.

Writing into Supabase is optional and only attempted if SUPABASE_URL and
SUPABASE_SERVICE_ROLE_KEY are both set — otherwise this runs entirely as
a dry run against a local communities JSON file with no network
dependency beyond Overpass itself.

Usage:
    python -m osm_importer.run_import \\
        --min-lat 42.70 --min-lon -71.52 --max-lat 42.82 --max-lon -71.40 \\
        --communities sample_communities.json \\
        --out review.csv \\
        --batch-id osm_nashua_2026_07_14_001 \\
        --write-limit 20
"""

import argparse
import csv
import json
import os
import sys
from datetime import date

from .community_match import CommunityRef, assign_nearest_community
from .dedupe import flag_batch_duplicates
from .fetch_osm import fetch_nodes
from .normalize import normalize_elements
from .report import build_summary
from .scoring import route, score_candidate

CSV_FIELDS = [
    "external_ref",
    "name",
    "category",
    "lat",
    "lon",
    "matched_community_name",
    "distance_km_to_community",
    "confidence_score",
    "routing_decision",
    "possible_duplicate_of",
    "import_batch_id",
    "raw_tags",
]


def load_communities(path: str) -> list[CommunityRef]:
    with open(path) as f:
        rows = json.load(f)
    return [CommunityRef(id=r["id"], name=r["name"], lat=r["lat"], lon=r["lon"]) for r in rows]


def default_batch_id() -> str:
    return f"osm_import_{date.today().isoformat()}"


def run(
    min_lat: float,
    min_lon: float,
    max_lat: float,
    max_lon: float,
    communities_path: str,
    out_path: str,
    batch_id: str,
    write_limit: int | None = None,
) -> list:
    print(f"Fetching OSM nodes for bbox ({min_lat},{min_lon},{max_lat},{max_lon})...", file=sys.stderr)
    elements = fetch_nodes(min_lat, min_lon, max_lat, max_lon)
    print(f"  {len(elements)} tagged nodes returned.", file=sys.stderr)

    candidates = normalize_elements(elements)
    communities = load_communities(communities_path)

    for candidate in candidates:
        assign_nearest_community(candidate, communities)
        candidate.confidence_score = score_candidate(candidate)
        candidate.routing_decision = route(candidate.confidence_score)

    flag_batch_duplicates(candidates)

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for c in candidates:
            writer.writerow(
                {
                    "external_ref": c.external_ref,
                    "name": c.name or "",
                    "category": c.category,
                    "lat": c.lat,
                    "lon": c.lon,
                    "matched_community_name": c.matched_community_name or "UNMATCHED",
                    "distance_km_to_community": c.distance_km_to_community,
                    "confidence_score": c.confidence_score,
                    "routing_decision": c.routing_decision,
                    "possible_duplicate_of": c.possible_duplicate_of or "",
                    "import_batch_id": batch_id,
                    "raw_tags": json.dumps(c.raw_tags, sort_keys=True),
                }
            )

    print(f"Wrote {len(candidates)} candidates to {out_path} (batch_id={batch_id})", file=sys.stderr)

    written = None
    write_errors = 0
    if os.environ.get("SUPABASE_URL") and os.environ.get("SUPABASE_SERVICE_ROLE_KEY"):
        from .supabase_writer import write_candidates

        limit_note = f", write_limit={write_limit}" if write_limit is not None else ""
        print(f"SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY set — writing candidates to Supabase{limit_note}...", file=sys.stderr)
        write_result = write_candidates(candidates, batch_id=batch_id, write_limit=write_limit)
        written = write_result["inserted"]
        write_errors = len(write_result["errors"])
        if write_result["skipped_already_imported"]:
            print(f"  {write_result['skipped_already_imported']} candidate(s) already imported previously, skipped.", file=sys.stderr)
        for err in write_result["errors"]:
            print(f"  WRITE ERROR ({err['external_ref']}, {err['name']!r}): {err['error']}", file=sys.stderr)
    else:
        print("No Supabase credentials in the environment — dry run only, nothing written to a database.", file=sys.stderr)

    summary = build_summary(candidates, batch_id=batch_id, written=written, write_errors=write_errors)
    print("\n" + summary.render() + "\n", file=sys.stderr)

    return candidates


def main():
    parser = argparse.ArgumentParser(description="Import OSM POIs as Shared Skies Landmark candidates.")
    parser.add_argument("--min-lat", type=float, required=True)
    parser.add_argument("--min-lon", type=float, required=True)
    parser.add_argument("--max-lat", type=float, required=True)
    parser.add_argument("--max-lon", type=float, required=True)
    parser.add_argument("--communities", required=True, help="Path to a JSON file of [{id, name, lat, lon}, ...]")
    parser.add_argument("--out", default="review.csv")
    parser.add_argument("--batch-id", default=None, help="Stable identifier stamped into every row (CSV and DB). Defaults to osm_import_<today>.")
    parser.add_argument("--write-limit", type=int, default=None, help="Cap how many candidates (highest confidence first) get written to Supabase. CSV always contains the full batch.")
    args = parser.parse_args()

    batch_id = args.batch_id or default_batch_id()
    run(args.min_lat, args.min_lon, args.max_lat, args.max_lon, args.communities, args.out, batch_id, args.write_limit)


if __name__ == "__main__":
    main()
