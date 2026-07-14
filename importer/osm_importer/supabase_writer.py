"""
Writes reviewed-ready candidates into the real schema (landmarks +
landmark_sources), via the Supabase Python client. Isolated in its own
module and only imported when actually used, so the rest of the pipeline
(fetch/normalize/score/match/dedupe) has zero dependency on a live
Supabase project and can run — and be tested — as a pure offline script.

NOTE: this module has not been exercised against a real Supabase project
(none exists yet for Shared Skies at the time this was written). The CSV
output path in run_import.py is the validated way to inspect a batch
today; treat this module as reviewed-but-unproven until it's run against
a real project once and the results are checked by hand.
"""

import os

from .normalize import Candidate


def get_client():
    from supabase import create_client  # imported lazily; not a hard dependency of the dry-run path

    url = os.environ["SUPABASE_URL"]
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]  # service role: bypasses RLS, admin-only, never ship to a client
    return create_client(url, key)


def write_candidates(candidates: list[Candidate]) -> None:
    """Insert each candidate as a landmarks row (lifecycle_state derived
    from its routing decision, never 'published' — see scoring.route)
    plus a matching landmark_sources provenance row. Candidates with no
    matched_community_id are skipped; a landmark can't exist without a
    community and an unmatched candidate needs a human to pick one."""
    client = get_client()

    lifecycle_by_route = {
        "high_priority_review": "candidate",
        "needs_review": "candidate",
        "stays_rumor": "rumor",
    }

    for candidate in candidates:
        if candidate.matched_community_id is None:
            continue

        landmark_row = {
            "community_id": candidate.matched_community_id,
            "name": candidate.name or "(unnamed)",
            "category": candidate.category,
            "location": f"POINT({candidate.lon} {candidate.lat})",
            "lifecycle_state": lifecycle_by_route.get(candidate.routing_decision, "candidate"),
            "source_confidence": candidate.confidence_score,
            "community_verification_status": "not_required",
        }
        inserted = client.table("landmarks").insert(landmark_row).execute()
        landmark_id = inserted.data[0]["id"]

        client.table("landmark_sources").insert(
            {
                "landmark_id": landmark_id,
                "source_type": "osm_import",
                "external_ref": candidate.external_ref,
                "raw_payload": candidate.raw_tags,
            }
        ).execute()
