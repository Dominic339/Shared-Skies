-- rumor_landmarks_view's LEFT JOIN to submission_tickets (added in
-- 20260748000000, to surface a Rumor's attached photo_ref) was silently
-- returning null for every single row regardless of whether a photo
-- was actually attached -- submission_tickets has no SELECT policy at
-- all for regular players (same class of gap landmark_sources hit
-- earlier this project), so security_invoker's RLS check on the join
-- target failed for every caller, and a LEFT JOIN just returns nulls
-- rather than erroring or dropping the row. Confirmed live: a fresh
-- Rumor submitted with a real uploaded photo still came back with
-- photo_ref = null from rumor_landmarks_view.
--
-- Scoped to landmark_submission tickets whose Landmark is still an
-- open Rumor -- once approved (lifecycle_state -> published) or the
-- underlying Rumor is otherwise no longer relevant to investigate,
-- this policy simply stops matching; it never needs to reach into
-- other ticket types (recommendations, reports, etc).
create policy submission_tickets_rumor_read on submission_tickets
  for select using (
    ticket_type = 'landmark_submission'
    and exists (
      select 1 from landmarks l
      where l.id = submission_tickets.subject_id and l.lifecycle_state = 'rumor'
    )
  );
