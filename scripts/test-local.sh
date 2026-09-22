#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR="$ROOT_DIR/backups/local-test"
TEST_DATA="$TEST_DIR/data"
PROJECT_NAME=openrct2-local-test
CONTAINER_NAME=openrct2-server-local-test

env_value() {
    local name=$1
    local value

    value=$(grep "^${name}=" "$ROOT_DIR/.env" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
    printf '%s' "$value"
}

TEST_PORT=${TEST_PORT:-$(env_value TEST_PORT)}
TEST_PORT=${TEST_PORT:-11754}
TEST_LOCAL_PORT=${TEST_LOCAL_PORT:-$(env_value TEST_LOCAL_PORT)}
TEST_LOCAL_PORT=${TEST_LOCAL_PORT:-$TEST_PORT}
TEST_BIND_ADDRESS=${TEST_BIND_ADDRESS:-$(env_value TEST_BIND_ADDRESS)}
TEST_BIND_ADDRESS=${TEST_BIND_ADDRESS:-127.0.0.1}
TEST_ADVERTISE=${TEST_ADVERTISE:-$(env_value TEST_ADVERTISE)}
TEST_ADVERTISE=${TEST_ADVERTISE:-0}
TEST_ADVERTISE_ADDRESS=${TEST_ADVERTISE_ADDRESS:-$(env_value TEST_ADVERTISE_ADDRESS)}
export TEST_PORT TEST_LOCAL_PORT TEST_BIND_ADDRESS TEST_ADVERTISE TEST_ADVERTISE_ADDRESS

usage() {
    printf 'Usage: %s <up|down|reset|status|logs>\n' "${0##*/}" >&2
    exit 2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

compose() {
    PUID=$(id -u) PGID=$(id -g) docker compose \
        --project-name "$PROJECT_NAME" \
        --file "$ROOT_DIR/compose.yaml" \
        --file "$ROOT_DIR/compose.local-test.yaml" \
        "$@"
}

park_file() {
    local configured_park

    configured_park=$(env_value PARK_FILE)
    printf '%s' "${configured_park:-server.park}"
}

prepare_data() {
    local park
    local source_park

    park=$(park_file)
    source_park="$ROOT_DIR/data/save/$park"
    [[ -f "$source_park" ]] || die "Park not found: $source_park"

    mkdir -p \
        "$TEST_DATA/chatlogs" \
        "$TEST_DATA/object" \
        "$TEST_DATA/plugin" \
        "$TEST_DATA/save" \
        "$TEST_DATA/serverlogs"

    cp "$ROOT_DIR/config/config.ini" "$TEST_DATA/config.ini"
    cp "$ROOT_DIR/config/groups.json" "$TEST_DATA/groups.json"
    cp "$source_park" "$TEST_DATA/save/$park"

    if [[ -f "$ROOT_DIR/data/users.json" ]]; then
        cp "$ROOT_DIR/data/users.json" "$TEST_DATA/users.json"
    fi
    if [[ -d "$ROOT_DIR/data/object" ]]; then
        cp -a "$ROOT_DIR/data/object/." "$TEST_DATA/object/"
    fi
    if [[ -d "$ROOT_DIR/data/plugin" ]]; then
        cp -a "$ROOT_DIR/data/plugin/." "$TEST_DATA/plugin/"
    fi

    chmod 600 "$TEST_DATA/config.ini" "$TEST_DATA/groups.json" "$TEST_DATA/save/$park"
    [[ ! -f "$TEST_DATA/users.json" ]] || chmod 600 "$TEST_DATA/users.json"
}

configure_advertising() {
    case "$TEST_ADVERTISE" in
        1|true|TRUE|yes|YES)
            sed -i 's/^advertise = false$/advertise = true/' "$TEST_DATA/config.ini"
            if [[ -n "$TEST_ADVERTISE_ADDRESS" ]]; then
                [[ "$TEST_ADVERTISE_ADDRESS" =~ ^[0-9A-Za-z.:_-]+$ ]] \
                    || die "TEST_ADVERTISE_ADDRESS contains unsupported characters."
            fi
            ;;
        *)
            sed -i 's/^advertise = true$/advertise = false/' "$TEST_DATA/config.ini"
            TEST_ADVERTISE_ADDRESS=
            ;;
    esac

    sed -i \
        "s|^advertise_address =.*|advertise_address = \"$TEST_ADVERTISE_ADDRESS\"|" \
        "$TEST_DATA/config.ini"
    chmod 600 "$TEST_DATA/config.ini"
}

wait_for_health() {
    local health

    for _ in {1..24}; do
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_NAME")
        case "$health" in
            healthy) return 0 ;;
            unhealthy|exited|dead) return 1 ;;
        esac
        sleep 5
    done

    return 1
}

[[ $# -eq 1 ]] || usage
command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose is not available."

case "$1" in
    up)
        [[ -f "$TEST_DATA/config.ini" ]] || prepare_data
        configure_advertising
        compose up -d
        if ! wait_for_health; then
            compose logs --no-color server >&2 || true
            compose down >/dev/null 2>&1 || true
            die "The local test server did not become healthy."
        fi

        printf '\nMLG Park local test is healthy.\n'
        if [[ "$TEST_BIND_ADDRESS" == "0.0.0.0" ]]; then
            printf 'Connect using this host\047s address on port %s.\n' "$TEST_LOCAL_PORT"
        else
            printf 'Connect directly to %s:%s.\n' "$TEST_BIND_ADDRESS" "$TEST_LOCAL_PORT"
        fi
        if [[ "$TEST_ADVERTISE" == 1 ]]; then
            printf 'Public advertising is enabled for %s:%s.\n' \
                "${TEST_ADVERTISE_ADDRESS:-the public endpoint}" "$TEST_PORT"
        else
            printf 'Public advertising is disabled for this test.\n'
        fi
        printf 'View logs: scripts/test-local.sh logs\n'
        printf 'Stop test: scripts/test-local.sh down\n'
        ;;
    down)
        compose down --remove-orphans
        printf 'Local test stopped. Test data was preserved.\n'
        ;;
    reset)
        compose down --remove-orphans
        rm -rf -- "$TEST_DIR"
        printf 'Local test stopped and test data removed.\n'
        ;;
    status)
        compose ps
        ;;
    logs)
        compose logs --no-color server
        ;;
    *) usage ;;
esac
