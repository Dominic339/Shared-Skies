"""
Turns raw Overpass elements into the common Candidate shape the rest of
the pipeline (scoring, community matching, dedupe, review output) works
with. Deliberately does NOT synthesize a description, assign a postcard,
suggest souvenirs, or infer accessibility — those are later enrichment
stages once the core ingestion path is proven, not part of this pass.
"""

from dataclasses import dataclass, field

from .tag_rules import classify


@dataclass
class Candidate:
    external_ref: str          # e.g. "osm:node:357737611"
    name: str | None
    category: str
    lat: float
    lon: float
    raw_tags: dict = field(default_factory=dict)

    # Filled in by later pipeline stages, not by normalize().
    matched_community_id: str | None = None
    matched_community_name: str | None = None
    distance_km_to_community: float | None = None
    confidence_score: float | None = None
    routing_decision: str | None = None
    possible_duplicate_of: str | None = None


def normalize_element(element: dict) -> Candidate:
    tags = element.get("tags", {})
    return Candidate(
        external_ref=f"osm:{element['type']}:{element['id']}",
        name=tags.get("name"),
        category=classify(tags),
        lat=element["lat"],
        lon=element["lon"],
        raw_tags=tags,
    )


def normalize_elements(elements: list[dict]) -> list[Candidate]:
    return [normalize_element(el) for el in elements]
