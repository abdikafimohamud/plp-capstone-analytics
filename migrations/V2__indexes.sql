-- V2__indexes.sql
-- BASELINE indexes: what a sensible first version of the schema needs.
-- The query-specific optimisations (covering index, GIN, rollups) are deliberately
-- NOT here: they arrive in V6 so that Day 4 can show real before/after evidence.

-- ------------------------------------------------------------------ events
-- BRIN: events arrive in time order, so occurred_at is physically correlated with
-- row position. A BRIN index is ~1000x smaller than a B-tree and lets cross-tenant
-- time-range scans (rollup refresh, operator dashboards) skip most of a partition.
CREATE INDEX events_occurred_at_brin
    ON events USING brin (occurred_at) WITH (pages_per_range = 32);

-- ------------------------------------------------------- dimension / FK lookups
CREATE INDEX tenants_plan_id_idx        ON tenants (plan_id);
CREATE INDEX end_users_signup_idx       ON end_users (tenant_id, signup_at);
CREATE INDEX funnel_steps_event_type_ix ON funnel_steps (event_type_id);

CREATE INDEX subscriptions_user_idx     ON subscriptions (tenant_id, user_id);
CREATE INDEX subscriptions_status_idx   ON subscriptions (tenant_id, status);
CREATE INDEX subscriptions_plan_idx     ON subscriptions (plan_id);

CREATE INDEX payments_subscription_idx  ON payments (subscription_id);

CREATE INDEX audit_log_tenant_time_idx  ON audit_log (tenant_id, changed_at);
CREATE INDEX audit_log_row_idx          ON audit_log (table_name, row_pk);
