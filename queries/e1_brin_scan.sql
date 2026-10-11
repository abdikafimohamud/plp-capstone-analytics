-- E1  BRIN EXPERIMENT: cross-tenant time-range scan (what the rollup refresh and
--     operator dashboards do).  Run with and without the BRIN index from V2.
SELECT event_type_id, count(*) AS events, count(DISTINCT tenant_id) AS tenants
FROM events
WHERE occurred_at >= now() - interval '6 hours'
  AND occurred_at <  now()
GROUP BY 1
ORDER BY 1;
