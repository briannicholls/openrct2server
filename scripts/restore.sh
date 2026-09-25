#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STAGING_DIR=
PREVIOUS_STATE=
ROLLBACK_NEEDED=0
WAS_RUNNING=0

usage() {
    printf 'Usage: %s <openrct2-backup.tar.gz>\n' "${0##*/}" >&2
    exit 2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

wait_for_health() {
    local container_id
    local health

    container_id=$(cd "$ROOT_DIR" && docker compose ps -q server)
    [[ -n "$container_id" ]] || return 1

    for _ in {1..24}; do
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")
        case "$health" in
            healthy) return 0 ;;
            unhealthy|exited|dead) return 1 ;;
        esac
        sleep 5
    done

    return 1
}

stop_server() {
    local container_id
    local status

    if ! (cd "$ROOT_DIR" && docker compose stop -t 30 server >/dev/null 2>&1); then
        (cd "$ROOT_DIR" && docker compose kill server >/dev/null 2>&1) || return 1
    fi
    container_id=$(cd "$ROOT_DIR" && docker compose ps -aq server) || return 1
    [[ -n "$container_id" ]] || return 0
    status=$(docker inspect --format '{{.State.Status}}' "$container_id") || return 1
    case "$status" in
        running|restarting)
            (cd "$ROOT_DIR" && docker compose kill server >/dev/null 2>&1) || return 1
            status=$(docker inspect --format '{{.State.Status}}' "$container_id") || return 1
            [[ "$status" != running && "$status" != restarting ]] || return 1
            ;;
    esac
}

rollback() {
    local status=$?
    local failed_data
    local recovery_ok=1

    if [[ $ROLLBACK_NEEDED -eq 1 ]]; then
        printf 'Restore failed; putting the previous state back...\n' >&2
        if stop_server; then
            if [[ -n "$PREVIOUS_STATE" && -d "$PREVIOUS_STATE/data" ]]; then
                if [[ -d "$ROOT_DIR/data" ]]; then
                    failed_data="$ROOT_DIR/backups/failed-restore-data-$(date -u +%Y%m%dT%H%M%SZ)"
                    mv "$ROOT_DIR/data" "$failed_data" || recovery_ok=0
                fi
                mv "$PREVIOUS_STATE/data" "$ROOT_DIR/data" || recovery_ok=0
            fi
            if [[ -n "$PREVIOUS_STATE" && -f "$PREVIOUS_STATE/config/config.ini" ]]; then
                install -m 644 "$PREVIOUS_STATE/config/config.ini" "$ROOT_DIR/config/config.ini" || recovery_ok=0
                install -m 644 "$PREVIOUS_STATE/config/groups.json" "$ROOT_DIR/config/groups.json" || recovery_ok=0
                install -m 600 "$PREVIOUS_STATE/.env" "$ROOT_DIR/.env" || recovery_ok=0
            fi
        else
            recovery_ok=0
        fi
        if [[ $WAS_RUNNING -eq 1 && $recovery_ok -eq 1 ]]; then
            rm -f -- \
                "$ROOT_DIR/data/.pending-resume-save" \
                "$ROOT_DIR/data/.active-resume-save" \
                "$ROOT_DIR/data/.startup-attempts"
            if ! (cd "$ROOT_DIR" && docker compose up -d --force-recreate server >/dev/null) \
                || ! wait_for_health; then
                recovery_ok=0
            fi
        fi
        if [[ $recovery_ok -eq 0 ]]; then
            printf 'Critical: automatic restore rollback did not recover the prior server.\n' >&2
        fi
    fi

    [[ -z "$STAGING_DIR" ]] || rm -rf -- "$STAGING_DIR"
    exit "$status"
}

set_env_value_in_file() {
    local file=$1
    local key=$2
    local value=$3

    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

[[ $# -eq 1 ]] || usage
[[ -f "$1" ]] || die "Backup not found: $1"
[[ -f "$ROOT_DIR/.env" ]] || die "Run scripts/setup.sh first."
[[ -f "$ROOT_DIR/config/config.ini" ]] || die "Missing config/config.ini."
[[ -f "$ROOT_DIR/config/groups.json" ]] || die "Missing config/groups.json."
[[ -d "$ROOT_DIR/data" ]] || die "No current server data was found."

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
command -v flock >/dev/null 2>&1 || die "flock is not installed."
command -v tar >/dev/null 2>&1 || die "tar is not installed."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is not installed."

mkdir -p "$ROOT_DIR/backups"
chmod 700 "$ROOT_DIR/backups"
exec 9> "$ROOT_DIR/backups/.operation.lock"
flock -n 9 || die "Another backup, update, or restore is already running."
export OPENRCT2_OPERATION_LOCKED=1

archive=$(readlink -f -- "$1")
archive_dir=${archive%/*}
archive_name=${archive##*/}
checksum_file="${archive}.sha256"

if [[ -f "$checksum_file" ]]; then
    (
        cd "$archive_dir"
        sha256sum -c "${archive_name}.sha256"
    )
else
    printf 'Warning: no checksum file found at %s\n' "$checksum_file" >&2
fi

archive_listing=$(tar -tzf "$archive")
if grep -Eq '(^/|(^|/)\.\.(/|$))' <<< "$archive_listing"; then
    die "The archive contains an unsafe path."
fi

STAGING_DIR=$(mktemp -d "$ROOT_DIR/.restore.XXXXXX")
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tar --no-same-owner -xzf "$archive" -C "$STAGING_DIR"
[[ -d "$STAGING_DIR/data/save" ]] || die "Backup does not contain data/save/."

has_new_config=0
has_new_groups=0
has_new_env=0
[[ ! -f "$STAGING_DIR/config/config.ini" ]] || has_new_config=1
[[ ! -f "$STAGING_DIR/config/groups.json" ]] || has_new_groups=1
[[ ! -f "$STAGING_DIR/.env" ]] || has_new_env=1

if [[ $has_new_config -eq 1 && $has_new_groups -eq 1 && $has_new_env -eq 1 ]]; then
    restore_config="$STAGING_DIR/config/config.ini"
    restore_groups="$STAGING_DIR/config/groups.json"
    restore_env="$STAGING_DIR/.env"
elif [[ $has_new_config -eq 1 || $has_new_groups -eq 1 || $has_new_env -eq 1 ]]; then
    die "Backup contains an incomplete new-format configuration."
elif [[ -f "$STAGING_DIR/data/config.ini" && -f "$STAGING_DIR/data/groups.json" ]]; then
    printf 'Restoring a legacy data-only backup with the current deployment settings.\n'
    restore_config="$STAGING_DIR/data/config.ini"
    restore_groups="$STAGING_DIR/data/groups.json"
    restore_env="$ROOT_DIR/.env"
else
    die "Backup does not contain a complete server configuration."
fi

cp "$restore_config" "$STAGING_DIR/restore-config.ini"
cp "$restore_groups" "$STAGING_DIR/restore-groups.json"
cp "$restore_env" "$STAGING_DIR/restore.env"
current_puid=$(grep '^PUID=[0-9]\+$' "$ROOT_DIR/.env" | tail -n 1 | cut -d= -f2 || true)
current_pgid=$(grep '^PGID=[0-9]\+$' "$ROOT_DIR/.env" | tail -n 1 | cut -d= -f2 || true)
set_env_value_in_file "$STAGING_DIR/restore.env" PUID "${current_puid:-$(id -u)}"
set_env_value_in_file "$STAGING_DIR/restore.env" PGID "${current_pgid:-$(id -g)}"

park_file=$(grep '^PARK_FILE=' "$STAGING_DIR/restore.env" | tail -n 1 | cut -d= -f2- || true)
park_file=${park_file:-server.park}
[[ -f "$STAGING_DIR/data/save/$park_file" ]] \
    || die "Backup does not contain the configured park: data/save/$park_file"

container_id=$(cd "$ROOT_DIR" && docker compose ps -aq server) \
    || die "Could not inspect the server container."
if [[ -n "$container_id" ]]; then
    container_status=$(docker inspect --format '{{.State.Status}}' "$container_id") \
        || die "Could not inspect the server state."
    case "$container_status" in
        running|restarting) WAS_RUNNING=1 ;;
    esac
fi

printf 'Creating a safety backup of the current state...\n'
ROLLBACK_NEEDED=1
"$ROOT_DIR/scripts/backup.sh" --leave-stopped

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
PREVIOUS_STATE="$ROOT_DIR/backups/pre-restore-state-${timestamp}"
if [[ -n "$container_id" ]]; then
    stop_server || die "Could not stop the server safely for restore."
fi

mkdir -p "$PREVIOUS_STATE/config"
cp "$ROOT_DIR/config/config.ini" "$PREVIOUS_STATE/config/config.ini"
cp "$ROOT_DIR/config/groups.json" "$PREVIOUS_STATE/config/groups.json"
cp "$ROOT_DIR/.env" "$PREVIOUS_STATE/.env"
mv "$ROOT_DIR/data" "$PREVIOUS_STATE/data"

mv "$STAGING_DIR/data" "$ROOT_DIR/data"
install -m 644 "$STAGING_DIR/restore-config.ini" "$ROOT_DIR/config/config.ini"
install -m 644 "$STAGING_DIR/restore-groups.json" "$ROOT_DIR/config/groups.json"
install -m 600 "$STAGING_DIR/restore.env" "$ROOT_DIR/.env"

if [[ $WAS_RUNNING -eq 1 ]]; then
    rm -f -- \
        "$ROOT_DIR/data/.pending-resume-save" \
        "$ROOT_DIR/data/.active-resume-save" \
        "$ROOT_DIR/data/.startup-attempts"
    (cd "$ROOT_DIR" && docker compose up -d --force-recreate server)
    wait_for_health || die "The restored service did not become healthy."
    (cd "$ROOT_DIR" && docker compose config) \
        | sha256sum | cut -d' ' -f1 > "$ROOT_DIR/data/.applied-compose.sha256"
    chmod 600 "$ROOT_DIR/data/.applied-compose.sha256"
    mkdir -p "$ROOT_DIR/data/.last-known-good"
    install -m 600 "$ROOT_DIR/config/config.ini" "$ROOT_DIR/data/.last-known-good/config.ini"
    install -m 600 "$ROOT_DIR/config/groups.json" "$ROOT_DIR/data/.last-known-good/groups.json"
    install -m 600 "$ROOT_DIR/.env" "$ROOT_DIR/data/.last-known-good/env"
    install -m 600 "$ROOT_DIR/compose.yaml" "$ROOT_DIR/data/.last-known-good/compose.yaml"
    install -m 700 "$ROOT_DIR/scripts/container-entrypoint.sh" \
        "$ROOT_DIR/data/.last-known-good/container-entrypoint.sh"
fi

ROLLBACK_NEEDED=0
trap - EXIT INT TERM
rm -rf -- "$STAGING_DIR"

printf 'Restore complete. Previous state remains at: %s\n' "$PREVIOUS_STATE"
if [[ $WAS_RUNNING -eq 0 ]]; then
    printf 'The service was previously stopped and remains stopped.\n'
fi
