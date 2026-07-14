"""
Reads a review_export.py CSV that's had its `decision` column filled in
(and, optionally, ai_suggested_name/ai_suggested_description edited
directly -- this tool applies whatever is in those columns at the time
you run it, so an edit IS how you correct a suggestion before approving
it) and applies the approved changes to the live `landmarks` table.

Per suggested_role, "approve" means:
  - archive_ignore:     lifecycle_state -> 'archived'
  - recovered_landmark: name/description updated from the (possibly
                         edited) ai_suggested_* columns
  - landmark_feature:   NOT applied to the landmark itself -- there's no
                         Landmark/Feature schema yet, so silently
                         archiving or renaming would be presuming a
                         decision that hasn't been made. Instead, the
                         suggested parent is recorded as a private
                         content_note, preserved for whenever that schema
                         exists, and the landmark row is left untouched.

`revised_category` and `parent_landmark_code` are independent of any AI
suggestion (e.g. a manual decision from cluster review on an already-
named record) and are applied/recorded the same way regardless of
whether `decision` or an AI suggestion is present for that row.

"reject" makes no landmark change but is recorded as a content_note, so
there's a record of what was considered and turned down.

Usage:
    python -m osm_importer.apply_enrichment --in reviewed.csv --dry-run
    python -m osm_importer.apply_enrichment --in reviewed.csv
"""

import argparse
import csv

from .supabase_writer import get_client

VALID_CATEGORIES = {
    "park", "trail", "museum", "historic_site", "garden", "overlook",
    "beach", "business", "memorial", "covered_bridge", "other",
}


def add_content_note(client, code_to_id: dict, code: str, note: str, dry_run: bool) -> None:
    landmark_id = code_to_id.get(code)
    if landmark_id is None:
        print(f"  [{code}] WARNING: code not found, skipping note")
        return
    if dry_run:
        print(f"  [{code}] would add content_note: {note}")
        return
    client.table("content_notes").insert(
        {"entity_table": "landmarks", "entity_id": landmark_id, "note": note}
    ).execute()


def apply_row(client, code_to_id: dict, row: dict, dry_run: bool) -> None:
    code = row["code"]
    landmark_id = code_to_id.get(code)
    if landmark_id is None:
        print(f"  [{code}] WARNING: code not found in this Community, skipping")
        return

    decision = (row.get("decision") or "").strip().lower()
    role = (row.get("ai_suggested_role") or "").strip()
    updates: dict = {}

    if decision == "reject":
        add_content_note(
            client, code_to_id, code,
            f"AI suggestion rejected during review: suggested_name={row.get('ai_suggested_name') or '(none)'}, "
            f"suggested_role={role or '(none)'}",
            dry_run,
        )
    elif decision == "approve":
        if role == "archive_ignore":
            updates["lifecycle_state"] = "archived"
        elif role == "recovered_landmark":
            if row.get("ai_suggested_name"):
                updates["name"] = row["ai_suggested_name"]
            if row.get("ai_suggested_description"):
                updates["description"] = row["ai_suggested_description"]
        elif role == "landmark_feature":
            add_content_note(
                client, code_to_id, code,
                f"AI suggests this is a feature of '{row.get('ai_suggested_parent_name') or '(unspecified)'}'. "
                f"Pending Landmark/Feature schema support -- not applied to this record.",
                dry_run,
            )
        elif row.get("ai_suggested_description"):
            # No role (e.g. a manually-reviewed, already-named record) but a
            # description was filled in anyway -- apply it, don't discard it.
            updates["description"] = row["ai_suggested_description"]
    elif decision:
        print(f"  [{code}] WARNING: unrecognized decision '{decision}' (expected 'approve' or 'reject'), skipping")

    # Independent of decision/role: a manual category correction or
    # parent/feature note from cluster review.
    revised_category = (row.get("revised_category") or "").strip()
    if revised_category:
        if revised_category not in VALID_CATEGORIES:
            print(f"  [{code}] WARNING: '{revised_category}' is not a valid category, skipping this field")
        else:
            updates["category"] = revised_category

    parent_code = (row.get("parent_landmark_code") or "").strip()
    if parent_code:
        add_content_note(
            client, code_to_id, code,
            f"Manually marked during review as a feature of landmark {parent_code}. "
            f"Pending Landmark/Feature schema support -- not applied to this record.",
            dry_run,
        )

    if updates:
        if dry_run:
            print(f"  [{code}] would update: {updates}")
        else:
            client.table("landmarks").update(updates).eq("id", landmark_id).execute()
            print(f"  [{code}] updated: {updates}")


def run(in_path: str, dry_run: bool) -> None:
    client = get_client()

    with open(in_path) as f:
        rows = list(csv.DictReader(f))

    codes = [r["code"] for r in rows]
    landmarks = (
        client.table("landmarks").select("id,code").in_("code", codes).execute().data
        if codes
        else []
    )
    code_to_id = {l["code"]: l["id"] for l in landmarks}

    actionable = [r for r in rows if (r.get("decision") or "").strip() or (r.get("revised_category") or "").strip() or (r.get("parent_landmark_code") or "").strip()]
    print(f"{len(rows)} rows read, {len(actionable)} have a decision or manual field set" + (" (DRY RUN -- nothing will be written)" if dry_run else ""))

    for row in actionable:
        apply_row(client, code_to_id, row, dry_run)

    print("Done." if not dry_run else "Dry run complete -- rerun without --dry-run to apply.")


def main():
    parser = argparse.ArgumentParser(description="Apply reviewed decisions from a review_export.py CSV to the live landmarks table.")
    parser.add_argument("--in", dest="in_path", required=True)
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without writing anything.")
    args = parser.parse_args()
    run(args.in_path, args.dry_run)


if __name__ == "__main__":
    main()
