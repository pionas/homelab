#!/bin/sh
# With a private cgroup namespace /sys/fs/cgroup is only this container's own subtree; Docker mounts
# it read-only, and systemd needs to create its units below it.
set -eu
mount -o remount,rw /sys/fs/cgroup
exec /sbin/init
