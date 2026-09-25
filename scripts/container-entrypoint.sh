#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

validate_park() {
    local park_file=$1
    local validation_dir
    local validator_pid

    validation_dir=$(mktemp -d)
    cp /data/config.ini /data/groups.json "$validation_dir/"
    for data_dir in object assetpack; do
        [[ ! -d "/data/$data_dir" ]] || cp -a "/data/$data_dir" "$validation_dir/$data_dir"
    done
    sed -i 's/^advertise = true$/advertise = false/' "$validation_dir/config.ini"

    /usr/bin/openrct2-cli host "$park_file" \
        --port=39971 \
        --address=127.0.0.1 \
        --user-data-path="$validation_dir" \
        > "$validation_dir/output.log" 2>&1 &
    validator_pid=$!

    for _ in {1..1200}; do
        if grep -Fq 'Listening for clients' "$validation_dir/output.log"; then
            kill -TERM "$validator_pid" >/dev/null 2>&1 || true
            wait "$validator_pid" 2>/dev/null || true
            rm -rf -- "$validation_dir"
            return 0
        fi
        if ! kill -0 "$validator_pid" >/dev/null 2>&1; then
            break
        fi
        sleep 0.25
    done

    validator_timed_out=0
    if kill -0 "$validator_pid" >/dev/null 2>&1; then
        validator_timed_out=1
    fi
    kill -TERM "$validator_pid" >/dev/null 2>&1 || true
    wait "$validator_pid" 2>/dev/null || true
    if [[ $validator_timed_out -eq 1 ]]; then
        printf 'OpenRCT2 validation timed out for %s:\n' "$park_file" >&2
    else
        printf 'OpenRCT2 could not load %s:\n' "$park_file" >&2
    fi
    sed 's/^/  /' "$validation_dir/output.log" >&2
    rm -rf -- "$validation_dir"
    return 1
}

if [[ ${1:-} == validate-park ]]; then
    [[ $# -eq 2 ]] || exit 2
    validate_park "$2"
    exit
fi

fail_stop() {
    local status=$?
    trap - ERR
    printf 'Container initialization failed with status %s; leaving it unhealthy instead of restart-looping.\n' \
        "$status" >&2
    exec sleep infinity
}
trap fail_stop ERR

if [[ ${1:-} == host ]]; then
    startup_attempts=0
    if [[ -f /data/.startup-attempts ]]; then
        read -r startup_attempts < /data/.startup-attempts || true
    fi
    [[ "$startup_attempts" =~ ^[0-9]+$ ]] || startup_attempts=0
    ((startup_attempts += 1))
    printf '%s\n' "$startup_attempts" > /data/.startup-attempts
    if (( startup_attempts > 3 )); then
        printf 'Startup failed three times; leaving the container unhealthy instead of restart-looping.\n' >&2
        exec sleep infinity
    fi
fi

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

if [[ ${1:-} == host ]]; then
    if [[ ! -f ${2:-} ]]; then
        printf 'Configured park is missing: %s\n' "${2:-unset}" >&2
        exec sleep infinity
    fi

    shopt -s nullglob
    selected_save=
    if [[ -f /data/.active-resume-save ]]; then
        read -r selected_save < /data/.active-resume-save
        if [[ "$selected_save" != /data/save/* || ! -f "$selected_save" ]]; then
            printf 'Pinned recovery save is invalid: %s\n' "$selected_save" >&2
            exec sleep infinity
        fi
        printf 'Resuming pinned recovery save: %s\n' "$selected_save"
    elif [[ -f /data/.pending-resume-save ]]; then
        mv /data/.pending-resume-save /data/.active-resume-save
        read -r selected_save < /data/.active-resume-save
        if [[ "$selected_save" != /data/save/* || ! -f "$selected_save" ]]; then
            printf 'Pending recovery save is invalid: %s\n' "$selected_save" >&2
            exec sleep infinity
        fi
        printf 'Resuming pinned recovery save: %s\n' "$selected_save"
    else
        if [[ -d /data/save/autosave ]]; then
            autosaves=(/data/save/autosave/*.park /data/save/autosave/*.sv6)
            for candidate in "${autosaves[@]}"; do
                if [[ -z "$selected_save" || "$candidate" -nt "$selected_save" ]]; then
                    selected_save=$candidate
                fi
            done
        fi
        if [[ -n "$selected_save" && "$selected_save" -nt "$2" ]]; then
            printf 'Resuming newer autosave: %s\n' "$selected_save"
        else
            selected_save=$2
        fi
    fi

    if ! validate_park "$selected_save"; then
        exec sleep infinity
    fi
    set -- "$1" "$selected_save" "${@:3}"
fi

exec /usr/bin/openrct2-cli "$@"
