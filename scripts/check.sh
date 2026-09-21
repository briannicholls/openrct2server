#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
local_only=0

if [[ ${1:-} == "--local" ]]; then
    local_only=1
elif [[ $# -ne 0 ]]; then
    printf 'Usage: %s [--local]\n' "${0##*/}" >&2
    exit 2
fi

cd "$ROOT_DIR"
docker compose config --quiet

container_id=$(docker compose ps -q server)
[[ -n "$container_id" ]] || {
    printf 'Error: the server container does not exist.\n' >&2
    exit 1
}

status=$(docker inspect --format '{{.State.Status}}' "$container_id")
health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' "$container_id")

printf 'Container status: %s\n' "$status"
printf 'Health status: %s\n' "$health"

[[ "$status" == "running" ]] || exit 1
[[ "$health" == "healthy" ]] || {
    printf 'Error: wait for startup or inspect docker compose logs server.\n' >&2
    exit 1
}

timeout 3 bash -c '>/dev/tcp/127.0.0.1/11753'
printf 'Local TCP check: reachable\n'

if [[ $local_only -eq 1 ]]; then
    exit 0
fi

command -v curl >/dev/null 2>&1 || {
    printf 'Error: curl is required for the server-list check.\n' >&2
    exit 1
}

server_name=$(grep '^server_name = ' "$ROOT_DIR/data/config.ini" | tail -n 1 | cut -d'"' -f2)
server_logs=$(docker compose logs --no-color server)
if ! grep -Fq 'Server successfully registered on master server' <<< "$server_logs"; then
    printf 'Error: this server has not confirmed master-server registration.\n' >&2
    printf 'Check TCP 11753, outbound HTTPS, and docker compose logs server.\n' >&2
    exit 1
fi

server_list=$(curl --fail --silent --show-error --max-time 15 https://servers.openrct2.io)
if grep -Fq "$server_name" <<< "$server_list"; then
    printf 'OpenRCT2 server list: %s is listed\n' "$server_name"
else
    printf 'Error: %s is not visible on the OpenRCT2 server list yet.\n' "$server_name" >&2
    printf 'Check TCP 11753, outbound HTTPS, and registration messages in the server logs.\n' >&2
    exit 1
fi
