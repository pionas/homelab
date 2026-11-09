#!/bin/sh
# systemd needs to create cgroups below /sys/fs/cgroup (with a private cgroup namespace this is only
# the container's own subtree). Remount it read-write only when it is not writable already.
set -eu
if mkdir /sys/fs/cgroup/homelab-probe 2>/dev/null; then
  rmdir /sys/fs/cgroup/homelab-probe
else
  mount -o remount,rw /sys/fs/cgroup
fi
exec /sbin/init
