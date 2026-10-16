#!/usr/bin/env bash
# Runs the namespace vessel against the hostile probe: what can the fire reach,
# and does the pit still go out when the vessel breaks or is extinguished?
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
ext="$here/../extinguisher"
spike=$(mktemp -d /tmp/firepit-ns.XXXX)
cg_root="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/firepit.slice"
host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2)
ids=() host_pids=() stopped_pids=()

free_ports() {
  python3 -c '
import socket
socks = [socket.socket() for _ in range(2)]
for s in socks: s.bind(("127.0.0.1", 0))
print(*[s.getsockname()[1] for s in socks])'
}

light() { # id kill_mode ; sets dir
  local id=$1 kill_mode=$2 dport aport
  dir="$spike/$id"; mkdir -p "$dir/host"; ids+=("$id")
  read -r dport aport < <(free_ports)
  python3 "$here/host.py" "$dir/host" "$dport" "$aport" "$host_ip" "firepit-$id" \
    "$dir/agent.sock" "$dir/undeclared.sock" > "$dir/host.out" 2>&1 &
  host_pids+=($!)
  until grep -q ready "$dir/host.out" 2>/dev/null; do sleep 0.05; done
  bash "$here/vessel.sh" "$id" "$dir" "127.0.0.1:$dport" 2 "$kill_mode" \
    ATTACKER_PORT="$aport" HOST_IP="$host_ip" ABSTRACT_NAME="firepit-$id" \
    UNDECLARED_SOCKET="$dir/undeclared.sock" HOST_UID="$(id -u)" HOST_HOME="$HOME" \
    HOST_SMOKE="$dir/smoke.log" HOST_PID="${host_pids[-1]}" \
    HOST_CGROUP_PROCS="$(dirname "$cg_root")/cgroup.procs"
}

main_pid() { systemctl --user show -p MainPID --value "firepit-$1.service"; }
now() { date +%s.%N; }

wait_out() { # id timeout_sec -> ms since $t0
  local unit="$cg_root/firepit-$1.service" deadline=$((SECONDS + $2))
  until [[ ! -d $unit ]] || grep -qx 'populated 0' "$unit/cgroup.events" 2>/dev/null; do
    ((SECONDS < deadline)) || { echo "STILL BURNING"; return; }
    sleep 0.01
  done
  awk -v a="$t0" -v b="$(now)" 'BEGIN { printf "out in %d ms\n", (b - a) * 1000 }'
}

survivors() { # beat_dir
  rm -f "$1"/*.beat; sleep 1.5
  local alive
  alive=$(cd "$1" && ls -- *.beat 2>/dev/null | sed 's/\.beat$//' | tr '\n' ' ')
  echo "${alive:-none}"
}

received() { # dir listener [pattern]
  local f="$1/host/$2.log"
  if [[ -f $f ]]; then grep -c -- "${3:-.}" "$f"; else echo 0; fi
}

cleanup() {
  for pid in "${stopped_pids[@]}"; do kill -CONT "$pid" 2>/dev/null; done
  for id in "${ids[@]}"; do
    bash "$ext/extinguish.sh" "$id" >/dev/null 2>&1
    systemctl --user stop "firepit-$id.service" 2>/dev/null
    rm -f "$XDG_RUNTIME_DIR/firepit/$id.json"
  done
  for pid in "${host_pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$spike"
}
trap cleanup EXIT

echo "kernel $(uname -r), $(systemctl --version | head -1), host ip ${host_ip:-none}"

echo; echo "== A. what the fire can reach (3 s), then extinguish with supervisor frozen"
light "reach-$$" control-group; d=$dir; sleep 3
echo "  fire's view:"
sed 's/^/    /' "$d/beats/attempts.log"
echo "  host received: attacker $(received "$d" attacker), direct to dest $(received "$d" dest '^direct'), udp $(received "$d" udp), abstract $(received "$d" abstract), declared agent $(received "$d" agent), undeclared $(received "$d" undeclared)"
echo "  chimney ok $(grep -c ' chimney ok ' "$d/beats/net.log"), dest received via chimney $(received "$d" dest '^ping'), smoke out records $(grep -c ' out chimney.net .* allow$' "$d/smoke.log")"
pid=$(main_pid "reach-$$"); stopped_pids+=("$pid"); kill -STOP "$pid"
bash "$ext/extinguish.sh" "reach-$$" | sed 's/^/  /'
echo "  still beating after: $(survivors "$d/beats")"

echo; echo "== B. supervisor SIGKILL, systemd kills the unit"
light "sup-cg-$$" control-group; d=$dir; sleep 2
t0=$(now); kill -9 "$(main_pid "sup-cg-$$")"
echo "  $(wait_out "sup-cg-$$" 6)"
echo "  still beating after: $(survivors "$d/beats")"

echo; echo "== C. supervisor SIGKILL, systemd told to kill only the main process (KillMode=process)"
light "sup-proc-$$" process; d=$dir; sleep 2
chimney_pid=$(cat "$d/chimney.pid")
kill -9 "$(main_pid "sup-proc-$$")"
echo "  fire still beating after: $(survivors "$d/beats")"
state=gone; kill -0 "$chimney_pid" 2>/dev/null && state=running
echo "  chimney (child of supervisor, outside bwrap): $state"
bash "$ext/extinguish.sh" "sup-proc-$$" | sed 's/^/  /'

echo; echo "== D. chimney SIGKILL"
light "chimney-$$" control-group; d=$dir; sleep 2
t0=$(now); kill -9 "$(cat "$d/chimney.pid")"
echo "  $(wait_out "chimney-$$" 6)"
echo "  chimney ok after kill: $(awk -v t="$t0" '$2=="chimney" && $3=="ok" && $1>t' "$d/beats/net.log" | wc -l)"
echo "  still beating after: $(survivors "$d/beats")"
