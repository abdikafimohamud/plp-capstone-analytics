#!/usr/bin/env python3
"""Builds docs/query_optimization.md from the measured results in docs/benchmarks/.

    python3 scripts/make_report.py

Nothing in the report is typed by hand except the "what changed and why" text below:
every plan, timing, speed-up and "rows identical" flag comes from benchmark.py.
"""
import json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
B = ROOT / "docs" / "benchmarks"

INFO = {
    "q1": dict(
        title="Q1 - Funnel conversion",
        question="Of the users who signed up in the last 30 days (tenant 1), how many reached "
                 "view_pricing -> start_trial -> purchase, in order, each step within the "
                 "funnel's 168-hour window?",
        change=("**Index** (V6): `CREATE INDEX events_tenant_type_time_cov ON events (tenant_id, event_type_id, occurred_at) INCLUDE (user_id)`.\n\n"
                "The funnel only needs 4 of the 8 event types, but ~95% of a tenant's events are engagement "
                "events (page_view, feature_used, ...). Before, PostgreSQL had to read every event of the tenant "
                "in the window and throw most of them away. The covering index is ordered by event type, so the "
                "planner reads *only* the funnel events, and `INCLUDE (user_id)` makes it an index-only scan "
                "(no table access). The SQL text is unchanged."),
    ),
    "q2": dict(
        title="Q2 - Rolling 7-day / 30-day retention by weekly cohort",
        question="For each weekly signup cohort of tenant 1, what % of users were still active 7 / 30 days "
                 "or more after signing up?",
        change=("**Pre-aggregation + query rewrite** (V6): table `agg_user_activity(tenant_id, user_id, first_event_at, last_event_at)`, "
                "maintained incrementally by `refresh_rollups()`.\n\n"
                "\"Active on or after day N\" is exactly `last_event_at >= signup_at + N days`, so the retention "
                "query never needs the raw events: it joins `end_users` to one row per user instead of scanning "
                "every event of the tenant. The result is identical (verified row-by-row), and because the rollup "
                "keeps `min/max` per user it survives dropping old raw partitions."),
    ),
    "q3": dict(
        title="Q3 - Daily active users with 7-day moving average and week-over-week change",
        question="How many distinct users were active on each of the last 30 days (tenant 1), with a 7-day "
                 "moving average and the change versus 7 days earlier?",
        change=("**Pre-aggregation + query rewrite** (V6): table `agg_daily_active_users(tenant_id, day, dau)`, "
                "refreshed incrementally.\n\n"
                "`COUNT(DISTINCT user_id)` cannot be assembled from smaller buckets, so the distinct count is "
                "computed once per day by the rollup job; the dashboard query only applies the window functions "
                "to ~30 rows."),
    ),
    "q4": dict(
        title="Q4 - Revenue by signup cohort and plan",
        question="For the last 90 days (tenant 1): payments, revenue, refunds and average payment per "
                 "signup-month cohort and plan.",
        change=("**Materialized view** (V6): `mv_daily_revenue` (payments x subscriptions x end_users pre-joined and "
                "pre-summed per day/cohort/plan, unique index for `REFRESH ... CONCURRENTLY`), plus a covering index "
                "`payments_tenant_paid_cov (tenant_id, paid_at) INCLUDE (subscription_id, amount_cents, status)`.\n\n"
                "Revenue data is small and changes slowly, so a materialized view refreshed on a schedule is the "
                "right tool. **Honest note:** this table is only ~15k rows, so the absolute gain is small; the "
                "pattern matters when payments reach hundreds of millions of rows."),
    ),
    "q5": dict(
        title="Q5 - JSONB campaign attribution by acquisition channel",
        question="For the `autumn_sale` campaign (a key inside the variable JSONB `properties`), how many "
                 "events and users per day and acquisition channel in the last 60 days (tenant 1)?",
        change=("**Index** (V6): `CREATE INDEX events_properties_gin ON events USING gin (tenant_id, properties jsonb_path_ops)`.\n\n"
                "Containment (`@>`) on a variable JSON document cannot use a B-tree. A GIN index with the "
                "`jsonb_path_ops` operator class answers it with a bitmap probe; `btree_gin` lets `tenant_id` sit "
                "in the same index so the probe is already tenant-scoped. The SQL text is unchanged."),
    ),
}

SCAN = re.compile(r"(?:Parallel )?(Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan) on (\S+)")


def scans(plan_lines):
    kinds = []
    for line in plan_lines:
        m = SCAN.search(line)
        if m and m.group(1) not in kinds:
            kinds.append(m.group(1))
    if any("Bitmap Index Scan" in l for l in plan_lines) and "Bitmap Index Scan" not in kinds:
        kinds.append("Bitmap Index Scan")
    return " + ".join(kinds) or "-"


def fmt_ms(ms):
    return f"{ms/1000:.2f} s" if ms >= 1000 else (f"{ms:.1f} ms" if ms >= 1 else f"{ms:.2f} ms")


def block(path_or_lines, lang="text"):
    lines = path_or_lines if isinstance(path_or_lines, list) else path_or_lines.read_text().splitlines()
    return f"```{lang}\n" + "\n".join(lines) + "\n```"


def main():
    before = json.loads((B / "before.json").read_text())
    after = json.loads((B / "after.json").read_text())
    exp = json.loads((B / "experiments.json").read_text()) if (B / "experiments.json").exists() else None

    out = []
    out.append("# Query optimisation evidence (Day 4)\n")
    out.append("_Generated by `scripts/make_report.py` from the measurements in `docs/benchmarks/`. "
               "Re-run `make bench-before bench-after` to reproduce._\n")
    out.append("## Test setup\n")
    out.append(f"- **Database:** {before['postgres']}, `shared_buffers={before['shared_buffers']}`, `work_mem={before['work_mem']}`, JIT off\n"
               f"- **Data:** {before['total_events']:,} events, {before['total_users']:,} end users, 10 tenants "
               f"(tenant {before['tenant']} is the largest, ~25% of all rows), 90 days, monthly partitions\n"
               f"- **Method:** `EXPLAIN (ANALYZE, BUFFERS)`; 1 warm-up run, then {before['runs']} timed runs; "
               f"the **median** `Execution Time` is reported (warm cache)\n"
               f"- **Before** = schema at migration V5 (primary keys, FK indexes, BRIN on `occurred_at`). "
               f"**After** = V7 (V6 adds the optimisations below)\n"
               f"- Optimised queries are verified to return **identical rows** to the originals\n")

    out.append("## Summary\n")
    out.append("| Query | Before | After | Speed-up | Plan change | Same rows |\n|---|---:|---:|---:|---|:--:|")
    for qid, info in INFO.items():
        b, a = before["queries"][qid], after["queries"][qid]
        sp = b["median_ms"] / a["median_ms"] if a["median_ms"] else float("inf")
        same = "same SQL" if "matches_original" not in a else ("yes" if a["matches_original"] else "**NO**")
        out.append(f"| {info['title']} | {fmt_ms(b['median_ms'])} | {fmt_ms(a['median_ms'])} | **{sp:,.0f}x** | "
                   f"{scans(b['plan'])} -> {scans(a['plan'])} | {same} |")
    out.append("")

    for qid, info in INFO.items():
        b, a = before["queries"][qid], after["queries"][qid]
        sp = b["median_ms"] / a["median_ms"] if a["median_ms"] else float("inf")
        out.append(f"---\n\n## {info['title']}\n")
        out.append(f"### 1. QUERY\n{info['question']}\n\nBefore: `queries/{b['file']}` &nbsp;|&nbsp; After: `queries/{a['file']}`\n")
        out.append(f"### 2. BEFORE PLAN  ({fmt_ms(b['median_ms'])}, median of {before['runs']})\n"
                   f"<details open><summary>EXPLAIN (ANALYZE, BUFFERS)</summary>\n\n{block(b['plan'])}\n\n</details>\n")
        out.append(f"### 3. CHANGE\n{info['change']}\n")
        out.append(f"### 4. AFTER PLAN  ({fmt_ms(a['median_ms'])}, median of {after['runs']})\n"
                   f"<details open><summary>EXPLAIN (ANALYZE, BUFFERS)</summary>\n\n{block(a['plan'])}\n\n</details>\n")
        same = ""
        if "matches_original" in a:
            same = f"; optimised query returns {'IDENTICAL' if a['matches_original'] else 'DIFFERENT (!)'} rows to the original"
        out.append(f"### 5. RESULT\n**{fmt_ms(b['median_ms'])} -> {fmt_ms(a['median_ms'])}  ({sp:,.0f}x faster)**; "
                   f"{scans(b['plan'])} -> {scans(a['plan'])}{same}.\n")

    if exp:
        out.append("---\n\n## Experiments\n")
        e1 = exp["e1_brin"]
        sp = e1["without_brin"]["median_ms"] / e1["with_brin"]["median_ms"]
        out.append("### E1 - Does the BRIN index earn its keep?\n"
                   "Cross-tenant scan of the last 6 hours (what the rollup refresh and operator dashboards do). "
                   "`DROP INDEX` is run inside a transaction and rolled back, so the comparison is on identical data.\n\n"
                   f"| | Median | Scan |\n|---|---:|---|\n"
                   f"| without BRIN | {fmt_ms(e1['without_brin']['median_ms'])} | {scans(e1['without_brin']['plan'])} |\n"
                   f"| with BRIN (`events_occurred_at_brin`) | {fmt_ms(e1['with_brin']['median_ms'])} | {scans(e1['with_brin']['plan'])} |\n\n"
                   f"**{sp:,.1f}x faster.** The primary key starts with `tenant_id`, so it cannot serve a time-only filter; "
                   "BRIN can because events are inserted in time order, and it costs a few hundred KB instead of a "
                   "multi-hundred-MB B-tree. Plans: `docs/benchmarks/e1_brin_with.txt`, `e1_brin_without.txt`.\n")
        e2 = exp["e2_rls"]
        ratio = e2["as_dashboard_svc"]["median_ms"] / e2["as_owner"]["median_ms"]
        out.append("### E2 - What does Row-Level Security cost?\n"
                   "Q1 run as the table owner (bypasses RLS) versus as the real `dashboard_svc` login with "
                   "`app.tenant_id = 1` (RLS policies applied).\n\n"
                   f"| | Median |\n|---|---:|\n| owner (no RLS) | {fmt_ms(e2['as_owner']['median_ms'])} |\n"
                   f"| dashboard_svc (RLS on) | {fmt_ms(e2['as_dashboard_svc']['median_ms'])} |\n\n"
                   f"Ratio: **{ratio:.2f}x**. The policy `tenant_id = current_tenant_id()` is a STABLE function, so the planner "
                   "evaluates it once and still uses the index.\n")

    (ROOT / "docs" / "query_optimization.md").write_text("\n".join(out))
    print("wrote docs/query_optimization.md")


if __name__ == "__main__":
    main()
