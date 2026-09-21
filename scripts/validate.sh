#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

for script in scripts/*.sh; do
    bash -n "$script"
done

docker compose --env-file .env.example config --quiet

grep -q '^advertise = true$' config/config.ini
grep -q '^known_keys_only = false$' config/config.ini
grep -q '^    "default_group": 2,$' config/groups.json

git check-ignore --quiet .env
git check-ignore --quiet data/save/server.park
git check-ignore --quiet backups/openrct2-test.tar.gz

printf 'Deployment configuration is valid.\n'
