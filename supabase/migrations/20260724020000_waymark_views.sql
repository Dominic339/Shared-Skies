-- One-row-always balance summary for the calling wayfinder, split by
-- source so the client can show the gold/silver breakdown without
-- summing raw lot rows itself. security_invoker relies purely on
-- currency_lots_self_read to scope this to the caller's own lots --
-- COALESCE covers the zero-lots case (aggregates with no GROUP BY always
-- return exactly one row, even over zero matching rows).
create or replace view wallet_balance_view
  with (security_invoker = true) as
select
  coalesce(sum(remaining_amount) filter (where source_type = 'paid'), 0) as paid_balance,
  coalesce(sum(remaining_amount) filter (where source_type != 'paid'), 0) as earned_balance,
  coalesce(sum(remaining_amount), 0) as total_balance
from currency_lots;

grant select on wallet_balance_view to authenticated;

-- Operation-level history (not per-lot allocation detail -- that's an
-- implementation detail the player doesn't need to see) for a simple
-- transaction list. security_invoker relies on wallet_operations_self_read.
create or replace view wallet_history_view
  with (security_invoker = true) as
select id, operation_type, total_amount, context_type, description, created_at
from wallet_operations;

grant select on wallet_history_view to authenticated;
