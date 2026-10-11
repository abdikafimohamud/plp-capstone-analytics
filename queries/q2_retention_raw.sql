-- Q2  ROLLING 7-DAY AND 30-DAY RETENTION BY WEEKLY SIGNUP COHORT   (BEFORE: raw events)
-- Question: of the users who signed up in each week, what percentage were still active
--           7 / 30 days or more after signing up? ("rolling" / unbounded retention:
--           the user has ANY event on or after day N.)
-- Only users old enough to be measured count in a denominator.
WITH last_seen AS (
    SELECT user_id, max(occurred_at) AS last_event_at
    FROM events
    WHERE tenant_id = :tenant
    GROUP BY user_id)
SELECT date_trunc('week', u.signup_at AT TIME ZONE 'UTC')::date                      AS cohort_week,
       count(*)                                                                      AS cohort_size,
       count(*) FILTER (WHERE u.signup_at <= now() - interval '7 days')              AS eligible_d7,
       count(*) FILTER (WHERE ls.last_event_at >= u.signup_at + interval '7 days')   AS retained_d7,
       round(100.0 * count(*) FILTER (WHERE ls.last_event_at >= u.signup_at + interval '7 days')
             / nullif(count(*) FILTER (WHERE u.signup_at <= now() - interval '7 days'), 0), 1) AS d7_pct,
       count(*) FILTER (WHERE u.signup_at <= now() - interval '30 days')             AS eligible_d30,
       count(*) FILTER (WHERE ls.last_event_at >= u.signup_at + interval '30 days')  AS retained_d30,
       round(100.0 * count(*) FILTER (WHERE ls.last_event_at >= u.signup_at + interval '30 days')
             / nullif(count(*) FILTER (WHERE u.signup_at <= now() - interval '30 days'), 0), 1) AS d30_pct
FROM end_users u
LEFT JOIN last_seen ls ON ls.user_id = u.user_id
WHERE u.tenant_id = :tenant
GROUP BY 1
ORDER BY 1;
