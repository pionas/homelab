# Disposable "machine" for the install steps: Debian with systemd as PID 1.
# Run by run.sh under rootless Docker only. Kernel- and hardware-wide units are masked anyway.
FROM debian:13
ENV container=docker DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
  && apt-get install -y --no-install-recommends systemd systemd-sysv dbus openssh-server iproute2 \
    ca-certificates curl gnupg kmod procps iptables \
  && rm -rf /var/lib/apt/lists/* \
  # Kernel- and hardware-wide units: in a container they could only touch the host, or fail.
  && systemctl mask systemd-sysctl.service systemd-modules-load.service systemd-udevd.service \
    systemd-udev-trigger.service systemd-timesyncd.service getty@tty1.service systemd-firstboot.service \
  && mkdir -p /root/.ssh && chmod 700 /root/.ssh
COPY entrypoint.sh /usr/local/sbin/homelab-entrypoint
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/local/sbin/homelab-entrypoint"]
