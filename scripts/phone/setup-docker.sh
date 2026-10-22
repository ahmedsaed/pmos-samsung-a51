#!/bin/sh
# Docker setup for the Samsung A51 (4.14 kernel without nf_tables).
# Run once: sudo sh ~/setup-docker.sh   (safe to re-run)
set -eu

apk add -q docker docker-cli-compose iptables iptables-legacy

# This kernel has no nf_tables: make "iptables" the legacy variant for
# everything that searches /usr/local/sbin first (login shells, dockerd).
mkdir -p /usr/local/sbin
for t in iptables ip6tables; do
	ln -sf /usr/sbin/$t-legacy /usr/local/sbin/$t
	ln -sf /usr/sbin/$t-legacy-save /usr/local/sbin/$t-save
	ln -sf /usr/sbin/$t-legacy-restore /usr/local/sbin/$t-restore
done

# OpenRC sources conf.d in its own helpers, so only *prepend* to PATH:
# replacing it hides OpenRC's /usr/libexec/rc/bin tools.
sed -i '/^export PATH="\/usr\/local\/sbin:\/usr\/local\/bin:\/usr\/sbin:\/usr\/bin:\/sbin:\/bin"$/d' /etc/conf.d/docker
line='export PATH="/usr/local/sbin:$PATH"'
grep -qxF "$line" /etc/conf.d/docker || echo "$line" >> /etc/conf.d/docker

# runc 1.5 (libpathrs) panics on this 4.14 kernel ("at least one candidate
# /proc/thread-self path should work"); use crun as the default runtime.
apk add -q crun
mkdir -p /etc/docker
if [ -e /etc/docker/daemon.json ] && ! grep -q '"crun"' /etc/docker/daemon.json; then
	cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
fi
cat > /etc/docker/daemon.json <<'JSON'
{
  "runtimes": {
    "crun": { "path": "/usr/bin/crun" }
  },
  "default-runtime": "crun"
}
JSON

# cgroup v2 device control needs BPF_PROG_TYPE_CGROUP_DEVICE (Linux 4.15+);
# on 4.14 crun fails with "bpf create: Invalid argument". Use cgroup v1
# controllers via OpenRC hybrid mode (needs a reboot to take effect).
if grep -q "^rc_cgroup_mode=" /etc/rc.conf; then
	sed -i "s/^rc_cgroup_mode=.*/rc_cgroup_mode=\"hybrid\"/" /etc/rc.conf
else
	echo "rc_cgroup_mode=\"hybrid\"" >> /etc/rc.conf
fi

# Samsung's Android "schedtune" controller allows only a few groups; creating
# one per container fails with "Out of memory". In hybrid mode, controllers
# listed in rc_cgroup_controllers are not mounted as v1 (and schedtune has
# no v2 equivalent), so this keeps it out of Docker's way.
if grep -q "^rc_cgroup_controllers=" /etc/rc.conf; then
	sed -i "s/^rc_cgroup_controllers=.*/rc_cgroup_controllers=\"schedtune\"/" /etc/rc.conf
else
	echo "rc_cgroup_controllers=\"schedtune\"" >> /etc/rc.conf
fi

addgroup ahmed docker 2>/dev/null || true
rc-update add docker default
rc-service docker restart

echo "--- check"
/usr/local/sbin/iptables --version
tail -1 /etc/conf.d/docker
crun --version | head -1
rc-service docker status
grep -E "^rc_cgroup_(mode|controllers)=" /etc/rc.conf
echo "Reboot if the cgroup settings were just changed: sudo reboot"
