#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
local_only=0

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

if [[ ${1:-} == "--local" ]]; then
    local_only=1
elif [[ $# -ne 0 ]]; then
    printf 'Usage: %s [--local]\n' "${0##*/}" >&2
    exit 2
fi

cd "$ROOT_DIR"
docker compose config --quiet

[[ -f "$ROOT_DIR/config/config.ini" ]] || die "Missing config/config.ini."
park_file=$(env_value PARK_FILE server.park)
[[ -f "$ROOT_DIR/data/save/$park_file" ]] || die "Configured park is missing: data/save/$park_file"

bind_address=$(env_value BIND_ADDRESS 0.0.0.0)
server_port=$(env_value SERVER_PORT 11753)
host_port=$(env_value HOST_PORT "$server_port")
advertise=$(ini_value advertise)
advertise_address=$(ini_value advertise_address)
server_name=$(ini_value server_name)
config_hash=$(sha256sum "$ROOT_DIR/config/config.ini" | cut -d' ' -f1)
groups_hash=$(sha256sum "$ROOT_DIR/config/groups.json" | cut -d' ' -f1)
entrypoint_hash=$(sha256sum "$ROOT_DIR/scripts/container-entrypoint.sh" | cut -d' ' -f1)
compose_hash=$(docker compose config | sha256sum | cut -d' ' -f1)
[[ -f "$ROOT_DIR/data/.applied-config.sha256" ]] \
    && [[ "$(< "$ROOT_DIR/data/.applied-config.sha256")" == "$config_hash" ]] \
    || die "The running configuration does not match config/config.ini."
[[ -f "$ROOT_DIR/data/.applied-groups.sha256" ]] \
    && [[ "$(< "$ROOT_DIR/data/.applied-groups.sha256")" == "$groups_hash" ]] \
    || die "The running groups do not match config/groups.json."
[[ -f "$ROOT_DIR/data/.applied-entrypoint.sha256" ]] \
    && [[ "$(< "$ROOT_DIR/data/.applied-entrypoint.sha256")" == "$entrypoint_hash" ]] \
    || die "The running container entrypoint is not the tracked version."
[[ -f "$ROOT_DIR/data/.applied-compose.sha256" ]] \
    && [[ "$(< "$ROOT_DIR/data/.applied-compose.sha256")" == "$compose_hash" ]] \
    || die "The running deployment does not match .env or compose.yaml."
probe_address=$bind_address
[[ "$probe_address" != 0.0.0.0 ]] || probe_address=127.0.0.1

container_id=$(docker compose ps -q server)
[[ -n "$container_id" ]] || die "The server container does not exist."

status=$(docker inspect --format '{{.State.Status}}' "$container_id")
health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' "$container_id")

printf 'Container status: %s\n' "$status"
printf 'Health status: %s\n' "$health"

[[ "$status" == "running" ]] || die "The server container is not running."
[[ "$health" == "healthy" ]] || die "Wait for startup or inspect docker compose logs server."

timeout 3 bash -c ">/dev/tcp/$probe_address/$host_port" \
    || die "Published TCP port is not reachable at $probe_address:$host_port."
printf 'Local TCP check: %s:%s is reachable\n' "$probe_address" "$host_port"

if [[ $local_only -eq 1 ]]; then
    exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required for the server-list check."

[[ "$advertise" == true ]] || die "Public registration is disabled in config/config.ini."

started_at=$(docker inspect --format '{{.State.StartedAt}}' "$container_id")
server_logs=$(docker compose logs --since "$started_at" --no-color server)
if ! grep -Fq 'Server successfully registered on master server' <<< "$server_logs"; then
    printf 'Error: this server has not confirmed master-server registration.\n' >&2
    printf 'Check Playit, outbound HTTPS, and docker compose logs server.\n' >&2
    exit 1
fi

server_list=$(curl --fail --silent --show-error --max-time 15 \
    "https://servers.openrct2.io/?check=$(date +%s%N)")
if grep -Fq "$server_name" <<< "$server_list"; then
    printf 'OpenRCT2 server list: %s is listed\n' "$server_name"
else
    printf 'Error: %s is not visible on the OpenRCT2 server list yet.\n' "$server_name" >&2
    printf 'Check Playit and registration messages in the server logs.\n' >&2
    exit 1
fi

printf 'Advertised endpoint: %s:%s\n' "${advertise_address:-automatic}" "$server_port"
