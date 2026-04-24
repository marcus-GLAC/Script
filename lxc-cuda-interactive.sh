#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 tteck & marcus-GLAC
# Author: tteck (tteckster), marcus-GLAC
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/marcus-GLAC/Script

#===============================================================================
# LXC CUDA Container - Community Scripts Compatible
# Supports: GPU Passthrough, CUDA Toolkit Installation
#===============================================================================

APP="LXC-CUDA"
var_tags="${var_tags:-os;gpu;cuda}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-16384}"
var_disk="${var_disk:-50}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

# CUDA Configuration
CUDA_VERSION="${CUDA_VERSION:-12.8}"
INSTALL_CUDA="${INSTALL_CUDA:-yes}"
GPU_PASSTHROUGH="${GPU_PASSTHROUGH:-yes}"

header_info "$APP"
variables
color
catch_errors

#===============================================================================
# GPU FUNCTIONS
#===============================================================================

get_gpu_count() {
    nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1 || echo "0"
}

get_gpu_list() {
    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null
}

check_nvidia_host() {
    if ! command -v nvidia-smi &>/dev/null; then
        msg_error "NVIDIA driver not found on host. Please install NVIDIA drivers first."
        exit 1
    fi
    if ! nvidia-smi &>/dev/null; then
        msg_error "nvidia-smi failed. Check your NVIDIA driver installation on host."
        exit 1
    fi
    msg_ok "NVIDIA driver detected on host"
}

configure_gpu_passthrough() {
    local ctid=$1
    local conf="/etc/pve/lxc/${ctid}.conf"
    
    msg_info "Configuring GPU passthrough for CT $ctid"
    
    # Backup config
    cp "$conf" "${conf}.backup"
    
    # Add cgroup permissions
    cat >> "$conf" << 'EOF'

# NVIDIA GPU Passthrough Configuration
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 509:* rwm
EOF

    local dev_idx=0
    
    # Add all GPU devices
    local gpu_count=$(get_gpu_count)
    for ((i=0; i<gpu_count; i++)); do
        if [ -e "/dev/nvidia${i}" ]; then
            echo "dev${dev_idx}: /dev/nvidia${i}" >> "$conf"
            ((dev_idx++))
        fi
    done
    
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
    
    msg_ok "GPU passthrough configured ($dev_idx devices)"
}

install_cuda_in_container() {
    local ctid=$1
    local cuda_ver=$2
    
    msg_info "Installing CUDA Toolkit $cuda_ver in CT $ctid"
    
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
        
        # Install CUDA keyring
        wget -q "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/cuda-keyring_1.1-1_all.deb" -O cuda-keyring.deb
        dpkg -i cuda-keyring.deb
        apt-get update
    '
    
    local cuda_major=$(echo "$cuda_ver" | cut -d. -f1)
    local cuda_minor=$(echo "$cuda_ver" | cut -d. -f2)
    local cuda_pkg="cuda-toolkit-${cuda_major}-${cuda_minor}"
    
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
    
    msg_ok "CUDA Toolkit $cuda_ver installed"
}

find_nvidia_driver_on_host() {
    local search_paths=("." "/root" "/tmp" "/var/tmp")
    for path in "${search_paths[@]}"; do
        local found
        found=$(ls "${path}"/NVIDIA-Linux-*.run 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            echo "$found"
            return 0
        fi
    done
    return 1
}

push_nvidia_driver() {
    local ctid=$1

    msg_info "Tìm kiếm NVIDIA driver installer trên host"

    local driver_path
    driver_path=$(find_nvidia_driver_on_host)

    if [[ -z "$driver_path" ]]; then
        msg_error "Không tìm thấy file NVIDIA-Linux-*.run trên host (tìm tại: . /root /tmp /var/tmp)"
        msg_info "Bỏ qua bước push NVIDIA driver"
        return 1
    fi

    local driver_filename
    driver_filename=$(basename "$driver_path")

    msg_info "Đang push ${driver_filename} vào CT ${ctid}:/root/${driver_filename}"
    pct push "$ctid" "$driver_path" "/root/$driver_filename"
    msg_ok "Đã push NVIDIA driver installer: /root/${driver_filename}"
}

install_uv_in_container() {
    local ctid=$1

    msg_info "Cài đặt uv package manager trong CT ${ctid}"

    pct exec "$ctid" -- bash -c '
        curl -LsSf https://astral.sh/uv/install.sh | sh

        # Đảm bảo uv có trong PATH cho các phiên không-login
        UV_ENV_LINE="source \$HOME/.local/bin/env 2>/dev/null || true"
        if ! grep -qF ".local/bin/env" /root/.bashrc 2>/dev/null; then
            echo "$UV_ENV_LINE" >> /root/.bashrc
        fi
    '

    msg_ok "uv đã được cài đặt"
}

install_vllm_in_container() {
    local ctid=$1

    msg_info "Cài đặt vLLM trong CT ${ctid} (có thể mất vài phút)"

    pct exec "$ctid" -- bash -c '
        export PATH="$HOME/.local/bin:$PATH"
        source "$HOME/.local/bin/env" 2>/dev/null || true

        cd /root

        if [ ! -d "/root/.venv" ]; then
            uv venv --python 3.12 --seed --managed-python
        fi

        # shellcheck disable=SC1091
        source /root/.venv/bin/activate

        uv pip install vllm --torch-backend=auto --extra-index-url https://wheels.vllm.ai/nightly
    '

    if [ $? -eq 0 ]; then
        msg_ok "vLLM đã được cài đặt trong /root/.venv"
    else
        msg_error "Cài đặt vLLM thất bại. Bạn có thể thử lại thủ công sau."
    fi
}

install_dev_tools() {
    local ctid=$1
    
    msg_info "Installing development tools"
    
    pct exec "$ctid" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y \
            build-essential g++ gcc make cmake pkg-config git \
            autoconf automake libtool \
            wget curl gnupg2 ca-certificates \
            htop btop glances pciutils lshw sysstat \
            python3 python3-pip python3-dev python3-venv \
            vim nano \
            freeglut3-dev libx11-dev libxmu-dev libxi-dev \
            libglu1-mesa-dev libfreeimage-dev libglfw3-dev \
            libcurl4-openssl-dev
    "
    
    # Try to install nvtop
    pct exec "$ctid" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y nvtop 2>/dev/null || true
    "
    
    msg_ok "Development tools installed"
}

#===============================================================================
# UPDATE SCRIPT
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
# MAIN INSTALLATION
#===============================================================================

# Check for NVIDIA on host before proceeding
if [[ "$GPU_PASSTHROUGH" == "yes" ]]; then
    check_nvidia_host
fi

# Build container using community-scripts framework
start
build_container

# CTID is set by build.func; ensure it is valid and try a fallback if needed
if [[ -z "${CTID:-}" ]]; then
    # Fallback: lấy CTID lớn nhất (mới tạo gần nhất) từ danh sách LXC
    CTID=$(pct list 2>/dev/null | awk 'NR>1 {last=$1} END{print last}')
fi

if [[ -n "${CTID:-}" ]] && [[ "$CTID" =~ ^[0-9]+$ ]]; then
    
    # Configure GPU passthrough
    if [[ "$GPU_PASSTHROUGH" == "yes" ]]; then
        configure_gpu_passthrough "$CTID"
        
        # Restart container to apply GPU config
        msg_info "Restarting container to apply GPU configuration"
        pct stop "$CTID" 2>/dev/null || true
        sleep 2
        pct start "$CTID"
        sleep 5
    fi
    
    # Install development tools
    install_dev_tools "$CTID"

    # Install CUDA (phải cài trước khi push NVIDIA driver)
    if [[ "$INSTALL_CUDA" == "yes" ]] && [[ "$GPU_PASSTHROUGH" == "yes" ]]; then
        install_cuda_in_container "$CTID" "$CUDA_VERSION"
    fi

    # Push NVIDIA driver installer từ host vào container (sau khi CUDA đã cài)
    push_nvidia_driver "$CTID"

    # Install uv
    install_uv_in_container "$CTID"
    
    # Validate GPU access
    if [[ "$GPU_PASSTHROUGH" == "yes" ]]; then
        msg_info "Validating GPU access in container"
        if pct exec "$CTID" -- nvidia-smi &>/dev/null; then
            msg_ok "GPU accessible in container"
            pct exec "$CTID" -- nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
        else
            msg_error "GPU not accessible. Try: pct restart $CTID"
        fi
        
        if [[ "$INSTALL_CUDA" == "yes" ]]; then
            msg_info "Validating CUDA installation"
            pct exec "$CTID" -- bash -c "source /etc/profile.d/cuda.sh && nvcc --version" 2>/dev/null && \
                msg_ok "CUDA compiler working" || \
                msg_error "CUDA validation failed"
        fi
    fi
fi

# Gọi description của community-scripts để in thông tin LXC
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"

# Hỏi người dùng có muốn cài vLLM hay không
if [[ -n "${CTID:-}" ]] && [[ "$CTID" =~ ^[0-9]+$ ]]; then
    echo ""
    echo -e "${INFO} ${GN}Bạn có muốn cài đặt vLLM trong container ngay bây giờ không?${CL}"
    echo -e "  Lệnh sẽ chạy trong CT ${CTID}:"
    echo -e "    ${CM}uv venv --python 3.12 --seed --managed-python${CL}"
    echo -e "    ${CM}source .venv/bin/activate${CL}"
    echo -e "    ${CM}uv pip install vllm --torch-backend=auto --extra-index-url https://wheels.vllm.ai/nightly${CL}"
    read -r -p "Cài đặt vLLM? [y/N]: " INSTALL_VLLM_ANSWER
    case "${INSTALL_VLLM_ANSWER,,}" in
        y|yes|có|co)
            install_vllm_in_container "$CTID"
            ;;
        *)
            msg_info "Bỏ qua cài đặt vLLM. Bạn có thể cài thủ công sau."
            ;;
    esac
fi

echo ""
echo -e "${INFO} Quick Commands:"
echo -e "  Enter container:  ${CM}pct enter $CTID${CL}"
echo -e "  Check GPU:        ${CM}pct exec $CTID -- nvidia-smi${CL}"
echo -e "  Check CUDA:       ${CM}pct exec $CTID -- nvcc --version${CL}"
echo ""
echo -e "${INFO} ${GN}Cài đặt driver NVIDIA trong container (sau khi vào):${CL}"
echo -e "  ${CM}chmod +x ~/NVIDIA-Linux-*.run && ~/NVIDIA-Linux-*.run --no-kernel-modules${CL}"
echo ""
echo -e "${INFO} ${GN}Thiết lập môi trường Python với uv:${CL}"
echo -e "  Bước 1 - Tạo virtual environment Python 3.12:"
echo -e "  ${CM}uv venv --python 3.12 --seed --managed-python${CL}"
echo ""
echo -e "  Bước 2 - Kích hoạt môi trường:"
echo -e "  ${CM}source .venv/bin/activate${CL}"
echo ""
echo -e "  Sau đó bạn có thể cài packages bình thường, ví dụ:"
echo -e "  ${CM}uv pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128${CL}"
echo ""
echo -e "${INFO} ${GN}Cài đặt vLLM thủ công (nếu chưa cài ở bước trước):${CL}"
echo -e "  ${CM}uv venv --python 3.12 --seed --managed-python${CL}"
echo -e "  ${CM}source .venv/bin/activate${CL}"
echo -e "  ${CM}uv pip install vllm --torch-backend=auto --extra-index-url https://wheels.vllm.ai/nightly${CL}"
