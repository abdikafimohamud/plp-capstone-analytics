-- V7__retention_policy.sql
-- Retention policy: RAW events are kept 90 days, aggregates are kept forever.
--
-- Why partition-drop instead of DELETE: dropping a month-partition is instant and
-- creates no dead tuples / WAL / vacuum work; DELETE of 100M rows would take hours
-- and bloat the table.
--
-- "Compression" in plain PostgreSQL: old partitions are archived as compressed
-- custom-format dumps before dropping (scripts/archive_partition.sh, pg_dump -Fc
-- compresses with zlib). With TimescaleDB the equivalent is native columnar
-- compression (add_compression_policy) - see docs/architecture.md.
--
-- Safety: a partition is only dropped when the rollups have already consumed it
-- (rollup_state.watermark >= partition upper bound).

CREATE OR REPLACE FUNCTION enforce_events_retention(
    p_keep    interval DEFAULT interval '90 days',
    p_dry_run boolean  DEFAULT true)
RETURNS TABLE (partition_name text, upper_bound timestamptz, action text)
LANGUAGE plpgsql AS $$
DECLARE
    r    record;
    v_wm timestamptz;
BEGIN
    SELECT watermark INTO v_wm FROM rollup_state WHERE name = 'events_rollups';

    FOR r IN
        SELECT c.relname::text AS relname,
               substring(pg_get_expr(c.relpartbound, c.oid) FROM 'TO \(''([^'']+)''\)')::timestamptz AS ub
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'events'::regclass
          AND c.relname <> 'events_default'
        ORDER BY 2
    LOOP
        partition_name := r.relname;
        upper_bound    := r.ub;
        IF r.ub >= now() - p_keep THEN
            action := 'keep (inside retention window)';
        ELSIF v_wm IS NULL OR v_wm < r.ub THEN
            action := 'SKIPPED: rollups have not consumed this partition yet';
        ELSIF p_dry_run THEN
            action := 'would drop (dry run)';
        ELSE
            EXECUTE format('ALTER TABLE events DETACH PARTITION %I', r.relname);
            EXECUTE format('DROP TABLE %I', r.relname);
            action := 'dropped';
        END IF;
        RETURN NEXT;
    END LOOP;
END $$;

-- One entry point for cron / the ingest service (call every few minutes):
--   SELECT * FROM run_maintenance();         -- partitions + rollups + health check
--   SELECT * FROM run_maintenance(true);     -- ... and actually drop expired partitions
CREATE OR REPLACE FUNCTION run_maintenance(p_apply_retention boolean DEFAULT false)
RETURNS TABLE (task text, detail text)
LANGUAGE plpgsql AS $$
DECLARE
    v_created int;
    v_stray   bigint;
    r         record;
BEGIN
    v_created := ensure_events_partitions(current_date, (current_date + interval '3 months')::date);
    task := 'partitions_created'; detail := v_created::text; RETURN NEXT;

    FOR r IN SELECT * FROM refresh_rollups() LOOP
        task := 'rollup:' || r.step; detail := r.rows_affected::text; RETURN NEXT;
    END LOOP;

    SELECT count(*) INTO v_stray FROM events_default;
    task := 'default_partition_rows';
    detail := CASE WHEN v_stray = 0 THEN '0 (ok)'
                   ELSE v_stray || ' WARNING: events outside every partition - create the missing partition' END;
    RETURN NEXT;

    FOR r IN SELECT * FROM enforce_events_retention(interval '90 days', NOT p_apply_retention)
             WHERE action NOT LIKE 'keep%' LOOP
        task := 'retention:' || r.partition_name; detail := r.action; RETURN NEXT;
    END LOOP;
END $$;
