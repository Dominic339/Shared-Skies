"""
Writes reviewed-ready candidates into the real schema (landmarks +
landmark_sources, plus a submission_ticket/duplicate_candidates pair for
anything the dedupe step flagged), via the Supabase Python client.
Isolated in its own module and only imported when actually used, so the
rest of the pipeline (fetch/normalize/score/match/dedupe) has zero
dependency on a live Supabase project and can run — and be tested — as a
pure offline script.
"""

import os

from .normalize import Candidate


def get_client():
    from supabase import create_client  # imported lazily; not a hard dependency of the dry-run path

    url = os.environ["SUPABASE_URL"]
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]  # service role: bypasses RLS, admin-only, never ship to a client
    return create_client(url, key)


LIFECYCLE_BY_ROUTE = {
    "high_priority_review": "candidate",
    "needs_review": "candidate",
    "stays_rumor": "rumor",
}


def write_candidates(candidates: list[Candidate], batch_id: str, write_limit: int | None = None) -> dict:
    """Insert candidates as landmarks rows (lifecycle_state derived from
    routing decision, never 'published' — see scoring.route) plus a
    matching landmark_sources provenance row. Candidates with no
    matched_community_id are skipped; a landmark can't exist without a
    community and an unmatched candidate needs a human to pick one.

    batch_id is stamped into every landmark_sources.raw_payload (under
    "_import_batch_id") rather than as a new column, so a faulty run can
    still be found and cleaned up without a schema change:
        delete from landmark_sources where raw_payload->>'_import_batch_id' = '...';

    write_limit, if given, caps how many candidates actually get written
    (highest confidence first) — for a controlled first test batch, not a
    change to which candidates exist in the CSV review output.

    Candidates flagged as a likely duplicate by dedupe.py are still
    inserted as their own landmark row (a human needs something to look
    at to decide whether to merge), but also get a submission_tickets +
    duplicate_candidates pair pointing at the earlier candidate they
    might duplicate, so that flag isn't silently dropped on the floor.
    """
    client = get_client()

    ordered = sorted(candidates, key=lambda c: c.confidence_score or 0, reverse=True)
    to_write = ordered[:write_limit] if write_limit is not None else ordered

    external_ref_to_landmark_id: dict[str, str] = {}
    inserted_count = 0
    duplicate_tickets_count = 0
    skipped_unmatched = 0

    for candidate in to_write:
        if candidate.matched_community_id is None:
            skipped_unmatched += 1
            continue

        landmark_row = {
            "community_id": candidate.matched_community_id,
            "name": candidate.name or "(unnamed)",
            "category": candidate.category,
            "location": f"POINT({candidate.lon} {candidate.lat})",
            "lifecycle_state": LIFECYCLE_BY_ROUTE.get(candidate.routing_decision, "candidate"),
            "source_confidence": candidate.confidence_score,
            "community_verification_status": "not_required",
        }
        inserted = client.table("landmarks").insert(landmark_row).execute()
        landmark_id = inserted.data[0]["id"]
        external_ref_to_landmark_id[candidate.external_ref] = landmark_id
        inserted_count += 1

        client.table("landmark_sources").insert(
            {
                "landmark_id": landmark_id,
                "source_type": "osm_import",
                "external_ref": candidate.external_ref,
                "raw_payload": {"_import_batch_id": batch_id, **candidate.raw_tags},
            }
        ).execute()

        if candidate.possible_duplicate_of is not None:
            original_landmark_id = external_ref_to_landmark_id.get(candidate.possible_duplicate_of)
            if original_landmark_id is not None:
                ticket = client.table("submission_tickets").insert(
                    {
                        "ticket_type": "duplicate_flag",
                        "subject_table": "landmarks",
                        "subject_id": landmark_id,
                        "status": "open",
                        "resolution_notes": f"Importer batch {batch_id}: possible duplicate of "
                        f"{candidate.possible_duplicate_of}, flagged by name/distance heuristic.",
                    }
                ).execute()
                client.table("duplicate_candidates").insert(
                    {
                        "ticket_id": ticket.data[0]["id"],
                        "candidate_landmark_id": original_landmark_id,
                    }
                ).execute()
                duplicate_tickets_count += 1

    return {
        "inserted": inserted_count,
        "duplicate_tickets": duplicate_tickets_count,
        "skipped_unmatched": skipped_unmatched,
        "batch_id": batch_id,
    }
