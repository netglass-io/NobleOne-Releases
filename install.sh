#!/bin/bash
# NobleOne Device Installation/Update Script
# For Raspberry Pi 5 / ARM64 Linux systems
# Installs CanBridge service and Tailscale remote access
#
# Usage:
#   sudo bash install.sh [--env preprod|prod]
#
# Options:
#   --env preprod   Use preprod Hub (default)
#   --env prod      Use production Hub

set -e

# --- Hub environments ---
HUB_PREPROD="https://preprod-hub.netglass.io"
HUB_PROD="https://prod-hub.netglass.io"

# Parse arguments
HUB_ENV="preprod"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            HUB_ENV="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo bash install.sh [--env preprod|prod]"
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

# Configuration
INSTALL_DIR="/opt/canbridge"
SERVICE_NAME="canbridge"
SERVICE_USER="canbridge"
RELEASE_REPO="netglass-io/NobleOne-Releases"

# TODO: Before production deployment, add channel selection logic
# For now, hardcoded to dev channel for POC testing
CHANNEL="dev"
if [ "$CHANNEL" = "dev" ]; then
    # Get latest dev pre-release tag
    LATEST_TAG=$(curl -s "https://api.github.com/repos/${RELEASE_REPO}/releases" | grep '"tag_name"' | grep 'dev' | head -1 | sed -E 's/.*"v([^"]+)".*/v\1/')
    DOWNLOAD_URL="https://github.com/${RELEASE_REPO}/releases/download/${LATEST_TAG}/canbridge-linux-arm64.tar.gz"
else
    # Production: use /releases/latest/
    DOWNLOAD_URL="https://github.com/${RELEASE_REPO}/releases/latest/download/canbridge-linux-arm64.tar.gz"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect if this is an update or fresh install
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service" && [ -f "${INSTALL_DIR}/DataService" ]; then
    OPERATION="UPDATE"
    echo -e "${BLUE}🔄 CanBridge Update Script${NC}"
    echo -e "${BLUE}==========================${NC}"
else
    OPERATION="INSTALL"
    echo -e "${BLUE}🚀 CanBridge Installation Script${NC}"
    echo -e "${BLUE}=================================${NC}"
fi
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Please run as root (use sudo)${NC}"
    exit 1
fi

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    echo -e "${YELLOW}⚠️  Warning: Detected architecture $ARCH, but CanBridge is built for ARM64${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r < /dev/tty
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo -e "${GREEN}✅ Architecture check passed: $ARCH${NC}"

# Create service user
echo -e "${BLUE}👤 Setting up service user...${NC}"
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "Creating service user: $SERVICE_USER"
    useradd -r -s /bin/false -d $INSTALL_DIR $SERVICE_USER
    # Add to dialout group for CAN device access
    # Add to i2c group for IMU sensor access
    usermod -a -G dialout,i2c $SERVICE_USER
    echo -e "${GREEN}✅ Created user $SERVICE_USER and added to dialout and i2c groups${NC}"
else
    echo -e "${GREEN}✅ Service user $SERVICE_USER already exists${NC}"
    # Ensure user is in dialout and i2c groups
    usermod -a -G dialout,i2c $SERVICE_USER
    echo -e "${GREEN}✅ Added $SERVICE_USER to dialout and i2c groups${NC}"
fi

# Create installation directory
echo -e "${BLUE}📁 Creating installation directory...${NC}"
mkdir -p $INSTALL_DIR
chown $SERVICE_USER:$SERVICE_USER $INSTALL_DIR

# Create data subdirectory for IMU calibration files
echo -e "${BLUE}📁 Creating data directory for IMU calibration...${NC}"
mkdir -p $INSTALL_DIR/data
chown $SERVICE_USER:$SERVICE_USER $INSTALL_DIR/data
chmod 755 $INSTALL_DIR/data
echo -e "${GREEN}✅ Data directory created at $INSTALL_DIR/data${NC}"

# Download and extract latest release
echo -e "${BLUE}⬇️  Downloading latest CanBridge release...${NC}"
cd /tmp
rm -f canbridge-linux-arm64.tar.gz
if curl -L -o canbridge-linux-arm64.tar.gz "$DOWNLOAD_URL"; then
    echo -e "${GREEN}✅ Download successful${NC}"
else
    echo -e "${RED}❌ Failed to download from $DOWNLOAD_URL${NC}"
    echo "Please check your internet connection and that the release exists."
    exit 1
fi

# Extract release
echo -e "${BLUE}📦 Extracting release...${NC}"
tar -xzf canbridge-linux-arm64.tar.gz
if [ ! -f "linux-arm64/DataService" ]; then
    echo -e "${RED}❌ DataService binary not found in release${NC}"
    exit 1
fi

# Handle update vs fresh install
if [ "$OPERATION" = "UPDATE" ]; then
    echo -e "${BLUE}🔄 Performing update...${NC}"
    
    # Stop the service
    echo -e "${BLUE}🛑 Stopping CanBridge service...${NC}"
    systemctl stop $SERVICE_NAME
    
    # Backup current binary
    echo -e "${BLUE}💾 Creating backup of current binary...${NC}"
    cp "$INSTALL_DIR/DataService" "$INSTALL_DIR/DataService.backup.$(date +%Y%m%d-%H%M%S)"
    
    # Update binary and debug files
    echo -e "${BLUE}📋 Updating CanBridge binary...${NC}"
    cp linux-arm64/DataService $INSTALL_DIR/
    cp linux-arm64/DataService.pdb $INSTALL_DIR/
    
    # Ensure proper ownership and permissions
    chown $SERVICE_USER:$SERVICE_USER $INSTALL_DIR/DataService $INSTALL_DIR/DataService.pdb
    chmod +x $INSTALL_DIR/DataService
    
    # Start the service
    echo -e "${BLUE}🚀 Starting CanBridge service...${NC}"
    systemctl start $SERVICE_NAME
    
    # Wait and check
    sleep 3
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${GREEN}✅ CanBridge updated and running successfully!${NC}"
    else
        echo -e "${RED}❌ Service failed to start after update${NC}"
        echo "Check logs: sudo journalctl -u $SERVICE_NAME -n 20"
        exit 1
    fi
    
else
    # Fresh installation
    echo -e "${BLUE}📋 Installing CanBridge...${NC}"
    cp linux-arm64/* $INSTALL_DIR/
    chown -R $SERVICE_USER:$SERVICE_USER $INSTALL_DIR
    chmod +x $INSTALL_DIR/DataService
    
fi

# Only create systemd service and setup for fresh installs
if [ "$OPERATION" = "INSTALL" ]; then
    
# Create systemd service file
echo -e "${BLUE}⚙️  Creating systemd service...${NC}"
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

# Environment
Environment=DOTNET_ENVIRONMENT=Production
Environment=ASPNETCORE_URLS=http://0.0.0.0:5000

# Capabilities for CAN interface configuration (native SocketCAN)
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_RAWIO
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_RAWIO

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

# Set up logrotate for service logs
echo -e "${BLUE}📝 Setting up log rotation...${NC}"
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

# Reload systemd and enable service
echo -e "${BLUE}🔄 Enabling service...${NC}"
systemctl daemon-reload
systemctl enable $SERVICE_NAME

# Check for CAN device
echo -e "${BLUE}🔍 Checking for CAN device...${NC}"
CAN_DEVICE_FOUND=false
for device in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyACM2 /dev/ttyUSB0; do
    if [ -e "$device" ]; then
        echo -e "${GREEN}✅ Found CAN device: $device${NC}"
        CAN_DEVICE_FOUND=true
        # Ensure proper permissions
        chown root:dialout $device
        chmod 660 $device
    fi
done

if [ "$CAN_DEVICE_FOUND" = false ]; then
    echo -e "${YELLOW}⚠️  No CAN device found. Please connect your CAN interface and restart the service.${NC}"
fi

# Start the service
echo -e "${BLUE}🚀 Starting CanBridge service...${NC}"
if systemctl start $SERVICE_NAME; then
    echo -e "${GREEN}✅ CanBridge service started successfully${NC}"
else
    echo -e "${YELLOW}⚠️  Service start may have issues. Check status below.${NC}"
fi

fi # End of install-only block

# Show service status for both install and update
echo -e "${BLUE}📊 Service Status:${NC}"
systemctl status $SERVICE_NAME --no-pager -l

# Cleanup
cd /
rm -rf /tmp/linux-arm64 /tmp/canbridge-linux-arm64.tar.gz

# =========================================================================
# Tailscale — remote access mesh
# =========================================================================
echo ""
echo -e "${BLUE}🔗 Tailscale Setup${NC}"
echo -e "${BLUE}==================${NC}"

# Install Tailscale binary if not present
if command -v tailscale &>/dev/null; then
    TS_STATE=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("BackendState","unknown"))' 2>/dev/null || echo "unknown")
    if [ "$TS_STATE" = "Running" ]; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
        echo -e "${GREEN}✅ Tailscale already running (IP: $TS_IP)${NC}"
    else
        echo -e "${GREEN}✅ Tailscale installed (not yet connected)${NC}"
    fi
else
    echo -e "${BLUE}⬇️  Installing Tailscale...${NC}"
    if curl -fsSL https://tailscale.com/install.sh | sh; then
        echo -e "${GREEN}✅ Tailscale installed${NC}"
    else
        echo -e "${RED}❌ Tailscale installation failed${NC}"
        echo "  Install manually: https://tailscale.com/download/linux"
    fi
fi

# =========================================================================
# Device Activation — register with Hub and join tailnet
# =========================================================================
echo ""
echo -e "${BLUE}🔑 Device Activation${NC}"
echo -e "${BLUE}====================${NC}"
echo "  Hub: $HUB_URL ($HUB_ENV)"
echo ""

# Generate a NodeInstanceId for this device
NODE_INSTANCE_ID=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || cat /proc/sys/kernel/random/uuid)

echo "  Device Instance ID: $NODE_INSTANCE_ID"
echo ""
echo -e "${YELLOW}  Generate an activation code in Hub: $HUB_URL/DeviceActivation${NC}"
echo ""
read -rp "  Enter activation code (or 'skip' to skip): " ACTIVATION_CODE < /dev/tty

if [ "$ACTIVATION_CODE" = "skip" ] || [ -z "$ACTIVATION_CODE" ]; then
    echo -e "${YELLOW}⚠️  Skipping activation — device not registered with Hub${NC}"
    echo "  Tailscale not connected. To activate later, re-run this script."
else
    # Normalize code to uppercase
    ACTIVATION_CODE=$(echo "$ACTIVATION_CODE" | tr '[:lower:]' '[:upper:]' | tr -d ' ')

    echo -e "${BLUE}🔗 Activating with Hub...${NC}"
    ACTIVATE_RESPONSE=$(curl -s -X POST "$HUB_URL/api/devices/activate" \
        -H "Content-Type: application/json" \
        -d "{\"nodeInstanceId\": \"$NODE_INSTANCE_ID\", \"activationCode\": \"$ACTIVATION_CODE\"}" 2>/dev/null || echo "")

    if [ -z "$ACTIVATE_RESPONSE" ]; then
        echo -e "${RED}❌ Could not reach Hub at $HUB_URL${NC}"
    else
        ACTIVATE_SUCCESS=$(echo "$ACTIVATE_RESPONSE" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("success",False))' 2>/dev/null || echo "False")

        if [ "$ACTIVATE_SUCCESS" = "True" ]; then
            DEVICE_NAME=$(echo "$ACTIVATE_RESPONSE" | python3 -c 'import sys,json; v=json.load(sys.stdin).get("deviceName"); print(v if v else "")' 2>/dev/null || echo "")
            UNIT_ID=$(echo "$ACTIVATE_RESPONSE" | python3 -c 'import sys,json; v=json.load(sys.stdin).get("unitId"); print(v if v else "")' 2>/dev/null || echo "")
            REGISTRY_TOKEN=$(echo "$ACTIVATE_RESPONSE" | python3 -c 'import sys,json; v=json.load(sys.stdin).get("registryToken"); print(v if v else "")' 2>/dev/null || echo "")
            TS_AUTHKEY=$(echo "$ACTIVATE_RESPONSE" | python3 -c 'import sys,json; v=json.load(sys.stdin).get("tailscaleAuthKey"); print(v if v else "")' 2>/dev/null || echo "")
            TS_LOGIN_SERVER=$(echo "$ACTIVATE_RESPONSE" | python3 -c 'import sys,json; v=json.load(sys.stdin).get("tailscaleLoginServer"); print(v if v else "")' 2>/dev/null || echo "")

            echo -e "${GREEN}✅ Activated as $DEVICE_NAME (Unit: $UNIT_ID)${NC}"

            # Docker login with registry token
            if [ -n "$REGISTRY_TOKEN" ]; then
                echo -e "${BLUE}🐳 Authenticating with container registry...${NC}"
                if echo "$REGISTRY_TOKEN" | docker login ghcr.io -u netglass-io --password-stdin 2>/dev/null; then
                    echo -e "${GREEN}✅ Docker authenticated with GHCR${NC}"
                else
                    echo -e "${YELLOW}⚠️  Docker login failed — may need manual auth${NC}"
                fi
            fi

            # Join tailnet
            if [ -n "$TS_AUTHKEY" ] && command -v tailscale &>/dev/null; then
                # Ensure tailscaled is running
                systemctl start tailscaled 2>/dev/null
                TS_HOSTNAME=$(hostname -s)
                TS_ARGS="--authkey=$TS_AUTHKEY --hostname=$TS_HOSTNAME"
                if [ -n "$TS_LOGIN_SERVER" ]; then
                    TS_ARGS="$TS_ARGS --login-server=$TS_LOGIN_SERVER"
                    echo -e "${BLUE}🔗 Joining tailnet as $TS_HOSTNAME (server: $TS_LOGIN_SERVER)...${NC}"
                else
                    echo -e "${BLUE}🔗 Joining tailnet as $TS_HOSTNAME...${NC}"
                fi
                if tailscale up $TS_ARGS; then
                    sleep 3
                    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
                    echo -e "${GREEN}✅ Joined tailnet (IP: $TS_IP)${NC}"
                    # Enable Tailscale SSH server for remote access
                    tailscale set --ssh --accept-risk=lose-ssh 2>/dev/null
                    echo -e "${GREEN}✅ Tailscale SSH enabled${NC}"
                else
                    echo -e "${RED}❌ Failed to join tailnet${NC}"
                fi
            elif [ -z "$TS_AUTHKEY" ]; then
                echo -e "${YELLOW}⚠️  No Tailscale auth key in Hub — configure in Device Activation > Tailscale${NC}"
            fi
        else
            ERROR_MSG=$(echo "$ACTIVATE_RESPONSE" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("errorMessage","Unknown error"))' 2>/dev/null || echo "Unknown error")
            echo -e "${RED}❌ Activation failed: $ERROR_MSG${NC}"
        fi
    fi
fi

echo ""
if [ "$OPERATION" = "UPDATE" ]; then
    echo -e "${GREEN}🎉 CanBridge Update Complete!${NC}"
else
    echo -e "${GREEN}🎉 Installation Complete!${NC}"
fi
echo ""
echo -e "${BLUE}📋 Management Commands:${NC}"
echo "  Start service:    sudo systemctl start $SERVICE_NAME"
echo "  Stop service:     sudo systemctl stop $SERVICE_NAME"
echo "  Restart service:  sudo systemctl restart $SERVICE_NAME"
echo "  Check status:     sudo systemctl status $SERVICE_NAME"
echo "  View logs:        sudo journalctl -u $SERVICE_NAME -f"
echo ""
echo -e "${BLUE}🌐 Service Details:${NC}"
echo "  Installation:     $INSTALL_DIR"
echo "  Service User:     $SERVICE_USER"
echo "  Web Interface:    http://localhost:5000"
echo ""
echo -e "${BLUE}🔗 Tailscale:${NC}"
TS_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
echo "  Tailscale IP:     $TS_IP"
echo "  Status:           sudo tailscale status"
echo "  SSH via tailnet:  ssh nodemin@$TS_IP"
echo ""
echo -e "${BLUE}🔧 Troubleshooting:${NC}"
echo "  • Ensure CAN device is connected"
echo "  • Check that user '$SERVICE_USER' is in 'dialout' and 'i2c' groups"
echo "  • Verify network connectivity for SignalR broadcasting"
echo ""

# Final service check
sleep 2
if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}✅ CanBridge is running successfully!${NC}"
else
    echo -e "${YELLOW}⚠️  CanBridge may not be running. Check logs:${NC}"
    echo "    sudo journalctl -u $SERVICE_NAME --no-pager -n 20"
fi

echo ""
echo -e "${BLUE}📋 Need Help?${NC}"
echo "  • Report bugs or issues: https://github.com/netglass-io/NobleOne-Releases/issues/new/choose"
echo "  • View existing issues: https://github.com/netglass-io/NobleOne-Releases/issues"
echo "  • Installation support: Use the 'Installation Support' template"
echo ""
