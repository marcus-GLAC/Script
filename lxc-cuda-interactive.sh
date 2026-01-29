#!/usr/bin/env bash
#===============================================================================
# LXC CUDA Container Setup Script for Proxmox VE
# Based on community-scripts/ProxmoxVE framework
# Version: 3.0
# Repository: https://github.com/marcus-GLAC/Script
#
# Features:
#   - Uses community-scripts build.func for standard LXC creation
#   - NVIDIA GPU passthrough support
#   - CUDA Toolkit installation
#   - Interactive menu-driven setup
#===============================================================================

# Source community-scripts build functions
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Copyright (c) 2021-2026 community-scripts
# Author: marcus-GLAC (based on tteck's work)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

#===============================================================================
# APP CONFIGURATION
#===============================================================================

APP="LXC-CUDA"
var_tags="${var_tags:-gpu,cuda,nvidia}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-16384}"
var_disk="${var_disk:-50}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-0}"  # MUST be 0 for GPU passthrough

# CUDA Configuration
CUDA_VERSION="${CUDA_VERSION:-12.8}"
INSTALL_CUDA="${INSTALL_CUDA:-yes}"
GPU_SELECTION="${GPU_SELECTION:-all}"

#===============================================================================
# CUSTOM COLORS & VARIABLES
#===============================================================================

# Additional colors
NVIDIA_GREEN='\033[38;5;118m'

#===============================================================================
# NVIDIA GPU FUNCTIONS
#===============================================================================

check_nvidia_host() {
    if ! command -v nvidia-smi &>/dev/null; then
        msg_error "NVIDIA driver not found on host. Please install NVIDIA drivers first."
        exit 1
    fi
    
    if ! nvidia-smi &>/dev/null; then
        msg_error "nvidia-smi failed. Check your NVIDIA driver installation."
        exit 1
    fi
    
    msg_ok "NVIDIA driver detected on host"
}

get_gpu_count() {
    nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1
}

get_gpu_list() {
    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null
}

show_gpu_info() {
    echo -e "\n${NVIDIA_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo -e "${NVIDIA_GREEN}           NVIDIA GPU Information${CL}"
    echo -e "${NVIDIA_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv 2>/dev/null
    echo -e "${NVIDIA_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}\n"
}

select_gpu() {
    local gpu_count=$(get_gpu_count)
    
    if [ "$gpu_count" -eq 0 ]; then
        msg_error "No NVIDIA GPUs detected"
        exit 1
    elif [ "$gpu_count" -eq 1 ]; then
        GPU_SELECTION="0"
        msg_ok "Single GPU detected, using GPU 0"
        return 0
    fi
    
    echo -e "\n${YW}Multiple GPUs detected. Select GPU to passthrough:${CL}"
    echo ""
    
    local idx=0
    while IFS= read -r gpu_info; do
        echo -e "  ${GN}[$idx]${CL} $gpu_info"
        ((idx++))
    done < <(get_gpu_list)
    echo -e "  ${GN}[all]${CL} Passthrough all GPUs"
    echo ""
    
    read -p "Enter selection [all]: " selection
    GPU_SELECTION="${selection:-all}"
    
    msg_ok "Selected: $GPU_SELECTION"
}

configure_gpu_passthrough() {
    local ctid=$1
    
    msg_info "Configuring GPU passthrough for container $ctid"
    
    local conf="/etc/pve/lxc/${ctid}.conf"
    
    # Backup config
    cp "$conf" "${conf}.backup.$(date +%Y%m%d%H%M%S)"
    
    # Add cgroup permissions
    cat >> "$conf" << 'EOF'

# NVIDIA GPU Passthrough Configuration
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 509:* rwm
EOF

    # Device counter
    local dev_idx=0
    
    # Add GPU devices based on selection
    if [ "$GPU_SELECTION" = "all" ]; then
        local gpu_count=$(get_gpu_count)
        for ((i=0; i<gpu_count; i++)); do
            if [ -e "/dev/nvidia${i}" ]; then
                echo "dev${dev_idx}: /dev/nvidia${i}" >> "$conf"
                ((dev_idx++))
            fi
        done
    else
        if [ -e "/dev/nvidia${GPU_SELECTION}" ]; then
            echo "dev${dev_idx}: /dev/nvidia${GPU_SELECTION}" >> "$conf"
            ((dev_idx++))
        fi
    fi
    
    # Add common NVIDIA devices
    for device in /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
        if [ -e "$device" ]; then
            echo "dev${dev_idx}: ${device}" >> "$conf"
            ((dev_idx++))
        fi
    done
    
    # Add nvidia-caps devices
    if [ -d "/dev/nvidia-caps" ]; then
        for cap_device in /dev/nvidia-caps/nvidia-cap*; do
            if [ -e "$cap_device" ]; then
                echo "dev${dev_idx}: ${cap_device}" >> "$conf"
                ((dev_idx++))
            fi
        done
    fi
    
    msg_ok "GPU passthrough configured (${dev_idx} devices)"
}

install_cuda_in_container() {
    local ctid=$1
    local cuda_version=$2
    
    if [ "$cuda_version" = "skip" ] || [ "$cuda_version" = "no" ]; then
        msg_info "Skipping CUDA installation"
        return 0
    fi
    
    msg_info "Installing CUDA Toolkit $cuda_version in container $ctid"
    
    # Detect OS and add CUDA repository
    pct exec "$ctid" -- bash -c '
        export DEBIAN_FRONTEND=noninteractive
        cd /tmp
        
        # Detect OS
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS_ID="$ID"
            OS_VERSION="$VERSION_ID"
        else
            OS_ID="debian"
            OS_VERSION="12"
        fi
        
        # Determine CUDA repo
        case "$OS_ID" in
            ubuntu)
                case "$OS_VERSION" in
                    24.04) CUDA_REPO="ubuntu2404" ;;
                    22.04) CUDA_REPO="ubuntu2204" ;;
                    20.04) CUDA_REPO="ubuntu2004" ;;
                    *) CUDA_REPO="ubuntu2204" ;;
                esac
                ;;
            debian)
                case "$OS_VERSION" in
                    12) CUDA_REPO="debian12" ;;
                    11) CUDA_REPO="debian11" ;;
                    *) CUDA_REPO="debian12" ;;
                esac
                ;;
            *)
                CUDA_REPO="debian12"
                ;;
        esac
        
        echo "Using CUDA repository: $CUDA_REPO"
        
        # Download and install CUDA keyring
        wget -q "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/cuda-keyring_1.1-1_all.deb" -O cuda-keyring.deb
        dpkg -i cuda-keyring.deb
        apt-get update
    '
    
    # Install CUDA toolkit
    local cuda_major=$(echo "$cuda_version" | cut -d. -f1)
    local cuda_minor=$(echo "$cuda_version" | cut -d. -f2)
    local cuda_pkg="cuda-toolkit-${cuda_major}-${cuda_minor}"
    
    msg_info "Installing $cuda_pkg (this may take 5-10 minutes)..."
    pct exec "$ctid" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y $cuda_pkg
    "
    
    # Configure environment
    pct exec "$ctid" -- bash -c '
        CUDA_PATH=$(ls -d /usr/local/cuda-* 2>/dev/null | head -1)
        if [ -z "$CUDA_PATH" ]; then
            CUDA_PATH="/usr/local/cuda"
        fi
        
        cat > /etc/profile.d/cuda.sh << CUDA_ENV
# CUDA Environment Variables
export PATH=${CUDA_PATH}/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=${CUDA_PATH}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
export CUDA_HOME=${CUDA_PATH}
CUDA_ENV
        chmod +x /etc/profile.d/cuda.sh
        
        if ! grep -q "source /etc/profile.d/cuda.sh" /root/.bashrc; then
            echo "source /etc/profile.d/cuda.sh" >> /root/.bashrc
        fi
        
        if [ ! -e /usr/local/cuda ]; then
            ln -s $CUDA_PATH /usr/local/cuda
        fi
    '
    
    msg_ok "CUDA Toolkit $cuda_version installed"
}

install_dev_tools() {
    local ctid=$1
    
    msg_info "Installing development tools and libraries"
    
    pct exec "$ctid" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y \
            build-essential g++ gcc make cmake pkg-config git \
            autoconf automake libtool \
            freeglut3-dev libx11-dev libxmu-dev libxi-dev \
            libglu1-mesa-dev libfreeimage-dev libglfw3-dev \
            libcurl4-openssl-dev \
            wget curl gnupg2 ca-certificates \
            htop btop glances pciutils lshw sysstat \
            python3 python3-pip python3-dev python3-venv \
            vim nano \
            net-tools iputils-ping dnsutils
    "
    
    # Try to install nvtop
    pct exec "$ctid" -- bash -c "
        apt-get install -y nvtop 2>/dev/null || echo 'nvtop not available'
    "
    
    msg_ok "Development tools installed"
}

validate_gpu_in_container() {
    local ctid=$1
    
    echo -e "\n${NVIDIA_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo -e "${NVIDIA_GREEN}           Validating GPU Access${CL}"
    echo -e "${NVIDIA_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    
    if pct exec "$ctid" -- nvidia-smi &>/dev/null; then
        msg_ok "nvidia-smi works in container"
        pct exec "$ctid" -- nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
    else
        msg_error "nvidia-smi failed in container"
        echo -e "${YW}Try restarting the container: pct restart $ctid${CL}"
    fi
    
    # Check CUDA if installed
    if pct exec "$ctid" -- bash -c "source /etc/profile.d/cuda.sh 2>/dev/null && command -v nvcc" &>/dev/null; then
        msg_ok "CUDA compiler available"
        pct exec "$ctid" -- bash -c "source /etc/profile.d/cuda.sh && nvcc --version" | grep release
    fi
    
    echo -e "${NVIDIA_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}\n"
}

#===============================================================================
# UPDATE SCRIPT FUNCTION (required by build.func)
#===============================================================================

function update_script() {
    header_info
    check_container_storage
    check_container_resources
    
    if [[ ! -d /var ]]; then
        msg_error "No ${APP} Installation Found!"
        exit
    fi
    
    msg_info "Updating ${APP} LXC"
    $STD apt-get update
    $STD apt-get -y upgrade
    
    # Update CUDA if installed
    if command -v nvcc &>/dev/null; then
        msg_info "Updating CUDA toolkit..."
        $STD apt-get -y upgrade cuda-toolkit-* 2>/dev/null || true
    fi
    
    msg_ok "Updated ${APP} LXC"
    msg_ok "Updated successfully!"
    exit
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

# Show header
header_info "$APP"

# Initialize variables and colors from build.func
variables
color
catch_errors

# Check NVIDIA on host
check_nvidia_host

# Show GPU information
show_gpu_info

# Ask about GPU selection
echo -e "${YW}Configure GPU passthrough?${CL}"
read -p "Passthrough GPUs to container? [Y/n]: " do_gpu
do_gpu="${do_gpu:-Y}"

if [[ "$do_gpu" =~ ^[Yy]$ ]]; then
    select_gpu
fi

# Ask about CUDA installation
echo -e "\n${YW}CUDA Toolkit Installation${CL}"
echo -e "  ${GN}[1]${CL} CUDA 12.8 (Latest)"
echo -e "  ${GN}[2]${CL} CUDA 12.6"
echo -e "  ${GN}[3]${CL} CUDA 12.4"
echo -e "  ${GN}[4]${CL} CUDA 12.2"
echo -e "  ${GN}[5]${CL} CUDA 11.8 (Legacy)"
echo -e "  ${GN}[6]${CL} Skip CUDA installation"
read -p "Select CUDA version [1]: " cuda_choice
cuda_choice="${cuda_choice:-1}"

case $cuda_choice in
    1) CUDA_VERSION="12.8" ;;
    2) CUDA_VERSION="12.6" ;;
    3) CUDA_VERSION="12.4" ;;
    4) CUDA_VERSION="12.2" ;;
    5) CUDA_VERSION="11.8" ;;
    6) CUDA_VERSION="skip" ;;
    *) CUDA_VERSION="12.8" ;;
esac

# Ask about development tools
echo -e "\n${YW}Install development tools and libraries?${CL}"
echo -e "(Includes: build-essential, cmake, OpenGL libs, Python, monitoring tools)"
read -p "Install dev tools? [Y/n]: " do_dev
do_dev="${do_dev:-Y}"

# Start container creation using build.func
echo ""
start
build_container

# Get the created container ID
CTID=$(cat /tmp/ctid 2>/dev/null || echo "$CT_ID")

# Configure GPU passthrough
if [[ "$do_gpu" =~ ^[Yy]$ ]]; then
    configure_gpu_passthrough "$CTID"
fi

# Start container for software installation
msg_info "Starting container for software installation"
pct start "$CTID"
sleep 5

# Wait for container to be ready
retry=0
while [ $retry -lt 30 ]; do
    if pct exec "$CTID" -- test -d /root &>/dev/null; then
        break
    fi
    sleep 2
    ((retry++))
done

# Install development tools
if [[ "$do_dev" =~ ^[Yy]$ ]]; then
    install_dev_tools "$CTID"
fi

# Install CUDA
if [ "$CUDA_VERSION" != "skip" ]; then
    install_cuda_in_container "$CTID" "$CUDA_VERSION"
fi

# Restart container to apply GPU configuration
msg_info "Restarting container to apply GPU configuration"
pct stop "$CTID"
sleep 2
pct start "$CTID"
sleep 5

# Validate GPU access
if [[ "$do_gpu" =~ ^[Yy]$ ]]; then
    validate_gpu_in_container "$CTID"
fi

# Show description
description

# Final message
msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo ""
echo -e "${YW}Quick Commands:${CL}"
echo -e "  pct enter $CTID              # Enter container"
echo -e "  pct exec $CTID -- nvidia-smi # Check GPU"
echo -e "  pct exec $CTID -- nvcc -V    # Check CUDA"
echo ""
