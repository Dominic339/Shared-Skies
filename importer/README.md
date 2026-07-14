# OSM Landmark Importer

A narrow, deliberately unambitious first pass at the content pipeline
described in the design discussion: pull real points of interest from
OpenStreetMap, normalize them, match each to the nearest Community, score
a rough confidence, flag obvious in-batch duplicates, and hand a human a
CSV to review. Nothing here auto-publishes anything, generates
descriptions, assigns postcards, or infers accessibility — those are
later enrichment stages once this core path is proven.

## Quick start (dry run, no database needed)

```bash
pip install -r requirements.txt
python -m osm_importer.run_import \
  --min-lat 42.70 --min-lon -71.52 --max-lat 42.82 --max-lon -71.40 \
  --communities sample_communities.json \
  --out review.csv
```

That bounding box covers Nashua, NH. Open `review.csv` afterward — each
row is one OSM node with its matched Community, a 0-100 confidence
score, and a routing decision (`high_priority_review` / `needs_review` /
`stays_rumor`). Nothing is written to any database in this mode.

`sample_communities.json` has one placeholder Community with a fake ID,
just enough to exercise the nearest-community matching logic. Replace it
with real rows (real `communities.id` values) once a real Supabase
project exists — see below.

## Writing into a real Supabase project

Once a Supabase project exists with the schema in
`../supabase/migrations/` applied (and at least one real Community row
inserted for whatever area you're importing — the importer matches
candidates against real `communities` rows, not `sample_communities.json`,
once you're pointed at a live project):

```bash
export SUPABASE_URL="https://<project>.supabase.co"
export SUPABASE_SERVICE_ROLE_KEY="<service role key — keep this secret, never ship it to a client>"
python -m osm_importer.run_import \
  --min-lat 42.70 --min-lon -71.52 --max-lat 42.82 --max-lon -71.40 \
  --communities real_communities.json \
  --out review.csv \
  --batch-id osm_nashua_2026_07_14_001 \
  --write-limit 20
```

If both environment variables are set, candidates are also inserted into
`landmarks` (as `candidate` or `rumor`, never `published`),
`landmark_sources` (provenance, tagged with `--batch-id` inside
`raw_payload._import_batch_id` so a bad run can be found and removed:
`delete from landmark_sources where raw_payload->>'_import_batch_id' = '...'`),
and, for anything dedupe.py flagged, a `submission_tickets` +
`duplicate_candidates` pair. The CSV is still written either way — it's
the reviewable record regardless of whether the database write also ran.

Use `--write-limit N` for a first controlled batch (e.g. 10-25) before
running the full area — every candidate still appears in the CSV either
way, only the database write is capped, and it takes the highest-
confidence candidates first.

**This write path has not yet been exercised against a real Supabase
project** — there wasn't one to test against when most of this was
written. The dry-run/CSV path has been validated against live OSM data
for Nashua, NH. One specific thing to check on the first real run: the
`location` field is sent as a WKT string (`"POINT(lon lat)"`); this
should cast to `geography(Point,4326)` the same way it would in a raw SQL
insert, but that cast behavior through PostgREST (what the Supabase
client talks to) hasn't been confirmed — inspect the first few rows in
Supabase Studio's map/geometry view to make sure the coordinates landed
correctly, not just that the insert didn't error.

## What this deliberately does not do (yet)

- No postcard template assignment.
- No souvenir category suggestions.
- No accessibility inference.
- No handling of OSM ways/relations (polygon-shaped features like park
  boundaries) — nodes only.
- No auto-publish, regardless of confidence score. Every candidate lands
  as `candidate` or `rumor` for a human to review, per the conservative
  launch policy: prove the false-positive rate is low before trusting
  the pipeline unsupervised.

## Tuning

Confidence weights live in `osm_importer/scoring.py` as named constants;
routing thresholds (95 / 80) live in the same file as `route()`. Both are
plain Python, not database configuration — change them and rerun, no
migration involved.

## Combined reports (community_report.py, clusters.py)

Query the live database directly rather than a single run's in-memory
candidates, so they reflect everything accumulated across every batch
for a Community:

```bash
python -m osm_importer.community_report --community-id <uuid>
python -m osm_importer.clusters --community-id <uuid> --radius-m 40
python -m osm_importer.review_export --community-id <uuid> --out review.csv
```

## Enrichment (osm_importer/enrichment/)

A narrow evidence-gathering + AI-classification pass for unnamed
imported landmarks -- never touches the live `landmarks` table, only
produces a CSV of suggestions for human review:

```bash
export GEMINI_API_KEY="<your free Google AI Studio key>"
python -m osm_importer.enrichment.enrich --community-id <uuid> --out enrichment_review.csv --limit 10
```

For each unnamed record it gathers: the object's own OSM tags, a direct
Wikidata/Wikipedia pull if the object already carries those tags (a
lookup, not a guess), and named OSM objects within `--radius-m` (default
150m). Only that evidence is given to Gemini (`gemini-flash-latest`,
Google's free tier), which is explicitly instructed to summarize what
it's given and say so when evidence is insufficient rather than invent
history. Every record is classified as `recovered_landmark` (a real
standalone destination), `landmark_feature` (belongs under a named
nearby parent), or `archive_ignore` (valid OSM data, not meaningful
Shared Skies content) -- with confidence, citations, and reasoning, all
marked for human review regardless of confidence.

Uses `requests` directly (not the curl-subprocess workaround
`fetch_osm.py` needs for Overpass) -- Wikidata/Wikipedia's public APIs
just needed a real User-Agent header, which is their documented
requirement, not a proxy or fingerprinting issue like Overpass's.
