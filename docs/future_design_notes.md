# Future Design Notes

Deferred systems that have been fully designed/agreed in discussion but are
intentionally NOT being built yet. Recorded here so the reasoning survives
until the project reaches the point where it's actually needed -- these are
not TODOs for right now.

## Overworld habitat & decoration system

**Status:** Deferred until after the initial Godot vertical slice (map,
auth, RLS, Landmark Display) is working. Phase 1 uses a single hardcoded
habitat for the Nashua test set -- nothing below is required for that.

### The core idea

As nature-related souvenir/collectible models are added to the game, the
same asset becomes eligible to appear as decoration in compatible parts of
the overworld map, globally -- not tied to any single Community's donation
progress. A returning player should be able to notice "I don't remember
seeing these mushrooms" and correctly infer new content was added. This is
a living visual record of the game's development, not a progress meter.

Rejected alternative: tying decoration density to per-Community donation
progress. Rejected because it conflates "this Community worked hard" with
"this content exists," and because a flat % blend of biomes per Community
looks visually noisy/conflicting up close.

### Habitat, not biome percentages

Also rejected: a single biome field or a percentage blend per Community
(e.g. "Nashua = 40% forest / 25% urban / ..."). Too abstract, not grounded
in real places, and produces visual conflict at any given point.

Instead: **discrete ecological habitat zones** assigned by actual
real-world geography -- e.g. Pine Forest, Oak Forest, Sandy Beach, Pebble
Beach, Rocky Coast, Salt Marsh, Freshwater Marsh, Cranberry Bog, Suburban
Park, Cemetery, Botanical Garden, Quarry. A single Community (Cape Cod
being the clearest example) can contain several habitat zones at once.
Each collectible/decoration asset declares which habitat(s) it belongs to
based on where it would actually be found (sea glass -> pebble beach,
cattails -> marsh/pond edge, pine mushrooms -> beneath pines) -- ecological
plausibility, not a spawn-table roll.

This also generalizes cleanly outside New England later (Florida adds
mangrove/cypress swamp/tropical hammock, Arizona adds Sonoran
desert/dry wash/saguaro hillside) without changing the placement logic,
just adding new habitat definitions.

**Schema implication:** habitat should NOT be a field on `communities` --
it needs its own spatial zone layer (polygons or a coarse grid, each
tagged with a habitat type) that the decoration system queries by
location. A Community just happens to overlap whatever zones fall inside
its boundary.

### Future thought: micro-feature modifiers (not new habitats)

Not for near-term implementation -- recorded because the architecture
above supports it without restructuring, so it shouldn't get reinvented
later as if it were a new problem.

Idea: layer subtle *modifiers* on top of a habitat rather than inventing
new habitat types for every variation. E.g. `Pine Forest + north-facing
slope` favors moss; `Pine Forest + sunny clearing` favors blueberries;
`Pebble Beach + high wave exposure` favors driftwood. Two Pine Forest
zones can feel different without multiplying the habitat catalog.

Why this doesn't require redesigning anything: the per-asset placement
layer already decides eligibility per cell via a filter over that cell's
tags (habitat, at minimum). A modifier is just another tag a cell can
carry, and an asset's eligibility filter becomes `habitat=X AND
modifier=Y` instead of just `habitat=X`. No new placement mechanism,
seeding scheme, or rendering path needed -- just richer per-cell tagging
whenever this actually gets picked up.

### Data sources for accurate habitat classification

Three real, free, non-crowdsourced datasets, layered together:

1. **NLCD (National Land Cover Database)**, USGS/MRLC -- the backbone.
   Satellite-derived, 30m-resolution raster, public domain, consistent
   methodology across the whole US (unlike OSM's patchy crowdsourced
   coverage). Full CONUS time series 1985-2024. Classifies deciduous /
   evergreen / mixed forest, woody/emergent wetlands, open water,
   developed (several intensities), shrub/scrub, grassland, pasture/crops.
   In New England, evergreen ~= pine/spruce and deciduous ~= oak/maple, so
   it maps onto "pine forest" vs "oak forest" almost directly. One-time
   batch download via the MRLC Viewer (draw a region, pick the product,
   get emailed a link) -- not a live API, so none of the Overpass-style
   rate-limit fragility we hit importing landmarks.
   https://www.mrlc.gov/viewer/

2. **NWI (National Wetlands Inventory)**, USFWS -- NLCD's wetland classes
   are coarse ("woody wetlands" / "emergent herbaceous wetlands"). NWI has
   actual delineated polygons distinguishing marsh/bog/swamp/pond types at
   real precision -- needed for "cranberry bog" / "salt marsh" specificity.
   Free, public domain, per-state download.
   https://www.fws.gov/program/national-wetlands-inventory/data-download

3. **OSM tags** -- narrower role than originally assumed: fills gaps
   neither NLCD nor NWI resolve. Specifically beach substrate
   (`natural=beach` + `surface=sand|pebblestone|shingle` -- NLCD just sees
   "barren"/"open water" near a coastline) and human-built categories that
   matter for flavor but get lumped into generic "developed" tiers by NLCD
   (`landuse=cemetery`, `leisure=park`, `leisure=garden`, quarry, etc.).

**Pipeline sketch:** download NLCD + NWI once for the 6 NE states, sample
habitat class per map grid cell (standard GIS raster sampling, e.g. via
`rasterio`), let NWI override NLCD's coarser wetland call where they
disagree, overlay OSM tags for beach material and constructed-landscape
categories. Same review-and-correct pattern as the landmark importer
applies at the edges -- a manual override table for cells where automated
classification is wrong, not full hand-authored zoning.

### Content model

Each nature-related asset carries two linked definitions sharing the same
underlying model/mesh:

- **Collectible definition** -- name, description, rarity, spawn
  region/habitat, museum category, obtainable status.
- **Overworld decoration definition** -- compatible habitats, placement
  surface, cluster size, decorative rarity/density, scale range, seasonal
  restrictions, enabled flag.

Publishing an asset makes it globally eligible in compatible habitat
zones immediately -- no per-Community unlock step.

A global decorative catalog (name TBD, e.g. `overworld_decor_definitions`)
tracks `model_asset_id`, `variant_id`, `enabled`, `introduced_at`,
`eligible_habitats`, `placement_rules`, `decorative_weight`.

### Rendering approach (Godot)

- `MultiMeshInstance3D` per decorative asset layer -- no per-object
  scripts, no collision, no individual nodes.
- Deterministic placement: `seed = f(chunk_coord, asset_definition_id)`.
  Each asset gets its OWN placement layer keyed off its own definition ID
  -- adding a new asset (e.g. purple mushrooms) only adds that layer;
  existing trees/flowers/shrubs don't reshuffle. Avoid a single global
  palette-version seed for this reason.
- Chunk/cell-based loading: only nearby cells generate; distant ones
  unload; consistent on return because placement is deterministic, not
  stored.
- Color/species variants (red/yellow/white/purple tulip) via MultiMesh
  per-instance custom data, not a separate MultiMeshInstance3D per variant
  -- keeps draw calls flat regardless of variant count.
- Device quality tiers change density/draw-distance/animation only --
  the underlying Community/game state is identical for every player.
- Map appearance means "this now exists and may be discoverable
  somewhere appropriate," never "tap this exact decorative instance to
  collect one" -- decoration and collection must stay visually distinct
  so the map doesn't turn into a resource-farming screen.

### Content delivery caveat

Godot has no built-in remote-asset-streaming system (no Unity-Addressables
equivalent). Unless/until a custom download-and-mount `.pck` system is
built, every new decorative/collectible asset ships via a normal app store
update. Treat "hot content updates without resubmission" as a distinct
future problem, not something implicitly solved by this design.

### Plant/pot separation

Living plants and containers are separate collectible systems:

- **Plant** (tulip, fern, mushroom, shrub, etc.) -- the collectible; same
  asset reused as the Atlas entry, the overworld decoration, and the
  placeable home item.
- **Pot** -- a separately-collected, reusable cosmetic container, chosen
  at placement time (`Select Plant -> Select Pot -> Place`). Pots are
  one-time collectibles, not consumed per-placement -- otherwise placing
  one piece of foliage would require holding two consumable items, which
  doesn't feel fair. This also lets players restyle a home's look by
  swapping pots without re-collecting plants.
