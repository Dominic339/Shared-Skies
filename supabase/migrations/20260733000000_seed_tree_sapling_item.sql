-- model_assets had RLS never enabled at all -- same gap feature_flags
-- had before it was fixed, just not yet noticed since nothing had
-- written to or read from this table until now. Fixing it while seeding
-- the first real row, same public-read shape as item_definitions_public_read
-- (players need to be able to look this up, but only a migration or the
-- future admin console should ever write to it).
alter table model_assets enable row level security;
create policy model_assets_public_read on model_assets
  for select using (true);

-- storage_path uses the same res:// convention every other model in the
-- client is already loaded by (e.g. profile_card_holder.glb, atlas_book_*.glb)
-- rather than a real asset-bundle/Storage key -- there's no asset
-- pipeline yet, so this is the honest current location, not a
-- placeholder to be confused with a future CDN path.
insert into model_assets (name, asset_category, storage_path)
values ('Tree', 'collectible', 'res://assets/models/tree.glb');

-- A test/placeholder collectible so the Museum donation loop (and its
-- dev-only Grant Test Item control) has something real to work with --
-- reuses the existing tree.glb model rather than waiting on real
-- souvenir art. Matches the "White Pine Sapling" example already used
-- when describing the Museum panel mockup.
insert into item_definitions (category, name, description, model_asset_id, rarity_tier, publication_state)
select
  'souvenir',
  'White Pine Sapling',
  'A small sapling, carefully dug up and kept in a pot -- fit for donation to a Community museum.',
  m.id,
  'common',
  'published'
from model_assets m
where m.storage_path = 'res://assets/models/tree.glb';
