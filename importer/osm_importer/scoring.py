"""
A first-pass, intentionally simple confidence heuristic (0-100) for an
imported Candidate. This is explicitly a starting point, not a calibrated
model — per the "treat thresholds as provisional policy, not permanent
constants" agreement, every weight below is a named constant meant to be
retuned once real review output shows whether high-scoring candidates
are actually good.

Nothing here writes to or reads from landmarks.source_confidence's shape
directly — this just produces the number that would go there.
"""

from .normalize import Candidate

WEIGHT_BASE_EXISTS_IN_OSM = 30
WEIGHT_HAS_NAME = 20
WEIGHT_HAS_EXTERNAL_REFERENCE = 25  # wikidata/wikipedia tag: a real independent verification signal
WEIGHT_HAS_WEBSITE = 10
WEIGHT_UNAMBIGUOUS_CATEGORY = 10  # classify() found a specific category, not the 'other' fallback
WEIGHT_MATCHED_TO_COMMUNITY = 5

# Conservative launch policy (see design discussion): even a 95+ score
# does not auto-publish for the first dataset. Everything routes to a
# human; the score only decides how urgently.
ROUTE_HIGH_PRIORITY_REVIEW = "high_priority_review"  # score >= 95
ROUTE_NEEDS_REVIEW = "needs_review"                   # 80 <= score < 95
ROUTE_STAYS_RUMOR = "stays_rumor"                     # score < 80


def score_candidate(candidate: Candidate) -> float:
    score = WEIGHT_BASE_EXISTS_IN_OSM

    if candidate.name:
        score += WEIGHT_HAS_NAME

    if "wikidata" in candidate.raw_tags or "wikipedia" in candidate.raw_tags:
        score += WEIGHT_HAS_EXTERNAL_REFERENCE

    if "website" in candidate.raw_tags or "contact:website" in candidate.raw_tags:
        score += WEIGHT_HAS_WEBSITE

    if candidate.category != "other":
        score += WEIGHT_UNAMBIGUOUS_CATEGORY

    if candidate.matched_community_id is not None:
        score += WEIGHT_MATCHED_TO_COMMUNITY

    return min(score, 100.0)


def route(score: float) -> str:
    if score >= 95:
        return ROUTE_HIGH_PRIORITY_REVIEW
    if score >= 80:
        return ROUTE_NEEDS_REVIEW
    return ROUTE_STAYS_RUMOR
