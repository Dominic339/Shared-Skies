-- Every published, donatable item definition crossed with every
-- published Community, showing whether it's been donated there yet and
-- by whom. Not security_invoker -- communities/item_definitions/
-- museum_exhibit_slots/museum_donations are all already public-read on
-- their own, so there's no caller-specific scoping needed here at all,
-- same reasoning as landmarks_map_view.
create or replace view museum_progress_view as
select
  c.id as community_id,
  c.name as community_name,
  d.id as item_definition_id,
  d.name as item_name,
  d.category,
  (don.id is not null) as donated,
  don.donor_wayfinder_id,
  pr.display_name as donor_display_name,
  don.donated_at
from communities c
cross join item_definitions d
left join museum_exhibit_slots s on s.community_id = c.id and s.item_definition_id = d.id
left join museum_donations don on don.exhibit_slot_id = s.id
left join public_profiles_view pr on pr.id = don.donor_wayfinder_id
where c.publication_state = 'published'
  and d.publication_state = 'published'
  and d.category in ('souvenir', 'decoration', 'token');

grant select on museum_progress_view to authenticated;

-- The calling wayfinder's own eligible-to-donate inventory --
-- security_invoker relies on item_instances_self_rw (auth.uid() =
-- owner_wayfinder_id), which is the only policy on that table, so this
-- is safe unlike the postcards/profile_card_placements cases (no second
-- policy broadens visibility here).
create or replace view my_donatable_items_view
  with (security_invoker = true) as
select
  i.id as item_instance_id,
  i.item_definition_id,
  d.name as item_name,
  d.category
from item_instances i
join item_definitions d on d.id = i.item_definition_id
where i.status = 'owned' and d.category in ('souvenir', 'decoration', 'token');

grant select on my_donatable_items_view to authenticated;
