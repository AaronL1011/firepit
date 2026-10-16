#!/usr/bin/env bash
# A process that refuses polite signals and proves it is alive by touching a file.
# Self-limits to MAX seconds so a failed spike never leaves a fire burning.
hb=$1 name=$2 max=${3:-60}
trap '' TERM HUP INT
echo $$ > "$hb/$name.pid"
end=$((SECONDS + max))
while ((SECONDS < end)); do
  touch "$hb/$name.beat"
  sleep 0.2
done
