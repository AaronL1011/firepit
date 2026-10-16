#!/usr/bin/env bash
# Minimal vessel: record the pit, put the fire in its own cgroup, supervise.
# Usage: vessel.sh PIT_ID SMOKE_DIR sealed|unsealed -- COMMAND ...
set -euo pipefail
id=$1 smoke=$2 mode=$3; shift 4
here=$(dirname "$(readlink -f "$0")")
common=$(dirname "$here")/common
registry="${XDG_RUNTIME_DIR:?}/firepit"
mkdir -p "$registry"

# Durable record before ignition. People read this; the Extinguisher never does.
printf '{"id":"%s","impl":"spike-vessel","started":"%s","smoke":"%s","mode":"%s"}\n' \
  "$id" "$(date -Is)" "$smoke" "$mode" > "$registry/$id.json"

seal=()
[[ $mode == sealed ]] && seal=(python3 "$common/seal.py" "$smoke" --)

PIT_ID=$id systemd-run --user --scope --quiet --collect \
  --slice=firepit.slice --unit="firepit-$id" -- "${seal[@]}" "$@" &
wait $!
