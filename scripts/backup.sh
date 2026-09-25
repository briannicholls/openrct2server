#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BACKUP_DIR="$ROOT_DIR/backups"
was_running=0
restarted=0
leave_stopped=0

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

numeric_env_value() {
    local key=$1
    local fallback=$2
    local value

    value=$(grep -E "^${key}=[0-9]+$" "$ROOT_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2 || true)
    printf '%s' "${value:-$fallback}"
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

restart_on_failure() {
    if [[ $was_running -eq 1 && $restarted -eq 0 ]]; then
        printf 'Restarting the server after backup interruption...\n' >&2
        if (cd "$ROOT_DIR" && docker compose up -d server >/dev/null) && wait_for_health; then
            restarted=1
        else
            printf 'Critical: the server did not recover after the backup interruption.\n' >&2
        fi
    fi
}

if [[ $# -eq 1 && $1 == --leave-stopped ]]; then
    leave_stopped=1
elif [[ $# -ne 0 ]]; then
    printf 'Usage: %s [--leave-stopped]\n' "${0##*/}" >&2
    exit 2
fi

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
command -v tar >/dev/null 2>&1 || die "tar is not installed."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is not installed."
command -v flock >/dev/null 2>&1 || die "flock is not installed."
[[ -f "$ROOT_DIR/.env" ]] || die "Run scripts/setup.sh first."
[[ -d "$ROOT_DIR/data/save" ]] || die "No server data was found."

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
if [[ ${OPENRCT2_OPERATION_LOCKED:-0} != 1 ]]; then
    exec 9> "$BACKUP_DIR/.operation.lock"
    flock -n 9 || die "Another backup, update, or restore is already running."
    export OPENRCT2_OPERATION_LOCKED=1
fi

backup_retention=$(numeric_env_value BACKUP_RETENTION_DAYS 30)
log_retention=$(numeric_env_value LOG_RETENTION_DAYS 14)
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
archive_name="openrct2-${timestamp}.tar.gz"
archive="$BACKUP_DIR/$archive_name"
temporary_archive="${archive}.tmp"

[[ ! -e "$archive" && ! -e "$temporary_archive" ]] || die "A backup for this second already exists; retry shortly."

container_id=$(cd "$ROOT_DIR" && docker compose ps -aq server) \
    || die "Could not inspect the server container."
if [[ -n "$container_id" ]]; then
    container_status=$(docker inspect --format '{{.State.Status}}' "$container_id") \
        || die "Could not inspect the server state."
    case "$container_status" in
        running|restarting)
            was_running=1
            if [[ $leave_stopped -eq 0 ]]; then
                [[ -f "$ROOT_DIR/data/.applied-config.sha256" \
                    && "$(< "$ROOT_DIR/data/.applied-config.sha256")" == "$(sha256sum "$ROOT_DIR/config/config.ini" | cut -d' ' -f1)" ]] \
                    || die "Configuration changes are pending; run scripts/update.sh before a standalone backup."
                [[ -f "$ROOT_DIR/data/.applied-groups.sha256" \
                    && "$(< "$ROOT_DIR/data/.applied-groups.sha256")" == "$(sha256sum "$ROOT_DIR/config/groups.json" | cut -d' ' -f1)" ]] \
                    || die "Group changes are pending; run scripts/update.sh before a standalone backup."
                [[ -f "$ROOT_DIR/data/.applied-entrypoint.sha256" \
                    && "$(< "$ROOT_DIR/data/.applied-entrypoint.sha256")" == "$(sha256sum "$ROOT_DIR/scripts/container-entrypoint.sh" | cut -d' ' -f1)" ]] \
                    || die "Entrypoint changes are pending; run scripts/update.sh before a standalone backup."
                [[ -f "$ROOT_DIR/data/.applied-compose.sha256" \
                    && "$(< "$ROOT_DIR/data/.applied-compose.sha256")" == "$(cd "$ROOT_DIR" && docker compose config | sha256sum | cut -d' ' -f1)" ]] \
                    || die "Deployment changes are pending; run scripts/update.sh before a standalone backup."
                trap restart_on_failure EXIT
            fi
            trap 'exit 130' INT
            trap 'exit 143' TERM
            (cd "$ROOT_DIR" && docker compose stop -t 30 server)
            ;;
    esac
fi

tar \
    --exclude='data/chatlogs' \
    --exclude='data/serverlogs' \
    --exclude='data/*.idx' \
    --exclude='data/.pending-resume-save' \
    --exclude='data/.active-resume-save' \
    --exclude='data/.startup-attempts' \
    -C "$ROOT_DIR" \
    -czf "$temporary_archive" \
    data \
    config \
    .env
mv "$temporary_archive" "$archive"
(
    cd "$BACKUP_DIR"
    sha256sum "$archive_name" > "${archive_name}.sha256"
)
chmod 600 "$archive" "${archive}.sha256"

for log_dir in "$ROOT_DIR/data/chatlogs" "$ROOT_DIR/data/serverlogs"; do
    [[ -d "$log_dir" ]] || continue
    find "$log_dir" -type f -name '*.txt' -mtime +0 -exec gzip -f -- {} +
    find "$log_dir" -type f \( -name '*.txt' -o -name '*.txt.gz' \) -mtime +"$log_retention" -delete
done

find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name 'openrct2-*.tar.gz' -o -name 'openrct2-*.tar.gz.sha256' \) \
    -mtime +"$backup_retention" -delete

if [[ $was_running -eq 1 && $leave_stopped -eq 0 ]]; then
    (cd "$ROOT_DIR" && docker compose up -d server)
    restarted=1
    wait_for_health || die "The server did not become healthy after the backup."
fi
trap - EXIT INT TERM

printf 'Backup created: %s\n' "$archive"
printf 'Copy the archive and checksum off this host.\n'
