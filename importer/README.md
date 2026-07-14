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
`../supabase/migrations/` applied:

```bash
export SUPABASE_URL="https://<project>.supabase.co"
export SUPABASE_SERVICE_ROLE_KEY="<service role key — keep this secret, never ship it to a client>"
python -m osm_importer.run_import ...
```

If both environment variables are set, candidates are also inserted into
`landmarks` (as `candidate` or `rumor`, never `published`) and
`landmark_sources` (provenance). The CSV is still written either way —
it's the reviewable record regardless of whether the database write also
ran.

**This write path has not yet been exercised against a real Supabase
project** — there wasn't one to test against when this was written. The
dry-run/CSV path has been validated against live OSM data for Nashua, NH;
treat `supabase_writer.py` as reviewed-but-unproven until it's run for
real once and the resulting rows are checked by hand.

## What this deliberately does not do (yet)

- No AI-generated descriptions.
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
