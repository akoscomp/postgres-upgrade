#!/bin/bash
set -Eeuo pipefail

BASE_DIR="/var/lib/postgresql"
DATA_DIR="$BASE_DIR/data"
SOURCE_DIR="$BASE_DIR/data_old"
SOURCE_STAGE="$BASE_DIR/source.staging"
TARGET_STAGE="$BASE_DIR/data.staging"
DUMP_FILE="/tmp/postgres-upgrade.sql"
SOURCE_PORT=55431
TARGET_PORT=55432

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

[[ "${TARGET_VERSION:-}" =~ ^[0-9]+$ ]] || fail "TARGET_VERSION must be a PostgreSQL major version number"
[[ -n "${POSTGRES_USER:-}" ]] || fail "POSTGRES_USER must be set"

RECOVERED_STAGE="$DATA_DIR/data.staging"
if [[ -f "$RECOVERED_STAGE/PG_VERSION" ]]; then
    recovered_version=$(<"$RECOVERED_STAGE/PG_VERSION")
    target_contents=$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n')
    if [[ "$recovered_version" == "$TARGET_VERSION" && "$target_contents" == "data.staging" ]]; then
        [[ ! -e "$BASE_DIR/data.recovered" ]] || fail "Recovery path already exists: $BASE_DIR/data.recovered"
        echo "Promoting the completed PostgreSQL $TARGET_VERSION staged database"
        mv "$RECOVERED_STAGE" "$BASE_DIR/data.recovered"
        rmdir "$DATA_DIR"
        mv "$BASE_DIR/data.recovered" "$DATA_DIR"
        chmod 700 "$DATA_DIR"
        chown -R 999:999 "$DATA_DIR"
        exit 0
    fi
fi

if [[ -f "$DATA_DIR/PG_VERSION" ]]; then
    current_version=$(<"$DATA_DIR/PG_VERSION")
    [[ "$current_version" == "$TARGET_VERSION" ]] && { echo "Database is already at version $TARGET_VERSION"; exit 0; }
    fail "Target directory contains PostgreSQL $current_version data; refusing to overwrite it"
fi

[[ -f "$SOURCE_DIR/PG_VERSION" ]] || fail "No source database found at $SOURCE_DIR/PG_VERSION"
source_version=$(<"$SOURCE_DIR/PG_VERSION")
[[ "$source_version" =~ ^[0-9]+$ ]] || fail "Invalid source PG_VERSION: $source_version"

SOURCE_BIN="/usr/lib/postgresql/$source_version/bin"
TARGET_BIN="/usr/lib/postgresql/$TARGET_VERSION/bin"
[[ -x "$SOURCE_BIN/pg_dumpall" ]] || fail "PostgreSQL $source_version binaries are unavailable"
[[ -x "$TARGET_BIN/initdb" && -x "$TARGET_BIN/pg_ctl" ]] || fail "PostgreSQL $TARGET_VERSION binaries are unavailable"

mkdir -p "$DATA_DIR"
if find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    fail "Target directory $DATA_DIR is not empty; refusing to overwrite it"
fi
[[ ! -e "$SOURCE_STAGE" ]] || fail "Staging path already exists: $SOURCE_STAGE"
[[ ! -e "$TARGET_STAGE" ]] || fail "Staging path already exists: $TARGET_STAGE"

source_started=0
target_started=0
cleanup() {
    if (( target_started )); then
        runuser -u postgres -- "$TARGET_BIN/pg_ctl" -D "$TARGET_STAGE" -m fast -w stop || true
    fi
    if (( source_started )); then
        runuser -u postgres -- "$SOURCE_BIN/pg_ctl" -D "$SOURCE_STAGE" -m fast -w stop || true
    fi
    rm -rf -- "$SOURCE_STAGE" "$TARGET_STAGE" "$DUMP_FILE"
}
trap cleanup EXIT

if [[ "$source_version" == "$TARGET_VERSION" ]]; then
    echo "Copying PostgreSQL $source_version database into the target directory"
    mkdir "$TARGET_STAGE"
    cp -a "$SOURCE_DIR/." "$TARGET_STAGE/"
    rm -f "$TARGET_STAGE/postmaster.pid"
else
    echo "Preparing a working copy of PostgreSQL $source_version"
    mkdir "$SOURCE_STAGE"
    cp -a "$SOURCE_DIR/." "$SOURCE_STAGE/"
    chown -R postgres:postgres "$SOURCE_STAGE"
    chmod 700 "$SOURCE_STAGE"
    rm -f "$SOURCE_STAGE/postmaster.pid"
    printf 'local all all trust\nhost all all 127.0.0.1/32 trust\nhost all all ::1/128 trust\n' > "$SOURCE_STAGE/pg_hba.conf"
    chown postgres:postgres "$SOURCE_STAGE/pg_hba.conf"

    echo "Starting the PostgreSQL $source_version working copy"
    runuser -u postgres -- "$SOURCE_BIN/pg_ctl" -D "$SOURCE_STAGE" \
        -o "-p $SOURCE_PORT -c data_directory=$SOURCE_STAGE -c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp -c hba_file=$SOURCE_STAGE/pg_hba.conf" -w start
    source_started=1

    echo "Dumping databases and roles"
    runuser -u postgres -- "$SOURCE_BIN/pg_dumpall" -h /tmp -p "$SOURCE_PORT" \
        -U "$POSTGRES_USER" > "$DUMP_FILE"
    runuser -u postgres -- "$SOURCE_BIN/pg_ctl" -D "$SOURCE_STAGE" -m fast -w stop
    source_started=0
    rm -rf -- "$SOURCE_STAGE"

    migration_user="migration_$$"
    echo "Initializing staged PostgreSQL $TARGET_VERSION data"
    mkdir "$TARGET_STAGE"
    chown postgres:postgres "$TARGET_STAGE"
    runuser -u postgres -- "$TARGET_BIN/initdb" -D "$TARGET_STAGE" \
        --username="$migration_user" --auth-local=trust --auth-host=scram-sha-256 \
        --encoding=UTF8 --locale=en_US.UTF-8
    printf "\nhost all all 0.0.0.0/0 scram-sha-256\nhost all all ::/0 scram-sha-256\n" >> "$TARGET_STAGE/pg_hba.conf"
    printf "\nlisten_addresses = '*'\n" >> "$TARGET_STAGE/postgresql.conf"

    echo "Starting PostgreSQL $TARGET_VERSION and restoring the dump"
    runuser -u postgres -- "$TARGET_BIN/pg_ctl" -D "$TARGET_STAGE" \
        -o "-p $TARGET_PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp" -w start
    target_started=1
    runuser -u postgres -- "$TARGET_BIN/psql" -h /tmp -p "$TARGET_PORT" \
        -U "$migration_user" -d postgres -X -v ON_ERROR_STOP=1 -f "$DUMP_FILE"
    runuser -u postgres -- "$TARGET_BIN/psql" -h /tmp -p "$TARGET_PORT" \
        -U "$migration_user" -d postgres -X -v ON_ERROR_STOP=1 \
        -c "ALTER DATABASE postgres OWNER TO \"$POSTGRES_USER\"" \
        -c "ALTER DATABASE template0 OWNER TO \"$POSTGRES_USER\"" \
        -c "ALTER DATABASE template1 OWNER TO \"$POSTGRES_USER\""
    runuser -u postgres -- "$TARGET_BIN/psql" -h /tmp -p "$TARGET_PORT" \
        -U "$migration_user" -d postgres -X -v ON_ERROR_STOP=1 \
        -c "ALTER ROLE \"$migration_user\" NOLOGIN"
    runuser -u postgres -- "$TARGET_BIN/pg_ctl" -D "$TARGET_STAGE" -m fast -w stop
    target_started=0
fi

chmod 700 "$TARGET_STAGE"
chown -R 999:999 "$TARGET_STAGE"
rmdir "$DATA_DIR"
mv "$TARGET_STAGE" "$DATA_DIR"
echo "Upgrade to PostgreSQL $TARGET_VERSION completed; source data remains at $SOURCE_DIR"