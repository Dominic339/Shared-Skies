-- community_recommendations already existed (community_id, nullable
-- landmark_id, author_wayfinder_id, body, status pending/published/
-- archived, public-read gated to status='published') -- same "table
-- already anticipated this, just never wired up" situation as
-- profile_card_slots/museum_exhibit_slots before those got built out.
-- This is the narrower system per the corrected scope: "Community X
-- recommends visiting Landmark Y, here's why" -- not a new-Community
-- proposal tool (that's explicitly deferred, Community Centers are
-- being premade/seeded separately).

-- A player can also see their OWN pending/archived recommendations,
-- not just published ones -- additive with the existing
-- community_recommendations_public_read (status = 'published') policy,
-- same pattern as postcards_original_collector_read.
create policy community_recommendations_self_read on community_recommendations
  for select using (auth.uid() = author_wayfinder_id);

-- Requires an existing, published Landmark (landmark_id is nullable on
-- the table for system/curated entries, but a player recommendation is
-- always about a real place they think is worth visiting -- "null =
-- system/curated" per the table's own original design). community_id is
-- derived from the Landmark itself, not chosen separately, since a
-- recommendation is inherently about a place that already belongs to a
-- Community.
create or replace function recommend_landmark(p_landmark_id uuid, p_body text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_community_id uuid;
  v_recommendation_id uuid;
begin
  if v_user_id is null then
    raise exception 'must be authenticated to recommend a Landmark';
  end if;
  if p_body is null or length(trim(p_body)) < 10 then
    raise exception 'please explain why this Landmark is worth visiting (at least 10 characters)';
  end if;
  if length(p_body) > 500 then
    raise exception 'recommendation is too long (500 characters max)';
  end if;

  select community_id into v_community_id from landmarks
  where id = p_landmark_id and lifecycle_state in ('seeded', 'published');
  if v_community_id is null then
    raise exception 'Landmark not found or not published';
  end if;

  if exists (
    select 1 from community_recommendations
    where landmark_id = p_landmark_id and author_wayfinder_id = v_user_id and status != 'archived'
  ) then
    raise exception 'you have already recommended this Landmark';
  end if;

  insert into community_recommendations (community_id, landmark_id, author_wayfinder_id, body, status)
  values (v_community_id, p_landmark_id, v_user_id, p_body, 'pending')
  returning id into v_recommendation_id;

  insert into submission_tickets (ticket_type, subject_table, subject_id, submitted_by, status, submitter_notes)
  values ('recommendation', 'community_recommendations', v_recommendation_id, v_user_id, 'open', p_body);

  return v_recommendation_id;
end;
$$;

grant execute on function recommend_landmark(uuid, text) to authenticated;

-- Manual admin decision functions, same lockdown/shape as
-- approve_rumor/reject_rumor -- SQL editor only, not granted to any
-- client role.
create or replace function approve_recommendation(p_ticket_id uuid, p_reviewed_by text, p_notes text default null)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_ticket record;
begin
  select * into v_ticket from submission_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception 'ticket not found';
  end if;
  if v_ticket.ticket_type != 'recommendation' then
    raise exception 'not a recommendation ticket';
  end if;
  if v_ticket.status not in ('open', 'in_review') then
    raise exception 'ticket already resolved';
  end if;
  if p_reviewed_by is null or length(trim(p_reviewed_by)) = 0 then
    raise exception 'reviewed_by is required';
  end if;

  update community_recommendations set status = 'published' where id = v_ticket.subject_id;

  update submission_tickets
  set status = 'approved', resolution_notes = p_notes, reviewed_by = p_reviewed_by, resolved_at = now()
  where id = p_ticket_id;

  return v_ticket.subject_id;
end;
$$;

revoke all on function approve_recommendation(uuid, text, text) from public;

-- Rejection archives rather than deletes -- preserves the submission
-- and reason for audit history, same principle as reject_rumor.
create or replace function reject_recommendation(p_ticket_id uuid, p_reviewed_by text, p_reason text)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_ticket record;
begin
  select * into v_ticket from submission_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception 'ticket not found';
  end if;
  if v_ticket.ticket_type != 'recommendation' then
    raise exception 'not a recommendation ticket';
  end if;
  if v_ticket.status not in ('open', 'in_review') then
    raise exception 'ticket already resolved';
  end if;
  if p_reviewed_by is null or length(trim(p_reviewed_by)) = 0 then
    raise exception 'reviewed_by is required';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a rejection reason is required';
  end if;

  update community_recommendations set status = 'archived' where id = v_ticket.subject_id;

  update submission_tickets
  set status = 'rejected', resolution_notes = p_reason, reviewed_by = p_reviewed_by, resolved_at = now()
  where id = p_ticket_id;

  return v_ticket.subject_id;
end;
$$;

revoke all on function reject_recommendation(uuid, text, text) from public;

-- Published recommendations for everyone, plus the caller's own
-- pending/archived ones (via community_recommendations_self_read
-- above) so a player can see their own submission is awaiting review.
create or replace view community_recommendations_view
  with (security_invoker = true) as
select
  r.id,
  r.community_id,
  c.name as community_name,
  r.landmark_id,
  l.name as landmark_name,
  l.category as landmark_category,
  r.body,
  r.status,
  r.author_wayfinder_id,
  pr.display_name as author_display_name,
  r.created_at
from community_recommendations r
join communities c on c.id = r.community_id
left join landmarks l on l.id = r.landmark_id
left join public_profiles_view pr on pr.id = r.author_wayfinder_id;

grant select on community_recommendations_view to authenticated;
