#!/usr/bin/env python3
"""Benchmark the five analytical queries with EXPLAIN (ANALYZE, BUFFERS).

  scripts/benchmark.py --phase before     # database migrated to V5 (baseline)
  scripts/benchmark.py --phase after      # database migrated to V7 (optimised)
  scripts/benchmark.py --experiments      # BRIN on/off, RLS overhead (needs V7)

For every query: 1 warm-up run, then RUNS timed runs; reports the median
"Execution Time" that PostgreSQL itself measures. In the 'after' phase it also runs
the original query and checks that both return IDENTICAL rows.

Connection: PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE (or a .env file).
Queries use psql-style :tenant placeholders; they are sent as bound parameters
(psycopg2 %(tenant)s), never by string concatenation.
"""
import argparse, json, os, re, statistics, sys
from pathlib import Path

import psycopg2
from psycopg2 import sql as pgsql   # composable SQL: the sanctioned way to prepend EXPLAIN

ROOT = Path(__file__).resolve().parent.parent
QDIR = ROOT / "queries"
OUT = ROOT / "docs" / "benchmarks"
TENANT = 1          # the largest tenant (~25% of all events)
RUNS = 5

QUERIES = [
    dict(id="q1", title="Q1  Funnel conversion (signup -> pricing -> trial -> purchase)",
         before="q1_funnel.sql", after="q1_funnel.sql"),
    dict(id="q2", title="Q2  Rolling 7-day / 30-day retention by weekly cohort",
         before="q2_retention_raw.sql", after="q2_retention_rollup.sql"),
    dict(id="q3", title="Q3  Daily active users with 7-day average and WoW change",
         before="q3_dau_raw.sql", after="q3_dau_rollup.sql"),
    dict(id="q4", title="Q4  Revenue by signup cohort and plan (last 90 days)",
         before="q4_revenue_raw.sql", after="q4_revenue_mv.sql"),
    dict(id="q5", title="Q5  JSONB campaign attribution by acquisition channel",
         before="q5_campaign.sql", after="q5_campaign.sql"),
]


def load_env():
    env = ROOT / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def connect():
    load_env()
    return psycopg2.connect(
        host=os.getenv("PGHOST", "localhost"), port=os.getenv("PGPORT", "5432"),
        user=os.getenv("PGUSER", "capstone_admin"), dbname=os.getenv("PGDATABASE", "capstone"),
        password=os.getenv("PGPASSWORD") or os.getenv("ADMIN_PASSWORD"))


def sql_for(fname):
    text = (QDIR / fname).read_text()
    return re.sub(r"(?<!:):tenant\b", "%(tenant)s", text)      # :tenant -> bound parameter


def explain(cur, sql):
    cur.execute(pgsql.SQL("EXPLAIN (ANALYZE, BUFFERS) ") + pgsql.SQL(sql), {"tenant": TENANT})
    lines = [r[0] for r in cur.fetchall()]
    exec_ms = float(re.search(r"Execution Time: ([\d.]+) ms", "\n".join(lines)).group(1))
    plan_ms = float(re.search(r"Planning Time: ([\d.]+) ms", "\n".join(lines)).group(1))
    return lines, exec_ms, plan_ms


def rows_of(cur, sql):
    cur.execute(sql, {"tenant": TENANT})
    return [tuple(str(c) for c in row) for row in cur.fetchall()]


def timed(cur, sql):
    explain(cur, sql)                                   # warm-up (fills caches)
    times, last = [], None
    for _ in range(RUNS):
        lines, ms, plan_ms = explain(cur, sql)
        times.append(ms)
        last = (lines, plan_ms)
    return dict(median_ms=round(statistics.median(times), 3), min_ms=min(times),
                max_ms=max(times), runs_ms=times, planning_ms=last[1], plan=last[0])


def run_phase(phase):
    conn = connect(); conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET jit = off")                        # JIT compile time is noise at this scale
    cur.execute("SELECT version(), current_setting('shared_buffers'), current_setting('work_mem'), "
                "(SELECT count(*) FROM events), (SELECT count(*) FROM end_users)")
    version, sb, wm, n_events, n_users = cur.fetchone()
    result = dict(phase=phase, tenant=TENANT, runs=RUNS, postgres=version.split(",")[0],
                  shared_buffers=sb, work_mem=wm, total_events=n_events, total_users=n_users,
                  queries={})
    for q in QUERIES:
        sql = sql_for(q[phase])
        r = timed(cur, sql)
        r["file"] = q[phase]
        r["rows"] = rows_of(cur, sql)
        if phase == "after" and q["before"] != q["after"]:
            r["matches_original"] = (rows_of(cur, sql_for(q["before"])) == r["rows"])
        print(f"{q['id']} {phase:6s} median {r['median_ms']:>10.2f} ms   "
              f"(min {r['min_ms']:.2f}, max {r['max_ms']:.2f})"
              + (f"   same rows as original: {r['matches_original']}" if "matches_original" in r else ""))
        result["queries"][q["id"]] = r
        (OUT / phase).mkdir(parents=True, exist_ok=True)
        (OUT / phase / f"{q['id']}.txt").write_text(
            f"-- {q['title']}\n-- file: queries/{q[phase]}   tenant_id={TENANT}   median of {RUNS} runs: "
            f"{r['median_ms']} ms\n\n" + "\n".join(r["plan"]) + "\n")
    (OUT / f"{phase}.json").write_text(json.dumps(result, indent=2))
    conn.close()


def run_experiments():
    load_env()
    conn = connect(); conn.autocommit = False
    cur = conn.cursor()
    cur.execute("SET jit = off")
    out = {}

    # ---- E1: BRIN on / off (DDL is transactional -> drop, measure, ROLLBACK)
    sql = sql_for("e1_brin_scan.sql")
    with_brin = timed(cur, sql)
    cur.execute("DROP INDEX events_occurred_at_brin")
    without_brin = timed(cur, sql)
    conn.rollback()                                      # the index is back
    out["e1_brin"] = dict(with_brin=with_brin, without_brin=without_brin)
    print(f"E1 BRIN   with {with_brin['median_ms']} ms | without {without_brin['median_ms']} ms")
    (OUT / "e1_brin_with.txt").write_text("\n".join(with_brin["plan"]) + "\n")
    (OUT / "e1_brin_without.txt").write_text("\n".join(without_brin["plan"]) + "\n")

    # ---- E2: cost of Row-Level Security (same query as owner vs as the real dashboard login)
    sql = sql_for("q1_funnel.sql")
    as_owner = timed(cur, sql)
    dash = psycopg2.connect(host=os.getenv("PGHOST", "localhost"), port=os.getenv("PGPORT", "5432"),
                            dbname=os.getenv("PGDATABASE", "capstone"), user="dashboard_svc",
                            password=os.environ["DASHBOARD_PASSWORD"])
    dash.autocommit = True
    dcur = dash.cursor()
    dcur.execute("SET jit = off")
    dcur.execute("SELECT set_config('app.tenant_id', %s, false)", (str(TENANT),))   # parameterised
    as_rls = timed(dcur, sql)
    dash.close()
    conn.rollback()
    out["e2_rls"] = dict(as_owner=as_owner, as_dashboard_svc=as_rls)
    print(f"E2 RLS    owner {as_owner['median_ms']} ms | dashboard_svc (RLS on) {as_rls['median_ms']} ms")
    (OUT / "e2_rls_plan.txt").write_text("\n".join(as_rls["plan"]) + "\n")

    (OUT / "experiments.json").write_text(json.dumps(out, indent=2))
    conn.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", choices=["before", "after"])
    ap.add_argument("--experiments", action="store_true")
    a = ap.parse_args()
    if a.phase:
        run_phase(a.phase)
    elif a.experiments:
        run_experiments()
    else:
        ap.print_help(); sys.exit(1)
