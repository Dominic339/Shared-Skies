"""
Harvests candidate images for every landmark in a Community from open,
already-linked sources -- OSM's own `image`/`wikimedia_commons` tags,
Wikidata's linked image (P18), and Wikipedia's page thumbnail. Runs
across ALL landmarks (named and unnamed), not just the ones that went
through AI enrichment -- named records need images just as much as
unnamed ones do.

This is evidence gathering, not approval: every row landed in
landmark_image_candidates says "an external source suggests this image
depicts this Landmark," never "this image is approved for use." Nothing
is downloaded into permanent storage yet -- that's a deliberate later
step, once there's a reason to take on asset management.

Deliberately skips "official website" as a source (the fifth priority
GPT/Dominic discussed) -- determining "reuse rights are clear" for an
arbitrary website isn't something this can safely automate; the four
Wikimedia-family sources below all carry structured, checkable license
metadata, which is why they're first in priority for a reason.

Usage:
    python -m osm_importer.image_harvest --community-id <uuid>
"""

import argparse
import sys
from collections import Counter

from .enrichment import wikimedia
from .supabase_writer import get_client


def harvest_candidates_for_landmark(raw_tags: dict) -> list[dict]:
    candidates = []

    image_tag = raw_tags.get("image")
    if image_tag:
        if image_tag.startswith("http"):
            candidates.append({
                "source_type": "osm_image", "source_url": image_tag, "thumbnail_url": None,
                "source_page_url": None, "attribution_text": None, "license": None,
                "evidence": {"tag": "image", "value": image_tag},
            })
        else:
            filename = image_tag.split(":", 1)[1] if ":" in image_tag else image_tag
            info = wikimedia.fetch_commons_file_info(filename)
            if info:
                candidates.append({
                    "source_type": "osm_image", "source_url": info["url"], "thumbnail_url": None,
                    "source_page_url": info["source_page_url"], "attribution_text": info["attribution_text"],
                    "license": info["license"], "evidence": {"tag": "image", "value": image_tag},
                })

    wc_tag = raw_tags.get("wikimedia_commons")
    if wc_tag:
        filename = None
        if wc_tag.startswith("Category:"):
            filename = wikimedia.fetch_commons_category_first_file(wc_tag.split(":", 1)[1])
        elif wc_tag.startswith("File:"):
            filename = wc_tag.split(":", 1)[1]
        else:
            filename = wc_tag  # ambiguous shorthand -- try as a bare filename
        if filename:
            info = wikimedia.fetch_commons_file_info(filename)
            if info:
                candidates.append({
                    "source_type": "wikimedia_commons", "source_url": info["url"], "thumbnail_url": None,
                    "source_page_url": info["source_page_url"], "attribution_text": info["attribution_text"],
                    "license": info["license"], "evidence": {"tag": "wikimedia_commons", "value": wc_tag},
                })

    qid = raw_tags.get("wikidata")
    if qid:
        entity = wikimedia.fetch_wikidata_entity(qid)
        if entity and entity.get("image_filename"):
            info = wikimedia.fetch_commons_file_info(entity["image_filename"])
            if info:
                candidates.append({
                    "source_type": "wikidata", "source_url": info["url"], "thumbnail_url": None,
                    "source_page_url": info["source_page_url"], "attribution_text": info["attribution_text"],
                    "license": info["license"],
                    "evidence": {"tag": "wikidata", "qid": qid, "filename": entity["image_filename"]},
                })

    wp_tag = raw_tags.get("wikipedia")
    if wp_tag:
        summary = wikimedia.fetch_wikipedia_summary(wp_tag)
        if summary and summary.get("original_image_url"):
            filename = wikimedia.commons_filename_from_url(summary["original_image_url"])
            info = wikimedia.fetch_commons_file_info(filename) if filename else None
            if info:
                candidates.append({
                    "source_type": "wikipedia", "source_url": info["url"],
                    "thumbnail_url": summary.get("thumbnail_url"), "source_page_url": summary.get("url"),
                    "attribution_text": info["attribution_text"], "license": info["license"],
                    "evidence": {"tag": "wikipedia", "value": wp_tag},
                })
            else:
                # Couldn't resolve full Commons license metadata, but the
                # image URL itself is still usable -- keep it rather than
                # discard a real candidate over missing attribution detail.
                candidates.append({
                    "source_type": "wikipedia", "source_url": summary["original_image_url"],
                    "thumbnail_url": summary.get("thumbnail_url"), "source_page_url": summary.get("url"),
                    "attribution_text": None, "license": None,
                    "evidence": {"tag": "wikipedia", "value": wp_tag},
                })

    return candidates


def run(community_id: str) -> None:
    client = get_client()

    landmarks = (
        client.table("landmarks")
        .select("id,code,name,category")
        .eq("community_id", community_id)
        .execute()
        .data
    )
    landmark_ids = [l["id"] for l in landmarks]
    sources = (
        client.table("landmark_sources")
        .select("landmark_id,raw_payload")
        .in_("landmark_id", landmark_ids)
        .execute()
        .data
        if landmark_ids
        else []
    )
    source_by_landmark = {s["landmark_id"]: s for s in sources}

    landmarks_with_candidates = 0
    source_type_counts: Counter = Counter()
    license_present_count = 0
    total_candidates = 0

    for i, landmark in enumerate(landmarks, start=1):
        raw_tags = dict(source_by_landmark.get(landmark["id"], {}).get("raw_payload") or {})
        raw_tags.pop("_import_batch_id", None)

        try:
            candidates = harvest_candidates_for_landmark(raw_tags)
        except Exception as e:
            print(f"[{i}/{len(landmarks)}] {landmark['code']}... ERROR: {e}", file=sys.stderr)
            continue

        if candidates:
            landmarks_with_candidates += 1
            for c in candidates:
                client.table("landmark_image_candidates").insert({
                    "landmark_id": landmark["id"],
                    **c,
                }).execute()
                source_type_counts[c["source_type"]] += 1
                if c["license"]:
                    license_present_count += 1
                total_candidates += 1
            print(f"[{i}/{len(landmarks)}] {landmark['code']}... {len(candidates)} candidate(s)", file=sys.stderr)
        else:
            print(f"[{i}/{len(landmarks)}] {landmark['code']}... none", file=sys.stderr)

    print("", file=sys.stderr)
    print(f"Coverage: {landmarks_with_candidates}/{len(landmarks)} landmarks have at least one image candidate "
          f"({landmarks_with_candidates / len(landmarks) * 100:.0f}%)" if landmarks else "No landmarks found", file=sys.stderr)
    print(f"Total candidates: {total_candidates}", file=sys.stderr)
    print(f"By source type: {dict(source_type_counts)}", file=sys.stderr)
    print(f"Candidates with license info: {license_present_count}/{total_candidates}" if total_candidates else "", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Harvest open-source image candidates for every landmark in a Community.")
    parser.add_argument("--community-id", required=True)
    args = parser.parse_args()
    run(args.community_id)


if __name__ == "__main__":
    main()
