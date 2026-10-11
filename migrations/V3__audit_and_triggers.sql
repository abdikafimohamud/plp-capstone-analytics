-- V3__audit_and_triggers.sql
-- Audit trail for the critical (money / account) tables.
-- events is NOT audited: it is append-only and far too high-volume; append-only is
-- enforced with privileges in V4 (application roles get INSERT but never UPDATE/DELETE).

CREATE OR REPLACE FUNCTION audit_row_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER                       -- app roles have no privilege on audit_log
SET search_path = public, pg_temp      -- hardening: a definer function must pin its search_path
AS $$
DECLARE
    v_old jsonb;
    v_new jsonb;
    v_row jsonb;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_new := to_jsonb(NEW);  v_row := v_new;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW IS NOT DISTINCT FROM OLD THEN
            RETURN NULL;               -- no-op update, nothing to record
        END IF;
        v_old := to_jsonb(OLD);  v_new := to_jsonb(NEW);  v_row := v_new;
    ELSE
        v_old := to_jsonb(OLD);  v_row := v_old;
    END IF;

    INSERT INTO audit_log (tenant_id, table_name, operation, row_pk, old_row, new_row, changed_by)
    VALUES (nullif(v_row ->> 'tenant_id', '')::int,
            TG_TABLE_NAME,
            left(TG_OP, 1),
            v_row ->> TG_ARGV[0],      -- TG_ARGV[0] = primary-key column name
            v_old,
            v_new,
            session_user);             -- the real login, not the definer
    RETURN NULL;                       -- AFTER trigger: return value ignored
END $$;

CREATE TRIGGER tenants_audit       AFTER INSERT OR UPDATE OR DELETE ON tenants
    FOR EACH ROW EXECUTE FUNCTION audit_row_change('tenant_id');
CREATE TRIGGER plans_audit         AFTER INSERT OR UPDATE OR DELETE ON plans
    FOR EACH ROW EXECUTE FUNCTION audit_row_change('plan_id');
CREATE TRIGGER subscriptions_audit AFTER INSERT OR UPDATE OR DELETE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION audit_row_change('subscription_id');
CREATE TRIGGER payments_audit      AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION audit_row_change('payment_id');

-- The audit log itself is tamper-evident: nobody (not even the owner) can edit or
-- delete rows through normal DML.
CREATE OR REPLACE FUNCTION audit_log_immutable()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only (% blocked)', TG_OP;
END $$;

CREATE TRIGGER audit_log_no_update_delete
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_immutable();
