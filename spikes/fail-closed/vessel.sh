#!/usr/bin/env bash
# Fail-closed vessel: the pit is a systemd service whose main process is the
# supervisor. If the supervisor dies or hangs, systemd kills the whole unit.
# The fire is sealed with Landlock and seccomp, and may connect only to the
# chimney's TCP port.
# Usage: vessel.sh PIT_ID PIT_DIR CHIMNEY_PORT DEST WATCHDOG_SEC [SMOKE_LIMIT_BYTES]
set -euo pipefail
id=$1 dir=$2 port=$3 dest=$4 watchdog=$5 limit=${6:-}
here=$(dirname "$(readlink -f "$0")")
common=$(dirname "$here")/common
python=$(command -v python3)
registry="${XDG_RUNTIME_DIR:?}/firepit"
mkdir -p "$registry" "$dir/work"
smoke="$dir/smoke.log"

printf '{"id":"%s","impl":"spike-service-vessel","started":"%s","smoke":"%s"}\n' \
  "$id" "$(date -Is)" "$smoke" > "$registry/$id.json"

limit_args=()
[[ -n $limit ]] && limit_args=(--smoke-limit "$limit")

systemd-run --user --quiet --collect --unit="firepit-$id" --slice=firepit.slice \
  --service-type=notify -p NotifyAccess=main \
  -p WatchdogSec="$watchdog" -p WatchdogSignal=SIGKILL \
  -p KillMode=control-group -p KillSignal=SIGKILL \
  -p "ExecStopPost=/bin/bash $common/terminal.sh $smoke" \
  -E PIT_ID="$id" \
  "$python" "$common/supervisor.py" "$id" "$smoke" "$port" "$dest" "${limit_args[@]}" -- \
  "$python" "$common/seal.py" --connect "$port" "$dir/work" -- /bin/bash "$here/probe.sh" "$dir/work"
