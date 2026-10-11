#!/usr/bin/env python3
"""Verifies the Day-5 security checklist against a RUNNING database.

  python tests/security_check.py

Connects as the real application login roles (ingest_svc, dashboard_svc) and as
the owner, and PROVES each control rather than reading the schema and hoping.
Exit code 0 only if every check passes.
"""
import os, re, sys
from pathlib import Path

import psycopg2
from psycopg2 import errors

ROOT = Path(__file__).resolve().parent.parent


def load_env():
    env = ROOT / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


load_env()
H = dict(host=os.getenv("PGHOST", "localhost"), port=os.getenv("PGPORT", "5432"),
         dbname=os.getenv("PGDATABASE", "capstone"))


def conn(user, pw):
    c = psycopg2.connect(user=user, password=pw, **H)
    c.autocommit = False
    return c


owner = conn(os.getenv("PGUSER", "capstone_admin"), os.getenv("PGPASSWORD") or os.getenv("ADMIN_PASSWORD"))
ingest = conn("ingest_svc", os.environ["INGEST_PASSWORD"])
dash = conn("dashboard_svc", os.environ["DASHBOARD_PASSWORD"])

results = []


def record(section, name, ok, detail=""):
    results.append((section, name, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  -> {detail}" if detail else ""))


def one(c, sql, params=None):
    with c.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()[0]


def denied(c, sql, params=None, expect=(errors.InsufficientPrivilege,), needle=None):
    """True if the statement is rejected with one of the expected errors
    (and, if given, the error message contains `needle`)."""
    try:
        with c.cursor() as cur:
            cur.execute(sql, params)
        return False
    except expect as e:
        return needle is None or needle in str(e)
    finally:
        c.rollback()


def set_tenant(c, tid):
    with c.cursor() as cur:
        cur.execute("SELECT set_config('app.tenant_id', %s, false)", (str(tid),))   # parameterised
    c.commit()


# ------------------------------------------------------------------------ 1
print("\n1. Least-privilege roles (no app superuser)")
supers = one(owner, "SELECT coalesce(string_agg(rolname, ','), '') FROM pg_roles WHERE rolsuper "
                    "AND rolname IN ('capstone_admin','ingest_svc','dashboard_svc','app_ingest','app_dashboard')")
record(1, "owner and application roles are not superusers", supers == "", supers or "none are superusers")
bypass = one(owner, "SELECT coalesce(string_agg(rolname, ','), '') FROM pg_roles WHERE rolbypassrls "
                    "AND rolname IN ('ingest_svc','dashboard_svc','app_ingest','app_dashboard')")
record(1, "application roles cannot bypass RLS", bypass == "", bypass or "BYPASSRLS not set")
record(1, "dashboard role cannot INSERT into events", denied(dash, "INSERT INTO events (tenant_id,user_id,event_type_id,occurred_at) VALUES (1,1,5,now())"))
record(1, "dashboard role cannot UPDATE payments", denied(dash, "UPDATE payments SET amount_cents = 1"))
record(1, "dashboard role cannot DELETE audit_log rows", denied(dash, "DELETE FROM audit_log"))
record(1, "ingest role cannot READ events", denied(ingest, "SELECT count(*) FROM events"))
record(1, "ingest role cannot read tenant names (column-level grant)", denied(ingest, "SELECT name FROM tenants"))
record(1, "ingest role cannot UPDATE or DELETE events (append-only)",
       denied(ingest, "UPDATE events SET user_id = 0") and denied(ingest, "DELETE FROM events"))
record(1, "dashboard role cannot touch pre-aggregate tables directly",
       denied(dash, "SELECT * FROM agg_user_activity") and denied(dash, "SELECT * FROM mv_daily_revenue"))
record(1, "neither app role can create objects",
       denied(dash, "CREATE TABLE pwn (x int)") and denied(ingest, "CREATE TABLE pwn (x int)"))

# ------------------------------------------------------------------------ 2
print("\n2. Row-Level Security on every multi-tenant / sensitive table")
tenant_tables = ["audit_log", "end_users", "events", "funnel_steps", "funnels", "payments", "subscriptions", "tenants"]
with owner.cursor() as cur:
    cur.execute("SELECT relname FROM pg_class WHERE relrowsecurity AND relnamespace = 'public'::regnamespace ORDER BY 1")
    enabled = [r[0] for r in cur.fetchall()]
missing = [t for t in tenant_tables if t not in enabled]
record(2, "RLS enabled on all 8 tenant-scoped tables", not missing, "enabled: " + ",".join(enabled) if not missing else "MISSING: " + ",".join(missing))

set_tenant(dash, 1)
own = one(dash, "SELECT count(*) FROM end_users")
expected = one(owner, "SELECT count(*) FROM end_users WHERE tenant_id = 1")
record(2, "tenant 1 sees exactly its own users", own == expected, f"{own} rows (owner count for tenant 1: {expected})")
other = one(dash, "SELECT count(*) FROM end_users WHERE tenant_id = 2")
record(2, "tenant 1 cannot read tenant 2 (explicit WHERE tenant_id = 2)", other == 0, f"{other} rows")
other_ev = one(dash, "SELECT count(*) FROM events WHERE tenant_id = 2 AND occurred_at > now() - interval '1 day'")
record(2, "same isolation on the partitioned events table", other_ev == 0, f"{other_ev} rows")
vis = one(dash, "SELECT count(DISTINCT tenant_id) FROM payments")
record(2, "payments: only one tenant visible", vis == 1, f"{vis} distinct tenant(s)")
set_tenant(dash, 2)
vis_view = one(dash, "SELECT count(*) FROM v_user_activity WHERE tenant_id <> 2")
mine_view = one(dash, "SELECT count(*) FROM v_user_activity")
record(2, "pre-aggregate views are tenant-filtered too", vis_view == 0 and mine_view > 0,
       f"{vis_view} foreign rows, {mine_view} own rows via v_user_activity")
dash.rollback()
with dash.cursor() as cur:
    cur.execute("SELECT set_config('app.tenant_id', '', false)")
none_set = one(dash, "SELECT count(*) FROM end_users")
record(2, "no tenant set -> no rows (fail closed)", none_set == 0, f"{none_set} rows")
set_tenant(dash, 1)
record(2, "cannot write a funnel for another tenant (RLS WITH CHECK)",
       denied(dash, "INSERT INTO funnels (tenant_id, name) VALUES (2, 'sneaky')", needle="row-level security"))
own_funnel_ok = True
try:
    with dash.cursor() as cur:
        cur.execute("INSERT INTO funnels (tenant_id, name) VALUES (1, 'rls-test funnel')")
except Exception as e:
    own_funnel_ok = False
dash.rollback()
record(2, "...but can write one for its own tenant", own_funnel_ok, "insert accepted, then rolled back")
try:
    with ingest.cursor() as cur:
        cur.execute("INSERT INTO events (tenant_id,user_id,event_type_id,occurred_at) VALUES (1, 1, 5, now())")
    ingest_ok = True
except Exception as e:
    ingest_ok = False
ingest.rollback()
record(2, "ingest role can append events (RLS INSERT policy)", ingest_ok, "insert accepted, then rolled back")

# ------------------------------------------------------------------------ 3
print("\n3. Sensitive fields hashed / encrypted")
cols = one(owner, "SELECT coalesce(string_agg(column_name, ','), '') FROM information_schema.columns "
                  "WHERE table_schema='public' AND (column_name ILIKE '%email%' OR column_name ILIKE '%password%')")
record(3, "no plaintext email/password column exists", cols == "email_hash", cols)
bad = one(owner, "SELECT count(*) FROM end_users WHERE email_hash IS NOT NULL AND octet_length(email_hash) <> 32")
record(3, "every email_hash is a 32-byte HMAC-SHA256", bad == 0, f"{bad} malformed")
# NB: do not scan the hash bytes for '@': a random 32-byte digest contains byte 0x40 ~12% of the time.
# Instead look for email-shaped text in every human-readable column of end_users.
leak = one(owner, "SELECT count(*) FROM end_users WHERE external_id ~ '@' "
                  "OR acquisition_channel ~ '@' OR country_code ~ '@'")
record(3, "no email-shaped plaintext in end_users text columns", leak == 0, f"{leak} rows contain '@'")
pe = one(owner, "SELECT current_setting('password_encryption')")
record(3, "role passwords are stored as SCRAM-SHA-256 verifiers (not md5/plain)", pe == "scram-sha-256", f"password_encryption={pe}")

# ------------------------------------------------------------------------ 4
print("\n4. Audit log on critical tables")
with owner.cursor() as cur:
    before = one(owner, "SELECT count(*) FROM audit_log WHERE table_name='tenants' AND operation='U'")
    cur.execute("UPDATE tenants SET name = name || ' (audit test)' WHERE tenant_id = 1")
    after = one(owner, "SELECT count(*) FROM audit_log WHERE table_name='tenants' AND operation='U'")
    cur.execute("SELECT old_row ->> 'name', new_row ->> 'name', changed_by FROM audit_log "
                "WHERE table_name='tenants' AND operation='U' ORDER BY audit_id DESC LIMIT 1")
    old, new, who = cur.fetchone()
owner.rollback()
record(4, "UPDATE on tenants writes an audit row (old + new image + who)",
       after == before + 1 and new == old + " (audit test)", f"changed_by={who}")
triggers = one(owner, "SELECT string_agg(DISTINCT c.relname, ',' ORDER BY c.relname) FROM pg_trigger t "
                      "JOIN pg_class c ON c.oid=t.tgrelid WHERE NOT t.tgisinternal AND t.tgname LIKE '%_audit'")
record(4, "audit triggers on tenants, plans, subscriptions, payments",
       triggers == "payments,plans,subscriptions,tenants", triggers)
record(4, "audit_log is append-only even for the owner (UPDATE/DELETE blocked)",
       denied(owner, "DELETE FROM audit_log", expect=(psycopg2.errors.RaiseException,)) and
       denied(owner, "UPDATE audit_log SET table_name='x'", expect=(psycopg2.errors.RaiseException,)))

# ------------------------------------------------------------------------ 5
print("\n5. Parameterized queries only")
bad_lines = []
pat = re.compile(r"""(execute|copy_expert|executemany)\s*\(\s*(f["']|["'][^"']*["']\s*(%|\+)|[^,)]*\.format\()""")
for py in list((ROOT / "ingest").glob("*.py")) + list((ROOT / "scripts").glob("*.py")) + [ROOT / "tests/security_check.py"]:
    for n, line in enumerate(py.read_text().splitlines(), 1):
        if pat.search(line):
            bad_lines.append(f"{py.relative_to(ROOT)}:{n}")
record(5, "no f-string / % / + / .format() SQL passed to execute() in application code",
       not bad_lines, ", ".join(bad_lines) or "scanned ingest/*.py and scripts/*.py")
inj = "1; DROP TABLE events; --"
try:
    with dash.cursor() as cur:
        cur.execute("SELECT count(*) FROM end_users WHERE external_id = %s", (inj,))
        cnt = cur.fetchone()[0]
    ok = cnt == 0 and one(owner, "SELECT to_regclass('events') IS NOT NULL")
except Exception as e:
    ok = False
dash.rollback()
record(5, "injection probe is treated as plain data", ok, f"payload {inj!r} matched 0 rows, events table intact")

# ------------------------------------------------------------------------ 6
print("\n6. Backups taken AND a test restore performed")
dumps = sorted((ROOT / "backups").glob("capstone_*.dump"))
record(6, "a pg_dump -Fc backup exists", bool(dumps), dumps[-1].name if dumps else "run scripts/backup.sh")
rlog = ROOT / "backups" / "restore_test.log"
passed = rlog.exists() and "RESULT: PASS" in rlog.read_text()
record(6, "last restore test passed", passed, "backups/restore_test.log" if passed else "run scripts/restore_test.sh")

# ---------------------------------------------------------------- summary
print()
fails = [r for r in results if not r[2]]
print(f"{len(results) - len(fails)}/{len(results)} checks passed")
for c in (owner, ingest, dash):
    c.close()
sys.exit(1 if fails else 0)
