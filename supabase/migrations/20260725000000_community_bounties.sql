-- Minimal Community Board: one bounty definition per Community for now
-- ("Visit one published Landmark in this Community"), auto-backfilled
-- and kept in sync with new Communities via a trigger -- same pattern as
-- profile_card_slots. A real Community Board will eventually be a menu
-- inside that Community's community center; this is deliberately just
-- the data + a plain list UI until that visual piece gets built.
create table community_bounties (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities (id) on delete cascade,
  title text not null,
  description text,
  -- Only one requirement type exists today -- kept as a text enum rather
  -- than hardcoding the logic inline so claim_bounty() can grow more
  -- kinds later (donate an item, submit a Rumor, etc.) without a schema
  -- change, same reasoning as postcards.season/weather/time_of_day being
  -- free-form for now.
  requirement_type text not null default 'visit_any_landmark'
    check (requirement_type in ('visit_any_landmark')),
  reward_amount integer not null check (reward_amount > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index community_bounties_community_idx on community_bounties (community_id);

insert into community_bounties (community_id, title, description, reward_amount)
select id, 'Visit a Landmark', 'Visit any one published Landmark in this Community.', 50
from communities
on conflict do nothing;

create or replace function create_default_bounty_for_community()
returns trigger
language plpgsql
as $$
begin
  insert into community_bounties (community_id, title, description, reward_amount)
  values (new.id, 'Visit a Landmark', 'Visit any one published Landmark in this Community.', 50);
  return new;
end;
$$;

create trigger trg_communities_create_default_bounty
  after insert on communities
  for each row execute function create_default_bounty_for_community();

-- One claim per (bounty, wayfinder) -- the unique index is the actual
-- enforcement against double-claiming (claim_bounty() also checks this
-- proactively for a clean error message, but the index is what holds
-- under a race between two concurrent claim attempts).
create table community_bounty_claims (
  id uuid primary key default gen_random_uuid(),
  bounty_id uuid not null references community_bounties (id) on delete cascade,
  wayfinder_id uuid not null references profiles (id) on delete cascade,
  wallet_operation_id uuid references wallet_operations (id) on delete set null,
  claimed_at timestamptz not null default now(),
  unique (bounty_id, wayfinder_id)
);

alter table community_bounties enable row level security;
alter table community_bounty_claims enable row level security;

create policy community_bounties_public_read on community_bounties
  for select using (active);

-- Self-read only -- no insert/update/delete policy for anon/authenticated
-- anywhere. All claims are created by claim_bounty() (security definer,
-- next migration), never a raw table write from the client.
create policy community_bounty_claims_self_read on community_bounty_claims
  for select using (auth.uid() = wayfinder_id);
