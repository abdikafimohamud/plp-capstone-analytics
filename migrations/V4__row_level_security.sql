-- V4__row_level_security.sql
-- Least-privilege roles + Row-Level Security.
--
-- Model:
--   * The migration/owner role (capstone_admin) owns the objects. It is NOT a
--     superuser and the applications never connect as it.
--   * Group roles (NOLOGIN) hold privileges; login roles are created OUTSIDE the
--     migrations (scripts/create_login_roles.sh) so no password is ever in git.
--   * Tenant isolation: every tenant-scoped table has RLS keyed on the session
--     setting app.tenant_id, set per request with set_config('app.tenant_id', $1, true).

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_ingest') THEN
        CREATE ROLE app_ingest NOLOGIN;      -- the Redis -> PostgreSQL consumer
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_dashboard') THEN
        CREATE ROLE app_dashboard NOLOGIN;   -- the read/query API serving dashboards
    END IF;
END $$;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO app_ingest, app_dashboard;

-- The tenant the current request acts for. NULL when unset -> policies match nothing.
CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS int
LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('app.tenant_id', true), '')::int $$;
GRANT EXECUTE ON FUNCTION current_tenant_id() TO app_ingest, app_dashboard;

-- ------------------------------------------------------------------ grants
-- Ingest: write-only on events, may read the two lookup sets it validates against.
GRANT INSERT ON events TO app_ingest;
GRANT USAGE  ON SEQUENCE events_event_id_seq TO app_ingest;
GRANT SELECT ON event_types TO app_ingest;
GRANT SELECT (tenant_id) ON tenants TO app_ingest;      -- column-level: ids only, not names

-- Dashboard: read-only on facts; may manage its own funnel definitions.
GRANT SELECT ON plans, event_types TO app_dashboard;    -- global reference data
GRANT SELECT ON tenants, end_users, events, subscriptions, payments, audit_log TO app_dashboard;
GRANT SELECT, INSERT, UPDATE, DELETE ON funnels, funnel_steps TO app_dashboard;
GRANT USAGE ON SEQUENCE funnels_funnel_id_seq TO app_dashboard;
-- (no INSERT/UPDATE/DELETE on events, payments, subscriptions, audit_log for anyone but the owner)

-- ----------------------------------------------------------- enable RLS
ALTER TABLE tenants       ENABLE ROW LEVEL SECURITY;
ALTER TABLE end_users     ENABLE ROW LEVEL SECURITY;
ALTER TABLE events        ENABLE ROW LEVEL SECURITY;
ALTER TABLE funnels       ENABLE ROW LEVEL SECURITY;
ALTER TABLE funnel_steps  ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log     ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------- policies
-- Dashboard role: only rows of the current tenant.
CREATE POLICY tenant_isolation ON tenants       FOR SELECT TO app_dashboard
    USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_isolation ON end_users     FOR SELECT TO app_dashboard
    USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_isolation ON events        FOR SELECT TO app_dashboard
    USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_isolation ON subscriptions FOR SELECT TO app_dashboard
    USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_isolation ON payments      FOR SELECT TO app_dashboard
    USING (tenant_id = current_tenant_id());
CREATE POLICY tenant_isolation ON audit_log     FOR SELECT TO app_dashboard
    USING (tenant_id = current_tenant_id());

CREATE POLICY tenant_isolation ON funnels FOR ALL TO app_dashboard
    USING      (tenant_id = current_tenant_id())
    WITH CHECK (tenant_id = current_tenant_id());

-- funnel_steps has no tenant_id: it inherits isolation through its parent funnel
CREATE POLICY tenant_isolation ON funnel_steps FOR ALL TO app_dashboard
    USING      (EXISTS (SELECT 1 FROM funnels f
                        WHERE f.funnel_id = funnel_steps.funnel_id
                          AND f.tenant_id = current_tenant_id()))
    WITH CHECK (EXISTS (SELECT 1 FROM funnels f
                        WHERE f.funnel_id = funnel_steps.funnel_id
                          AND f.tenant_id = current_tenant_id()));

-- Ingest role: may append events for any tenant (the consumer serves all tenants)
-- and see the tenant id list; it can never read events back.
CREATE POLICY ingest_append ON events  FOR INSERT TO app_ingest WITH CHECK (true);
CREATE POLICY ingest_ids    ON tenants FOR SELECT TO app_ingest USING (true);

-- NOTE: the table owner and superusers bypass RLS. That is why applications must
-- never connect as the owner (see tests/security_check.sh).
-- NOTE: events is partitioned. Policies on the parent govern queries made through
-- the parent; app roles have no privileges on the partitions themselves, so they
-- cannot bypass RLS by addressing events_2026_10 directly.
