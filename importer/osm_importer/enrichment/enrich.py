"""
Evidence-gathering + AI-classification pass for unnamed imported
landmarks. Never touches the live `landmarks` table -- writes a CSV of
suggestions for human review, same spirit as review_export.py.

Resumable by construction, not by a separate tracked state table: before
gathering evidence, check whether a prior enrichment_runs row for this
entity already has evidence -- reuse it instead of re-hitting Overpass/
Wikidata/Wikipedia. Before classifying, check whether a prior row already
has a successful response -- skip the AI call entirely and reuse it. This
means quota exhaustion (Overpass rate limits, Gemini's daily free-tier
cap) is a normal pause, not lost work: run the same command again later
and only the genuinely unfinished records do anything.

Every "needs evidence / has evidence, needs AI / AI complete, needs
review / published" state is derived from enrichment_runs + landmarks at
query time, not stored redundantly -- see metrics.py, which reports
exactly this breakdown.

For each unnamed record, gathers:
  - its own raw OSM tags (already imported, from landmark_sources)
  - a direct Wikidata/Wikipedia pull, if the object already carries those
    tags (a lookup, not a guess)
  - nearby named OSM objects within radius_m (context: "what park/street/
    building is this thing actually part of?")

Then asks the configured provider to classify the record as one of:
  - recovered_landmark  -- evidence clearly identifies a real destination
  - landmark_feature    -- belongs under a larger parent place
  - archive_ignore      -- valid OSM data, not meaningful Shared Skies content

The model is explicitly instructed to summarize only the evidence given
and say so when evidence is insufficient, never invent history. Every
result is marked for human review regardless of confidence -- this pass
produces suggestions, not publications.

Usage:
    python -m osm_importer.enrichment.enrich --community-id <uuid> --out enrichment_review.csv --limit 10
"""

import argparse
import csv
import json
import sys
import time

from ..community_match import haversine_km
from ..fetch_osm import fetch_nearby_named
from ..supabase_writer import get_client
from . import wikimedia
from .persistence import record_enrichment_run
from .providers.base import EnrichmentProvider
from .providers.gemini import GeminiProvider

FIELDS = [
    "code",
    "external_ref",
    "category",
    "lat",
    "lon",
    "own_raw_tags",
    "wikidata_hit",
    "wikipedia_hit",
    "nearby_named",
    "suggested_name",
    "suggested_role",
    "suggested_parent_name",
    "description",
    "confidence",
    "citations",
    "human_review_required",
    "reasoning",
]

PROMPT_TEMPLATE = """You are helping classify an unnamed real-world map object imported from \
OpenStreetMap for a game called Shared Skies, which turns real places into "Landmarks" players \
can visit.

You must base your answer ONLY on the evidence provided below. Do not invent history, names, or \
facts that are not directly supported by this evidence. If the evidence is insufficient to \
determine what this object is, say so honestly rather than guessing.

EVIDENCE
--------
Raw OSM tags on the object itself:
{raw_tags}

Direct Wikidata lookup (if the object had a wikidata tag):
{wikidata}

Direct Wikipedia summary (if the object had a wikipedia tag):
{wikipedia}

Named OSM objects within {radius_m}m of this object:
{nearby}

TASK
----
Classify this object as exactly one of:
  - "recovered_landmark": the evidence clearly identifies this as a real, nameable, standalone \
destination worth its own map pin.
  - "landmark_feature": the evidence suggests this is a real but minor component that belongs \
under a larger nearby destination (e.g. an information board inside a named park, one plaque \
among several at one memorial).
  - "archive_ignore": this is valid OSM mapping data but not meaningful standalone content for \
a game about visiting places (e.g. an unlabeled utility node, insufficient evidence to say \
anything useful).

Respond with ONLY a JSON object with these exact keys:
{{
  "suggested_name": string or null,
  "suggested_role": "recovered_landmark" | "landmark_feature" | "archive_ignore",
  "suggested_parent_name": string or null (only if suggested_role is landmark_feature, must be \
one of the nearby named objects listed above),
  "description": string or null (one or two factual sentences, ONLY from the evidence above, or \
null if there isn't enough to say anything factual),
  "confidence": number 0-100,
  "citations": array of strings, each naming which piece of evidence above supports your answer,
  "reasoning": short string explaining your classification
}}
"""


def gather_evidence(landmark: dict, source: dict, radius_m: float) -> dict:
    raw_tags = dict(source.get("raw_payload") or {})
    raw_tags.pop("_import_batch_id", None)

    wikidata = None
    if raw_tags.get("wikidata"):
        wikidata = wikimedia.fetch_wikidata_entity(raw_tags["wikidata"])

    wikipedia = None
    if raw_tags.get("wikipedia"):
        wikipedia = wikimedia.fetch_wikipedia_summary(raw_tags["wikipedia"])

    nearby_elements = fetch_nearby_named(landmark["lat"], landmark["lon"], radius_m=radius_m)
    nearby = []
    for el in nearby_elements:
        distance_m = haversine_km(landmark["lat"], landmark["lon"], el["lat"], el["lon"]) * 1000
        nearby.append({"name": el["tags"]["name"], "distance_m": round(distance_m, 1), "tags": el["tags"]})
    nearby.sort(key=lambda n: n["distance_m"])

    return {"raw_tags": raw_tags, "wikidata": wikidata, "wikipedia": wikipedia, "nearby": nearby}


def build_prompt(evidence: dict, radius_m: float) -> str:
    return PROMPT_TEMPLATE.format(
        raw_tags=json.dumps(evidence["raw_tags"], indent=2) or "(none)",
        wikidata=json.dumps(evidence["wikidata"]) if evidence["wikidata"] else "(none -- no wikidata tag, or lookup failed)",
        wikipedia=json.dumps(evidence["wikipedia"]) if evidence["wikipedia"] else "(none -- no wikipedia tag, or lookup failed)",
        nearby=json.dumps(evidence["nearby"][:10], indent=2) if evidence["nearby"] else "(none found)",
        radius_m=radius_m,
    )


def get_cached_evidence(client, entity_id: str) -> dict | None:
    """Most recent evidence blob already stored for this entity, if any --
    reused instead of re-hitting Overpass/Wikidata/Wikipedia. This is the
    fix for today's actual waste: evidence gathering used to happen fresh
    on every attempt, even for records that had already succeeded at this
    exact step before and only failed later, at classification."""
    rows = (
        client.table("enrichment_runs")
        .select("evidence")
        .eq("entity_id", entity_id)
        .not_.is_("evidence", "null")
        .order("created_at", desc=True)
        .limit(1)
        .execute()
        .data
    )
    return rows[0]["evidence"] if rows else None


def get_successful_run(client, entity_id: str) -> dict | None:
    """Most recent successful classification for this entity, if any --
    skip the AI call entirely and reuse it rather than paying for (or
    burning quota on) a repeat classification of something already
    answered."""
    rows = (
        client.table("enrichment_runs")
        .select("evidence,response")
        .eq("entity_id", entity_id)
        .not_.is_("response", "null")
        .order("created_at", desc=True)
        .limit(1)
        .execute()
        .data
    )
    return rows[0] if rows else None


def to_csv_row(landmark: dict, source: dict, evidence: dict, suggestion: dict) -> dict:
    return {
        "code": landmark["code"],
        "external_ref": source.get("external_ref", ""),
        "category": landmark["category"],
        "lat": landmark["lat"],
        "lon": landmark["lon"],
        "own_raw_tags": json.dumps(evidence["raw_tags"], sort_keys=True),
        "wikidata_hit": json.dumps(evidence["wikidata"]) if evidence["wikidata"] else "",
        "wikipedia_hit": json.dumps(evidence["wikipedia"]) if evidence["wikipedia"] else "",
        "nearby_named": "; ".join(f"{n['name']} ({n['distance_m']}m)" for n in evidence["nearby"][:5]),
        "suggested_name": suggestion.get("suggested_name") or "",
        "suggested_role": suggestion.get("suggested_role", ""),
        "suggested_parent_name": suggestion.get("suggested_parent_name") or "",
        "description": suggestion.get("description") or "",
        "confidence": suggestion.get("confidence", ""),
        "citations": "; ".join(suggestion.get("citations", [])),
        "human_review_required": True,  # always -- this pass produces suggestions, not publications
        "reasoning": suggestion.get("reasoning", ""),
    }


def enrich_one(client, landmark: dict, source: dict, radius_m: float, provider: EnrichmentProvider) -> tuple[dict, bool]:
    """Returns (csv_row, made_network_call) -- callers use the second value
    to skip pacing delays after a pure cache-hit, which made zero requests
    and has nothing to be gentle about."""
    already_done = get_successful_run(client, landmark["id"])
    if already_done is not None:
        return to_csv_row(landmark, source, already_done["evidence"], already_done["response"]), False

    evidence = get_cached_evidence(client, landmark["id"])
    if evidence is None:
        evidence = gather_evidence(landmark, source, radius_m)
        prompt = build_prompt(evidence, radius_m)
        # Persist evidence immediately, independent of whether
        # classification below succeeds -- if it doesn't, or the process
        # dies, or quota runs out right after this, the evidence is
        # already safe and a future run skips straight to classification.
        record_enrichment_run(
            client, landmark["id"], provider.name, "evidence_only",
            prompt, evidence, response=None, confidence=None, error=None,
        )
    else:
        prompt = build_prompt(evidence, radius_m)

    start = time.monotonic()
    try:
        suggestion, resolved_model, usage = provider.classify(prompt)
    except Exception as e:
        duration_ms = round((time.monotonic() - start) * 1000)
        record_enrichment_run(
            client, landmark["id"], provider.name, getattr(provider, "MODEL_ALIAS", provider.name),
            prompt, evidence, response=None, confidence=None, error=str(e), duration_ms=duration_ms,
        )
        raise
    duration_ms = round((time.monotonic() - start) * 1000)

    record_enrichment_run(
        client, landmark["id"], provider.name, resolved_model,
        prompt, evidence, response=suggestion, confidence=suggestion.get("confidence"), duration_ms=duration_ms,
        input_tokens=usage.input_tokens, output_tokens=usage.output_tokens, thinking_tokens=usage.thinking_tokens,
    )

    return to_csv_row(landmark, source, evidence, suggestion), True


def run(community_id: str, out_path: str, limit: int | None, radius_m: float, provider: EnrichmentProvider | None = None) -> None:
    client = get_client()
    provider = provider or GeminiProvider()

    from ..clusters import decode_point

    landmarks = (
        client.table("landmarks")
        .select("id,code,name,category,location")
        .eq("community_id", community_id)
        .eq("name", "(unnamed)")
        .execute()
        .data
    )
    if limit is not None:
        landmarks = landmarks[:limit]

    for l in landmarks:
        lat, lon = decode_point(l["location"])
        l["lat"], l["lon"] = lat, lon

    landmark_ids = [l["id"] for l in landmarks]
    sources_by_landmark = {}
    if landmark_ids:
        sources = (
            client.table("landmark_sources")
            .select("landmark_id,external_ref,raw_payload")
            .in_("landmark_id", landmark_ids)
            .execute()
            .data
        )
        sources_by_landmark = {s["landmark_id"]: s for s in sources}

    rows = []
    skipped_already_resolved = 0
    for i, landmark in enumerate(landmarks, start=1):
        source = sources_by_landmark.get(landmark["id"], {})
        try:
            row, made_network_call = enrich_one(client, landmark, source, radius_m, provider)
            rows.append(row)
        except Exception as e:
            print(f"[{i}/{len(landmarks)}] {landmark['code']}... ERROR: {e}", file=sys.stderr)
            rows.append(
                {field: "" for field in FIELDS}
                | {"code": landmark["code"], "external_ref": source.get("external_ref", ""), "reasoning": f"ERROR: {e}"}
            )
            time.sleep(4)  # a real attempt was made and failed -- still worth pacing before the next one
            continue

        if made_network_call:
            print(f"[{i}/{len(landmarks)}] {landmark['code']}... done", file=sys.stderr)
            time.sleep(4)  # gentle pacing -- a fresh record hits Overpass (shared, rate-limited) once and the provider once
        else:
            skipped_already_resolved += 1
            print(f"[{i}/{len(landmarks)}] {landmark['code']}... already resolved, reused", file=sys.stderr)

    if skipped_already_resolved:
        print(f"{skipped_already_resolved} record(s) reused a prior successful classification -- no network calls made for them.", file=sys.stderr)

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {len(rows)} enrichment suggestions to {out_path}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Evidence + AI classification pass for unnamed landmarks.")
    parser.add_argument("--community-id", required=True)
    parser.add_argument("--out", default="enrichment_review.csv")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--radius-m", type=float, default=150.0)
    args = parser.parse_args()
    run(args.community_id, args.out, args.limit, args.radius_m)


if __name__ == "__main__":
    main()
