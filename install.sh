#!/bin/bash
# NobleOne Device Installation Script
# Single command to fully provision a Jetson device:
#   CanBridge, Docker, Chromium kiosk, Tailscale, Hub activation, Node container.
#
# Usage:
#   curl -fsSL -H "Accept: application/vnd.github.v3.raw" \
#     "https://api.github.com/repos/netglass-io/NobleOne-Releases/contents/install.sh" | sudo bash
#
# Options:
#   --env preprod|prod   Hub environment (default: preprod)
#   --skip-canbridge     Skip CanBridge installation
#   --skip-chromium      Skip Chromium/kiosk installation
#   --skip-kiosk         Skip kiosk environment configuration

set -euo pipefail

# --- Configuration ---
HUB_PREPROD="https://preprod-hub.netglass.io"
HUB_PROD="https://prod-hub.netglass.io"
INSTALL_DIR="/opt/canbridge"
SERVICE_NAME="canbridge"
SERVICE_USER="canbridge"
RELEASE_REPO="netglass-io/NobleOne-Releases"
NODE_PORT=5233

# Determine the real user (when run via sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# --- Colors & helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

step_count=0
step()     { step_count=$((step_count + 1)); echo ""; echo -e "${BLUE}${BOLD}[$step_count] $1${NC}"; }
ok()       { echo -e "  ${GREEN}✓${NC} $1"; }
fail()     { echo -e "  ${RED}✗${NC} $1"; }
info()     { echo -e "  $1"; }
skip_msg() { echo -e "  ${YELLOW}⚠ SKIP${NC} $1"; }

# --- Parse arguments ---
HUB_ENV="preprod"
SKIP_CANBRIDGE=false
SKIP_CHROMIUM=false
SKIP_KIOSK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)            HUB_ENV="$2"; shift 2 ;;
        --skip-canbridge) SKIP_CANBRIDGE=true; shift ;;
        --skip-chromium)  SKIP_CHROMIUM=true; shift ;;
        --skip-kiosk)     SKIP_KIOSK=true; shift ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo bash install.sh [--env preprod|prod] [--skip-canbridge] [--skip-chromium] [--skip-kiosk]"
            exit 1
            ;;
    esac
done

case "$HUB_ENV" in
    preprod) HUB_URL="$HUB_PREPROD" ;;
    prod)    HUB_URL="$HUB_PROD" ;;
    *)
        echo "Unknown environment: $HUB_ENV (use 'preprod' or 'prod')"
        exit 1
        ;;
esac

# =========================================================================
# Pre-flight checks
# =========================================================================
echo -e "${BOLD}NobleOne Device Setup${NC}"
echo "Device: $(hostname -s)"
echo "Hub:    $HUB_URL ($HUB_ENV)"
echo ""

# Root check
if [ "$EUID" -ne 0 ]; then
    fail "This script must be run as root (use sudo)"
    exit 1
fi

# Architecture check
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    echo -e "${YELLOW}Warning: Detected architecture $ARCH — this script is designed for ARM64 Jetson devices${NC}"
    read -rp "Continue anyway? (y/N): " REPLY < /dev/tty
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi
ok "Architecture: $ARCH"

# Jetson detection
if [ -f /proc/device-tree/model ]; then
    MODEL=$(tr -d '\0' < /proc/device-tree/model)
    ok "Jetson device: $MODEL"
elif [ -f /etc/nv_tegra_release ]; then
    ok "Tegra device confirmed"
else
    echo -e "${YELLOW}Warning: Could not confirm Jetson hardware (continuing anyway)${NC}"
fi

# Internet check
if ! curl -s --head --connect-timeout 5 https://github.com > /dev/null 2>&1; then
    fail "No internet connectivity — cannot reach github.com"
    exit 1
fi
ok "Internet connectivity confirmed"

# =========================================================================
# Step 1: Install CanBridge
# =========================================================================
step "Install CanBridge"

if $SKIP_CANBRIDGE; then
    skip_msg "CanBridge installation (--skip-canbridge)"
else
    # Detect update vs fresh install
    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && [ -f "${INSTALL_DIR}/DataService" ]; then
        OPERATION="UPDATE"
        info "Existing installation detected — performing update"
    else
        OPERATION="INSTALL"
        info "Fresh installation"
    fi

    # Resolve download URL
    if [ "$HUB_ENV" = "prod" ]; then
        DOWNLOAD_URL="https://github.com/${RELEASE_REPO}/releases/latest/download/canbridge-linux-arm64.tar.gz"
    else
        LATEST_TAG=$(curl -s "https://api.github.com/repos/${RELEASE_REPO}/releases" | grep '"tag_name"' | grep 'dev' | head -1 | sed -E 's/.*"v([^"]+)".*/v\1/')
        DOWNLOAD_URL="https://github.com/${RELEASE_REPO}/releases/download/${LATEST_TAG}/canbridge-linux-arm64.tar.gz"
    fi

    # Service user
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -s /bin/false -d $INSTALL_DIR $SERVICE_USER
        usermod -a -G dialout,i2c $SERVICE_USER
        ok "Created service user $SERVICE_USER"
    else
        usermod -a -G dialout,i2c $SERVICE_USER
        ok "Service user $SERVICE_USER exists"
    fi

    # Directories
    mkdir -p $INSTALL_DIR/data
    chown $SERVICE_USER:$SERVICE_USER $INSTALL_DIR $INSTALL_DIR/data
    chmod 755 $INSTALL_DIR/data

    # Download
    info "Downloading CanBridge release..."
    cd /tmp
    rm -f canbridge-linux-arm64.tar.gz
    if ! curl -sL -o canbridge-linux-arm64.tar.gz "$DOWNLOAD_URL"; then
        fail "Failed to download from $DOWNLOAD_URL"
        exit 1
    fi

    # Extract
    tar -xzf canbridge-linux-arm64.tar.gz
    if [ ! -f "linux-arm64/DataService" ]; then
        fail "DataService binary not found in release"
        exit 1
    fi

    if [ "$OPERATION" = "UPDATE" ]; then
        systemctl stop $SERVICE_NAME
        cp "$INSTALL_DIR/DataService" "$INSTALL_DIR/DataService.backup.$(date +%Y%m%d-%H%M%S)"
        cp linux-arm64/DataService $INSTALL_DIR/
        cp linux-arm64/DataService.pdb $INSTALL_DIR/ 2>/dev/null || true
        chown $SERVICE_USER:$SERVICE_USER $INSTALL_DIR/DataService
        chmod +x $INSTALL_DIR/DataService
        systemctl start $SERVICE_NAME
    else
        cp linux-arm64/* $INSTALL_DIR/
        chown -R $SERVICE_USER:$SERVICE_USER $INSTALL_DIR
        chmod +x $INSTALL_DIR/DataService

        # Systemd service
        cat > /etc/systemd/system/$SERVICE_NAME.service << EOF
[Unit]
Description=CanBridge Data Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/DataService
Restart=always
RestartSec=10

Environment=DOTNET_ENVIRONMENT=Production
Environment=ASPNETCORE_URLS=http://0.0.0.0:5000

AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_RAWIO
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_RAWIO

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

        # Logrotate
        cat > /etc/logrotate.d/canbridge << EOF
/var/log/canbridge.log {
    daily
    missingok
    rotate 7
    compress
    notifempty
    create 644 $SERVICE_USER $SERVICE_USER
}
EOF

        systemctl daemon-reload
        systemctl enable $SERVICE_NAME

        # CAN device check
        CAN_DEVICE_FOUND=false
        for device in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyACM2 /dev/ttyUSB0; do
            if [ -e "$device" ]; then
                ok "Found CAN device: $device"
                CAN_DEVICE_FOUND=true
                chown root:dialout "$device"
                chmod 660 "$device"
            fi
        done
        if [ "$CAN_DEVICE_FOUND" = false ]; then
            info "${YELLOW}No CAN device found — connect interface and restart service${NC}"
        fi

        systemctl start $SERVICE_NAME || true
    fi

    # Verify
    sleep 3
    if systemctl is-active --quiet $SERVICE_NAME; then
        ok "CanBridge running"
    else
        fail "CanBridge not running — check: journalctl -u $SERVICE_NAME"
    fi

    # Cleanup
    cd /
    rm -rf /tmp/linux-arm64 /tmp/canbridge-linux-arm64.tar.gz
fi

# =========================================================================
# Step 2: Install Docker
# =========================================================================
step "Install Docker"

if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version 2>/dev/null | head -1)"
else
    info "Installing Docker..."
    apt-get update -qq
    apt-get install -y -qq docker.io docker-compose-plugin > /dev/null
    systemctl enable docker
    systemctl start docker
    ok "Docker installed"
fi

if id -nG "$REAL_USER" | grep -qw docker; then
    ok "$REAL_USER already in docker group"
else
    usermod -aG docker "$REAL_USER"
    ok "Added $REAL_USER to docker group"
fi

# =========================================================================
# Step 3: Install Chromium (native deb)
# =========================================================================
step "Install Chromium"

if $SKIP_CHROMIUM; then
    skip_msg "Chromium installation (--skip-chromium)"
else
    CHROMIUM_PATH=$(which chromium 2>/dev/null || echo "")
    if [ -n "$CHROMIUM_PATH" ] && [[ "$CHROMIUM_PATH" != *"snap"* ]]; then
        ok "Chromium already installed: $(chromium --version 2>/dev/null || echo 'unknown')"
    else
        # Remove snap chromium if present
        if snap list chromium &>/dev/null 2>&1; then
            info "Removing snap Chromium..."
            pkill -f chromium 2>/dev/null || true
            sleep 2
            snap remove chromium
        fi

        # Remove transitional package
        if dpkg -l 2>/dev/null | grep -q "^ii.*chromium-browser"; then
            apt remove -y chromium-browser > /dev/null
            apt autoremove -y > /dev/null
        fi

        # Install via XtraDeb PPA
        info "Adding XtraDeb PPA and installing Chromium..."
        add-apt-repository -y ppa:xtradeb/apps > /dev/null 2>&1
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chromium > /dev/null 2>&1

        if command -v chromium &>/dev/null; then
            ok "Chromium installed: $(chromium --version 2>/dev/null || echo 'unknown')"
        else
            fail "Chromium installation failed"
        fi
    fi

    # GPU-accelerated launchers
    LAUNCHER_DIR="$REAL_HOME/.local/bin"
    mkdir -p "$LAUNCHER_DIR"

    if [ ! -f "$LAUNCHER_DIR/chromium-gpu" ]; then
        cat > "$LAUNCHER_DIR/chromium-gpu" << 'LAUNCHER'
#!/bin/bash
export __EGL_VENDOR_LIBRARY_DIRS=/usr/lib/aarch64-linux-gnu/tegra-egl
exec chromium --enable-gpu --ignore-gpu-blocklist --enable-gpu-rasterization --password-store=basic "$@"
LAUNCHER
        chmod +x "$LAUNCHER_DIR/chromium-gpu"
        ok "Created GPU launcher"
    fi

    if [ ! -f "$LAUNCHER_DIR/chromium-kiosk" ]; then
        cat > "$LAUNCHER_DIR/chromium-kiosk" << 'LAUNCHER'
#!/bin/bash
export __EGL_VENDOR_LIBRARY_DIRS=/usr/lib/aarch64-linux-gnu/tegra-egl
exec chromium --enable-gpu --ignore-gpu-blocklist --enable-gpu-rasterization --kiosk --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --disable-web-security --disable-features=VizDisplayCompositor --password-store=basic "$@"
LAUNCHER
        chmod +x "$LAUNCHER_DIR/chromium-kiosk"
        ok "Created kiosk launcher"
    fi

    chown -R "$REAL_USER:$REAL_USER" "$LAUNCHER_DIR"
fi

# =========================================================================
# Step 4: Configure kiosk environment
# =========================================================================
step "Configure kiosk environment"

if $SKIP_KIOSK; then
    skip_msg "Kiosk environment (--skip-kiosk)"
else
    # HDMI audio blacklist
    if [ ! -f /etc/modprobe.d/blacklist-hdmi-audio.conf ]; then
        echo "blacklist snd_hda_tegra" > /etc/modprobe.d/blacklist-hdmi-audio.conf
        ok "HDMI audio blacklisted"
    else
        ok "HDMI audio already blacklisted"
    fi

    # Waveshare wake service
    if systemctl is-enabled waveshare-wake &>/dev/null 2>&1; then
        ok "waveshare-wake service already installed"
    else
        cat > /etc/systemd/system/waveshare-wake.service << 'UNIT'
[Unit]
Description=Wake Waveshare touchscreen on resume
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "echo 1-1 > /sys/bus/usb/drivers/usb/unbind; sleep 1; echo 1-1 > /sys/bus/usb/drivers/usb/bind"

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
UNIT
        systemctl daemon-reload
        systemctl enable waveshare-wake 2>/dev/null
        ok "waveshare-wake service installed"
    fi

    # Enable auto-login for kiosk user
    GDM_CONF="/etc/gdm3/custom.conf"
    if [ -f "$GDM_CONF" ]; then
        if grep -q "^AutomaticLoginEnable" "$GDM_CONF"; then
            ok "Auto-login already configured"
        else
            sed -i "/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=$REAL_USER" "$GDM_CONF"
            ok "Auto-login enabled for $REAL_USER"
        fi
    fi

    # Disable screen blanking and lock
    sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
        gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null && \
        ok "Screen blanking disabled" || info "Could not set idle-delay (will apply after login)"
    sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
        gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null && \
        ok "Screen lock disabled" || info "Could not set screen lock (will apply after login)"

    # Remove GNOME login keyring to prevent unlock prompt on auto-login
    KEYRING_DIR="$REAL_HOME/.local/share/keyrings"
    if [ -f "$KEYRING_DIR/login.keyring" ]; then
        rm -f "$KEYRING_DIR/login.keyring"
        ok "Login keyring removed (Chromium uses --password-store=basic)"
    else
        ok "No login keyring to clean up"
    fi

    # Remove update nag packages
    if dpkg -l 2>/dev/null | grep -qE "^ii.*(update-notifier|gnome-software) "; then
        info "Removing update notifier and GNOME Software..."
        apt-get remove -y -qq update-notifier gnome-software 2>/dev/null
        apt-get autoremove -y -qq 2>/dev/null
        ok "Update notifications removed"
    else
        ok "No update nag packages found"
    fi

    # Passwordless sudo for kiosk user (Node container SSHs to host for shutdown/reboot)
    SUDOERS_FILE="/etc/sudoers.d/$REAL_USER"
    if [ -f "$SUDOERS_FILE" ]; then
        ok "Passwordless sudo already configured"
    else
        echo "$REAL_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
        ok "Passwordless sudo enabled for $REAL_USER"
    fi

    # Kiosk autostart
    AUTOSTART_DIR="$REAL_HOME/.config/autostart"
    AUTOSTART_FILE="$AUTOSTART_DIR/node-kiosk.desktop"
    if [ -f "$AUTOSTART_FILE" ]; then
        ok "Kiosk autostart already configured"
    else
        mkdir -p "$AUTOSTART_DIR"
        cat > "$AUTOSTART_FILE" << DESKTOP
[Desktop Entry]
Type=Application
Name=Node Kiosk
Comment=Launch Node UI in Chromium kiosk mode
Exec=$REAL_HOME/.local/bin/chromium-kiosk http://localhost:$NODE_PORT
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
DESKTOP
        chown -R "$REAL_USER:$REAL_USER" "$AUTOSTART_DIR"
        ok "Kiosk autostart created"
    fi
fi

# =========================================================================
# Step 5: Install Tailscale
# =========================================================================
step "Install Tailscale"

if command -v tailscale &>/dev/null; then
    TS_STATE=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("BackendState","unknown"))' 2>/dev/null || echo "unknown")
    if [ "$TS_STATE" = "Running" ]; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
        ok "Tailscale already running (IP: $TS_IP)"
    else
        ok "Tailscale installed (not yet connected)"
    fi
else
    info "Installing Tailscale..."
    if curl -fsSL https://tailscale.com/install.sh | sh; then
        ok "Tailscale installed"
    else
        fail "Tailscale installation failed"
        info "Install manually: https://tailscale.com/download/linux"
    fi
fi

# =========================================================================
# Step 6: Device Activation
# =========================================================================
step "Device Activation"

# Require HTTPS
if [[ "$HUB_URL" != https://* ]]; then
    fail "Hub URL must use HTTPS (got: $HUB_URL)"
    exit 1
fi

# Generate NodeInstanceId
NODE_INSTANCE_ID=$(cat /proc/sys/kernel/random/uuid)
info "NodeInstanceId: $NODE_INSTANCE_ID"

echo ""
echo -e "${YELLOW}  Generate an activation code in Hub: $HUB_URL/DeviceActivation${NC}"
echo ""
read -rp "  Enter activation code: " ACTIVATION_CODE < /dev/tty

if [ -z "$ACTIVATION_CODE" ]; then
    fail "Activation code is required"
    exit 1
fi

# Normalize
ACTIVATION_CODE=$(echo "$ACTIVATION_CODE" | tr '[:lower:]' '[:upper:]' | tr -d ' ')

info "Activating with $HUB_URL ..."
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
HTTP_STATUS=$(curl -s -o "$TMPFILE" -w "%{http_code}" \
    -X POST "$HUB_URL/api/devices/activate" \
    -H "Content-Type: application/json" \
    -d "{\"nodeInstanceId\": \"$NODE_INSTANCE_ID\", \"activationCode\": \"$ACTIVATION_CODE\"}" \
    2>/dev/null) || HTTP_STATUS="000"
BODY=$(cat "$TMPFILE")

if [ "$HTTP_STATUS" = "000" ]; then
    fail "Could not connect to $HUB_URL"
    exit 1
fi

SUCCESS=$(echo "$BODY" | python3 -c "import sys,json; print(str(json.load(sys.stdin).get('success',False)).lower())" 2>/dev/null || echo "false")

if [ "$SUCCESS" != "true" ]; then
    ERROR_MSG=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('errorMessage','Unknown error'))" 2>/dev/null || echo "Activation failed (HTTP $HTTP_STATUS)")
    fail "$ERROR_MSG"
    exit 1
fi

# Extract activation data
TRUCK_KEY=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['truckKey'])")
UNIT_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['unitId'])")
DEVICE_NAME=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['deviceName'])")
REGISTRY_TOKEN=$(echo "$BODY" | python3 -c "import sys,json; v=json.load(sys.stdin).get('registryToken',''); print(v if v else '')")
TS_AUTHKEY=$(echo "$BODY" | python3 -c "import sys,json; v=json.load(sys.stdin).get('tailscaleAuthKey',''); print(v if v else '')")
TS_LOGIN_SERVER=$(echo "$BODY" | python3 -c "import sys,json; v=json.load(sys.stdin).get('tailscaleLoginServer',''); print(v if v else '')")

ok "Activated as $DEVICE_NAME (Unit: $UNIT_ID)"

# =========================================================================
# Step 7: Fetch and run setup script from Hub
# =========================================================================
step "Run setup"

if [ -z "$REGISTRY_TOKEN" ]; then
    fail "No registry token returned — cannot fetch setup script"
    fail "Configure GHCR PAT in Hub: $HUB_URL/DeviceActivation"
    exit 1
fi

info "Downloading setup script from Hub..."
SETUP_TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE" "$SETUP_TMPFILE"' EXIT

SETUP_HTTP_STATUS=$(curl -s -o "$SETUP_TMPFILE" -w "%{http_code}" \
    -H "Authorization: Bearer $REGISTRY_TOKEN" \
    "$HUB_URL/api/devices/setup" 2>/dev/null) || SETUP_HTTP_STATUS="000"

if [ "$SETUP_HTTP_STATUS" != "200" ]; then
    fail "Failed to download setup script (HTTP $SETUP_HTTP_STATUS)"
    if [ "$SETUP_HTTP_STATUS" = "404" ]; then
        fail "Setup script not configured in Hub — add it via $HUB_URL/DeviceActivation"
    fi
    exit 1
fi

ok "Setup script downloaded"

# Pass activation data as environment variables (avoids secrets in ps output)
export NOBLE_TRUCK_KEY="$TRUCK_KEY"
export NOBLE_UNIT_ID="$UNIT_ID"
export NOBLE_DEVICE_NAME="$DEVICE_NAME"
export NOBLE_HUB_URL="$HUB_URL"
export NOBLE_HUB_ENV="$HUB_ENV"
export NOBLE_REGISTRY_TOKEN="$REGISTRY_TOKEN"
export NOBLE_TS_AUTHKEY="$TS_AUTHKEY"
export NOBLE_TS_LOGIN_SERVER="$TS_LOGIN_SERVER"
export NOBLE_REAL_USER="$REAL_USER"
export NOBLE_REAL_HOME="$REAL_HOME"
export NOBLE_NODE_PORT="$NODE_PORT"
export NOBLE_SKIP_CANBRIDGE="$SKIP_CANBRIDGE"
export NOBLE_SKIP_CHROMIUM="$SKIP_CHROMIUM"
export NOBLE_SKIP_KIOSK="$SKIP_KIOSK"

bash "$SETUP_TMPFILE"
