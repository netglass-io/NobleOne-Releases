#!/bin/bash
# NobleOne Device Setup Script
# Full provisioning for a new Jetson device: CanBridge, Docker, Chromium kiosk, Node container.
# Uses Hub activation codes for device identity — no pre-shared secrets needed.
#
# Usage:
#   curl -s https://raw.githubusercontent.com/netglass-io/NobleOne-Releases/main/setup.sh | sudo bash
#
# Or with options:
#   curl -s https://raw.githubusercontent.com/netglass-io/NobleOne-Releases/main/setup.sh | sudo bash -s -- --hub-url https://hub.netglass.io
#
# Options:
#   --hub-url <url>            Hub URL (default: https://preprod-hub.netglass.io)
#   --activation-code <code>   Activation code (prompted if not provided)
#   --skip-canbridge           Skip CanBridge installation
#   --skip-chromium            Skip Chromium/kiosk installation
#   --skip-kiosk               Skip kiosk environment configuration

set -euo pipefail

# --- Configuration ---
DEFAULT_HUB_URL="https://preprod-hub.netglass.io"
NODE_IMAGE="ghcr.io/netglass-io/node:dev"
NODE_PORT=5233
RELEASE_REPO="netglass-io/NobleOne-Releases"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/main/install.sh"

# Determine the real user (when run via sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# Device name from hostname
DEVICE_NAME="${HOSTNAME%%.*}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Parse arguments ---
HUB_URL=""
ACTIVATION_CODE=""
SKIP_CANBRIDGE=false
SKIP_CHROMIUM=false
SKIP_KIOSK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hub-url)         HUB_URL="$2"; shift 2 ;;
        --activation-code) ACTIVATION_CODE="$2"; shift 2 ;;
        --skip-canbridge)  SKIP_CANBRIDGE=true; shift ;;
        --skip-chromium)   SKIP_CHROMIUM=true; shift ;;
        --skip-kiosk)      SKIP_KIOSK=true; shift ;;
        *)                 echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Helpers ---
step_count=0

step() {
    step_count=$((step_count + 1))
    echo ""
    echo -e "${BLUE}${BOLD}[$step_count] $1${NC}"
}

ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

skip_msg() {
    echo -e "  ${YELLOW}⚠ SKIP${NC} $1"
}

fail() {
    echo -e "  ${RED}✗${NC} $1"
}

info() {
    echo -e "  $1"
}

# =========================================================================
# Pre-flight checks
# =========================================================================
echo -e "${BOLD}NobleOne Device Setup${NC}"
echo "Device: $DEVICE_NAME"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
    exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    echo -e "${YELLOW}Warning: Detected architecture $ARCH — this script is designed for ARM64 Jetson devices${NC}"
    read -rp "Continue anyway? (y/N): " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for Jetson hardware
if [ -f /proc/device-tree/model ]; then
    MODEL=$(tr -d '\0' < /proc/device-tree/model)
    ok "Jetson device: $MODEL"
elif [ -f /etc/nv_tegra_release ]; then
    ok "Tegra device confirmed"
else
    echo -e "${YELLOW}Warning: Could not confirm Jetson hardware (continuing anyway)${NC}"
fi

# Check internet
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
    if systemctl is-active canbridge &>/dev/null; then
        ok "CanBridge already installed and running"
    else
        info "Installing CanBridge..."
        curl -s "$INSTALL_SCRIPT_URL" | bash
        if systemctl is-active canbridge &>/dev/null; then
            ok "CanBridge installed and running"
        else
            fail "CanBridge installation may have issues — check: journalctl -u canbridge"
        fi
    fi
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

# Add real user to docker group
if id -nG "$REAL_USER" | grep -qw docker; then
    ok "$REAL_USER already in docker group"
else
    usermod -aG docker "$REAL_USER"
    ok "Added $REAL_USER to docker group"
fi

# =========================================================================
# Step 3: Install Chromium (native deb)
# =========================================================================
step "Install Chromium (native deb)"

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

        # Add XtraDeb PPA and install
        info "Adding XtraDeb PPA and installing Chromium..."
        add-apt-repository -y ppa:xtradeb/apps > /dev/null 2>&1
        apt-get update -qq
        apt-get install -y -qq chromium > /dev/null

        if command -v chromium &>/dev/null; then
            ok "Chromium installed: $(chromium --version 2>/dev/null || echo 'unknown')"
        else
            fail "Chromium installation failed"
        fi
    fi

    # Create GPU-accelerated launcher scripts
    LAUNCHER_DIR="$REAL_HOME/.local/bin"
    mkdir -p "$LAUNCHER_DIR"

    if [ ! -f "$LAUNCHER_DIR/chromium-gpu" ]; then
        cat > "$LAUNCHER_DIR/chromium-gpu" << 'LAUNCHER'
#!/bin/bash
export __EGL_VENDOR_LIBRARY_DIRS=/usr/lib/aarch64-linux-gnu/tegra-egl
exec chromium --enable-gpu --ignore-gpu-blocklist --enable-gpu-rasterization "$@"
LAUNCHER
        chmod +x "$LAUNCHER_DIR/chromium-gpu"
        ok "Created GPU launcher: $LAUNCHER_DIR/chromium-gpu"
    fi

    if [ ! -f "$LAUNCHER_DIR/chromium-kiosk" ]; then
        cat > "$LAUNCHER_DIR/chromium-kiosk" << 'LAUNCHER'
#!/bin/bash
export __EGL_VENDOR_LIBRARY_DIRS=/usr/lib/aarch64-linux-gnu/tegra-egl
exec chromium --enable-gpu --ignore-gpu-blocklist --enable-gpu-rasterization --kiosk --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --disable-web-security --disable-features=VizDisplayCompositor "$@"
LAUNCHER
        chmod +x "$LAUNCHER_DIR/chromium-kiosk"
        ok "Created kiosk launcher: $LAUNCHER_DIR/chromium-kiosk"
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
        systemctl enable waveshare-wake
        ok "waveshare-wake service installed"
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
# Step 5: Authenticate Docker with GHCR
# =========================================================================
step "Authenticate Docker with GHCR"

if sudo -u "$REAL_USER" docker manifest inspect "$NODE_IMAGE" &>/dev/null 2>&1; then
    ok "Already authenticated with GHCR"
else
    info "Docker authentication needed for ghcr.io"
    echo ""
    read -rp "  Enter GitHub PAT (or 'skip' to skip): " GITHUB_PAT
    if [ "$GITHUB_PAT" = "skip" ]; then
        skip_msg "GHCR authentication (user skipped)"
    else
        if echo "$GITHUB_PAT" | sudo -u "$REAL_USER" docker login ghcr.io -u netglass-io --password-stdin 2>/dev/null; then
            ok "Authenticated with GHCR"
        else
            fail "GHCR authentication failed"
        fi
    fi
fi

# =========================================================================
# Step 6: Activate with Hub
# =========================================================================
step "Activate with Hub"

# Check if already activated (Node .env exists with a TRUCK_KEY)
NODE_DIR="$REAL_HOME/Node"
if [ -f "$NODE_DIR/.env" ] && grep -q "TRUCK_KEY=" "$NODE_DIR/.env" 2>/dev/null; then
    EXISTING_KEY=$(grep "TRUCK_KEY=" "$NODE_DIR/.env" | cut -d= -f2)
    if [ -n "$EXISTING_KEY" ] && [ "$EXISTING_KEY" != "REPLACE_WITH_ACTUAL_KEY" ]; then
        ok "Device already activated (TruckKey exists)"
        info "To re-activate, remove $NODE_DIR/.env and re-run this script"
        ALREADY_ACTIVATED=true
    fi
fi

if [ "${ALREADY_ACTIVATED:-false}" != "true" ]; then
    # Prompt for Hub URL
    if [ -z "$HUB_URL" ]; then
        echo ""
        read -rp "  Hub URL [$DEFAULT_HUB_URL]: " HUB_URL
        HUB_URL="${HUB_URL:-$DEFAULT_HUB_URL}"
    fi

    # Require HTTPS — activation returns a Bearer token that must not be sent in cleartext
    if [[ "$HUB_URL" != https://* ]]; then
        fail "Hub URL must use HTTPS (got: $HUB_URL)"
        fail "The activation response contains credentials that must not be sent over plain HTTP"
        exit 1
    fi

    # Prompt for activation code
    if [ -z "$ACTIVATION_CODE" ]; then
        read -rp "  Activation code: " ACTIVATION_CODE
    fi

    if [ -z "$ACTIVATION_CODE" ]; then
        fail "Activation code is required"
        exit 1
    fi

    # Generate NodeInstanceId
    NODE_INSTANCE_ID=$(cat /proc/sys/kernel/random/uuid)
    info "NodeInstanceId: $NODE_INSTANCE_ID"

    # Normalize code to uppercase
    ACTIVATION_CODE=$(echo "$ACTIVATION_CODE" | tr '[:lower:]' '[:upper:]')

    # Call activation endpoint
    info "Activating with $HUB_URL ..."
    TMPFILE=$(mktemp)
    HTTP_STATUS=$(curl -s -o "$TMPFILE" -w "%{http_code}" \
        -X POST "$HUB_URL/api/devices/activate" \
        -H "Content-Type: application/json" \
        -d "{\"nodeInstanceId\": \"$NODE_INSTANCE_ID\", \"activationCode\": \"$ACTIVATION_CODE\"}" \
        2>/dev/null) || HTTP_STATUS="000"
    BODY=$(cat "$TMPFILE")
    rm -f "$TMPFILE"

    if [ "$HTTP_STATUS" = "000" ]; then
        fail "Could not connect to $HUB_URL"
        exit 1
    fi

    # Parse response
    SUCCESS=$(echo "$BODY" | python3 -c "import sys,json; print(str(json.load(sys.stdin).get('success',False)).lower())" 2>/dev/null || echo "false")

    if [ "$SUCCESS" != "true" ]; then
        ERROR_MSG=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('errorMessage','Unknown error'))" 2>/dev/null || echo "Activation failed (HTTP $HTTP_STATUS)")
        fail "$ERROR_MSG"
        exit 1
    fi

    # Extract values
    TRUCK_KEY=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['truckKey'])")
    UNIT_ID=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unitId'])")
    DEVICE_DISPLAY_NAME=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['deviceName'])")

    ok "Activated as $DEVICE_DISPLAY_NAME (Unit: $UNIT_ID)"
fi

# =========================================================================
# Step 7: Deploy Node container
# =========================================================================
step "Deploy Node container"

mkdir -p "$NODE_DIR/Data"

# Write .env (only if we just activated)
if [ "${ALREADY_ACTIVATED:-false}" != "true" ]; then
    cat > "$NODE_DIR/.env" << ENV
ASPNETCORE_ENVIRONMENT=Production
CANBRIDGE_URL=http://localhost:5000
COGNODE_URL=http://localhost:5001
HUB_URL=$HUB_URL
TRUCK_KEY=$TRUCK_KEY
DashTestMode=false
SSH_HOST=172.17.0.1
SSH_USER=$REAL_USER
SSH_PASSWORD=Welcome7
ENV
    ok "Created $NODE_DIR/.env"
fi

# Write docker-compose.yml
cat > "$NODE_DIR/docker-compose.yml" << COMPOSE
name: ${DEVICE_NAME}-node

services:
  node:
    image: $NODE_IMAGE
    container_name: ${DEVICE_NAME}-node
    pull_policy: always
    restart: unless-stopped
    network_mode: host
    environment:
      - ASPNETCORE_ENVIRONMENT=\${ASPNETCORE_ENVIRONMENT:?ASPNETCORE_ENVIRONMENT value not set}
      - CANBRIDGE_URL=\${CANBRIDGE_URL:?CANBRIDGE_URL value not set}
      - COGNODE_URL=\${COGNODE_URL:?COGNODE_URL value not set}
      - HUB_URL=\${HUB_URL:?HUB_URL value not set}
      - TRUCK_KEY=\${TRUCK_KEY:?TRUCK_KEY value not set}
      - DashTestMode=\${DashTestMode:-false}
      - SSH_HOST=\${SSH_HOST:?SSH_HOST value not set}
      - SSH_USER=\${SSH_USER:?SSH_USER value not set}
      - SSH_PASSWORD=\${SSH_PASSWORD:?SSH_PASSWORD value not set}
    volumes:
      - ./Data:/app/Data
COMPOSE
ok "Created $NODE_DIR/docker-compose.yml"

chown -R "$REAL_USER:$REAL_USER" "$NODE_DIR"

# Pull and start container
info "Pulling and starting Node container..."
cd "$NODE_DIR"
sudo -u "$REAL_USER" docker compose pull 2>/dev/null
sudo -u "$REAL_USER" docker compose up -d 2>/dev/null

sleep 5

if docker ps --format '{{.Names}}' | grep -q "${DEVICE_NAME}-node"; then
    ok "Node container running: ${DEVICE_NAME}-node"
else
    fail "Node container not running — check: docker logs ${DEVICE_NAME}-node"
fi

# =========================================================================
# Step 8: Verification
# =========================================================================
step "Verification"

echo ""
PASS=0
TOTAL=0

# CanBridge
if ! $SKIP_CANBRIDGE; then
    TOTAL=$((TOTAL + 1))
    if systemctl is-active canbridge &>/dev/null; then
        ok "CanBridge running"
        PASS=$((PASS + 1))
    else
        fail "CanBridge not running"
    fi
fi

# Docker
TOTAL=$((TOTAL + 1))
if command -v docker &>/dev/null; then
    ok "Docker installed"
    PASS=$((PASS + 1))
else
    fail "Docker not installed"
fi

# Chromium
if ! $SKIP_CHROMIUM; then
    TOTAL=$((TOTAL + 1))
    CHROMIUM_PATH=$(which chromium 2>/dev/null || echo "")
    if [ -n "$CHROMIUM_PATH" ] && [[ "$CHROMIUM_PATH" != *"snap"* ]]; then
        ok "Chromium installed (native deb)"
        PASS=$((PASS + 1))
    else
        fail "Chromium not installed as native deb"
    fi
fi

# Kiosk autostart
if ! $SKIP_KIOSK; then
    TOTAL=$((TOTAL + 1))
    if [ -f "$REAL_HOME/.config/autostart/node-kiosk.desktop" ]; then
        ok "Kiosk autostart configured"
        PASS=$((PASS + 1))
    else
        fail "Kiosk autostart missing"
    fi
fi

# Node container
TOTAL=$((TOTAL + 1))
if docker ps --format '{{.Names}}' | grep -q "${DEVICE_NAME}-node"; then
    ok "Node container running"
    PASS=$((PASS + 1))
else
    fail "Node container not running"
fi

# Port listening
TOTAL=$((TOTAL + 1))
if ss -tlnp 2>/dev/null | grep -q ":$NODE_PORT"; then
    ok "Node listening on port $NODE_PORT"
    PASS=$((PASS + 1))
else
    echo -e "  ${YELLOW}⚠${NC} Port $NODE_PORT not yet listening (container may still be starting)"
fi

echo ""
echo -e "${BOLD}Results: $PASS/$TOTAL checks passed${NC}"
if [ "$PASS" -eq "$TOTAL" ]; then
    echo -e "${GREEN}${BOLD}Setup complete!${NC}"
else
    echo -e "${YELLOW}Some checks failed — review output above${NC}"
fi
echo ""
echo "Next steps:"
echo "  - Open http://localhost:$NODE_PORT in a browser to verify Node UI"
echo "  - Reboot device for kiosk mode to take effect"
if [ "${ALREADY_ACTIVATED:-false}" != "true" ]; then
    echo "  - Assign $DEVICE_DISPLAY_NAME to a customer/location in Hub"
fi
