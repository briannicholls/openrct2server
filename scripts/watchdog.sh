#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STATE_FILE="$ROOT_DIR/backups/.watchdog-state"
FAILURE_THRESHOLD=3
MAX_OBSERVATION_GAP=480
RESTART_COOLDOWN=3600

env_value() {
    local key=$1
    local fallback=${2:-}
    local value

    value=$(grep "^${key}=" "$ROOT_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
    printf '%s' "${value:-$fallback}"
}

ini_value() {
    local key=$1
    local value

    value=$(grep "^${key} = " "$ROOT_DIR/config/config.ini" | tail -n 1 | cut -d= -f2- || true)
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    value=${value#\"}
    value=${value%\"}
    printf '%s' "$value"
}

write_state() {
    local failures_value=$1
    local first_failure_value=$2
    local last_observation_value=$3
    local last_restart_value=$4
    local container_start_value=$5
    local temporary_state="${STATE_FILE}.tmp"

    printf '%s %s %s %s %s\n' \
        "$failures_value" "$first_failure_value" "$last_observation_value" \
        "$last_restart_value" "$container_start_value" \
        > "$temporary_state"
    mv "$temporary_state" "$STATE_FILE"
}

reset_observations() {
    write_state 0 0 "$(date +%s)" "$last_restart" "$container_start"
}

for command_name in curl docker flock python3 timeout; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Watchdog error: %s is not installed.\n' "$command_name" >&2
        exit 1
    }
done

mkdir -p "$ROOT_DIR/backups"
exec 9> "$ROOT_DIR/backups/.operation.lock"
if ! flock -n 9; then
    printf 'Watchdog: maintenance operation is active; skipping.\n'
    exit 0
fi

failures=0
first_failure=0
last_observation=0
last_restart=0
observed_container_start=0
container_start=0
if [[ -f "$STATE_FILE" ]]; then
    read -r failures first_failure last_observation last_restart observed_container_start \
        < "$STATE_FILE" || true
fi
for value_name in failures first_failure last_observation last_restart observed_container_start; do
    [[ "${!value_name}" =~ ^[0-9]+$ ]] || printf -v "$value_name" 0
done

if ! "$ROOT_DIR/scripts/check.sh" --local >/dev/null 2>&1; then
    reset_observations
    printf 'Watchdog error: local deployment check failed; automatic restart suppressed.\n' >&2
    exit 1
fi
container_id=$(cd "$ROOT_DIR" && docker compose ps -q server)
container_started_at=$(docker inspect --format '{{.State.StartedAt}}' "$container_id")
container_start=$(date -d "$container_started_at" +%s)
now=$(date +%s)

server_name=$(ini_value server_name)
advertise_address=$(ini_value advertise_address)
server_port=$(env_value SERVER_PORT 11753)
host_port=$(env_value HOST_PORT "$server_port")
[[ -n "$server_name" && -n "$advertise_address" ]] || {
    reset_observations
    printf 'Watchdog error: public server identity is incomplete.\n' >&2
    exit 1
}

if ! players=$("$ROOT_DIR/scripts/server-info.py" --port "$host_port" --field players) \
    || ! reported_name=$("$ROOT_DIR/scripts/server-info.py" --port "$host_port" --field name); then
    reset_observations
    printf 'Watchdog error: OpenRCT2 gameInfo query failed; automatic restart suppressed.\n' >&2
    exit 1
fi
if [[ ! "$players" =~ ^[0-9]+$ || "$reported_name" != "$server_name" ]]; then
    reset_observations
    printf 'Watchdog error: OpenRCT2 gameInfo did not match the configured server.\n' >&2
    exit 1
fi

if ! timeout 10 bash -c ">/dev/tcp/$advertise_address/$server_port"; then
    reset_observations
    printf 'Watchdog error: public endpoint %s:%s is unreachable; game restart suppressed.\n' \
        "$advertise_address" "$server_port" >&2
    exit 1
fi

if ! server_list=$(curl --fail --silent --show-error --max-time 20 \
    "https://servers.openrct2.io/?check=$(date +%s%N)"); then
    reset_observations
    printf 'Watchdog error: OpenRCT2 master list is unavailable; game restart suppressed.\n' >&2
    exit 1
fi
if [[ "$server_list" != *'<div class="server-table">'* \
    || "$server_list" != *'<div class="heading">Server</div>'* ]]; then
    reset_observations
    printf 'Watchdog error: OpenRCT2 master-list response was not recognized; restart suppressed.\n' >&2
    exit 1
fi

if grep -Fq "<div>${server_name}</div>" <<< "$server_list"; then
    rm -f -- "$ROOT_DIR/data/.pending-resume-save"
    if (( now - last_restart >= RESTART_COOLDOWN )); then
        last_restart=0
    fi
    write_state 0 0 "$now" "$last_restart" "$container_start"
    printf 'Watchdog: public listing is healthy.\n'
    exit 0
fi

if (( players > 0 )); then
    reset_observations
    printf 'Watchdog warning: listing is absent, but %s player(s) are connected; restart suppressed.\n' \
        "$players" >&2
    exit 0
fi
if (( now - last_restart < RESTART_COOLDOWN )); then
    reset_observations
    printf 'Watchdog warning: listing is absent, but recovery is in its cooldown period.\n' >&2
    exit 0
fi
if (( failures == 0 \
    || now - last_observation > MAX_OBSERVATION_GAP \
    || observed_container_start != container_start )); then
    failures=0
    first_failure=$now
fi

((failures += 1))
(( failures <= FAILURE_THRESHOLD )) || failures=$FAILURE_THRESHOLD
write_state "$failures" "$first_failure" "$now" "$last_restart" "$container_start"
if (( failures < FAILURE_THRESHOLD )); then
    printf 'Watchdog warning: listing is absent (%s/%s); waiting before recovery.\n' \
        "$failures" "$FAILURE_THRESHOLD" >&2
    exit 0
fi

shopt -s nullglob
autosaves=("$ROOT_DIR"/data/save/autosave/*.park "$ROOT_DIR"/data/save/autosave/*.sv6)
latest_autosave=
for autosave in "${autosaves[@]}"; do
    if [[ -z "$latest_autosave" || "$autosave" -nt "$latest_autosave" ]]; then
        latest_autosave=$autosave
    fi
done
if [[ -z "$latest_autosave" || $(stat -c %Y "$latest_autosave") -lt $first_failure ]]; then
    printf 'Watchdog warning: listing is absent, but no fresh autosave is available; restart suppressed.\n' >&2
    exit 0
fi
autosave_mtime=$(stat -c %Y "$latest_autosave")
autosave_size=$(stat -c %s "$latest_autosave")
if (( autosave_size < 1024 || now - autosave_mtime < 60 )); then
    printf 'Watchdog warning: newest autosave is incomplete or still being written; restart suppressed.\n' >&2
    exit 1
fi
container_autosave="/data/save/autosave/${latest_autosave##*/}"
if ! (cd "$ROOT_DIR" && docker compose exec -T server \
    /opt/openrct2/container-entrypoint.sh validate-park "$container_autosave" >/dev/null 2>&1); then
    printf 'Watchdog error: OpenRCT2 could not load the fresh autosave; restart suppressed.\n' >&2
    exit 1
fi

latest_container_id=$(cd "$ROOT_DIR" && docker compose ps -q server)
latest_started_at=$(docker inspect --format '{{.State.StartedAt}}' "$latest_container_id")
latest_container_start=$(date -d "$latest_started_at" +%s)
if [[ "$latest_container_id" != "$container_id" || $latest_container_start -ne $container_start ]]; then
    reset_observations
    printf 'Watchdog warning: server changed during observation; restart suppressed.\n' >&2
    exit 0
fi
if ! players=$("$ROOT_DIR/scripts/server-info.py" --port "$host_port" --field players) \
    || [[ ! "$players" =~ ^[0-9]+$ || $players -ne 0 ]]; then
    reset_observations
    printf 'Watchdog warning: player state changed before recovery; restart suppressed.\n' >&2
    exit 0
fi

# Persist cooldown before restart so interruption cannot cause a restart loop.
write_state 0 0 "$now" "$now" "$container_start"
printf 'Watchdog: listing remained absent with no players and a fresh autosave; restarting OpenRCT2.\n' >&2
if ! (cd "$ROOT_DIR" && docker compose stop -t 30 server); then
    printf 'Watchdog error: server could not be stopped safely; recovery aborted.\n' >&2
    exit 1
fi
stopped_status=$(docker inspect --format '{{.State.Status}}' "$container_id")
if [[ "$stopped_status" == running || "$stopped_status" == restarting ]]; then
    printf 'Watchdog error: server remained active after stop; recovery aborted.\n' >&2
    exit 1
fi

printf '%s\n' "$container_autosave" > "$ROOT_DIR/data/.pending-resume-save.tmp"
mv "$ROOT_DIR/data/.pending-resume-save.tmp" "$ROOT_DIR/data/.pending-resume-save"
(cd "$ROOT_DIR" && docker compose up -d server)

for _ in {1..24}; do
    if "$ROOT_DIR/scripts/check.sh" --local >/dev/null 2>&1; then
        break
    fi
    sleep 5
done
if ! "$ROOT_DIR/scripts/check.sh" --local >/dev/null 2>&1; then
    printf 'Watchdog error: server did not recover local health after restart.\n' >&2
    exit 1
fi

for _ in {1..12}; do
    if timeout 25 "$ROOT_DIR/scripts/check.sh" >/dev/null 2>&1; then
        recovered_id=$(cd "$ROOT_DIR" && docker compose ps -q server)
        recovered_started_at=$(docker inspect --format '{{.State.StartedAt}}' "$recovered_id")
        recovered_start=$(date -d "$recovered_started_at" +%s)
        write_state 0 0 "$(date +%s)" "$now" "$recovered_start"
        printf 'Watchdog: public registration recovered.\n'
        exit 0
    fi
    sleep 5
done

printf 'Watchdog error: server restarted but did not return to the public list.\n' >&2
exit 1
