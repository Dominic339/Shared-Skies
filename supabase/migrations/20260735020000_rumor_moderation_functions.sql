-- Manual admin decision functions -- called from the Supabase SQL editor
-- (running as the postgres role, which already has full privileges) for
-- now, not exposed to anon/authenticated at all. Neither is granted to
-- any client role, matching the same lockdown as award_waymarks -- a
-- player must never be able to approve/reject their own or anyone
-- else's submission.
--
-- Usage from the SQL editor:
--   select approve_rumor('<ticket_id>');
--   select reject_rumor('<ticket_id>', 'reason for rejection');

-- Promotes the Rumor's existing landmarks row in place rather than
-- creating a new one -- "approval creates or promotes the real
-- Landmark" is satisfied by the SAME row simply changing state, since
-- lifecycle_state/publication_state were always tracked on it from
-- submission onward.
create or replace function approve_rumor(p_ticket_id uuid, p_notes text default null)
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
  if v_ticket.ticket_type != 'landmark_submission' then
    raise exception 'not a landmark submission ticket';
  end if;
  if v_ticket.status not in ('open', 'in_review') then
    raise exception 'ticket already resolved';
  end if;

  update landmarks
  set lifecycle_state = 'published', publication_state = 'published'
  where id = v_ticket.subject_id;

  update submission_tickets
  set status = 'approved', resolution_notes = p_notes, resolved_at = now()
  where id = p_ticket_id;

  return v_ticket.subject_id;
end;
$$;

revoke all on function approve_rumor(uuid, text) from public;

-- Rejection preserves the submission (landmarks row + landmark_sources +
-- the ticket itself) rather than deleting anything -- lifecycle_state
-- moves to 'rejected', publication_state stays 'draft' (it was never
-- published and shouldn't be), and the reason is required so there's
-- always an audit trail for why.
create or replace function reject_rumor(p_ticket_id uuid, p_reason text)
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
  if v_ticket.ticket_type != 'landmark_submission' then
    raise exception 'not a landmark submission ticket';
  end if;
  if v_ticket.status not in ('open', 'in_review') then
    raise exception 'ticket already resolved';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a rejection reason is required';
  end if;

  update landmarks set lifecycle_state = 'rejected' where id = v_ticket.subject_id;

  update submission_tickets
  set status = 'rejected', resolution_notes = p_reason, resolved_at = now()
  where id = p_ticket_id;

  return v_ticket.subject_id;
end;
$$;

revoke all on function reject_rumor(uuid, text) from public;
