#!/usr/bin/env bash
# Put out one pit, or every pit, through the kernel. Never asks the vessel.
set -euo pipefail
uid=$(id -u)
root="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/firepit.slice"

case "${1:-}" in
  "") echo "usage: extinguish.sh PIT_ID | --all" >&2; exit 2 ;;
  --all) target=$root name="every pit" ;;
  *) target="" name="pit $1"
     # A vessel may run its pit as a scope or a service; the group is the same either way.
     for unit in "$root/firepit-$1.scope" "$root/firepit-$1.service"; do
       if [[ -d $unit ]]; then target=$unit; fi
     done ;;
esac

if [[ -z $target || ! -d $target ]]; then
  [[ $1 == --all ]] && { echo "out: nothing burning"; exit 0; }
  echo "no such pit: $1" >&2; exit 2
fi

start=$(date +%s%N)
echo 1 > "$target/cgroup.kill"

# Out means the kernel reports the group empty, or the group is gone.
deadline=$((SECONDS + 5))
until [[ ! -d $target ]] || grep -qx 'populated 0' "$target/cgroup.events" 2>/dev/null; do
  ((SECONDS < deadline)) || { echo "STILL BURNING: $name" >&2; exit 1; }
  sleep 0.01
done
echo "out: $name ($(( ($(date +%s%N) - start) / 1000000 )) ms)"
