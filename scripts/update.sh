#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LAST_GOOD_DIR="$ROOT_DIR/data/.last-known-good"
ROLLBACK_DIR=
ROLLBACK_NEEDED=0

usage() {
    printf 'Usage: %s [park-file]\n' "${0##*/}" >&2
    exit 2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

env_value() {
    local key=$1
    local fallback=${2:-}
    local value

    value=$(grep "^${key}=" "$ROOT_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
    printf '%s' "${value:-$fallback}"
}

set_env_value() {
    local key=$1
    local value=$2

    if grep -q "^${key}=" "$ROOT_DIR/.env"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ROOT_DIR/.env"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ROOT_DIR/.env"
    fi
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

store_last_good() {
    local staging
    local previous="${LAST_GOOD_DIR}.old.$$"

    staging=$(mktemp -d "$ROOT_DIR/data/.last-known-good.new.XXXXXX") || return 1
    if ! install -m 600 "$ROOT_DIR/config/config.ini" "$staging/config.ini" \
        || ! install -m 600 "$ROOT_DIR/config/groups.json" "$staging/groups.json" \
        || ! install -m 600 "$ROOT_DIR/.env" "$staging/env" \
        || ! install -m 600 "$ROOT_DIR/compose.yaml" "$staging/compose.yaml" \
        || ! install -m 700 "$ROOT_DIR/scripts/container-entrypoint.sh" \
            "$staging/container-entrypoint.sh"; then
        rm -rf -- "$staging"
        return 1
    fi

    if [[ -d "$LAST_GOOD_DIR" ]] && ! mv "$LAST_GOOD_DIR" "$previous"; then
        rm -rf -- "$staging"
        return 1
    fi
    if mv "$staging" "$LAST_GOOD_DIR"; then
        rm -rf -- "$previous"
        return 0
    fi

    [[ ! -d "$previous" ]] || mv "$previous" "$LAST_GOOD_DIR" || true
    rm -rf -- "$staging"
    return 1
}

rollback() {
    local status=$?
    local rejected_save
    local recovery_ok=1

    if [[ $ROLLBACK_NEEDED -eq 1 ]]; then
        printf 'Update failed; restoring the previous configuration and park...\n' >&2
        install -m 644 "$ROLLBACK_DIR/config.ini" "$ROOT_DIR/config/config.ini" || recovery_ok=0
        install -m 644 "$ROLLBACK_DIR/groups.json" "$ROOT_DIR/config/groups.json" || recovery_ok=0
        install -m 600 "$ROLLBACK_DIR/env" "$ROOT_DIR/.env" || recovery_ok=0
        install -m 644 "$ROLLBACK_DIR/compose.yaml" "$ROOT_DIR/compose.yaml" || recovery_ok=0
        install -m 755 "$ROLLBACK_DIR/container-entrypoint.sh" \
            "$ROOT_DIR/scripts/container-entrypoint.sh" || recovery_ok=0

        if [[ $recovery_ok -eq 1 ]] && stop_server; then
            if [[ -d "$ROLLBACK_DIR/save" ]]; then
                rejected_save="$ROLLBACK_DIR/rejected-save"
                if [[ -d "$ROOT_DIR/data/save" ]] && ! mv "$ROOT_DIR/data/save" "$rejected_save"; then
                    recovery_ok=0
                elif ! mv "$ROLLBACK_DIR/save" "$ROOT_DIR/data/save"; then
                    recovery_ok=0
                    [[ ! -d "$rejected_save" ]] || mv "$rejected_save" "$ROOT_DIR/data/save" || true
                fi
            fi
        else
            recovery_ok=0
        fi

        if [[ $recovery_ok -eq 1 ]]; then
            rm -f -- \
                "$ROOT_DIR/data/.pending-resume-save" \
                "$ROOT_DIR/data/.active-resume-save" \
                "$ROOT_DIR/data/.startup-attempts"
            if ! (cd "$ROOT_DIR" && docker compose up -d --force-recreate server >/dev/null) \
                || ! wait_for_health; then
                recovery_ok=0
            else
                if ! (cd "$ROOT_DIR" && docker compose config) \
                    | sha256sum | cut -d' ' -f1 > "$ROOT_DIR/data/.applied-compose.sha256" \
                    || ! chmod 600 "$ROOT_DIR/data/.applied-compose.sha256"; then
                    recovery_ok=0
                fi
                store_last_good || recovery_ok=0
            fi
        fi
        if [[ $recovery_ok -eq 0 ]]; then
            printf 'Critical: automatic rollback did not fully recover the prior server.\n' >&2
        fi
    fi

    [[ -z "$ROLLBACK_DIR" ]] || rm -rf -- "$ROLLBACK_DIR"
    exit "$status"
}

[[ $# -le 1 ]] || usage
[[ -f "$ROOT_DIR/.env" ]] || die "Run scripts/setup.sh first."
[[ -f "$ROOT_DIR/config/config.ini" ]] || die "Missing config/config.ini."
[[ -f "$ROOT_DIR/config/groups.json" ]] || die "Missing config/groups.json."
[[ -d "$ROOT_DIR/data/save" ]] || die "No server data was found."

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
command -v tar >/dev/null 2>&1 || die "tar is not installed."
command -v flock >/dev/null 2>&1 || die "flock is not installed."

mkdir -p "$ROOT_DIR/backups"
chmod 700 "$ROOT_DIR/backups"
exec 9> "$ROOT_DIR/backups/.operation.lock"
flock -n 9 || die "Another backup, update, or restore is already running."
export OPENRCT2_OPERATION_LOCKED=1

park_source=${1:-}
new_park_name=
if [[ -n "$park_source" ]]; then
    [[ -f "$park_source" ]] || die "Park file not found: $park_source"
    extension=${park_source##*.}
    extension=${extension,,}
    case "$extension" in
        park|sv6) ;;
        *) die "Expected an OpenRCT2 .park file or legacy .sv6 save." ;;
    esac
    new_park_name="server.${extension}"
fi

ROLLBACK_DIR=$(mktemp -d "$ROOT_DIR/.update.XXXXXX")
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -f "$LAST_GOOD_DIR/config.ini" ]]; then
    cp "$LAST_GOOD_DIR/config.ini" "$ROLLBACK_DIR/config.ini"
elif [[ -f "$ROOT_DIR/data/config.ini" ]]; then
    cp "$ROOT_DIR/data/config.ini" "$ROLLBACK_DIR/config.ini"
else
    cp "$ROOT_DIR/config/config.ini" "$ROLLBACK_DIR/config.ini"
fi
if [[ -f "$LAST_GOOD_DIR/groups.json" ]]; then
    cp "$LAST_GOOD_DIR/groups.json" "$ROLLBACK_DIR/groups.json"
elif [[ -f "$ROOT_DIR/data/groups.json" ]]; then
    cp "$ROOT_DIR/data/groups.json" "$ROLLBACK_DIR/groups.json"
else
    cp "$ROOT_DIR/config/groups.json" "$ROLLBACK_DIR/groups.json"
fi
if [[ -f "$LAST_GOOD_DIR/env" ]]; then
    cp "$LAST_GOOD_DIR/env" "$ROLLBACK_DIR/env"
else
    cp "$ROOT_DIR/.env" "$ROLLBACK_DIR/env"
fi
if [[ -f "$LAST_GOOD_DIR/compose.yaml" ]]; then
    cp "$LAST_GOOD_DIR/compose.yaml" "$ROLLBACK_DIR/compose.yaml"
else
    cp "$ROOT_DIR/compose.yaml" "$ROLLBACK_DIR/compose.yaml"
fi
if [[ -f "$LAST_GOOD_DIR/container-entrypoint.sh" ]]; then
    cp "$LAST_GOOD_DIR/container-entrypoint.sh" "$ROLLBACK_DIR/container-entrypoint.sh"
else
    cp "$ROOT_DIR/scripts/container-entrypoint.sh" "$ROLLBACK_DIR/container-entrypoint.sh"
fi
[[ -z "$park_source" ]] || cp "$park_source" "$ROLLBACK_DIR/new-park"
ROLLBACK_NEEDED=1

backup_output=$("$ROOT_DIR/scripts/backup.sh" --leave-stopped)
printf '%s\n' "$backup_output"
backup_archive=
while IFS= read -r output_line; do
    case "$output_line" in
        'Backup created: '*) backup_archive=${output_line#Backup created: } ;;
    esac
done <<< "$backup_output"
[[ -f "$backup_archive" ]] || die "Could not locate the safety backup archive."

mkdir "$ROLLBACK_DIR/extracted"
tar -xzf "$backup_archive" -C "$ROLLBACK_DIR/extracted" data/save
mv "$ROLLBACK_DIR/extracted/data/save" "$ROLLBACK_DIR/save"
rm -rf -- "$ROLLBACK_DIR/extracted"

if [[ -n "$park_source" ]]; then
    mkdir -p "$ROOT_DIR/data/save"
    install -m 600 "$ROLLBACK_DIR/new-park" "$ROOT_DIR/data/save/$new_park_name"
    set_env_value PARK_FILE "$new_park_name"
    rm -rf -- "$ROOT_DIR/data/save/autosave"
    rm -f -- \
        "$ROOT_DIR/data/.pending-resume-save" \
        "$ROOT_DIR/data/.active-resume-save" \
        "$ROOT_DIR/data/.startup-attempts"
    mkdir -p "$ROOT_DIR/data/save/autosave"
fi

rm -f -- \
    "$ROOT_DIR/data/.pending-resume-save" \
    "$ROOT_DIR/data/.active-resume-save" \
    "$ROOT_DIR/data/.startup-attempts"
(cd "$ROOT_DIR" && docker compose up -d server)
wait_for_health || die "The updated server did not become healthy."
(cd "$ROOT_DIR" && docker compose config) \
    | sha256sum | cut -d' ' -f1 > "$ROOT_DIR/data/.applied-compose.sha256"
chmod 600 "$ROOT_DIR/data/.applied-compose.sha256"

for _ in {1..60}; do
    if "$ROOT_DIR/scripts/check.sh" >/dev/null 2>&1; then
        store_last_good || die "Could not save the verified deployment state."
        ROLLBACK_NEEDED=0
        trap - EXIT INT TERM
        rm -rf -- "$ROLLBACK_DIR"
        printf 'Public server update completed successfully.\n'
        exit 0
    fi
    sleep 5
done

die "The updated server did not register on the public server list."
