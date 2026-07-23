-- Deliberately NOT security_invoker, unlike most views in this codebase.
-- postcards_self_rw only lets the CURRENT holder read a postcard row --
-- but a postcard in transit has holder_wayfinder_id set to null, and
-- once delivered it belongs to the recipient, never the sender again.
-- Under security_invoker, joining postcards here would silently drop the
-- postcard's own details (landmark/season/etc.) from the sender's view
-- of their own sent mail the moment it leaves their hands, and from the
-- recipient's view of an undelivered piece of mail addressed to them --
-- the exact same class of bug profile_card_collection_view hit earlier
-- with profile_card_placements' RLS. Running as the view owner instead
-- sidesteps that, which means the `where` clause below is the ONLY
-- access control here (mirroring postcard_mailings_participant_rw's own
-- USING clause) and must never be dropped.
create or replace view postcard_mailings_view as
select
  m.id as mailing_id,
  m.postcard_id,
  m.sender_id,
  sender.display_name as sender_display_name,
  m.recipient_id,
  recipient.display_name as recipient_display_name,
  m.message_kind,
  m.canned_message_key,
  m.message_text,
  m.mailed_at,
  m.delivered_at,
  p.landmark_id,
  l.name as landmark_name,
  p.community_id,
  c.name as community_name,
  p.season,
  p.weather,
  p.time_of_day
from postcard_mailings m
join postcards p on p.id = m.postcard_id
join landmarks l on l.id = p.landmark_id
join communities c on c.id = p.community_id
left join public_profiles_view sender on sender.id = m.sender_id
left join public_profiles_view recipient on recipient.id = m.recipient_id
where auth.uid() in (m.sender_id, m.recipient_id);

grant select on postcard_mailings_view to authenticated;
