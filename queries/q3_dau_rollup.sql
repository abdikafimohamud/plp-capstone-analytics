-- Q3  DAILY ACTIVE USERS, 7-DAY MOVING AVERAGE, WEEK-OVER-WEEK CHANGE   (AFTER: rollup)
-- DISTINCT counts cannot be summed from smaller buckets, so DAU is stored per day
-- (agg_daily_active_users, V6) and only the window functions run at query time.
WITH daily AS (
    SELECT day, dau
    FROM agg_daily_active_users
    WHERE tenant_id = :tenant
      AND day >= (now() AT TIME ZONE 'UTC')::date - 30)
SELECT day,
       dau,
       round(avg(dau) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 1) AS dau_7d_avg,
       dau - lag(dau, 7) OVER (ORDER BY day)                                          AS wow_change
FROM daily
ORDER BY day;
