#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
cp /config/config.ini /data/config.ini
cp /config/groups.json /data/groups.json
chmod 600 /data/config.ini /data/groups.json
sha256sum /data/config.ini | cut -d' ' -f1 > /data/.applied-config.sha256
sha256sum /data/groups.json | cut -d' ' -f1 > /data/.applied-groups.sha256
sha256sum /opt/openrct2/container-entrypoint.sh \
    | cut -d' ' -f1 > /data/.applied-entrypoint.sha256
chmod 600 \
    /data/.applied-config.sha256 \
    /data/.applied-groups.sha256 \
    /data/.applied-entrypoint.sha256

exec /usr/bin/openrct2-cli "$@"
