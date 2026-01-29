#!/bin/bash
set -euo pipefail

### ========= CHECK ENV =========
if ! command -v pct >/dev/null; then
  echo "ERROR: This script must be run on Proxmox host"
  exit 1
fi

if ! command -v nvidia-smi >/dev/null; then
  echo "ERROR: NVIDIA driver not found on host"
  exit 1
fi

nvidia-smi >/dev/null || { echo "ERROR: nvidia-smi failed"; exit 1; }

### ========= USER INPUT =========
read -rp "LXC CTID (e.g. 120): " CTID
read -rp "Hostname (e.g. lxc-cuda): " HOSTNAME
read -rp "CPU cores: " CORES
read -rp "RAM (MB, e.g. 32768): " MEMORY
read -rp "Disk size (GB, e.g. 100): " DISK
read -rsp "LXC root password: " PASSWORD
echo ""

### ========= DEFAULT CONFIG =========
TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
STORAGE="local-lvm"
BRIDGE="vmbr0"
IP="dhcp"

### ========= CONFIRM =========
echo "--------------------------------------"
echo "CTID     : $CTID"
echo "Hostname : $HOSTNAME"
echo "CPU      : $CORES"
echo "RAM      : $MEMORY MB"
echo "Disk     : $DISK GB"
echo "Storage  : $STORAGE"
echo "--------------------------------------"
read -rp "Proceed? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

### ========= CREATE LXC =========
pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --rootfs "$STORAGE:$DISK" \
  --net0 name=eth0,bridge="$BRIDGE",ip="$IP" \
  --password "$PASSWORD" \
  --unprivileged 0 \
  --features keyctl=1,nesting=1

### ========= GPU PASSTHROUGH =========
cat <<EOF >> /etc/pve/lxc/$CTID.conf
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 509:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
EOF

### ========= START LXC =========
pct start "$CTID"
sleep 5

### ========= INSTALL CUDA INSIDE LXC =========
pct exec "$CTID" -- bash <<'EOF'
set -e

apt update && apt upgrade -y

apt install -y \
  g++ freeglut3-dev build-essential \
  libx11-dev libxmu-dev libxi-dev \
  libglu1-mesa-dev libfreeimage-dev \
  libglfw3-dev wget htop btop nvtop \
  glances git pciutils cmake curl \
  libcurl4-openssl-dev

wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb

apt update
apt install -y cuda-toolkit-12-8

cp ~/.bashrc ~/.bashrc-backup || true
grep -qxF 'export PATH=/usr/local/cuda-12.8/bin${PATH:+:${PATH}}' ~/.bashrc || \
echo 'export PATH=/usr/local/cuda-12.8/bin${PATH:+:${PATH}}' >> ~/.bashrc
EOF

### ========= VALIDATE =========
echo "=== VALIDATING GPU INSIDE LXC ==="
pct exec "$CTID" -- nvidia-smi
pct exec "$CTID" -- nvcc --version

echo "======================================"
echo "LXC $CTID READY WITH CUDA 12.8"
echo "Login: pct enter $CTID"
echo "======================================"
