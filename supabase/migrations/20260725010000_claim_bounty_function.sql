-- The only path that awards bounty Waymarks -- verifies everything
-- server-side (bounty is active, requirement is actually met, not
-- already claimed) before internally calling award_waymarks(), rather
-- than trusting the client to only ask for what it's earned. Safe to
-- expose to authenticated: it always acts on auth.uid(), never a
-- supplied user_id, and the reward amount always comes from the
-- trusted community_bounties row, never from the caller.
create or replace function claim_bounty(p_bounty_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_bounty record;
  v_already_claimed boolean;
  v_requirement_met boolean;
  v_operation_id uuid;
  v_idempotency_key text;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to claim a bounty';
  end if;

  select * into v_bounty from community_bounties where id = p_bounty_id and active;
  if v_bounty.id is null then
    raise exception 'bounty not found or no longer active';
  end if;

  select exists (
    select 1 from community_bounty_claims
    where bounty_id = p_bounty_id and wayfinder_id = v_user_id
  ) into v_already_claimed;
  if v_already_claimed then
    raise exception 'bounty already claimed';
  end if;

  if v_bounty.requirement_type = 'visit_any_landmark' then
    select exists (
      select 1 from visits v
      join landmarks l on l.id = v.landmark_id
      where v.wayfinder_id = v_user_id and l.community_id = v_bounty.community_id
    ) into v_requirement_met;
  else
    raise exception 'unknown bounty requirement type: %', v_bounty.requirement_type;
  end if;

  if not v_requirement_met then
    raise exception 'bounty requirement not met yet';
  end if;

  -- Keyed on the bounty+player pair, not a client-supplied value -- a
  -- retried request (dropped connection, double-tap) for the same
  -- bounty can never award twice, regardless of the claim-row race
  -- handled below.
  v_idempotency_key := 'bounty:' || p_bounty_id || ':' || v_user_id;
  v_operation_id := award_waymarks(
    v_user_id, v_bounty.reward_amount, 'earned', 'bounty', p_bounty_id, v_bounty.title, v_idempotency_key
  );

  begin
    insert into community_bounty_claims (bounty_id, wayfinder_id, wallet_operation_id)
    values (p_bounty_id, v_user_id, v_operation_id);
  exception when unique_violation then
    -- Two concurrent claim attempts both passed the already_claimed
    -- check above before either committed -- the award itself already
    -- happened exactly once (award_waymarks' own idempotency_key check
    -- guarantees that regardless of which insert below wins), so this
    -- just means we lost the race to record the claim row. Nothing
    -- further to do.
    null;
  end;

  return v_operation_id;
end;
$$;

grant execute on function claim_bounty(uuid) to authenticated;
