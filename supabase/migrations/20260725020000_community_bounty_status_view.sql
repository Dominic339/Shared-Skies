-- Per-bounty status for the calling wayfinder in one query: whether
-- they've already claimed it and whether they currently meet its
-- requirement -- lets the client enable/disable the Claim button
-- without a wasted round-trip to claim_bounty() first. `claimed` and
-- `requirement_met` both come from IS NOT NULL / EXISTS, which are
-- always well-defined true/false (never SQL NULL) regardless of
-- whether a claim row exists yet -- unlike profile_card_slots_view's
-- earlier is_own_card bug, there's no bare equality-against-a-nullable-
-- column here to repeat that mistake with.
create or replace view community_bounty_status_view
  with (security_invoker = true) as
select
  b.id as bounty_id,
  b.community_id,
  c.name as community_name,
  b.title,
  b.description,
  b.reward_amount,
  (cl.id is not null) as claimed,
  exists (
    select 1 from visits v
    join landmarks l on l.id = v.landmark_id
    where v.wayfinder_id = auth.uid() and l.community_id = b.community_id
  ) as requirement_met
from community_bounties b
join communities c on c.id = b.community_id
left join community_bounty_claims cl on cl.bounty_id = b.id and cl.wayfinder_id = auth.uid()
where b.active;

grant select on community_bounty_status_view to authenticated;
