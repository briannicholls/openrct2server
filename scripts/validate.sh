#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

for script in scripts/*.sh; do
    bash -n "$script"
done
python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' \
    scripts/server-info.py
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze --user verify \
        systemd/openrct2-watchdog.service \
        systemd/openrct2-watchdog.timer
fi

docker compose --env-file .env.example config --quiet
compose_config=$(docker compose --env-file .env.example config)

grep -q '^advertise = true$' config/config.ini
grep -q '^advertise_address = "della-avoided\.tun\.ply\.gg"$' config/config.ini
grep -q '^server_name = "{RED}\$M{WHITE}L{BABYBLUE}G{WHITE} B5 - Ultimate Fun Land"$' config/config.ini
grep -q '^server_description = "Buy \$MLG\. Don.t focus on no girls, just buy \$MLG\."$' config/config.ini
grep -q '^known_keys_only = false$' config/config.ini
grep -q '^    "default_group": 2,$' config/groups.json
grep -q '^HOST_PORT=11753$' .env.example
grep -q '^SERVER_PORT=11753$' .env.example
grep -q 'target: /config' <<< "$compose_config"
grep -q 'rm -f /data/.active-resume-save /data/.startup-attempts' <<< "$compose_config"

git check-ignore --quiet .env
git check-ignore --quiet data/save/server.park
git check-ignore --quiet backups/openrct2-test.tar.gz

if grep -R --exclude=validate.sh -E -i 'tailscale|compose\.local-test|test-local\.sh|TEST_(BIND_ADDRESS|LOCAL_PORT|PORT|ADVERTISE)' \
    README.md compose.yaml config scripts .env.example; then
    printf 'Error: legacy split-deployment references remain.\n' >&2
    exit 1
fi

printf 'Deployment configuration is valid.\n'
