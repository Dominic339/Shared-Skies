-- Call latency, captured at the moment it happens -- can't be
-- reconstructed later from anything else, unlike most other metrics
-- (which can be derived from landmarks/enrichment_runs after the fact).
alter table enrichment_runs add column duration_ms integer;
