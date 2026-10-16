#!/usr/bin/env bash
# Breaks each part of a running pit and reports whether the fire went out,
# or the chimney was cut, and whether anything crossed without smoke.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
ext="$here/../extinguisher"
spike=$(mktemp -d /tmp/firepit-fc.XXXX)
cg_root="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/firepit.slice"
ids=() outside_pids=() stopped_pids=()

free_ports() {
  python3 -c '
import socket
socks = [socket.socket() for _ in range(2)]
for s in socks: s.bind(("127.0.0.1", 0))
print(*[s.getsockname()[1] for s in socks])'
}

light() { # id watchdog_sec [smoke_limit] ; sets dir
  local id=$1 watchdog=$2 limit=${3:-} dport cport
  dir="$spike/$id"; mkdir -p "$dir"; ids+=("$id")
  read -r dport cport < <(free_ports)
  python3 "$here/outside.py" "$dir" "$dport" "$cport" >/dev/null 2>&1 &
  outside_pids+=($!)
  until (exec 9<>"/dev/tcp/127.0.0.1/$dport") 2>/dev/null; do sleep 0.05; done
  bash "$here/vessel.sh" "$id" "$dir" "$cport" "127.0.0.1:$dport" "$watchdog" $limit
}

main_pid() { systemctl --user show -p MainPID --value "firepit-$1.service"; }
now() { date +%s.%N; }

wait_out() { # id timeout_sec -> prints ms since $t0, or STILL BURNING
  local unit="$cg_root/firepit-$1.service" deadline=$((SECONDS + $2))
  until [[ ! -d $unit ]] || grep -qx 'populated 0' "$unit/cgroup.events" 2>/dev/null; do
    ((SECONDS < deadline)) || { echo "STILL BURNING"; return; }
    sleep 0.01
  done
  awk -v a="$t0" -v b="$(now)" 'BEGIN { printf "out in %d ms\n", (b - a) * 1000 }'
}

survivors() { # beat_dir -> names of processes still beating
  rm -f "$1"/*.beat; sleep 1.5
  local alive
  alive=$(cd "$1" && ls -- *.beat 2>/dev/null | sed 's/\.beat$//' | tr '\n' ' ')
  echo "${alive:-none}"
}

count() { # dir route result [after_ts]
  awk -v r="$2" -v res="$3" -v t="${4:-0}" '$2==r && $3==res && $1>t' "$1/work/net.log" 2>/dev/null | wc -l
}

lines() { [[ -f $1 ]] && wc -l < "$1" || echo 0; }
smoke_out() { grep -c ' out chimney.net .* allow$' "$1/smoke.log"; }
terminal() { grep -o 'vessel terminal .*' "$1/smoke.log" || echo "MISSING"; }

cleanup() {
  for pid in "${stopped_pids[@]}"; do kill -CONT "$pid" 2>/dev/null; done
  for id in "${ids[@]}"; do
    bash "$ext/extinguish.sh" "$id" >/dev/null 2>&1
    systemctl --user stop "firepit-$id.service" 2>/dev/null
    rm -f "$XDG_RUNTIME_DIR/firepit/$id.json"
  done
  for pid in "${outside_pids[@]}"; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$spike"
}
trap cleanup EXIT

echo "kernel $(uname -r), $(systemctl --version | head -1)"

echo; echo "== A. baseline: healthy pit, 3 s"
light "base-$$" 2; d=$dir; sleep 3
echo "  chimney          ok $(count "$d" chimney ok)   fail $(count "$d" chimney fail)"
echo "  direct to dest   ok $(count "$d" direct ok)   denied $(count "$d" direct denied)"
echo "  udp to dest      ok $(count "$d" udp ok)   denied $(count "$d" udp denied)"
echo "  same port, other host (127.0.0.2)   ok $(count "$d" samePortOtherHost ok)   attacker received $(lines "$d/attacker.log")"
echo "  $(cat "$d/work/attempts.log")"
echo "  dest received $(lines "$d/echo.log"), smoke out records $(smoke_out "$d")"
bash "$ext/extinguish.sh" "base-$$" | sed 's/^/  /'; sleep 0.3
echo "  terminal record: $(terminal "$d")"

echo; echo "== B. supervisor SIGKILL"
light "kill-sup-$$" 2; d=$dir; sleep 2
t0=$(now); kill -9 "$(main_pid "kill-sup-$$")"
echo "  $(wait_out "kill-sup-$$" 6)"
echo "  still beating after: $(survivors "$d/work")"
echo "  terminal record: $(terminal "$d")"

echo; echo "== C. supervisor hung (SIGSTOP), watchdog 2 s"
light "hang-sup-$$" 2; d=$dir; sleep 2
pid=$(main_pid "hang-sup-$$"); stopped_pids+=("$pid")
t0=$(now); kill -STOP "$pid"
echo "  $(wait_out "hang-sup-$$" 8)"
echo "  still beating after: $(survivors "$d/work")"
echo "  terminal record: $(terminal "$d")"

echo; echo "== D. chimney SIGKILL"
light "kill-chimney-$$" 2; d=$dir; sleep 2
before=$(smoke_out "$d")
t0=$(now); kill -9 "$(cat "$d/chimney.pid")"
echo "  $(wait_out "kill-chimney-$$" 6)"
echo "  chimney ok after kill: $(count "$d" chimney ok "$t0")"
echo "  smoke out records added after kill: $(( $(smoke_out "$d") - before ))"
echo "  still beating after: $(survivors "$d/work")"
echo "  $(grep -o 'vessel chimney died.*' "$d/smoke.log")"
echo "  terminal record: $(terminal "$d")"

echo; echo "== E. smoke full (chimney file size limit 2048 B)"
light "full-$$" 2 2048; d=$dir; t0=$(now)
echo "  $(wait_out "full-$$" 10) (from ignition)"
echo "  chimney answered $(count "$d" chimney ok) requests"
echo "  dest received $(lines "$d/echo.log"), smoke out records $(smoke_out "$d")  (pass if received <= recorded)"
echo "  still beating after: $(survivors "$d/work")"
echo "  $(grep -o 'vessel chimney died.*' "$d/smoke.log")"
echo "  terminal record: $(terminal "$d")"

echo; echo "== F. two vessel implementations, both supervisors frozen, extinguish --all"
scope_id="impl-scope-$$"; ids+=("$scope_id"); mkdir -p "$spike/$scope_id"
bash "$ext/vessel.sh" "$scope_id" "$spike/$scope_id" sealed -- bash "$ext/probe.sh" "$spike/$scope_id" 2>/dev/null &
scope_sup=$!
light "impl-service-$$" 30; d=$dir; sleep 2
service_sup=$(main_pid "impl-service-$$")
stopped_pids+=("$scope_sup" "$service_sup")
kill -STOP "$scope_sup" "$service_sup"
bash "$ext/extinguish.sh" --all | sed 's/^/  /'
echo "  scope vessel still beating: $(survivors "$spike/$scope_id")"
echo "  service vessel still beating: $(survivors "$d/work")"
kill -CONT "$scope_sup" 2>/dev/null; wait "$scope_sup" 2>/dev/null || true
