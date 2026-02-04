# Prod DB Migration Runbook (kubectl exec + psql)

This repo currently uses Drizzle SQL migrations under
`core/packages/drizzle/migrations/`.

## Apply a migration on prod

Assuming you can SSH to the cluster node (currently `ubuntu@10.81.16.103`):

```bash
ssh ubuntu@10.81.16.103 'sudo kubectl get pods -o wide'

# Apply a local migration file by piping it to psql inside postgres-0.
cat core/packages/drizzle/migrations/0002_good_epoch.sql | \
  ssh ubuntu@10.81.16.103 \
  'sudo kubectl exec -i postgres-0 -- sh -lc '"'"'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'"'"''

# Verify tables
ssh ubuntu@10.81.16.103 \
  'sudo kubectl exec postgres-0 -- sh -lc '"'"'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\\dt"'"'"''
```

## Common failure: role "root" does not exist

If you run `psql` without specifying `-U` and `-d`, Postgres may default to the
OS username (e.g. `root`) and fail with:

```
FATAL:  role "root" does not exist
```

Fix: always use the Postgres container env vars (set in `deploy/postgres.yaml`):

```bash
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

## Optional: inspect Drizzle migration table

Drizzle migrator uses a migrations table under the `drizzle` schema. A safe
existence check:

```sql
SELECT to_regclass('drizzle.__drizzle_migrations');
```

Note: the argument to `to_regclass` must be a quoted string, otherwise SQL may
parse `drizzle` as an identifier and error.
