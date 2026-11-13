# PostgreSQL Upgrade

This project migrates a PostgreSQL data directory to a newer major version using a logical dump and restore. The source cluster is copied to a staging directory and mounted read-only; the live target is written separately.

## Requirements

- Docker Engine and the Docker Compose plugin
- A complete, offline copy of the source PostgreSQL data directory
- A source superuser name that can connect to the copied cluster
- A target major version supported by the upgrader image (PostgreSQL 12 through 18 in the included Dockerfile)

## Configure

Create the Compose environment file:

```sh
cp sample.env .env
```

Edit `.env`:

```dotenv
POSTGRES_TARGET_VERSION=17
POSTGRES_USER=postgres
POSTGRES_PASSWORD=replace-with-a-strong-password
POSTGRES_DB=postgres
```

`POSTGRES_TARGET_VERSION` is the target PostgreSQL major version, not the upgrader image tag. Set `POSTGRES_USER` to a superuser that exists in the source cluster. The dump restores the source roles and databases; these variables do not rename or recreate them.

The Compose file uses the published `akoscomp/postgres-upgrade:18` helper image. To build the helper from this checkout instead, build it with the same tag before starting Compose:

```sh
docker build -t akoscomp/postgres-upgrade:18 ./postgres-upgrade
```

## Prepare the Source

1. Stop the source PostgreSQL server cleanly. Do not copy a live data directory.
2. Make a complete copy of its data directory at `data/postgres-old/`. `PG_VERSION` must be directly inside this directory, for example `data/postgres-old/PG_VERSION`.
3. Keep the copy intact until the target has been verified and separately backed up.
4. Ensure `data/postgres/data/` is absent or empty. The upgrader refuses to overwrite an existing target cluster.

The source directory is mounted read-only at `/var/lib/postgresql/data_old`. The target cluster is written to `data/postgres/data/` and mounted by the PostgreSQL service at `/var/lib/postgresql/data`.

## Run the Migration

Start the project from this directory:

```sh
docker compose up -d
```

Compose runs `postgres-upgrade` first and starts `postgres` only after the migration container exits successfully. Follow progress with:

```sh
docker compose logs -f postgres-upgrade
docker compose ps -a
```

The upgrader makes a working copy of the source, runs `pg_dumpall`, initializes the target version, restores databases and roles, and then promotes the completed target directory. The original source copy is not changed. A failed migration should leave the source available for another attempt; inspect the logs and target directory before retrying. Do not delete the source copy or staging data as a first troubleshooting step.

## Verify

Check the target version and restored databases. Replace `postgres` with a valid source superuser if needed:

```sh
docker compose exec postgres psql -U postgres -d postgres \
  -c 'SHOW server_version;' \
  -c '\l'
```

After confirming the application works, take a fresh backup of the target and retain the original source copy according to your backup policy.

## Collation Compatibility

The helper image is Debian-based and uses glibc. Avoid using an Alpine target image for a cluster initialized by this helper: Alpine uses musl, whose locale/collation behavior and version reporting differ. Those differences can produce PostgreSQL collation-version warnings and may affect indexes used for text sorting or comparison. Use the standard Debian-based `postgres:<major>` image unless the helper is deliberately changed to use a matching locale implementation.

Do not run `ALTER DATABASE ... REFRESH COLLATION VERSION` merely to silence a warning. Rebuild affected collation-dependent indexes first, then refresh the recorded version.

## Network and Credentials

The target cluster configuration accepts SCRAM-authenticated TCP connections from IPv4 and IPv6 addresses. Restrict network reachability with Docker networks and host firewall rules; do not expose the database publicly without additional controls. The `POSTGRES_PASSWORD` environment value does not replace passwords restored from the source cluster.

The upgrader creates a temporary bootstrap superuser for the restore and marks it `NOLOGIN` afterward. PostgreSQL requires its bootstrap role to remain in the cluster.