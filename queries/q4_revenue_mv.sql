-- Q4  REVENUE BY SIGNUP-MONTH COHORT AND PLAN, LAST 90 DAYS   (AFTER: materialized view)
-- mv_daily_revenue (V6) already holds the joined, pre-summed daily numbers.
SELECT m.cohort_month,
       pl.name                                                         AS plan,
       sum(m.payments)                                                 AS payments,
       sum(m.revenue_cents)                                            AS revenue_cents,
       sum(m.refunded_cents)                                           AS refunded_cents,
       round(sum(m.revenue_cents) / nullif(sum(m.succeeded_payments), 0) / 100.0, 2) AS avg_payment
FROM mv_daily_revenue m
JOIN plans pl ON pl.plan_id = m.plan_id
WHERE m.tenant_id = :tenant
  AND m.day >= (now() AT TIME ZONE 'UTC')::date - 90
GROUP BY 1, 2
ORDER BY 1, 2;
