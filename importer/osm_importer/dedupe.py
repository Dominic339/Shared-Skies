"""
Flags likely duplicate candidates within a single import batch: two nodes
close together with similar names are almost always the same real place
mapped twice in OSM (a bench vs. the park it sits in, a duplicate node
from a data import years ago, etc.).

This only catches within-batch duplicates. Catching a new candidate that
duplicates an already-published Landmark is a separate, later step (it
needs a query against the live `landmarks` table, not just this batch),
and belongs in run_import.py once Supabase is wired up for real.
"""

from difflib import SequenceMatcher

from .community_match import haversine_km
from .normalize import Candidate

DUPLICATE_DISTANCE_METERS = 30
DUPLICATE_NAME_SIMILARITY_THRESHOLD = 0.8


def _name_similarity(a: str | None, b: str | None) -> float:
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a.lower(), b.lower()).ratio()


def flag_batch_duplicates(candidates: list[Candidate]) -> None:
    """Mutates candidates in place, setting possible_duplicate_of on the
    later candidate in each pair (the earlier one in the list is treated
    as the original)."""
    for i, candidate in enumerate(candidates):
        if candidate.possible_duplicate_of is not None:
            continue
        for earlier in candidates[:i]:
            distance_m = haversine_km(candidate.lat, candidate.lon, earlier.lat, earlier.lon) * 1000
            if distance_m > DUPLICATE_DISTANCE_METERS:
                continue
            if _name_similarity(candidate.name, earlier.name) >= DUPLICATE_NAME_SIMILARITY_THRESHOLD:
                candidate.possible_duplicate_of = earlier.external_ref
                break
