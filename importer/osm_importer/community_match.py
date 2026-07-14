"""
Assigns each Candidate to its nearest Community by straight-line
(haversine) distance to the community's center_point. This runs in plain
Python against a list of communities pulled from Supabase (or, for a dry
run, a local JSON file) rather than doing the distance calculation in
PostGIS, since candidates aren't in the database yet at this stage.

A production version could push this into a single PostGIS query once
candidates are already staged in a table (ST_Distance against
communities.center_point) — left as plain Python here because it's the
same answer and doesn't require anything to exist in the database first.
"""

import math
from dataclasses import dataclass

from .normalize import Candidate


@dataclass
class CommunityRef:
    id: str
    name: str
    lat: float
    lon: float


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0088  # mean Earth radius, km
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    a = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def assign_nearest_community(
    candidate: Candidate, communities: list[CommunityRef], max_radius_km: float = 50.0
) -> None:
    """Mutates candidate in place. Leaves matched_community_id as None
    (and distance_km_to_community as None) if nothing is within
    max_radius_km — an unmatched candidate should be flagged for manual
    assignment, never silently attached to the nearest community
    regardless of how far away it actually is."""
    best: tuple[CommunityRef, float] | None = None
    for community in communities:
        distance = haversine_km(candidate.lat, candidate.lon, community.lat, community.lon)
        if best is None or distance < best[1]:
            best = (community, distance)

    if best is not None and best[1] <= max_radius_km:
        candidate.matched_community_id = best[0].id
        candidate.matched_community_name = best[0].name
        candidate.distance_km_to_community = round(best[1], 3)
