#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

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

[[ $# -eq 1 ]] || usage
[[ -f "$1" ]] || die "Backup not found: $1"
[[ -f "$ROOT_DIR/.env" ]] || die "Run scripts/setup.sh first."

archive=$(readlink -f -- "$1")
archive_dir=${archive%/*}
archive_name=${archive##*/}
checksum_file="${archive}.sha256"

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
command -v tar >/dev/null 2>&1 || die "tar is not installed."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is not installed."

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

staging_dir=$(mktemp -d "$ROOT_DIR/.restore.XXXXXX")
cleanup() {
    rm -rf -- "$staging_dir"
}
trap cleanup EXIT

tar --no-same-owner -xzf "$archive" -C "$staging_dir"
[[ -f "$staging_dir/data/config.ini" ]] || die "Backup does not contain data/config.ini."
[[ -f "$staging_dir/data/groups.json" ]] || die "Backup does not contain data/groups.json."
[[ -d "$staging_dir/data/save" ]] || die "Backup does not contain data/save/."

park_file=$(grep '^PARK_FILE=' "$ROOT_DIR/.env" | tail -n 1 | cut -d= -f2- || true)
park_file=${park_file:-server.park}
[[ -f "$staging_dir/data/save/$park_file" ]] \
    || die "Backup does not contain the configured park: data/save/$park_file"

was_running=0
if [[ -n "$(cd "$ROOT_DIR" && docker compose ps --status running -q server)" ]]; then
    was_running=1
fi

printf 'Creating a safety backup of the current state...\n'
"$ROOT_DIR/scripts/backup.sh"

(cd "$ROOT_DIR" && docker compose stop -t 30 server >/dev/null)

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
previous_data="$ROOT_DIR/backups/pre-restore-data-${timestamp}"
mv "$ROOT_DIR/data" "$previous_data"

if ! mv "$staging_dir/data" "$ROOT_DIR/data"; then
    mv "$previous_data" "$ROOT_DIR/data"
    die "Could not install restored data; the original data was put back."
fi

if [[ $was_running -eq 1 ]]; then
    if ! (cd "$ROOT_DIR" && docker compose up -d server) || ! wait_for_health; then
        failed_data="$ROOT_DIR/backups/failed-restore-data-${timestamp}"
        mv "$ROOT_DIR/data" "$failed_data"
        mv "$previous_data" "$ROOT_DIR/data"
        (cd "$ROOT_DIR" && docker compose up -d server) || true
        die "The restored service did not become healthy; the original data was restored."
    fi
fi

trap - EXIT
cleanup

printf 'Restore complete. Previous raw data remains at: %s\n' "$previous_data"
if [[ $was_running -eq 0 ]]; then
    printf 'The service was previously stopped and remains stopped.\n'
fi
