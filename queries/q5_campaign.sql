-- Q5  JSONB CAMPAIGN ATTRIBUTION BY CHANNEL
-- Question: for the "autumn_sale" campaign (a key inside the variable JSONB
--           properties), how many events and users per day and acquisition channel?
-- The same statement is benchmarked before and after: the optimisation is the GIN index.
SELECT (e.occurred_at AT TIME ZONE 'UTC')::date                      AS day,
       u.acquisition_channel                                         AS channel,
       count(*)                                                      AS campaign_events,
       count(DISTINCT e.user_id)                                     AS users,
       count(*) FILTER (WHERE e.properties @> '{"device": "mobile"}') AS mobile_events
FROM events e
JOIN end_users u ON u.tenant_id = e.tenant_id AND u.user_id = e.user_id
WHERE e.tenant_id = :tenant
  AND e.properties @> '{"campaign": "autumn_sale"}'
  AND e.occurred_at >= now() - interval '60 days'
  AND e.occurred_at <  now()
GROUP BY 1, 2
ORDER BY 1, 2;
