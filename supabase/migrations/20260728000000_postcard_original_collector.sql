-- holder_wayfinder_id tracks who CURRENTLY has the physical postcard --
-- correct for mailing (postcards are single-copy, giftable, "null once
-- fully given away" per the column's own original comment), but wrong
-- for the Atlas, which is meant to be a permanent collection record, not
-- a live inventory check. Once a postcard is mailed away, holder_wayfinder_id
-- no longer points at whoever originally collected it -- there was no
-- way to answer "did I ever get a postcard here" once you'd given your
-- copy away. original_collector_id is set once at creation and never
-- touched again afterward, independent of who holds the physical card
-- now. This is also exactly the lookup a future postcard reprint system
-- (community center, "reprint any design you've personally collected
-- for a cost") will need -- searching by original collector rather than
-- current holder, so this is the right foundation to lay now rather
-- than retrofit later.
alter table postcards add column original_collector_id uuid references profiles (id) on delete set null;

-- Backfill: for a postcard that's already been mailed at least once, the
-- original collector is whoever sent it FIRST (its earliest mailing's
-- sender), not its current holder. For a postcard never mailed (still
-- 'held'), the current holder IS the original collector.
update postcards p
set original_collector_id = coalesce(
  (select m.sender_id from postcard_mailings m where m.postcard_id = p.id order by m.mailed_at asc limit 1),
  p.holder_wayfinder_id
);

-- Additive with postcards_self_rw (auth.uid() = holder_wayfinder_id) --
-- multiple permissive policies OR together, so a wayfinder can now read
-- their own postcard rows either as current holder OR as original
-- collector, regardless of whether the card has since moved on. This is
-- what lets atlas_view (security_invoker, unchanged) keep seeing a
-- postcard for has_postcard purposes after it's been mailed away --
-- without this, the row would simply vanish from view the moment
-- holder_wayfinder_id stopped being auth.uid(), the same RLS-visibility
-- gap already hit once on profile_card_placements/profile_card_collection_view.
create policy postcards_original_collector_read on postcards
  for select using (auth.uid() = original_collector_id);

-- The duplicate-postcard guard checked holder_wayfinder_id, which broke
-- the moment a postcard could be mailed away (a buggy repeat is_first_visit
-- insert would no longer find the original row and would create a
-- second postcard for the same wayfinder+landmark). original_collector_id
-- is the correct, permanent key for "has this wayfinder ever gotten a
-- postcard here" regardless of mailing history.
create or replace function create_postcard_on_first_visit()
returns trigger
language plpgsql
as $$
begin
  insert into postcards (holder_wayfinder_id, original_collector_id, landmark_id, community_id, season, weather, time_of_day)
  select new.wayfinder_id, new.wayfinder_id, l.community_id, 'summer', 'clear', 'day'
  from landmarks l
  where l.id = new.landmark_id
    and not exists (
      select 1 from postcards p
      where p.original_collector_id = new.wayfinder_id and p.landmark_id = new.landmark_id
    );
  return new;
end;
$$;

-- has_postcard now relies on the two postcards read policies (self as
-- current holder, self as original collector) to define "which postcard
-- rows count as mine" instead of restating that logic here -- an EXISTS
-- check (not the previous LEFT JOIN) specifically to avoid duplicating a
-- Landmark's row if a wayfinder somehow has more than one visible
-- postcard for it (their own original PLUS one received via mail from
-- someone else who also collected there).
create or replace view atlas_view
  with (security_invoker = true) as
select
  l.id as landmark_id,
  l.code,
  l.name,
  l.category,
  l.community_id,
  c.name as community_name,
  v.first_visited_at,
  (v.landmark_id is not null) as visited,
  exists (select 1 from postcards p where p.landmark_id = l.id) as has_postcard
from landmarks l
join communities c on c.id = l.community_id
left join (
  select landmark_id, wayfinder_id, min(visited_at) as first_visited_at
  from visits
  group by landmark_id, wayfinder_id
) v on v.landmark_id = l.id;

grant select on atlas_view to authenticated;

-- postcard_collection_view (the Postcards screen's "my collection") had
-- no explicit filter, relying purely on postcards_self_rw to scope it to
-- current holdings. Adding postcards_original_collector_read above would
-- otherwise silently widen it to also include postcards already mailed
-- away, which isn't what that screen is for -- it reflects what you
-- physically hold right now (and can still mail), not a permanent
-- collection history. Explicit filter keeps its behavior exactly as it
-- was. A future reprint index (searchable by everything you've ever
-- personally collected, regardless of current holder) is a separate view
-- this migration deliberately does not build yet -- original_collector_id
-- is what it will key off of when that feature actually gets built.
create or replace view postcard_collection_view
  with (security_invoker = true) as
select
  p.id,
  p.code,
  p.landmark_id,
  l.name as landmark_name,
  p.community_id,
  c.name as community_name,
  p.season,
  p.weather,
  p.time_of_day,
  p.artwork_render_url,
  p.collected_at,
  p.status
from postcards p
join landmarks l on l.id = p.landmark_id
join communities c on c.id = p.community_id
where p.holder_wayfinder_id = auth.uid();

grant select on postcard_collection_view to authenticated;
