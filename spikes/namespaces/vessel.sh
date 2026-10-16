#!/usr/bin/env bash
# Namespace vessel: a systemd service whose supervisor runs the fire inside
# bwrap with its own user, mount, network, pid, ipc and uts namespaces.
# The fire sees only what is mounted in: system binaries read-only, a tmpfs
# scratch dir, the chimney socket, and one declared host socket.
# Usage: vessel.sh PIT_ID PIT_DIR DEST WATCHDOG_SEC KILL_MODE [KEY=VALUE ...]
#   KEY=VALUE pairs are passed to the fire's environment (test instrumentation).
set -euo pipefail
id=$1 dir=$2 dest=$3 watchdog=$4 kill_mode=$5; shift 5
here=$(dirname "$(readlink -f "$0")")
spikes=$(dirname "$here")
common=$spikes/common
bwrap=/usr/local/lib/firepit/bwrap
python=$(command -v python3)
python_real=$(readlink -f "$python")
python_prefix=$(dirname "$(dirname "$python_real")")
registry="${XDG_RUNTIME_DIR:?}/firepit"
smoke="$dir/smoke.log"

[[ -x $bwrap ]] || { echo "vessel: $bwrap missing; run: sudo bash $common/install.sh" >&2; exit 1; }
mkdir -p "$registry" "$dir/beats"
printf '{"id":"%s","impl":"spike-namespace-vessel","started":"%s","smoke":"%s"}\n' \
  "$id" "$(date -Is)" "$smoke" > "$registry/$id.json"

probe_env=()
for pair in "$@"; do probe_env+=(--setenv "${pair%%=*}" "${pair#*=}"); done

fire=(
  "$bwrap"
  --unshare-all --unshare-user --disable-userns --die-with-parent --new-session
  --clearenv --setenv PATH /usr/bin --setenv HOME /scratch
  --setenv DEST "$dest" --setenv BEAT_SH "$common/beat.sh" "${probe_env[@]}"
  --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib
  --symlink usr/lib64 /lib64 --symlink usr/sbin /sbin --ro-bind /etc /etc
  --ro-bind "$python_prefix" "$python_prefix" --ro-bind "$spikes" "$spikes"
  --proc /proc --dev /dev --tmpfs /tmp --tmpfs /scratch
  --dir /run/firepit
  --bind "$dir/chimney.sock" /run/firepit/chimney.sock
  --bind "$dir/agent.sock" /run/firepit/agent.sock
  --bind "$dir/beats" /beats
  -- "$python_real" "$here/probe.py"
)

systemd-run --user --quiet --collect --unit="firepit-$id" --slice=firepit.slice \
  --service-type=notify -p NotifyAccess=main \
  -p WatchdogSec="$watchdog" -p WatchdogSignal=SIGKILL \
  -p KillMode="$kill_mode" -p KillSignal=SIGKILL \
  -p "ExecStopPost=/bin/bash $common/terminal.sh $smoke" \
  "$python" "$common/supervisor.py" "$id" "$smoke" "$dir/chimney.sock" "$dest" -- "${fire[@]}"
