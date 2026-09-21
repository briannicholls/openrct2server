#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

usage() {
    printf 'Usage: %s <park-file> [users.json]\n' "${0##*/}" >&2
    exit 2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

ensure_env_value() {
    local key=$1
    local value=$2

    if ! grep -q "^${key}=" "$ROOT_DIR/.env"; then
        printf '%s=%s\n' "$key" "$value" >> "$ROOT_DIR/.env"
    fi
}

[[ $# -ge 1 && $# -le 2 ]] || usage
[[ $EUID -ne 0 ]] || die "Run setup as the deployment user, not with sudo."

PARK_SOURCE=$1
USERS_SOURCE=${2:-}

[[ -f "$PARK_SOURCE" ]] || die "Park file not found: $PARK_SOURCE"
if [[ -n "$USERS_SOURCE" ]]; then
    [[ -f "$USERS_SOURCE" ]] || die "users.json not found: $USERS_SOURCE"
fi

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose is not available."
docker info >/dev/null 2>&1 || die "The Docker daemon is unavailable to this user."

case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "The pinned OpenRCT2 image requires an amd64 VM." ;;
esac

extension=${PARK_SOURCE##*.}
extension=${extension,,}
case "$extension" in
    park|sv6) ;;
    *) die "Expected an OpenRCT2 .park file or legacy .sv6 save." ;;
esac

park_name="server.${extension}"
park_destination="$ROOT_DIR/data/save/$park_name"

umask 077
mkdir -p \
    "$ROOT_DIR/backups" \
    "$ROOT_DIR/data/chatlogs" \
    "$ROOT_DIR/data/object" \
    "$ROOT_DIR/data/plugin" \
    "$ROOT_DIR/data/save" \
    "$ROOT_DIR/data/serverlogs"

if [[ ! -f "$ROOT_DIR/data/config.ini" ]]; then
    cp "$ROOT_DIR/config/config.ini" "$ROOT_DIR/data/config.ini"
else
    printf 'Preserving existing data/config.ini\n'
fi

if [[ ! -f "$ROOT_DIR/data/groups.json" ]]; then
    cp "$ROOT_DIR/config/groups.json" "$ROOT_DIR/data/groups.json"
else
    printf 'Preserving existing data/groups.json\n'
fi

if [[ -f "$park_destination" ]]; then
    cmp -s "$PARK_SOURCE" "$park_destination" \
        || die "$park_destination already exists and differs; use backup/restore instead of overwriting it."
else
    cp "$PARK_SOURCE" "$park_destination"
fi

if [[ -n "$USERS_SOURCE" ]]; then
    if [[ -f "$ROOT_DIR/data/users.json" ]]; then
        cmp -s "$USERS_SOURCE" "$ROOT_DIR/data/users.json" \
            || die "data/users.json already exists and differs."
    else
        cp "$USERS_SOURCE" "$ROOT_DIR/data/users.json"
    fi
fi

if [[ ! -f "$ROOT_DIR/.env" ]]; then
    {
        printf 'PARK_FILE=%s\n' "$park_name"
        printf 'PUID=%s\n' "$(id -u)"
        printf 'PGID=%s\n' "$(id -g)"
        printf 'BIND_ADDRESS=0.0.0.0\n'
        printf 'MEMORY_LIMIT=1g\n'
        printf 'CPU_LIMIT=1.0\n'
        printf 'BACKUP_RETENTION_DAYS=30\n'
        printf 'LOG_RETENTION_DAYS=14\n'
    } > "$ROOT_DIR/.env"
else
    configured_park=$(grep '^PARK_FILE=' "$ROOT_DIR/.env" | tail -n 1 | cut -d= -f2- || true)
    if [[ -n "$configured_park" && "$configured_park" != "$park_name" ]]; then
        die ".env selects $configured_park, but the supplied park installs as $park_name."
    fi

    ensure_env_value PARK_FILE "$park_name"
    ensure_env_value PUID "$(id -u)"
    ensure_env_value PGID "$(id -g)"
    ensure_env_value BIND_ADDRESS 0.0.0.0
    ensure_env_value MEMORY_LIMIT 1g
    ensure_env_value CPU_LIMIT 1.0
    ensure_env_value BACKUP_RETENTION_DAYS 30
    ensure_env_value LOG_RETENTION_DAYS 14
fi

chmod 600 "$ROOT_DIR/.env" "$ROOT_DIR/data/config.ini" "$ROOT_DIR/data/groups.json"
[[ ! -f "$ROOT_DIR/data/users.json" ]] || chmod 600 "$ROOT_DIR/data/users.json"

(
    cd "$ROOT_DIR"
    docker compose config --quiet
)

printf '\nSetup complete. Next steps:\n'
printf '1. Keep TCP 11753 restricted to the administrator while bootstrapping admin access.\n'
printf '2. Start the server with: docker compose up -d\n'
printf '3. Follow startup with: docker compose logs -f server\n'
printf '4. After promoting an administrator, open TCP 11753 publicly and run scripts/check.sh.\n'
