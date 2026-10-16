#!/usr/bin/env bash
# Runs every scenario and prints what survived. Cleans up after itself.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
spike=$(mktemp -d /tmp/firepit-spike.XXXX)
user_cg="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service"
methods=(main child nohup daemon migrate proxy-run proxy-timer)
ids=()

ignite() { # id mode -> sets $sup
  local id=$1 mode=$2
  ids+=("$id")
  mkdir -p "$spike/$id"
  bash "$here/vessel.sh" "$id" "$spike/$id" "$mode" -- bash "$here/probe.sh" "$spike/$id" &
  sup=$!
}

forget_beats() { rm -f "$spike/$1"/*.beat; }

report() { # id
  local id=$1 hb=$spike/$1 attempt after
  printf '  %-12s %-11s %s\n' method attempt "after"
  for m in "${methods[@]}"; do
    attempt=$(awk -v m="$m" '$1==m {print $2}' "$hb/attempts.log" 2>/dev/null)
    attempt=${attempt:-started}
    if [[ $attempt == blocked ]]; then after=-
    elif [[ -f $hb/$m.beat ]]; then after=SURVIVED
    else after=out
    fi
    printf '  %-12s %-11s %s\n' "$m" "$attempt" "$after"
  done
  printf '  %-12s %s\n' docker.sock "$(awk '$1=="docker.sock" {print $2}' "$hb/attempts.log")"
}

cleanup() {
  for id in "${ids[@]}"; do
    bash "$here/extinguish.sh" "$id" >/dev/null 2>&1
    systemctl --user stop "firepit-escape-run-$id.service" "firepit-escape-timer-$id.timer" \
      "firepit-escape-timer-$id.service" 2>/dev/null
    if [[ -d $user_cg/firepit-escape-$id ]]; then
      echo 1 > "$user_cg/firepit-escape-$id/cgroup.kill"
      sleep 0.2
      rmdir "$user_cg/firepit-escape-$id"
    fi
    rm -f "${XDG_RUNTIME_DIR}/firepit/$id.json"
  done
  for pidfile in "$spike"/*/*.pid; do
    [[ -f $pidfile ]] || continue
    pid=$(<"$pidfile")
    grep -q beat.sh "/proc/$pid/cmdline" 2>/dev/null && kill -9 "$pid"
  done
  rm -rf "$spike"
}
trap cleanup EXIT

scenario_frozen() { # mode
  local id="frozen-$1-$$"
  echo; echo "== $1 fire, supervisor frozen, extinguish one pit"
  ignite "$id" "$1"; sleep 2
  kill -STOP "$sup"
  bash "$here/extinguish.sh" "$id" | sed 's/^/  /'
  sleep 1; forget_beats "$id"; sleep 5
  report "$id"
  kill -CONT "$sup"; wait "$sup" 2>/dev/null
}

scenario_all() {
  local a="all-a-$$" b="all-b-$$"
  echo; echo "== two sealed pits, extinguish --all"
  ignite "$a" sealed; local sa=$sup
  ignite "$b" sealed; local sb=$sup
  sleep 2
  bash "$here/extinguish.sh" --all | sed 's/^/  /'
  sleep 1; forget_beats "$a"; forget_beats "$b"; sleep 2
  echo "  pit a:"; report "$a" | grep -E '^  (main|child|nohup|daemon) '
  echo "  pit b:"; report "$b" | grep -E '^  (main|child|nohup|daemon) '
  wait "$sa" "$sb" 2>/dev/null
}

scenario_supervisor_dies() {
  local id="orphan-$$"
  echo; echo "== sealed fire, supervisor SIGKILLed (fail-closed?)"
  ignite "$id" sealed; sleep 2
  kill -9 "$sup"; wait "$sup" 2>/dev/null
  sleep 1; forget_beats "$id"; sleep 2
  report "$id" | grep -E '^  (method|main|child|nohup|daemon) '
}

echo "kernel $(uname -r), spike dir $spike"
scenario_frozen unsealed
scenario_frozen sealed
scenario_all
scenario_supervisor_dies
