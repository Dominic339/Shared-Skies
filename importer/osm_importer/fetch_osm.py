"""
Thin wrapper around the Overpass API (the standard free query interface
for OpenStreetMap data). Fetches raw node-level POIs within a bounding box.

Deliberately node-only for this first pass: parks/reserves mapped as
way/relation polygons are out of scope until there's a real reason to
handle centroid-of-polygon geometry. Anything shaped that way is simply
absent from these results, not silently mishandled.

Shells out to `curl` rather than using Python's requests/urllib: in this
dev environment, requests and urllib both get a 406 from the real Overpass
server (confirmed via raw-socket testing with ALPN forced to http/1.1 —
it isn't a proxy or header issue), while curl succeeds reliably against
the same endpoint. Likely TLS-fingerprint-based bot mitigation on
Overpass's side. If this ever needs to run somewhere without curl
available, revisit — but there's no reason to fight a working, standard
tool in the meantime.
"""

import json
import subprocess
import tempfile
import time

from .tag_rules import overpass_selectors

OVERPASS_URL = "https://overpass-api.de/api/interpreter"


def build_query(min_lat: float, min_lon: float, max_lat: float, max_lon: float, timeout: int = 25) -> str:
    bbox = f"{min_lat},{min_lon},{max_lat},{max_lon}"
    clauses = "\n".join(f'  node{selector}({bbox});' for selector in overpass_selectors())
    return f"""[out:json][timeout:{timeout}];
(
{clauses}
);
out body;
"""


def fetch_nodes(
    min_lat: float, min_lon: float, max_lat: float, max_lon: float, timeout: int = 25, max_attempts: int = 3
) -> list[dict]:
    """Return raw Overpass 'node' elements within the given bounding box.
    Each element looks like {"type": "node", "id": ..., "lat": ..., "lon": ..., "tags": {...}}.
    Nodes with no tags at all are dropped (they carry no usable information).

    The public Overpass instance is shared, rate-limited infrastructure and
    occasionally returns a transient non-JSON error body (or an empty
    response) even when the query itself is fine — observed directly while
    building this importer, not a hypothetical. Retried a few times with a
    short backoff before giving up for real."""
    query = build_query(min_lat, min_lon, max_lat, max_lon, timeout=timeout)

    last_error: Exception | None = None
    for attempt in range(1, max_attempts + 1):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".ql", delete=True) as f:
            f.write(query)
            f.flush()
            result = subprocess.run(
                ["curl", "-sS", "--max-time", str(timeout + 10), OVERPASS_URL,
                 "--data-urlencode", f"data@{f.name}"],
                capture_output=True, text=True, timeout=timeout + 15, check=True,
            )
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as e:
            last_error = e
            if attempt < max_attempts:
                time.sleep(2 * attempt)
            continue
        elements = payload.get("elements", [])
        return [el for el in elements if el.get("tags")]

    raise RuntimeError(
        f"Overpass API returned a non-JSON response {max_attempts} times in a row "
        f"(likely transient rate limiting/server load, not a query error)"
    ) from last_error
