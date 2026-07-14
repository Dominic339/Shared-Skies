"""
The single source of truth mapping OpenStreetMap tags to Shared Skies
Landmark categories (must stay in sync with the `landmarks.category` check
constraint in supabase/migrations/20260714000000_initial_schema.sql).

Used by both fetch_osm.py (to build the Overpass query) and normalize.py
(to classify each returned element). Order matters: the first matching rule
wins, so more specific tags should come before general ones.

This is a first-pass, intentionally simple mapping. Expect to refine it
once real review output shows systematic miscategorization.
"""

from typing import NamedTuple, Optional


class TagRule(NamedTuple):
    key: str
    value: Optional[str]  # None means "any value for this key"
    category: str


TAG_RULES: list[TagRule] = [
    TagRule("tourism", "museum", "museum"),
    TagRule("historic", "memorial", "memorial"),
    TagRule("memorial", None, "memorial"),
    TagRule("historic", "monument", "memorial"),
    TagRule("bridge", "covered", "covered_bridge"),
    TagRule("historic", None, "historic_site"),
    TagRule("tourism", "viewpoint", "overlook"),
    TagRule("natural", "beach", "beach"),
    TagRule("leisure", "beach_resort", "beach"),
    TagRule("leisure", "garden", "garden"),
    TagRule("leisure", "nature_reserve", "park"),
    TagRule("leisure", "park", "park"),
    TagRule("shop", None, "business"),
    TagRule("amenity", "cafe", "business"),
    TagRule("amenity", "restaurant", "business"),
    # Fallback categories for anything else the Overpass query picked up
    # (tourism=attraction, tourism=artwork, tourism=picnic_site, etc.)
]

DEFAULT_CATEGORY = "other"


def classify(tags: dict) -> str:
    """Return the first matching Landmark category for a tag dict, or
    DEFAULT_CATEGORY if nothing matches."""
    for rule in TAG_RULES:
        if rule.key not in tags:
            continue
        if rule.value is None or tags[rule.key] == rule.value:
            return rule.category
    return DEFAULT_CATEGORY


def overpass_selectors() -> list[str]:
    """Build the list of Overpass tag selectors used to construct the
    fetch query. Broader than TAG_RULES on purpose (e.g. plain
    tourism=* / historic=* catch-alls) so the importer sees the same
    candidates a human browsing OSM around a town would see, and lets
    classify() sort them out afterward rather than under-fetching."""
    return [
        '["leisure"="park"]',
        '["leisure"="nature_reserve"]',
        '["leisure"="garden"]',
        '["leisure"="beach_resort"]',
        '["natural"="beach"]',
        '["tourism"]',
        '["historic"]',
        '["memorial"]',
        '["bridge"="covered"]',
    ]
