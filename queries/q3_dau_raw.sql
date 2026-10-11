-- Q3  DAILY ACTIVE USERS, 7-DAY MOVING AVERAGE, WEEK-OVER-WEEK CHANGE   (BEFORE: raw events)
-- Question: how many distinct users were active each day for the last 30 UTC days?
WITH daily AS (
    SELECT (occurred_at AT TIME ZONE 'UTC')::date AS day,
           count(DISTINCT user_id)                AS dau
    FROM events
    WHERE tenant_id = :tenant
      AND occurred_at >= (((now() AT TIME ZONE 'UTC')::date - 30)::timestamp AT TIME ZONE 'UTC')
      AND occurred_at <  now()
    GROUP BY 1)
SELECT day,
       dau,
       round(avg(dau) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 1) AS dau_7d_avg,
       dau - lag(dau, 7) OVER (ORDER BY day)                                          AS wow_change
FROM daily
ORDER BY day;
