#!/bin/bash
set -e


# ----------[ Define CONSTANT ]----------
RED='\e[1;31m'
GREEN='\e[0;34m'
BLUEF='\e[1;34m' #Biru
WHITE='\e[1;37m'
YELLOW='\e[93m'
ORANGE='\e[38;5;166m'
CYAN='\e[0;36m'
OKEGREEN='\033[92m'
LIGHTGREEN='\e[1;32m'
RESET="\033[00m" #normal


# ----------[ Define arguments ]----------
package_manager=""
# source_ip_store=192.168.30.29
# source_port_store=4433
# store_link="http://${source_ip_store}:${source_port_store}"
# store_ssh="${store_link}/id_rsa.pub"
store_ssh="https://raw.githubusercontent.com/RS42005-PhungPD/EMP_INSTALL/main/id_rsa.pub"

# ----------[ Define functions ]----------
systemd_works() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 1
    fi

    PID1=$(readlink /proc/1/exe)
    if [[ "$PID1" != *"systemd"* ]]; then
        return 1
    fi

    if systemctl is-system-running 2>&1 | grep -q "System has not been booted with systemd"; then
        return 1
    fi

    if systemctl is-system-running 2>&1 | grep -q "Failed to connect to bus"; then
        return 1
    fi

    return 0
}


sync_time() {
    echo "[INFO] Syncing system time..."

    if grep -qaE 'docker|containerd|kubepods|lxc' /proc/1/cgroup 2>/dev/null; then
        echo "[INFO] Container detected → skip time sync (use host time)"
        return 0
    fi

    if command -v timedatectl >/dev/null 2>&1 \
       && ps -p 1 -o comm= | grep -qw systemd; then

        if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
            if timedatectl show -p CanNTP --value 2>/dev/null | grep -qw yes; then
                echo "[INFO] Using systemd-timesyncd"
                timedatectl set-ntp true || true
                systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
                systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
                return 0
            else
                echo "[WARN] systemd present but NTP not supported"
                return 0
            fi
        fi
    fi

    if command -v chronyc >/dev/null 2>&1; then
        echo "[INFO] Using chrony"
        chronyc makestep || true
        return 0
    fi

    case "$PACKAGE_MANAGER" in
        apt)
            apt update -y || true
            apt install -y chrony || true
            chronyc makestep || true
            ;;
        yum|dnf)
            $PACKAGE_MANAGER install -y chrony || true
            chronyc makestep || true
            ;;
        apk)
            apk add --no-cache chrony || true
            chronyc makestep || true
            ;;
        *)
            echo "[WARN] No supported time sync method available"
            ;;
    esac
}


install_ssh() {
    if [[ "$PACKAGE_MANAGER" == "apt" ]] || [[ "$PACKAGE_MANAGER" == "apt-get" ]] || [[ "$PACKAGE_MANAGER" == "yum" ]] || [[ "$PACKAGE_MANAGER" == "dnf" ]]; then
        $PACKAGE_MANAGER install -y openssh-server
    elif [[ "$PACKAGE_MANAGER" == "pacman" ]]; then
        pacman -S --noconfirm openssh
    elif [[ "$PACKAGE_MANAGER" == "apk" ]]; then
        apk add openssh
        rc-update add sshd
    fi

    if systemd_works; then
        systemctl enable ssh
        systemctl restart ssh
    elif command -v service >/dev/null 2>&1; then
        service ssh start
    else
        if [ -x "/usr/sbin/sshd" ]; then
            SSHD_BIN="/usr/sbin/sshd"
        elif [ -x "/usr/bin/sshd" ]; then
            SSHD_BIN="/usr/bin/sshd"
        else
            echo -e "${RED}Can't find SSHD service.${RESET}"
            exit 1
        fi

        mkdir -p /var/run/sshd
        ssh-keygen -A
        sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

        if ! pgrep -x "sshd" > /dev/null; then
            $SSHD_BIN -D &
            echo -e "${GREEN}SSH service is running.${RESET}"
        fi
    fi
}

install_docker () {
    case "$PACKAGE_MANAGER" in
        apt|apt-get)
            if ! command -v docker > /dev/null 2>&1; then
                $PACKAGE_MANAGER update
                $PACKAGE_MANAGER install -y apt-transport-https ca-certificates lsb-release gnupg   

                if [[ $OS_DISTRO == "ubuntu" ]]; then
                    $PACKAGE_MANAGER install -y software-properties-common
                fi

                curl -fsSL "https://download.docker.com/linux/${OS_DISTRO}/gpg" \
                    | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
                    https://download.docker.com/linux/${OS_DISTRO} ${OS_CODENAME} stable" \
                    | tee /etc/apt/sources.list.d/docker.list > /dev/null

                $PACKAGE_MANAGER update
                $PACKAGE_MANAGER install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                echo -e "${GREEN}Docker installed. Please logout/login to apply docker group.${RESET}"
            fi

            if command -v nvidia-smi >/dev/null 2>&1; then
                distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
                curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
                curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list
                $PACKAGE_MANAGER update
                $PACKAGE_MANAGER install -y nvidia-docker2
            fi
            ;;
        pacman)
            $PACKAGE_MANAGER -Syu --noconfirm
            $PACKAGE_MANAGER -S --noconfirm docker

            if command -v nvidia-smi >/dev/null 2>&1; then
                $PACKAGE_MANAGER -S --noconfirm nvidia-container-toolkit
            fi
            ;;
        yum)
            $PACKAGE_MANAGER install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            $PACKAGE_MANAGER install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

            if command -v nvidia-smi >/dev/null 2>&1; then
                $PACKAGE_MANAGER install -y nvidia-docker2
            fi
            ;;
        dnf)
            $PACKAGE_MANAGER install -y dnf-plugins-core
            $PACKAGE_MANAGER config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            $PACKAGE_MANAGER install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

            if command -v nvidia-smi >/dev/null 2>&1; then
                $PACKAGE_MANAGER install -y nvidia-docker2
            fi
            ;;
        apk)
            $PACKAGE_MANAGER update
            $PACKAGE_MANAGER add docker

            if command -v nvidia-smi >/dev/null 2>&1; then
                $PACKAGE_MANAGER add nvidia-container-toolkit
            fi
            ;;
        *)
            echo -e "${RED}Unsupported package manager: ${PACKAGE_MANAGER}${RESET}"
            return 1
            ;;
    esac

    # # Start docker
    # if systemd_works; then
    #     systemctl enable docker
    #     systemctl restart docker
    # elif command -v service >/dev/null 2>&1; then
    #     service docker start
    # else
    #     echo -e "${BLUEF}No systemd or service, running dockerd manually${RESET}"
    #     dockerd &
    # fi
}


# ----------[ main ]----------
# get params
if [[ -z "$DEVICE_ID" ]]; then
    echo -e "${RED}ERROR: DEVICE_ID is missing.${RESET}"
    exit 1
else
    device_id="$DEVICE_ID"
fi


# Check Privilege
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Not running as root, checking sudo password...${RESET}"

    if sudo -v; then
        echo -e "${GREEN}Sudo password correct → using sudo.${RESET}"
    else
        echo -e "${RED}Wrong password or no sudo permissions.${RESET}"
        exit 1
    fi

else
    echo -e "${GREEN}Running as root.${RESET}"
fi


# Check OS Release
if [ -f /etc/os-release ]; then
    . /etc/os-release

    if [ "$ID" = "ubuntu" ] || echo "$ID_LIKE" | grep -q "ubuntu"; then
        OS_DISTRO="ubuntu"
    elif [ "$ID" = "debian" ] || [ "$ID" = "raspbian" ] || [ "$ID" = "kali" ]; then
        OS_DISTRO="$ID"
    else
        echo -e "${RED}Cannot detect OS distro info.${RESET}"
        return 1
    fi

    OS_ARCHITECTURE=$ID_LIKE

    if [ -n "$VERSION_CODENAME" ]; then
        OS_CODENAME="$VERSION_CODENAME"
    else
        OS_CODENAME=$(lsb_release -cs)
    fi

    CPU_ARCH=$(uname -m)

else
    echo -e "${RED}Cannot detect OS release info.${RESET}"
    return 1
fi


# Check package manager
if command -v apt >/dev/null 2>&1; then
    PACKAGE_MANAGER="apt"
elif command -v apt-get >/dev/null 2>&1; then
    PACKAGE_MANAGER="apt-get"
elif command -v pacman >/dev/null 2>&1; then
    PACKAGE_MANAGER="pacman"
elif command -v yum >/dev/null 2>&1; then
    PACKAGE_MANAGER="yum"
elif command -v dnf >/dev/null 2>&1; then
    PACKAGE_MANAGER="dnf"
elif command -v apk >/dev/null 2>&1; then
    PACKAGE_MANAGER="apk"
fi


# Update requirements library
echo -e "${GREEN}Update and install requirement libs${RESET}"
case "$PACKAGE_MANAGER" in
    apt|apt-get)
        export DEBIAN_FRONTEND=noninteractive
        $PACKAGE_MANAGER update -y
        $PACKAGE_MANAGER install -y build-essential pkg-config libssl-dev libudev-dev tzdata gnupg

        sync_time

        if ! command -v curl > /dev/null 2>&1; then
            echo -e "${BLUEF}curl is not installer. ${RESET}"
            $PACKAGE_MANAGER installcurl -y
        else
            echo -e "${LIGHTGREEN}curl is installed. ${RESET}"
        fi

        if ! command -v unzip > /dev/null 2>&1; then
            echo -e "${BLUEF} unzip is not installer. ${RESET}"
            $PACKAGE_MANAGER install unzip -y
        else
            echo -e "${LIGHTGREEN}unzip is installed. ${RESET}"
        fi

        install_ssh
        install_docker
        apt install sshpass
        ;;
    pacman)
        pacman -Syu --noconfirm
        pacman -S --noconfirm base-devel pkgconf openssl systemd

        if ! command -v curl > /dev/null 2>&1; then
            echo -e "${BLUEF}curl is not installed.${RESET}"
            pacman -S --noconfirm curl
        else
            echo -e "${LIGHTGREEN}curl is installed.${RESET}"
        fi

        if ! command -v unzip > /dev/null 2>&1; then
            echo -e "${BLUEF}unzip is not installed.${RESET}"
            pacman -S --noconfirm unzip
        else
            echo -e "${LIGHTGREEN}unzip is installed.${RESET}"
        fi

        install_ssh
        install_docker
        ;;
    yum|dnf)
        $PACKAGE_MANAGER update -y
        $PACKAGE_MANAGER groupinstall -y "Development Tools"
        $PACKAGE_MANAGER install -y pkgconfig openssl-devel systemd-devel

        if ! command -v curl > /dev/null 2>&1; then
            echo -e "${BLUEF}curl is not installed.${RESET}"
            $PACKAGE_MANAGER install -y curl
        else
            echo -e "${LIGHTGREEN}curl is installed.${RESET}"
        fi

        if ! command -v unzip > /dev/null 2>&1; then
            echo -e "${BLUEF}unzip is not installed.${RESET}"
            $PACKAGE_MANAGER install -y unzip
        else
            echo -e "${LIGHTGREEN}unzip is installed.${RESET}"
        fi

        install_ssh
        install_docker
        ;;
    apk)
        apk update
        apk add build-base pkgconfig openssl-dev

        if ! command -v curl > /dev/null 2>&1; then
            echo -e "${BLUEF}curl is not installed.${RESET}"
            apk add curl
        else
            echo -e "${LIGHTGREEN}curl is installed.${RESET}"
        fi

        if ! command -v unzip > /dev/null 2>&1; then
            echo -e "${BLUEF}unzip is not installed.${RESET}"
            apk add unzip
        else
            echo -e "${LIGHTGREEN}unzip is installed.${RESET}"
        fi

        install_ssh
        install_docker
        ;;
    *)
        echo -e "${RED}No supported package manager found.${RESET}"
        exit 1
        ;;
esac

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo $REAL_USER
echo $REAL_HOME

# Import SSH key
echo -e "${GREEN}import ssh key ${RESET}"

SSH_DIR="$REAL_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
    chown "$REAL_USER" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
fi

SSH_KEY="$(curl -sSf "$store_ssh")"

if ! grep -qxF "$SSH_KEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "$SSH_KEY" >> "$AUTH_KEYS"
fi

chown "$REAL_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

echo -e "${LIGHTGREEN}import done ${RESET}"


# if [[ "$CPU_ARCH" == "x86_64" ]]; then
#     image_arch="amd64"
# elif [[ "$CPU_ARCH" == "aarch64" ]]; then
#     image_arch=$CPU_ARCH
# else
#     image_arch=""
# fi

CONFIG_FOLDER="/var/local/edge"
mkdir -p $CONFIG_FOLDER
COMPOSE_FILE="docker-compose.yml"
CONFIG_FILE="${CONFIG_FOLDER}/config.toml"
SOURCE_IMAGE="harbor.rainscales.com/eme_dev/edge-controller:latest"
HOST_IP=$(hostname -I | awk '{print $1}')
HOST_SSH_PORT=22
HOST_OS_NAME=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
HOST_USER=$(whoami)
HOST_MAC=$(ip link show | awk '/ether/ {print $2; exit}')
MQTT_HOST="113.176.195.22"
MQTT_PORT=31002
MQTT_USERNAME="device-${device_id}"
MQTT_PASSWORD="device_${device_id}"
STORE_URL="harbor.rainscales.com"
STORE_USERNAME="nvdluan"
STORE_PASSWORD="Nvdluan123"
LOG_HOST="192.168.30.34"
LOG_PORT=32010
TOPIC_BASE="device"
TELEMETRY_REFRESH_TIME=5
DOCKER_INFO_REFRESH_TIME=10
COMMAND_INFO_REFRESH_TIME=0.5

sudo cat > $CONFIG_FILE <<EOF
[monitoring]
interval_seconds = 5
enable_gpu = true
enable_power = true

[mqtt]
broker = "$MQTT_HOST"
port = $MQTT_PORT
client_id = "${device_id}"
username = "$MQTT_USERNAME"
password = "$MQTT_PASSWORD"
default_topic = "$TOPIC_BASE"
telemetry_topic = "telemetry"
alert_topic = "logs"
docker_info_topic = "docker-info"
command_topic = "applications"
operator_topic = "operator"
ssh_topic = "ssh"
qos = 1

[alerting]
cpu_threshold_percent = 80.0
memory_threshold_percent = 85.0
alert_cooldown_seconds = 300
sustained_alert_seconds = 60

[docker]
socket_path = "unix:///var/run/docker.sock"
enable_container_monitoring = true
username = "$STORE_USERNAME"
password = "$STORE_PASSWORD"
store_url = "$STORE_URL"

[ssh]
local_ssh_port=22
EOF

cat > $COMPOSE_FILE <<EOF
services:
  edge-controller:
    image: ${SOURCE_IMAGE}
    container_name: edge-controller
    restart: unless-stopped
    privileged: true
    pid: host
    volumes:
      # Mount Docker socket for container monitoring
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /dev:/dev
      - /sys:/sys:ro
      - /run:/run
      - /lib/modules:/lib/modules:ro
      - /lib/firmware:/lib/firmware:ro
      # Mount config file
      - $CONFIG_FILE:/etc/edge-controller/config.toml:ro
      # Mount Docker group for permissions
      - /etc/group:/etc/group:ro
      # Gpu
      - /usr/lib/x86_64-linux-gnu/libcuda.so.1:/usr/lib/x86_64-linux-gnu/libcuda.so.1:ro
      - /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1:ro
      - /usr/lib/x86_64-linux-gnu/libnvidia-cfg.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-cfg.so.1:ro
      - /usr/lib/x86_64-linux-gnu/libnvidia-encode.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-encode.so.1:ro
      - /usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:ro
      - /usr/bin/nvidia-smi:/usr/bin/nvidia-smi:ro
    environment:
      - RUST_LOG=info
      - CONFIG_PATH=/etc/edge-controller/config.toml
    logging:
      driver: gelf
      options:
        gelf-address: "udp://${LOG_HOST}:${LOG_PORT}"
        gelf-compression-type: "none"
        tag: "edge-controller"
EOF


docker login $STORE_URL -u $STORE_USERNAME -p $STORE_PASSWORD

if docker compose version >/dev/null 2>&1; then
    docker compose up -d
elif docker-compose version >/dev/null 2>&1; then
    docker-compose up -d
else
    docker run -d \
    --name edge-controller \
    --restart unless-stopped \
    --privileged \
    --pid=host \
    \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v /dev:/dev \
    -v /sys:/sys:ro \
    -v /run:/run \
    -v /lib/modules:/lib/modules:ro \
    -v /lib/firmware:/lib/firmware:ro \
    -v "$CONFIG_FILE":/etc/edge-controller/config.toml:ro \
    -v /etc/group:/etc/group:ro \
    -v /usr/lib/x86_64-linux-gnu/libcuda.so.1:/usr/lib/x86_64-linux-gnu/libcuda.so.1:ro \
    -v /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1:ro \
    -v /usr/lib/x86_64-linux-gnu/libnvidia-cfg.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-cfg.so.1:ro \
    -v /usr/lib/x86_64-linux-gnu/libnvidia-encode.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-encode.so.1:ro \
    -v /usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1:ro \
    -v /usr/bin/nvidia-smi:/usr/bin/nvidia-smi:ro \
    \
    -e RUST_LOG=info \
    -e CONFIG_PATH=/etc/edge-controller/config.toml \
    \
    --log-driver=gelf \
    --log-opt gelf-address=udp://${LOG_HOST}:${LOG_PORT} \
    --log-opt gelf-compression-type=none \
    --log-opt tag=edge-controller \
    \
    "${SOURCE_IMAGE}"
fi
