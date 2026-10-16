#!/usr/bin/env bash
# One-time admin install for Firepit spikes.
#
# What it grants: permission to create user namespaces, which the network
# and mount isolation of a pit needs.
# To which program: a root-owned copy of bubblewrap at
#   /usr/local/lib/firepit/bwrap, and nothing else.
# How to remove it: sudo bash install.sh --uninstall
#
# Only needed where AppArmor restricts unprivileged user namespaces
# (Ubuntu 23.10 and later). Elsewhere it does nothing.
set -euo pipefail

bin_dir=/usr/local/lib/firepit
bin=$bin_dir/bwrap
profile=/etc/apparmor.d/firepit-bwrap

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

if [[ ${1:-} == --uninstall ]]; then
  [[ -f $profile ]] && apparmor_parser -R "$profile" && rm -f "$profile"
  rm -f "$bin"
  rmdir "$bin_dir" 2>/dev/null || true
  echo "removed"
  exit 0
fi

if [[ $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0) != 1 ]]; then
  echo "user namespaces are not restricted on this system; nothing to install"
  exit 0
fi

command -v bwrap >/dev/null || { echo "bubblewrap is not installed (apt install bubblewrap)" >&2; exit 1; }

install -d -m 0755 -o root -g root "$bin_dir"
install -m 0755 -o root -g root "$(command -v bwrap)" "$bin"

cat > "$profile" <<EOF
# Firepit: lets $bin create user namespaces. Nothing else changes.
abi <abi/4.0>,
include <tunables/global>

profile firepit-bwrap $bin flags=(unconfined) {
  userns,

  include if exists <local/firepit-bwrap>
}
EOF
apparmor_parser -r "$profile"
echo "installed: $bin may create user namespaces"
