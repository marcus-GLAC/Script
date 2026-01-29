#!/bin/bash
#===============================================================================
# LXC CUDA Container Setup Script for Proxmox VE
# Interactive Menu-Driven Installation
# Version: 2.0
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
BACKTITLE="Proxmox VE Helper Scripts - LXC with NVIDIA GPU Support"

# Terminal size
HEIGHT=20
WIDTH=70

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
    whiptail --title "$TITLE" \
        --msgbox "Welcome to LXC CUDA Container Setup!\n\n\
This wizard will guide you through creating a new LXC container with:\n\n\
  ✓ NVIDIA GPU passthrough\n\
  ✓ CUDA Toolkit installation\n\
  ✓ Development tools\n\n\
Detected GPU:\n$(get_nvidia_info)\n\n\
Press OK to continue..." \
        18 $WIDTH
}

main_menu() {
    local choice
    choice=$(whiptail --title "$TITLE" \
        --backtitle "$BACKTITLE" \
        --menu "Choose installation mode:" 15 $WIDTH 5 \
        "1" "Quick Install (Default Settings)" \
        "2" "Advanced Install (Custom Settings)" \
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

get_resources() {
    local form_data
    
    form_data=$(whiptail --title "Resource Allocation" \
        --backtitle "$BACKTITLE" \
        --form "Configure container resources:" 16 $WIDTH 4 \
        "CPU Cores:" 1 1 "$DEFAULT_CORES" 1 20 10 0 \
        "Memory (MB):" 2 1 "$DEFAULT_MEMORY" 2 20 10 0 \
        "Swap (MB):" 3 1 "$DEFAULT_SWAP" 3 20 10 0 \
        "Disk (GB):" 4 1 "$DEFAULT_DISK" 4 20 10 0 \
        3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ]; then
        echo "$form_data"
        return 0
    else
        echo -e "$DEFAULT_CORES\n$DEFAULT_MEMORY\n$DEFAULT_SWAP\n$DEFAULT_DISK"
        return 1
    fi
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
        20 $WIDTH 10 "${templates[@]}" 3>&1 1>&2 2>&3)
    
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
        storages+=("$counter" "$storage")
        ((counter++))
    done < <(list_storages)
    
    if [ ${#storages[@]} -eq 0 ]; then
        echo "$DEFAULT_STORAGE"
        return 1
    fi
    
    local choice
    choice=$(whiptail --title "Select Storage" \
        --backtitle "$BACKTITLE" \
        --menu "Choose storage for container:" \
        18 $WIDTH 8 "${storages[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$choice" ]; then
        echo "${storages[$((choice*2-1))]}"
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
        bridges+=("$counter" "$bridge")
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
        16 $WIDTH 6 "${bridges[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$choice" ]; then
        echo "${bridges[$((choice*2-1))]}"
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
        "1" "DHCP (Automatic IP)" \
        "2" "Static IP (Manual)" \
        "3" "Manual (Configure later)" \
        3>&1 1>&2 2>&3)
    
    case $choice in
        1) echo "dhcp" ;;
        2) 
            local ip
            ip=$(whiptail --title "Static IP Configuration" \
                --backtitle "$BACKTITLE" \
                --inputbox "Enter IP address with CIDR:\n\nExample: 192.168.1.100/24" \
                10 $WIDTH "192.168.1.100/24" 3>&1 1>&2 2>&3)
            
            if [ $? -eq 0 ] && [ -n "$ip" ]; then
                local gw
                gw=$(whiptail --title "Gateway" \
                    --backtitle "$BACKTITLE" \
                    --inputbox "Enter gateway IP:\n\nExample: 192.168.1.1" \
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
        16 $WIDTH 6 \
        "1" "CUDA 12.8 (Latest - Recommended)" \
        "2" "CUDA 12.6" \
        "3" "CUDA 12.4" \
        "4" "CUDA 12.2" \
        "5" "CUDA 11.8 (Legacy)" \
        "6" "Skip CUDA installation" \
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
        --checklist "Select additional features:" \
        18 $WIDTH 8 \
        "1" "Install development tools (git, cmake, gcc)" ON \
        "2" "Install monitoring tools (htop, nvtop, btop)" ON \
        "3" "Install Python3 and pip" ON \
        "4" "Enable container nesting (for Docker)" ON \
        "5" "Auto-start container on boot" ON \
        "6" "Install text editors (vim, nano)" ON \
        3>&1 1>&2 2>&3)
    
    echo "$options"
}

confirm_configuration() {
    local config="$1"
    
    whiptail --title "Confirm Configuration" \
        --backtitle "$BACKTITLE" \
        --yesno "$config\n\nProceed with installation?" \
        22 $WIDTH
}

show_gpu_info() {
    local gpu_info
    gpu_info=$(nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,temperature.gpu,utilization.gpu \
        --format=csv,noheader 2>/dev/null)
    
    whiptail --title "GPU Information" \
        --backtitle "$BACKTITLE" \
        --msgbox "Detected NVIDIA GPU(s):\n\n$gpu_info\n\n\
Driver Information:\n$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)\n\n\
Press OK to return to menu." \
        20 $WIDTH
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
            msg_info "Downloading template..."
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
    
    msg_ok "Container created successfully"
}

configure_gpu_passthrough() {
    local ctid=$1
    
    msg_info "Configuring GPU passthrough..."
    
    local conf="/etc/pve/lxc/${ctid}.conf"
    
    # Backup
    cp "$conf" "${conf}.backup"
    
    # Add GPU configuration
    cat >> "$conf" << 'EOF'

# NVIDIA GPU Passthrough Configuration
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 509:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
EOF

    # Add all NVIDIA devices
    for device in /dev/nvidia*; do
        if [ -e "$device" ] && [[ ! "$device" =~ nvidia-caps ]]; then
            local dev_name=$(basename "$device")
            if ! grep -q "$dev_name" "$conf"; then
                echo "lxc.mount.entry: $device dev/$dev_name none bind,optional,create=file" >> "$conf"
            fi
        fi
    done
    
    msg_ok "GPU passthrough configured"
}

start_container() {
    local ctid=$1
    
    msg_info "Starting container..."
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
    
    msg_ok "Container started"
}

install_cuda_toolkit() {
    local ctid=$1
    local cuda_version=$2
    local install_dev=$3
    local install_monitor=$4
    local install_python=$5
    local install_editors=$6
    
    msg_info "Installing CUDA Toolkit $cuda_version..."
    
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
            apt-transport-https
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
                git
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
                lshw
        " || msg_warn "Some monitoring tools failed to install"
        
        # Try to install nvtop (may not be in repos)
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y nvtop 2>/dev/null || true
        "
    fi
    
    # Install Python
    if [ "$install_python" = "true" ]; then
        msg_info "Installing Python3..."
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y \
                python3 \
                python3-pip \
                python3-dev \
                python3-venv
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
        
        msg_info "Installing CUDA Toolkit $cuda_version (this may take a while)..."
        pct exec "$ctid" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y $cuda_pkg
        " || msg_error "Failed to install CUDA Toolkit"
        
        # Configure CUDA environment
        msg_info "Configuring CUDA environment..."
        pct exec "$ctid" -- bash -c "
            cat > /etc/profile.d/cuda.sh << 'CUDA_ENV'
export PATH=/usr/local/cuda-${cuda_version}/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-${cuda_version}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
export CUDA_HOME=/usr/local/cuda-${cuda_version}
CUDA_ENV
            chmod +x /etc/profile.d/cuda.sh
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
    
    msg_ok "Installation completed"
}

validate_installation() {
    local ctid=$1
    local cuda_version=$2
    
    msg_info "Validating installation..."
    
    echo ""
    echo "=========================================="
    echo "           Validation Results"
    echo "=========================================="
    echo ""
    
    # Test nvidia-smi
    echo -e "${CYAN}Testing nvidia-smi...${NC}"
    if pct exec "$ctid" -- nvidia-smi &>/dev/null; then
        msg_ok "nvidia-smi works"
        pct exec "$ctid" -- nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    else
        msg_warn "nvidia-smi failed (may need container restart)"
    fi
    
    echo ""
    
    # Test nvcc if CUDA installed
    if [ "$cuda_version" != "skip" ]; then
        echo -e "${CYAN}Testing CUDA compiler...${NC}"
        if pct exec "$ctid" -- bash -c "source /etc/profile.d/cuda.sh && nvcc --version" &>/dev/null; then
            msg_ok "CUDA compiler works"
            pct exec "$ctid" -- bash -c "source /etc/profile.d/cuda.sh && nvcc --version" | grep "release"
        else
            msg_warn "CUDA compiler test failed"
        fi
    fi
    
    echo ""
    echo "=========================================="
}

#===============================================================================
# INSTALLATION WORKFLOWS
#===============================================================================

quick_install() {
    header_info
    
    msg_info "Starting Quick Install with default settings..."
    echo ""
    
    # Get required info
    CTID=$(get_container_id) || exit 0
    HOSTNAME=$(get_hostname) || HOSTNAME="lxc-cuda-$CTID"
    
    # Use defaults
    CORES=$DEFAULT_CORES
    MEMORY=$DEFAULT_MEMORY
    SWAP=$DEFAULT_SWAP
    DISK=$DEFAULT_DISK
    TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
    STORAGE=$DEFAULT_STORAGE
    BRIDGE=$DEFAULT_BRIDGE
    IP="dhcp"
    CUDA_VERSION=$DEFAULT_CUDA
    INSTALL_DEV="true"
    INSTALL_MONITOR="true"
    INSTALL_PYTHON="true"
    INSTALL_EDITORS="true"
    ONBOOT="1"
    NESTING="true"
    
    # Show configuration
    local config="Container Configuration:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CTID:      $CTID
Hostname:  $HOSTNAME
CPU:       $CORES cores
Memory:    $MEMORY MB
Swap:      $SWAP MB
Disk:      $DISK GB
Storage:   $STORAGE
Template:  Debian 12
Network:   $BRIDGE (DHCP)
CUDA:      $CUDA_VERSION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! confirm_configuration "$config"; then
        msg_warn "Installation cancelled"
        return
    fi
    
    # Execute installation
    create_container "$CTID" "$HOSTNAME" "$CORES" "$MEMORY" "$SWAP" "$DISK" \
        "$TEMPLATE" "$STORAGE" "$BRIDGE" "$IP" "$ONBOOT" "$NESTING"
    
    configure_gpu_passthrough "$CTID"
    start_container "$CTID"
    install_cuda_toolkit "$CTID" "$CUDA_VERSION" "$INSTALL_DEV" "$INSTALL_MONITOR" \
        "$INSTALL_PYTHON" "$INSTALL_EDITORS"
    validate_installation "$CTID" "$CUDA_VERSION"
    
    show_completion_summary "$CTID" "$HOSTNAME"
}

advanced_install() {
    header_info
    
    msg_info "Starting Advanced Install..."
    echo ""
    
    # Gather all configuration
    CTID=$(get_container_id) || exit 0
    HOSTNAME=$(get_hostname) || HOSTNAME="lxc-cuda-$CTID"
    
    # Resources
    local resources
    resources=$(get_resources)
    CORES=$(echo "$resources" | sed -n '1p')
    MEMORY=$(echo "$resources" | sed -n '2p')
    SWAP=$(echo "$resources" | sed -n '3p')
    DISK=$(echo "$resources" | sed -n '4p')
    
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
    
    [[ "$options" =~ \"1\" ]] && INSTALL_DEV="true"
    [[ "$options" =~ \"2\" ]] && INSTALL_MONITOR="true"
    [[ "$options" =~ \"3\" ]] && INSTALL_PYTHON="true"
    [[ "$options" =~ \"4\" ]] && NESTING="true"
    [[ "$options" =~ \"5\" ]] && ONBOOT="1"
    [[ "$options" =~ \"6\" ]] && INSTALL_EDITORS="true"
    
    # Show configuration
    local config="Container Configuration:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CTID:      $CTID
Hostname:  $HOSTNAME
CPU:       $CORES cores
Memory:    $MEMORY MB
Swap:      $SWAP MB
Disk:      $DISK GB
Storage:   $STORAGE
Template:  $(basename "$TEMPLATE")
Network:   $BRIDGE ($IP)
CUDA:      $CUDA_VERSION
Auto-boot: $([ "$ONBOOT" = "1" ] && echo "Yes" || echo "No")
Nesting:   $([ "$NESTING" = "true" ] && echo "Yes" || echo "No")
Dev Tools: $([ "$INSTALL_DEV" = "true" ] && echo "Yes" || echo "No")
Monitors:  $([ "$INSTALL_MONITOR" = "true" ] && echo "Yes" || echo "No")
Python:    $([ "$INSTALL_PYTHON" = "true" ] && echo "Yes" || echo "No")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! confirm_configuration "$config"; then
        msg_warn "Installation cancelled"
        return
    fi
    
    # Execute installation
    create_container "$CTID" "$HOSTNAME" "$CORES" "$MEMORY" "$SWAP" "$DISK" \
        "$TEMPLATE" "$STORAGE" "$BRIDGE" "$IP" "$ONBOOT" "$NESTING"
    
    configure_gpu_passthrough "$CTID"
    start_container "$CTID"
    install_cuda_toolkit "$CTID" "$CUDA_VERSION" "$INSTALL_DEV" "$INSTALL_MONITOR" \
        "$INSTALL_PYTHON" "$INSTALL_EDITORS"
    validate_installation "$CTID" "$CUDA_VERSION"
    
    show_completion_summary "$CTID" "$HOSTNAME"
}

show_completion_summary() {
    local ctid=$1
    local hostname=$2
    
    whiptail --title "Installation Complete!" \
        --backtitle "$BACKTITLE" \
        --msgbox "✓ Container $ctid created successfully!\n\n\
Hostname: $hostname\n\
Status: $(pct status "$ctid")\n\n\
Quick Commands:\n\
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\
Enter container:\n\
  pct enter $ctid\n\n\
Console access:\n\
  pct console $ctid\n\n\
Check GPU:\n\
  pct exec $ctid -- nvidia-smi\n\n\
Check CUDA:\n\
  pct exec $ctid -- nvcc --version\n\n\
Container management:\n\
  pct stop $ctid\n\
  pct start $ctid\n\
  pct restart $ctid\n\
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\
Press OK to exit." \
        30 $WIDTH
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
