#!/bin/bash
# CanBridge Installation/Update Script
# For Raspberry Pi 5 / ARM64 Linux systems
# Automatically detects and handles both initial install and updates

set -e

# Configuration
INSTALL_DIR="/opt/canbridge"
SERVICE_NAME="canbridge"
SERVICE_USER="canbridge"
RELEASE_REPO="netglass-io/NobleOne-Releases"
DOWNLOAD_URL="https://github.com/${RELEASE_REPO}/releases/latest/download/canbridge-linux-arm64.tar.gz"

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
    read -p "Continue anyway? (y/N): " -n 1 -r
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
    usermod -a -G dialout $SERVICE_USER
    echo -e "${GREEN}✅ Created user $SERVICE_USER and added to dialout group${NC}"
else
    echo -e "${GREEN}✅ Service user $SERVICE_USER already exists${NC}"
    # Ensure user is in dialout group
    usermod -a -G dialout $SERVICE_USER
    echo -e "${GREEN}✅ Added $SERVICE_USER to dialout group${NC}"
fi

# Create installation directory
echo -e "${BLUE}📁 Creating installation directory...${NC}"
mkdir -p $INSTALL_DIR
chown $SERVICE_USER:$SERVICE_USER $INSTALL_DIR

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
Environment=ASPNETCORE_URLS=http://localhost:5000

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

echo ""
if [ "$OPERATION" = "UPDATE" ]; then
    echo -e "${GREEN}🎉 CanBridge Update Complete!${NC}"
else
    echo -e "${GREEN}🎉 CanBridge Installation Complete!${NC}"
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
echo -e "${BLUE}🔧 Troubleshooting:${NC}"
echo "  • Ensure CAN device is connected"
echo "  • Check that user '$SERVICE_USER' is in 'dialout' group"
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
