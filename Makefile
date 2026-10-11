# Convenience targets. Needs: docker compose (primary path) and python3 with `pip install -r ingest/requirements.txt`.
# Without Docker, point PG* variables at any PostgreSQL 16 and use `make local-*`.
.PHONY: up down migrate clean-migrate roles bulk bench-before bench-after bench-experiments \
        ingest-demo security backup restore-test monitoring-urls local-clean-migrate

up:                ## start postgres, replica, redis, exporters, prometheus, grafana
	docker compose up -d
down:
	docker compose down
migrate:           ## apply pending migrations (Flyway)
	docker compose run --rm flyway migrate
clean-migrate:     ## the lab command: build the schema from an empty database
	docker compose run --rm flyway clean migrate
roles:             ## create ingest_svc / dashboard_svc login roles from .env
	scripts/create_login_roles.sh
bulk:              ## load the ~10M-event benchmark dataset (a few minutes)
	scripts/load_bulk_data.sh
bench-before:      ## baseline = schema at V5
	docker compose run --rm flyway clean
	docker compose run --rm flyway -target=5 migrate
	$(MAKE) bulk
	python3 scripts/benchmark.py --phase before
bench-after:       ## optimised = schema at V7
	docker compose run --rm flyway migrate
	scripts/psql.sh -c "SELECT * FROM refresh_rollups('1970-01-01')" -c "REFRESH MATERIALIZED VIEW mv_daily_revenue"
	scripts/psql.sh -c "VACUUM (ANALYZE) events"
	python3 scripts/benchmark.py --phase after
	python3 scripts/make_report.py
bench-experiments:
	python3 scripts/benchmark.py --experiments
	python3 scripts/make_report.py
ingest-demo:       ## push 200k events through Redis and drain them into PostgreSQL
	python3 ingest/producer.py --count 200000
	python3 ingest/consumer.py --until-empty
security:
	python3 tests/security_check.py
backup:
	scripts/backup.sh
restore-test:
	scripts/restore_test.sh

local-clean-migrate:   ## no Docker: stand-in for flyway on a local PostgreSQL (see scripts/migrate_local.sh)
	scripts/migrate_local.sh clean
