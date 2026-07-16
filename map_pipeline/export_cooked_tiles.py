"""
Reads Planetiler's canonical mbtiles (standard MVT/gzip) and exports a
small, human-readable JSON payload per tile for Godot to load directly --
no protobuf/MVT decoder needed client-side. Deterministic and disposable:
delete everything under the output directory and re-run to reproduce it
exactly from the canonical mbtiles.

JSON was chosen deliberately for this first pass over a compact binary
format -- readable output makes it trivial to spot a coordinate/alignment
bug by eye. Revisit only if real device benchmarking shows it's too slow
or large; don't optimize this before there's a reason to.

CRITICAL: the projection math below (EARTH_RADIUS_METERS, ORIGIN_LAT,
ORIGIN_LNG, the Web Mercator + cos(ORIGIN_LAT) scale correction) MUST
stay byte-for-byte identical to client/scripts/geo_projection.gd. This
is what guarantees road/water geometry and the player/Landmark markers
end up in the exact same local coordinate space -- if these two files'
formulas ever diverge, the map will look right and the markers will
quietly drift relative to it.

Usage:
    python3 export_cooked_tiles.py --mbtiles nashua.mbtiles --zoom 14 \
        --center-tile 4939 6034 --radius 2 --out ../client/assets/map_tiles/nashua
"""

import argparse
import gzip
import json
import math
import sqlite3
from pathlib import Path

import mapbox_vector_tile

EARTH_RADIUS_METERS = 6378137.0
ORIGIN_LAT = 42.7654
ORIGIN_LNG = -71.4676


def mercator_x(lng_deg: float) -> float:
    return EARTH_RADIUS_METERS * math.radians(lng_deg)


def mercator_y(lat_deg: float) -> float:
    lat_rad = math.radians(lat_deg)
    return EARTH_RADIUS_METERS * math.log(math.tan(math.pi / 4.0 + lat_rad / 2.0))


SCALE = math.cos(math.radians(ORIGIN_LAT))
ORIGIN_MX = mercator_x(ORIGIN_LNG)
ORIGIN_MY = mercator_y(ORIGIN_LAT)


def tile_local_to_world(z: int, x: int, y: int, mvt_x: float, mvt_y: float, extent: int) -> tuple[float, float]:
    """MVT tile-local coordinate -> (local_x, local_z) in the same space
    GeoProjection.to_local() produces from a lat/lng."""
    n = 2 ** z
    world_size = 2.0 * math.pi * EARTH_RADIUS_METERS
    tile_size = world_size / n

    tile_left = -math.pi * EARTH_RADIUS_METERS + x * tile_size
    tile_top = math.pi * EARTH_RADIUS_METERS - y * tile_size

    world_x = tile_left + (mvt_x / extent) * tile_size
    world_y = tile_top - (mvt_y / extent) * tile_size

    local_x = (world_x - ORIGIN_MX) * SCALE
    local_z = -(world_y - ORIGIN_MY) * SCALE
    return local_x, local_z


def convert_ring(ring: list, z: int, x: int, y: int, extent: int) -> list:
    return [list(tile_local_to_world(z, x, y, px, py, extent)) for px, py in ring]


def export_tile(cur: sqlite3.Cursor, z: int, x: int, y: int, extent: int) -> dict | None:
    # mbtiles stores tile_row flipped (TMS scheme), not XYZ.
    tms_y = (2 ** z - 1) - y
    row = cur.execute(
        "select tile_data from tiles where zoom_level=? and tile_column=? and tile_row=?",
        (z, x, tms_y),
    ).fetchone()
    if row is None:
        return None

    decoded = mapbox_vector_tile.decode(gzip.decompress(row[0]))

    roads = []
    for feature in decoded.get("roads", {}).get("features", []):
        geom = feature["geometry"]
        props = feature["properties"]
        lines = [geom["coordinates"]] if geom["type"] == "LineString" else geom["coordinates"]
        for line in lines:
            roads.append({
                "class": props.get("class", "unknown"),
                "name": props.get("name"),
                "points": convert_ring(line, z, x, y, extent),
            })

    water = []
    for feature in decoded.get("water", {}).get("features", []):
        geom = feature["geometry"]
        if geom["type"] == "Polygon":
            polygons = [geom["coordinates"]]
        elif geom["type"] == "MultiPolygon":
            polygons = geom["coordinates"]
        else:
            continue
        for polygon in polygons:
            # First ring is the exterior; later rings are holes. Holes
            # are ignored for this first proof -- not needed to prove
            # ground/water/roads render and align correctly.
            if polygon:
                water.append({"points": convert_ring(polygon[0], z, x, y, extent)})

    return {"z": z, "x": x, "y": y, "roads": roads, "water": water}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mbtiles", required=True)
    parser.add_argument("--zoom", type=int, default=14)
    parser.add_argument("--center-tile", type=int, nargs=2, metavar=("X", "Y"), required=True)
    parser.add_argument("--radius", type=int, default=2, help="tiles in each direction from center")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    conn = sqlite3.connect(args.mbtiles)
    cur = conn.cursor()
    extent = 4096  # Planetiler/Mapbox default tile extent

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    cx, cy = args.center_tile
    written, missing = 0, 0
    for x in range(cx - args.radius, cx + args.radius + 1):
        for y in range(cy - args.radius, cy + args.radius + 1):
            tile = export_tile(cur, args.zoom, x, y, extent)
            if tile is None:
                missing += 1
                continue
            out_path = out_dir / f"{args.zoom}_{x}_{y}.json"
            out_path.write_text(json.dumps(tile))
            written += 1
            print(f"  {out_path.name}: {len(tile['roads'])} road(s), {len(tile['water'])} water polygon(s)")

    print(f"\nWrote {written} tile(s), {missing} tile(s) had no data in the source mbtiles.")


if __name__ == "__main__":
    main()
