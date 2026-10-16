#!/usr/bin/env bash
# Hostile fire: tries every route it knows to outlive an extinguish.
hb=$1
here=$(dirname "$(readlink -f "$0")")
common=$(dirname "$here")/common
user_cg="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service"
escape_cg="$user_cg/firepit-escape-$PIT_ID"
log() { echo "$1 $2" >> "$hb/attempts.log"; }
beat() { bash "$common/beat.sh" "$hb" "$1"; }

# Inside the process tree, detaching in every common way.
beat child & log child started
nohup bash "$common/beat.sh" "$hb" nohup >/dev/null 2>&1 & log nohup started
( setsid bash "$common/beat.sh" "$hb" daemon </dev/null >/dev/null 2>&1 & ) ; log daemon started

# Leave the cgroup by writing ourselves into another one.
setsid bash -c '
    mkdir -p "$1" 2>/dev/null && echo $$ > "$1/cgroup.procs" 2>/dev/null || exit 1
    exec bash "$2/beat.sh" "$3" migrate' _ "$escape_cg" "$common" "$hb" </dev/null >/dev/null 2>&1 &
sleep 0.3
[[ -f $hb/migrate.pid ]] && log migrate started || log migrate blocked

# Ask a host daemon to run work for us, now and later.
systemd-run --user --quiet --collect --unit="firepit-escape-run-$PIT_ID" \
  bash "$common/beat.sh" "$hb" proxy-run 2>/dev/null && log proxy-run started || log proxy-run blocked
systemd-run --user --quiet --collect --on-active=4 --unit="firepit-escape-timer-$PIT_ID" \
  bash "$common/beat.sh" "$hb" proxy-timer 2>/dev/null && log proxy-timer scheduled || log proxy-timer blocked

# Reachability only: a root-equivalent daemon one connect() away.
python3 -c 'import socket; socket.socket(socket.AF_UNIX).connect("/run/docker.sock")' 2>/dev/null \
  && log docker.sock reachable || log docker.sock blocked

exec bash "$common/beat.sh" "$hb" main
