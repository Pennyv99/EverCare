#!/bin/bash

set -Eeuo pipefail

project_dir="/home/ubuntu/test"
cd "$project_dir"
source venv/bin/activate

main_pid=""
tts_pid=""
active_pid=""

stop_children() {
    trap - EXIT INT TERM
    for child_pid in "$active_pid" "$tts_pid" "$main_pid"; do
        if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
            kill "$child_pid" 2>/dev/null || true
        fi
    done

    for child_pid in "$active_pid" "$tts_pid" "$main_pid"; do
        if [[ -n "$child_pid" ]]; then
            wait "$child_pid" 2>/dev/null || true
        fi
    done
}

handle_signal() {
    stop_children
    exit 0
}

trap stop_children EXIT
trap handle_signal INT TERM

python3 -u main.py &
main_pid=$!

python3 -u tts_worker.py &
tts_pid=$!

api_ready=0
for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:8000/health >/dev/null; then
        api_ready=1
        break
    fi

    if ! kill -0 "$main_pid" 2>/dev/null; then
        echo "MemoryMate API exited during startup" >&2
        exit 1
    fi

    if ! kill -0 "$tts_pid" 2>/dev/null; then
        echo "MemoryMate TTS worker exited during startup" >&2
        exit 1
    fi

    sleep 1
done

if [[ "$api_ready" -ne 1 ]]; then
    echo "MemoryMate API did not become ready within 60 seconds" >&2
    exit 1
fi

python3 -u active_mode.py &
active_pid=$!

set +e
wait -n "$main_pid" "$tts_pid" "$active_pid"
child_status=$?
set -e

if [[ "$child_status" -eq 0 ]]; then
    child_status=1
fi

exit "$child_status"
