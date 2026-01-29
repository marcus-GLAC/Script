#!/bin/bash
#===============================================================================
# LXC CUDA Container Setup Script for Proxmox VE
# Interactive Menu-Driven Installation with GPU Selection
# Version: 2.1
# Repository: https://github.com/marcus-GLAC/Script
#===============================================================================

set -euo pipefail

#===============================================================================
# CONFIGURATION & COLORS
#===============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
DEFAULT_CORES=4
DEFAULT_MEMORY=16384
DEFAULT_SWAP=8192
DEFAULT_DISK=50
DEFAULT_STORAGE="local-lvm"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_CUDA="12.8"

# Script title for whiptail
TITLE="LXC CUDA Container Setup"
BACKTITLE="Proxmox VE Helper Scripts - LXC with NVIDIA GPU Support v2.1"

# Terminal size
HEIGHT=20
WIDTH=78

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

header_info() {
    clear
    cat << "EOF"
    __   _  ______    _______ __  __ _____   ___  
   / /  | |/ / ___| / / ____|  \/  |  __ \ / _ \ 
  / /   |   / /    / / |    | \  / | |  | / /_\ \
 / /    |  < /    / /| |    | |\/| | |  | |  _  |
/ /____ | . \ \__/ / | |____| |  | | |__| | | | |
\______/|_|\_\____/   \_____|_|  |_|_____/|_| |_|
                                                   
   Proxmox LXC Container with NVIDIA CUDA Support
           https://github.com/marcus-GLAC/Script
EOF
    echo ""
}

#===============================================================================
# PREREQUISITE CHECKS
#===============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_error "This script must be run as root"
    fi
}

check_proxmox() {
    if ! command -v pct &>/dev/null; then
        msg_error "This script must be run on a Proxmox VE host"
    fi
}

check_nvidia() {
    if ! command -v nvidia-smi &>/dev/null; then
        msg_error "NVIDIA driver not found. Please install NVIDIA drivers first."
    fi
    
    if ! nvidia-smi &>/dev/null; then
        msg_error "nvidia-smi failed. Check your NVIDIA driver installation."
    fi
}

check_whiptail() {
    if ! command -v whiptail &>/dev/null; then
        msg_info "Installing whiptail..."
        apt-get update &>/dev/null
        apt-get install -y whiptail &>/dev/null
        msg_ok "Whiptail installed"
    fi
}

run_checks() {
    header_info
    msg_info "Running prerequisite checks..."
    check_root
    check_proxmox
    check_nvidia
    check_whiptail
    msg_ok "All checks passed"
    sleep 2
}

#===============================================================================
# GPU DETECTION AND SELECTION
#===============================================================================

get_gpu_count() {
    nvidia-smi --query-gpu=count --format=csv,noheader | head -1
}

get_gpu_list() {
    nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader 2>/dev/null
}

get_gpu_info_by_index() {
    local idx=$1
    nvidia-smi -i "$idx" --query-gpu=name,memory.total,driver_version,pci.bus_id --format=csv,noheader 2>/dev/null
}

select_gpu() {
    local gpu_count=$(get_gpu_count)
    
    if [ "$gpu_count" -eq 0 ]; then
        msg_error "No NVIDIA GPUs detected"
    elif [ "$gpu_count" -eq 1 ]; then
        # Only one GPU, use it automatically
        echo "0"
        return 0
    fi
    
    # Multiple GPUs, let user choose
    local gpu_list=()
    local counter=0
    
    while IFS= read -r gpu_info; do
        local index=$(echo "$gpu_info" | cut -d',' -f1)
        local name=$(echo "$gpu_info" | cut -d',' -f2 | xargs)
        local memory=$(echo "$gpu_info" | cut -d',' -f3 | xargs)
        local driver=$(echo "$gpu_info" | cut -d',' -f4 | xargs)
        
        gpu_list+=("$index" "GPU $index: $name | $memory | Driver: $driver")
        ((counter++))
    done < <(get_gpu_list)
    
    # Add option for all GPUs
    gpu_list+=("all" "All GPUs (Passthrough all $gpu_count GPUs)")
    
    local choice
    choice=$(whiptail --title "Select GPU" \
        --backtitle "$BACKTITLE" \
        --menu "Multiple GPUs detected. Choose which GPU to passthrough:" \
        20 $WIDTH 10 "${gpu_list[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$choice" ]; then
        echo "$choice"
        return 0
    else
        echo "0"
        return 1
    fi
}

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

list_templates() {
    pveam available --section system 2>/dev/null | \
        grep -E "debian-12|ubuntu-24|ubuntu-22" | \
        awk '{print $2}' | \
        head -20
}

list_storages() {
    pvesm status 2>/dev/null | \
        awk 'NR>1 {print $1}' | \
        grep -v "^$"
}

list_bridges() {
    ip -o link show type bridge 2>/dev/null | \
        awk -F': ' '{print $2}' | \
        grep -v "^$"
}

get_nvidia_info() {
    nvidia-smi --query-gpu=name,driver_version,memory.total \
        --format=csv,noheader 2>/dev/null | head -1
}

validate_ctid() {
    local ctid=$1
    
    # Check if numeric
    if ! [[ "$ctid" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # Check range
    if [ "$ctid" -lt 100 ] || [ "$ctid" -gt 999999999 ]; then
        return 1
    fi
    
    # Check if exists
    if pct status "$ctid" &>/dev/null; then
        return 1
    fi
    
    return 0
}

#===============================================================================
# MENU FUNCTIONS
#===============================================================================

show_welcome() {
    local gpu_count=$(get_gpu_count)
    local gpu_info=$(get_gpu_list | head -3)
    
    whiptail --title "$TITLE" \
        --msgbox "Welcome to LXC CUDA Container Setup!\n\n\
This wizard will guide you through creating a new LXC container with:\n\n\
  ✓ NVIDIA GPU passthrough\n\
  ✓ CUDA Toolkit installation\n\
  ✓ Development tools\n\n\
Detected GPUs: $gpu_count\n\
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\
$gpu_info\n\
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\
Press OK to continue..." \
        22 $WIDTH
}

main_menu() {
    local choice
    choice=$(whiptail --title "$TITLE" \
        --backtitle "$BACKTITLE" \
        --menu "Choose installation mode:" 16 $WIDTH 5 \
        "1" "Quick Install (Recommended for single GPU)" \
        "2" "Advanced Install (Custom configuration)" \
        "3" "View GPU Information" \
        "4" "Exit" \
        3>&1 1>&2 2>&3)
    
    echo "$choice"
}

get_container_id() {
    local ctid=""
    
    while true; do
        ctid=$(whiptail --title "Container ID" \
            --backtitle "$BACKTITLE" \
            --inputbox "Enter Container ID (CTID):\n\n\
Requirements:\n\
  • Must be between 100 and 999999999\n\
  • Must be unique (not already in use)\n\n\
Suggested: 120" \
            15 $WIDTH "" 3>&1 1>&2 2>&3)
        
        # Check if cancelled
        if [ $? -ne 0 ]; then
            return 1
        fi
        
        # Validate
        if validate_ctid "$ctid"; then
            echo "$ctid"
            return 0
        else
            whiptail --title "Invalid CTID" \
                --msgbox "Invalid Container ID or CTID already exists.\n\nPlease try again." \
                8 $WIDTH
        fi
    done
}

get_hostname() {
    local hostname=""
    
    hostname=$(whiptail --title "Hostname" \
        --backtitle "$BACKTITLE" \
        --inputbox "Enter hostname for the container:\n\n\
Only alphanumeric characters and hyphens allowed." \
        12 $WIDTH "lxc-cuda" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$hostname" ]; then
        echo "$hostname"
        return 0
    else
        echo "lxc-cuda"
        return 1
    fi
}

get_cpu_cores() {
    local cores
    
    # Get total CPU cores on host
    local total_cores=$(nproc)
    local suggested_cores=$((total_cores / 2))
    [ $suggested_cores -lt 2 ] && suggested_cores=2
    [ $suggested_cores -gt 16 ] && suggested_cores=16
    
    cores=$(whiptail --title "CPU Cores" \
        --backtitle "$BACKTITLE" \
        --inputbox "Enter number of CPU cores for the container:\n\n\
Host has: $total_cores cores\n\
Suggested: $suggested_cores cores\n\
Range: 1-$total_cores" \
        14 $WIDTH "$suggested_cores" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$cores" ]; then
        # Validate range
        if [ "$cores" -ge 1 ] && [ "$cores" -le "$total_cores" ]; then
            echo "$cores"
            return 0
        fi
    fi
    
    echo "$DEFAULT_CORES"
    return 1
}

get_memory() {
    local memory
    
    # Get total memory on host (in MB)
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local suggested_mem=$((total_mem / 2))
    [ $suggested_mem -lt 4096 ] && suggested_mem=4096
    [ $suggested_mem -gt 65536 ] && suggested_mem=65536
    
    memory=$(whiptail --title "Memory (RAM)" \
        --backtitle "$BACKTITLE" \
        --inputbox "Enter memory size in MB:\n\n\
Host has: $total_mem MB\n\
Suggested: $suggested_mem MB\n\
Minimum: 2048 MB\n\
Range: 2048-$total_mem" \
        15 $WIDTH "$suggested_mem" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$memory" ]; then
        # Validate range
        if [ "$memory" -ge 2048 ] && [ "$memory" -le "$total_mem" ]; then
            echo "$memory"
            return 0
        fi
    fi
    
    echo "$DEFAULT_MEMORY"
    return 1
}

get_swap() {
    local swap
    local default_swap=$(($(get_memory 2>/dev/null || echo $DEFAULT_MEMORY) / 2))
    
    swap=$(whiptail --title "Swap Memory" \
        --backtitle "$BACKTITLE" \
        --inputbox "Enter swap size in MB:\n\n\
Suggested: $default_swap MB (half of RAM)\n\
Set to 0 to disable swap\n\
Range: 0-65536" \
        13 $WIDTH "$default_swap" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$swap" ]; then
        echo "$swap"
        return 0
    fi
    
    echo "$DEFAULT_SWAP"
    return 1
}

get_disk() {
    local disk
    
    disk=$(whiptail --title "Disk Size" \
        --backtitle "$BACKTITLE" \
        --inputbox "Enter disk size in GB:\n\n\
Minimum: 20 GB (for OS + CUDA)\n\
Recommended: 50+ GB\n\
Range: 20-1000" \
        13 $WIDTH "$DEFAULT_DISK" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$disk" ]; then
        # Validate range
        if [ "$disk" -ge 20 ] && [ "$disk" -le 1000 ]; then
            echo "$disk"
            return 0
        fi
    fi
    
    echo "$DEFAULT_DISK"
    return 1
}

select_template() {
    local templates=()
    local counter=1
    
    # Get available templates
    while IFS= read -r template; do
        templates+=("$counter" "$template")
        ((counter++))
    done < <(list_templates)
    
    # If no templates found, use default
    if [ ${#templates[@]} -eq 0 ]; then
        echo "local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
        return 1
    fi
    
    local choice
    choice=$(whiptail --title "Select OS Template" \
        --backtitle "$BACKTITLE" \
        --menu "Choose an OS template for your container:" \
        22 $WIDTH 12 "${templates[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$choice" ]; then
        echo "${templates[$((choice*2-1))]}"
        return 0
    else
        echo "local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
        return 1
    fi
}

select_storage() {
    local storages=()
    local counter=1
    
    while IFS= read -r storage; do
        # Get storage info
        local storage_info=$(pvesm status | awk -v st="$storage" '$1==st {print $2, $3, $4}')
        storages+=("$counter" "$storage ($storage_info)")
        ((counter++))
    done < <(list_storages)
    
    if [ ${#storages[@]} -eq 0 ]; then
        echo "$DEFAULT_STORAGE"
        return 1
    fi
    
    local choice
    choice=$(whiptail --title "Select Storage" \
        --backtitle "$BACKTITLE" \
        --menu "Choose storage pool for container:" \
        20 $WIDTH 10 "${storages[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$choice" ]; then
        # Extract just the storage name (before the space)
        local storage_name="${storages[$((choice*2-1))]}"
        echo "$storage_name" | awk '{print $1}'
        return 0
    else
        echo "$DEFAULT_STORAGE"
        return 1
    fi
}

select_network_bridge() {
    local bridges=()
    local counter=1
    
    while IFS= read -r bridge; do
        # Get IP info for bridge
        local ip_info=$(ip -4 addr show "$bridge" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
        if [ -n "$ip_info" ]; then
            bridges+=("$counter" "$bridge ($ip_info)")
        else
            bridges+=("$counter" "$bridge")
        fi
        ((counter++))
    done < <(list_bridges)
    
    if [ ${#bridges[@]} -eq 0 ]; then
        echo "$DEFAULT_BRIDGE"
        return 1
    fi
    
    local choice
    choice=$(whiptail --title "Network Bridge" \
        --backtitle "$BACKTITLE" \
        --menu "Choose network bridge:" \
        18 $WIDTH 8 "${bridges[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$choice" ]; then
        # Extract just the bridge name
        local bridge_name="${bridges[$((choice*2-1))]}"
        echo "$bridge_name" | awk '{print $1}'
        return 0
    else
        echo "$DEFAULT_BRIDGE"
        return 1
    fi
}

select_network_mode() {
    local choice
    choice=$(whiptail --title "Network Configuration" \
        --backtitle "$BACKTITLE" \
        --menu "Select IP configuration mode:" \
        14 $WIDTH 3 \
        "1" "DHCP (Automatic IP assignment)" \
        "2" "Static IP (Manual configuration)" \
        "3" "Manual (Configure after creation)" \
        3>&1 1>&2 2>&3)
    
    case $choice in
        1) echo "dhcp" ;;
        2) 
            local ip
            ip=$(whiptail --title "Static IP Configuration" \
                --backtitle "$BACKTITLE" \
                --inputbox "Enter IP address with CIDR notation:\n\nExample: 192.168.1.100/24" \
                10 $WIDTH "192.168.1.100/24" 3>&1 1>&2 2>&3)
            
            if [ $? -eq 0 ] && [ -n "$ip" ]; then
                local gw
                gw=$(whiptail --title "Gateway" \
                    --backtitle "$BACKTITLE" \
                    --inputbox "Enter gateway IP address:\n\nExample: 192.168.1.1" \
                    10 $WIDTH "192.168.1.1" 3>&1 1>&2 2>&3)
                
                if [ $? -eq 0 ] && [ -n "$gw" ]; then
                    echo "$ip,gw=$gw"
                else
                    echo "$ip"
                fi
            else
                echo "dhcp"
            fi
            ;;
        3) echo "manual" ;;
        *) echo "dhcp" ;;
    esac
}

select_cuda_version() {
    local choice
    choice=$(whiptail --title "CUDA Toolkit Version" \
        --backtitle "$BACKTITLE" \
        --menu "Select CUDA Toolkit version to install:" \
        18 $WIDTH 7 \
        "1" "CUDA 12.8 (Latest - Recommended)" \
        "2" "CUDA 12.6" \
        "3" "CUDA 12.4" \
        "4" "CUDA 12.2" \
        "5" "CUDA 11.8 (Legacy support)" \
        "6" "Skip CUDA installation (Install manually later)" \
        3>&1 1>&2 2>&3)
    
    case $choice in
        1) echo "12.8" ;;
        2) echo "12.6" ;;
        3) echo "12.4" ;;
        4) echo "12.2" ;;
        5) echo "11.8" ;;
        6) echo "skip" ;;
        *) echo "12.8" ;;
    esac
}

select_additional_options() {
    local options
    options=$(whiptail --title "Additional Options" \
        --backtitle "$BACKTITLE" \
        --checklist "Select additional features to install:" \
        20 $WIDTH 8 \
        "1" "Development tools (git, cmake, gcc, build-essential)" ON \
        "2" "Monitoring tools (htop, nvtop, btop, glances)" ON \
        "3" "Python3 with pip and virtualenv" ON \
        "4" "Enable container nesting (for Docker support)" ON \
        "5" "Auto-start container on host boot" ON \
        "6" "Text editors (vim, nano)" ON \
        "7" "Network tools (curl, wget, net-tools)" ON \
        3>&1 1>&2 2>&3)
    
    echo "$options"
}

confirm_configuration() {
    local config="$1"
    
    whiptail --title "Confirm Configuration" \
        --backtitle "$BACKTITLE" \
        --yesno "$config\n\nDo you want to proceed with the installation?" \
        24 $WIDTH
}

show_gpu_info() {
    local gpu_info
    gpu_info=$(nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,temperature.gpu,utilization.gpu,power.draw \
        --format=csv 2>/dev/null)
    
    whiptail --title "GPU Information" \
        --backtitle "$BACKTITLE" \
        --msgbox "Detected NVIDIA GPU(s):\n\n$gpu_info\n\nPress OK to return to menu." \
        22 $WIDTH
}

#===============================================================================
# INSTALLATION FUNCTIONS
#===============================================================================

create_container() {
    local ctid=$1
    local hostname=$2
    local cores=$3
    local memory=$4
    local swap=$5
    local disk=$6
    local template=$7
    local storage=$8
    local bridge=$9
    local ip=${10}
    local onboot=${11}
    local nesting=${12}
    
    msg_info "Creating LXC container $ctid..."
    
    local features="keyctl=1"
    if [ "$nesting" = "true" ]; then
        features="$features,nesting=1"
    fi
    
    # Download template if needed
    if [[ "$template" == local:* ]]; then
        local template_name=$(basename "$template")
        if [ ! -f "/var/lib/vz/template/cache/$template_name" ]; then
            msg_info "Downloading template $template_name..."
            pveam download local "$template_name" || msg_error "Failed to download template"
        fi
    fi
    
    # Create container
    pct create "$ctid" "$template" \
        --hostname "$hostname" \
        --cores "$cores" \
        --memory "$memory" \
        --swap "$swap" \
        --rootfs "$storage:$disk" \
        --net0 "name=eth0,bridge=$bridge,ip=$ip,firewall=1" \
        --unprivileged 0 \
        --features "$features" \
        --onboot "$onboot" \
        --start 0 || msg_error "Failed to create container"
    
    msg_ok "Container $ctid created successfully"
}

configure_gpu_passthrough() {
    local ctid=$1
    local gpu_selection=$2
    
    msg_info "Configuring GPU passthrough for container $ctid..."
    
    local conf="/etc/pve/lxc/${ctid}.conf"
    
    # Backup
    cp "$conf" "${conf}.backup"
    
    # Add base GPU configuration
    cat >> "$conf" << 'EOF'

# NVIDIA GPU Passthrough Configuration
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 509:* rwm
EOF

    # Add devices based on GPU selection
    if [ "$gpu_selection" = "all" ]; then
        msg_info "Configuring passthrough for all GPUs..."
        
        # Add all GPU devices
        local gpu_count=$(get_gpu_count)
        for ((i=0; i<gpu_count; i++)); do
            echo "lxc.mount.entry: /dev/nvidia${i} dev/nvidia${i} none bind,optional,create=file" >> "$conf"
        done
        
        # Add common devices
        for device in /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
            if [ -e "$device" ]; then
                local dev_name=$(basename "$device")
                echo "lxc.mount.entry: $device dev/$dev_name none bind,optional,create=file" >> "$conf"
            fi
        done
        
        msg_ok "All $gpu_count GPUs configured for passthrough"
    else
        msg_info "Configuring passthrough for GPU $gpu_selection..."
        
        # Add specific GPU device
        echo "lxc.mount.entry: /dev/nvidia${gpu_selection} dev/nvidia${gpu_selection} none bind,optional,create=file" >> "$conf"
        
        # Add common devices
        for device in /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
            if [ -e "$device" ]; then
                local dev_name=$(basename "$device")
                echo "lxc.mount.entry: $device dev/$dev_name none bind,optional,create=file" >> "$conf"
            fi
        done
        
        msg_ok "GPU $gpu_selection configured for passthrough"
    fi
    
    # Set CUDA_VISIBLE_DEVICES if specific GPU selected
    if [ "$gpu_selection" != "all" ]; then
        cat >> "$conf" << EOF

# Set CUDA_VISIBLE_DEVICES for GPU $gpu_selection
lxc.environment: CUDA_VISIBLE_DEVICES=$gpu_selection
EOF
    fi
}

start_container() {
    local ctid=$1
    
    msg_info "Starting container $ctid..."
    pct start "$ctid" || msg_error "Failed to start container"
    
    sleep 3
    
    # Wait for container to be ready
    local retry=0
    while [ $retry -lt 30 ]; do
        if pct exec "$ctid" -- test -d /root &>/dev/null; then
            break
        fi
        sleep 2
        ((retry++))
    done
    
    if [ $retry -ge 30 ]; then
        msg_warn "Container may not be fully ready, continuing anyway..."
    else
        msg_ok "Container started and ready"
    fi
}

install_cuda_toolkit() {
    local ctid=$1
    local cuda_version=$2
    local install_dev=$3
    local install_monitor=$4
    local install_python=$5
    local install_editors=$6
    local install_network=$7
    
    msg_info "Installing packages in container $ctid..."
    
    # Update system
    msg_info "Updating system packages..."
    pct exec "$ctid" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get upgrade -y
    " || msg_warn "System update had some issues, continuing..."
    
    # Install base packages
    msg_info "Installing base packages..."
    pct exec "$ctid" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y \
            wget curl gnupg2 \
            software-properties-common \
            ca-certificates \
            apt-transport-https \
            lsb-release
    " || msg_error "Failed to install base packages"
    
    # Install development tools
    if [ "$install_dev" = "true" ]; then
        msg_info "Installing development tools..."
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y \
                build-essential \
                g++ gcc make cmake \
                pkg-config \
                git \
                autoconf automake libtool
        " || msg_warn "Some development tools failed to install"
    fi
    
    # Install monitoring tools
    if [ "$install_monitor" = "true" ]; then
        msg_info "Installing monitoring tools..."
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y \
                htop btop \
                glances \
                pciutils \
                lshw \
                sysstat
        " || msg_warn "Some monitoring tools failed to install"
        
        # Try to install nvtop
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y nvtop 2>/dev/null || echo 'nvtop not available in repos, skipping...'
        "
    fi
    
    # Install Python
    if [ "$install_python" = "true" ]; then
        msg_info "Installing Python3 and tools..."
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y \
                python3 \
                python3-pip \
                python3-dev \
                python3-venv \
                python3-setuptools \
                python3-wheel
        " || msg_warn "Python installation had issues"
    fi
    
    # Install editors
    if [ "$install_editors" = "true" ]; then
        msg_info "Installing text editors..."
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y vim nano
        " || msg_warn "Text editors installation had issues"
    fi
    
    # Install network tools
    if [ "$install_network" = "true" ]; then
        msg_info "Installing network tools..."
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y \
                curl wget \
                net-tools \
                iputils-ping \
                dnsutils \
                telnet \
                netcat-openbsd
        " || msg_warn "Network tools installation had issues"
    fi
    
    # Install CUDA
    if [ "$cuda_version" != "skip" ]; then
        msg_info "Adding CUDA repository..."
        pct exec "$ctid" -- bash -c "
            cd /tmp
            wget -q https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
            dpkg -i cuda-keyring_1.1-1_all.deb
            apt-get update
        " || msg_error "Failed to add CUDA repository"
        
        local cuda_major=$(echo "$cuda_version" | cut -d. -f1)
        local cuda_minor=$(echo "$cuda_version" | cut -d. -f2)
        local cuda_pkg="cuda-toolkit-${cuda_major}-${cuda_minor}"
        
        msg_info "Installing CUDA Toolkit $cuda_version (this may take 5-10 minutes)..."
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y $cuda_pkg
        " || msg_error "Failed to install CUDA Toolkit"
        
        # Configure CUDA environment
        msg_info "Configuring CUDA environment variables..."
        pct exec "$ctid" -- bash -c "
            cat > /etc/profile.d/cuda.sh << 'CUDA_ENV'
export PATH=/usr/local/cuda-${cuda_version}/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-${cuda_version}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
export CUDA_HOME=/usr/local/cuda-${cuda_version}
CUDA_ENV
            chmod +x /etc/profile.d/cuda.sh
            
            # Also add to bashrc for convenience
            echo 'source /etc/profile.d/cuda.sh' >> /root/.bashrc
        "
        
        msg_ok "CUDA Toolkit $cuda_version installed successfully"
    fi
    
    # Cleanup
    msg_info "Cleaning up..."
    pct exec "$ctid" -- bash -c "
        apt-get autoremove -y
        apt-get clean
        rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
    " || true
    
    msg_ok "All packages installed successfully"
}

validate_installation() {
    local ctid=$1
    local cuda_version=$2
    local gpu_selection=$3
    
    msg_info "Validating installation..."
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "           Validation Results"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Test nvidia-smi
    echo -e "${CYAN}Testing nvidia-smi...${NC}"
    if pct exec "$ctid" -- nvidia-smi &>/dev/null; then
        msg_ok "nvidia-smi works correctly"
        echo ""
        pct exec "$ctid" -- nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=table
        echo ""
    else
        msg_warn "nvidia-smi failed - GPU may not be accessible"
        echo "Try restarting the container: pct restart $ctid"
    fi
    
    # Test nvcc if CUDA installed
    if [ "$cuda_version" != "skip" ]; then
        echo ""
        echo -e "${CYAN}Testing CUDA compiler (nvcc)...${NC}"
        if pct exec "$ctid" -- bash -c "source /etc/profile.d/cuda.sh && nvcc --version" &>/dev/null; then
            msg_ok "CUDA compiler works correctly"
            pct exec "$ctid" -- bash -c "source /etc/profile.d/cuda.sh && nvcc --version" | grep "release"
        else
            msg_warn "CUDA compiler test failed"
        fi
    fi
    
    # Show GPU assignment
    echo ""
    if [ "$gpu_selection" = "all" ]; then
        echo -e "${GREEN}✓${NC} All GPUs are passed through to this container"
    else
        echo -e "${GREEN}✓${NC} GPU $gpu_selection is passed through to this container"
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

#===============================================================================
# INSTALLATION WORKFLOWS
#===============================================================================

quick_install() {
    header_info
    
    msg_info "Starting Quick Install with recommended settings..."
    echo ""
    
    # Get required info
    CTID=$(get_container_id) || exit 0
    HOSTNAME=$(get_hostname) || HOSTNAME="lxc-cuda-$CTID"
    
    # Select GPU
    GPU_SELECTION=$(select_gpu)
    
    # Get resources with smart defaults
    CORES=$(get_cpu_cores) || CORES=$DEFAULT_CORES
    MEMORY=$(get_memory) || MEMORY=$DEFAULT_MEMORY
    SWAP=$((MEMORY / 2))
    DISK=$(get_disk) || DISK=$DEFAULT_DISK
    
    # Use defaults for other settings
    TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
    STORAGE=$DEFAULT_STORAGE
    BRIDGE=$DEFAULT_BRIDGE
    IP="dhcp"
    CUDA_VERSION=$DEFAULT_CUDA
    INSTALL_DEV="true"
    INSTALL_MONITOR="true"
    INSTALL_PYTHON="true"
    INSTALL_EDITORS="true"
    INSTALL_NETWORK="true"
    ONBOOT="1"
    NESTING="true"
    
    # Show configuration
    local gpu_info=$(get_gpu_info_by_index "$GPU_SELECTION")
    [ "$GPU_SELECTION" = "all" ] && gpu_info="All GPUs ($(get_gpu_count) total)"
    
    local config="Container Configuration:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CTID:       $CTID
Hostname:   $HOSTNAME
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Resources:
  CPU:      $CORES cores
  Memory:   $MEMORY MB
  Swap:     $SWAP MB
  Disk:     $DISK GB
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Storage:    $STORAGE
Template:   Debian 12 (Latest)
Network:    $BRIDGE (DHCP)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GPU:        $gpu_info
CUDA:       $CUDA_VERSION (Latest)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Features:
  • Development tools (git, cmake, gcc)
  • Monitoring tools (htop, nvtop, btop)
  • Python3 with pip
  • Text editors (vim, nano)
  • Network tools
  • Container nesting enabled
  • Auto-start on boot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! confirm_configuration "$config"; then
        msg_warn "Installation cancelled"
        return
    fi
    
    # Execute installation
    create_container "$CTID" "$HOSTNAME" "$CORES" "$MEMORY" "$SWAP" "$DISK" \
        "$TEMPLATE" "$STORAGE" "$BRIDGE" "$IP" "$ONBOOT" "$NESTING"
    
    configure_gpu_passthrough "$CTID" "$GPU_SELECTION"
    start_container "$CTID"
    install_cuda_toolkit "$CTID" "$CUDA_VERSION" "$INSTALL_DEV" "$INSTALL_MONITOR" \
        "$INSTALL_PYTHON" "$INSTALL_EDITORS" "$INSTALL_NETWORK"
    validate_installation "$CTID" "$CUDA_VERSION" "$GPU_SELECTION"
    
    show_completion_summary "$CTID" "$HOSTNAME" "$GPU_SELECTION"
}

advanced_install() {
    header_info
    
    msg_info "Starting Advanced Install with custom configuration..."
    echo ""
    
    # Gather all configuration
    CTID=$(get_container_id) || exit 0
    HOSTNAME=$(get_hostname) || HOSTNAME="lxc-cuda-$CTID"
    
    # Select GPU first
    GPU_SELECTION=$(select_gpu)
    
    # Resources
    CORES=$(get_cpu_cores) || CORES=$DEFAULT_CORES
    MEMORY=$(get_memory) || MEMORY=$DEFAULT_MEMORY
    SWAP=$(get_swap) || SWAP=$DEFAULT_SWAP
    DISK=$(get_disk) || DISK=$DEFAULT_DISK
    
    # Template and storage
    TEMPLATE=$(select_template)
    STORAGE=$(select_storage)
    
    # Network
    BRIDGE=$(select_network_bridge)
    IP=$(select_network_mode)
    
    # CUDA
    CUDA_VERSION=$(select_cuda_version)
    
    # Additional options
    local options
    options=$(select_additional_options)
    
    INSTALL_DEV="false"
    INSTALL_MONITOR="false"
    INSTALL_PYTHON="false"
    NESTING="false"
    ONBOOT="0"
    INSTALL_EDITORS="false"
    INSTALL_NETWORK="false"
    
    [[ "$options" =~ \"1\" ]] && INSTALL_DEV="true"
    [[ "$options" =~ \"2\" ]] && INSTALL_MONITOR="true"
    [[ "$options" =~ \"3\" ]] && INSTALL_PYTHON="true"
    [[ "$options" =~ \"4\" ]] && NESTING="true"
    [[ "$options" =~ \"5\" ]] && ONBOOT="1"
    [[ "$options" =~ \"6\" ]] && INSTALL_EDITORS="true"
    [[ "$options" =~ \"7\" ]] && INSTALL_NETWORK="true"
    
    # Show configuration
    local gpu_info=$(get_gpu_info_by_index "$GPU_SELECTION")
    [ "$GPU_SELECTION" = "all" ] && gpu_info="All GPUs ($(get_gpu_count) total)"
    
    local config="Container Configuration:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CTID:       $CTID
Hostname:   $HOSTNAME
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Resources:
  CPU:      $CORES cores
  Memory:   $MEMORY MB
  Swap:     $SWAP MB
  Disk:     $DISK GB
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Storage:    $STORAGE
Template:   $(basename "$TEMPLATE")
Network:    $BRIDGE ($IP)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GPU:        $gpu_info
CUDA:       $CUDA_VERSION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Features:
  Auto-boot:  $([ "$ONBOOT" = "1" ] && echo "Yes" || echo "No")
  Nesting:    $([ "$NESTING" = "true" ] && echo "Yes" || echo "No")
  Dev Tools:  $([ "$INSTALL_DEV" = "true" ] && echo "Yes" || echo "No")
  Monitors:   $([ "$INSTALL_MONITOR" = "true" ] && echo "Yes" || echo "No")
  Python:     $([ "$INSTALL_PYTHON" = "true" ] && echo "Yes" || echo "No")
  Editors:    $([ "$INSTALL_EDITORS" = "true" ] && echo "Yes" || echo "No")
  Network:    $([ "$INSTALL_NETWORK" = "true" ] && echo "Yes" || echo "No")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! confirm_configuration "$config"; then
        msg_warn "Installation cancelled"
        return
    fi
    
    # Execute installation
    create_container "$CTID" "$HOSTNAME" "$CORES" "$MEMORY" "$SWAP" "$DISK" \
        "$TEMPLATE" "$STORAGE" "$BRIDGE" "$IP" "$ONBOOT" "$NESTING"
    
    configure_gpu_passthrough "$CTID" "$GPU_SELECTION"
    start_container "$CTID"
    install_cuda_toolkit "$CTID" "$CUDA_VERSION" "$INSTALL_DEV" "$INSTALL_MONITOR" \
        "$INSTALL_PYTHON" "$INSTALL_EDITORS" "$INSTALL_NETWORK"
    validate_installation "$CTID" "$CUDA_VERSION" "$GPU_SELECTION"
    
    show_completion_summary "$CTID" "$HOSTNAME" "$GPU_SELECTION"
}

show_completion_summary() {
    local ctid=$1
    local hostname=$2
    local gpu=$3
    
    local gpu_desc="GPU $gpu"
    [ "$gpu" = "all" ] && gpu_desc="All GPUs"
    
    whiptail --title "Installation Complete! 🎉" \
        --backtitle "$BACKTITLE" \
        --msgbox "✓ Container $ctid has been created successfully!\n\n\
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\
Container Info:\n\
  CTID:     $ctid\n\
  Hostname: $hostname\n\
  Status:   $(pct status "$ctid")\n\
  GPU:      $gpu_desc\n\
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\
\n\
Quick Access Commands:\n\
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\
Enter container:\n\
  pct enter $ctid\n\
\n\
Console access:\n\
  pct console $ctid\n\
\n\
Check GPU status:\n\
  pct exec $ctid -- nvidia-smi\n\
\n\
Check CUDA version:\n\
  pct exec $ctid -- nvcc --version\n\
\n\
Container management:\n\
  pct stop $ctid       # Stop container\n\
  pct start $ctid      # Start container\n\
  pct restart $ctid    # Restart container\n\
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\
\n\
Enjoy your LXC CUDA container! 🚀\n\
\n\
Press OK to exit." \
        32 $WIDTH
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

main() {
    # Run checks
    run_checks
    
    # Show welcome
    show_welcome
    
    # Main loop
    while true; do
        choice=$(main_menu)
        
        case $choice in
            1)
                quick_install
                break
                ;;
            2)
                advanced_install
                break
                ;;
            3)
                show_gpu_info
                ;;
            4|"")
                msg_info "Exiting..."
                exit 0
                ;;
            *)
                msg_warn "Invalid option"
                ;;
        esac
    done
}

# Trap errors
trap 'msg_error "Script failed at line $LINENO"' ERR

# Run main
main "$@"
