"""
Groups nearby landmarks by pure proximity, regardless of name similarity
-- unlike dedupe.py, which only flags likely literal duplicates (same
place mapped twice). This is a different, complementary question: are
several *distinct*, real features close enough together that they might
belong to one larger destination rather than each deserving its own map
pin (e.g. six individually-named memorial stones inside one Holocaust
memorial installation)?

Deliberately not folded into duplicate_candidates -- semantically related
nearby features are not duplicates, and overloading that table would
blur a distinction that matters for how a human reviews them. This stays
importer-side output only; no schema involved.

Usage:
    python -m osm_importer.community_report --community-id <uuid>  # for counts
    python -m osm_importer.clusters --community-id <uuid> --radius-m 40
"""

import argparse

from .community_match import haversine_km
from .supabase_writer import get_client


def find_clusters(landmarks: list[dict], radius_m: float) -> list[list[dict]]:
    """Union-find style transitive clustering: two landmarks are in the
    same cluster if within radius_m of each other, OR each within
    radius_m of some other member already in the cluster (a chain of
    six memorial stones spaced ~5m apart forms one cluster even though
    the two ends might be 30m apart)."""
    n = len(landmarks)
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i, j):
        ri, rj = find(i), find(j)
        if ri != rj:
            parent[ri] = rj

    for i in range(n):
        for j in range(i + 1, n):
            distance_m = haversine_km(landmarks[i]["lat"], landmarks[i]["lon"], landmarks[j]["lat"], landmarks[j]["lon"]) * 1000
            if distance_m <= radius_m:
                union(i, j)

    groups: dict[int, list[dict]] = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(landmarks[i])

    return [group for group in groups.values() if len(group) > 1]


def load_landmarks_with_coords(client, community_id: str) -> list[dict]:
    rows = (
        client.table("landmarks")
        .select("id,code,name,category,source_confidence,lifecycle_state,location")
        .eq("community_id", community_id)
        .execute()
        .data
    )
    result = []
    for r in rows:
        lat, lon = decode_point(r["location"])
        result.append({**r, "lat": lat, "lon": lon})
    return result


def decode_point(ewkb_hex: str) -> tuple[float, float]:
    """Decode a PostGIS geography(Point) EWKB hex string (as returned by
    PostgREST) back into (lat, lon)."""
    import struct

    b = bytes.fromhex(ewkb_hex)
    lon, lat = struct.unpack("<dd", b[9:25])
    return lat, lon


def render_clusters(clusters: list[list[dict]], radius_m: float) -> str:
    if not clusters:
        return f"No clusters found within {radius_m:.0f}m -- nothing looks like it needs a parent/child review."

    lines = [f"{len(clusters)} cluster(s) found within {radius_m:.0f}m:\n"]
    for idx, cluster in enumerate(clusters, start=1):
        lines.append(f"Cluster {idx} ({len(cluster)} landmarks):")
        for member in sorted(cluster, key=lambda m: m["name"]):
            lines.append(
                f"  {member['code']:10s} {member['name']:35s} "
                f"cat={member['category']:15s} conf={member['source_confidence']:>5} "
                f"state={member['lifecycle_state']}"
            )
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Find clusters of nearby landmarks for one Community.")
    parser.add_argument("--community-id", required=True)
    parser.add_argument("--radius-m", type=float, default=40.0)
    args = parser.parse_args()

    client = get_client()
    landmarks = load_landmarks_with_coords(client, args.community_id)
    clusters = find_clusters(landmarks, args.radius_m)
    print(render_clusters(clusters, args.radius_m))


if __name__ == "__main__":
    main()
