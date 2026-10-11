-- Q4  REVENUE BY SIGNUP-MONTH COHORT AND PLAN, LAST 90 DAYS   (BEFORE: 3-table join)
-- Question: which signup cohorts and plans generate the revenue; how much was refunded?
SELECT date_trunc('month', u.signup_at AT TIME ZONE 'UTC')::date                    AS cohort_month,
       pl.name                                                                       AS plan,
       count(*)                                                                      AS payments,
       coalesce(sum(p.amount_cents) FILTER (WHERE p.status = 'succeeded'), 0)        AS revenue_cents,
       coalesce(sum(p.amount_cents) FILTER (WHERE p.status = 'refunded'),  0)        AS refunded_cents,
       round(coalesce(sum(p.amount_cents) FILTER (WHERE p.status = 'succeeded'), 0)
             / nullif(count(*) FILTER (WHERE p.status = 'succeeded'), 0) / 100.0, 2) AS avg_payment
FROM payments p
JOIN subscriptions s ON s.subscription_id = p.subscription_id
JOIN end_users u     ON u.tenant_id = s.tenant_id AND u.user_id = s.user_id
JOIN plans pl        ON pl.plan_id = s.plan_id
WHERE p.tenant_id = :tenant
  AND p.paid_at >= (((now() AT TIME ZONE 'UTC')::date - 90)::timestamp AT TIME ZONE 'UTC')
GROUP BY 1, 2
ORDER BY 1, 2;
