-- Q2  ROLLING 7-DAY AND 30-DAY RETENTION BY WEEKLY SIGNUP COHORT   (AFTER: rollup)
-- Identical result. "Active on or after day N" is exactly "last_event_at >= signup + N days",
-- and last_event_at is maintained incrementally in agg_user_activity (V6), so the
-- 10M-row events table is never touched.
SELECT date_trunc('week', u.signup_at AT TIME ZONE 'UTC')::date                      AS cohort_week,
       count(*)                                                                      AS cohort_size,
       count(*) FILTER (WHERE u.signup_at <= now() - interval '7 days')              AS eligible_d7,
       count(*) FILTER (WHERE ua.last_event_at >= u.signup_at + interval '7 days')   AS retained_d7,
       round(100.0 * count(*) FILTER (WHERE ua.last_event_at >= u.signup_at + interval '7 days')
             / nullif(count(*) FILTER (WHERE u.signup_at <= now() - interval '7 days'), 0), 1) AS d7_pct,
       count(*) FILTER (WHERE u.signup_at <= now() - interval '30 days')             AS eligible_d30,
       count(*) FILTER (WHERE ua.last_event_at >= u.signup_at + interval '30 days')  AS retained_d30,
       round(100.0 * count(*) FILTER (WHERE ua.last_event_at >= u.signup_at + interval '30 days')
             / nullif(count(*) FILTER (WHERE u.signup_at <= now() - interval '30 days'), 0), 1) AS d30_pct
FROM end_users u
LEFT JOIN agg_user_activity ua ON ua.tenant_id = u.tenant_id AND ua.user_id = u.user_id
WHERE u.tenant_id = :tenant
GROUP BY 1
ORDER BY 1;
