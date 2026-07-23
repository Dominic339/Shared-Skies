-- Removes the original flat-balance Waymark system (waymark_balances +
-- waymark_transactions), superseded by the lot-based ledger
-- (currency_lots/wallet_operations/wallet_transactions) added a few
-- migrations ago. Verified before writing this migration:
--   - no other migration, SQL function/view/trigger, or client code
--     anywhere in the repo references either table (only the original
--     schema migration that created them ever mentions their names);
--   - no foreign key from any other table points at either of them;
--   - their own trigger instances (trg_waymark_balances_updated_at,
--     trg_audit_waymark_balances) are dedicated to this table alone, but
--     the FUNCTIONS those triggers call (set_updated_at(), record_audit_log())
--     are shared by a dozen-plus other tables and must NOT be dropped --
--     only the two trigger instances themselves are legacy-specific.
--   - audit_log rows already recorded against waymark_balances (if any --
--     it was never wired to any code path that would have written to it)
--     are left alone deliberately: an audit trail should never be deleted
--     just because the table it once described is gone.
--
-- No CASCADE anywhere below -- every dependent object is dropped
-- explicitly, in dependency order (policies and triggers before the
-- tables they're attached to), so nothing unexpected can be silently
-- swept away by a cascading drop.
do $$
begin
  if exists (select 1 from waymark_balances limit 1)
     or exists (select 1 from waymark_transactions limit 1) then
    raise exception
      'waymark_balances/waymark_transactions still have rows -- archive or migrate them before running this cleanup, do not drop blind';
  end if;
end;
$$;

drop policy if exists waymark_balances_self_read on waymark_balances;
drop policy if exists waymark_transactions_self_read on waymark_transactions;

drop trigger if exists trg_waymark_balances_updated_at on waymark_balances;
drop trigger if exists trg_audit_waymark_balances on waymark_balances;

drop table waymark_transactions;
drop table waymark_balances;
