-- 20260746000000 was edited (facing_degrees changed from "not null
-- default 0" to nullable/no-default) after it had already been run once
-- with the original definition -- re-running the edited copy hit
-- "column already exists" on its add column statement, since the
-- column (and the views built on top of it) were already live from
-- that first run. This finishes the edit's actual intent without
-- re-adding anything already there.
alter table landmarks alter column facing_degrees drop default;
alter table landmarks alter column facing_degrees drop not null;

-- Every existing row currently has facing_degrees = 0 only because that
-- was the old column default, not a real hand-picked orientation --
-- this feature only just landed, nothing has had a chance to be
-- manually tuned yet. Clearing it back to null lets these Landmarks
-- immediately pick up automatic road-facing too, instead of being
-- stuck facing due north forever.
update landmarks set facing_degrees = null where facing_degrees = 0;
