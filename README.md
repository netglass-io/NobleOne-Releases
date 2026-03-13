# NobleOne Fleet Management System

AI-powered forklift fleet management system with real-time CAN bus integration, driver interfaces, and cloud analytics.

## 🚀 Quick Installation

For **Nvidia Jetson** (Nano, AGX Orin, Thor):

```bash
# Preprod (default) — fetches Tailscale config from preprod Hub:
curl -fsSL https://raw.githubusercontent.com/netglass-io/NobleOne-Releases/main/install.sh | sudo bash

# Production:
curl -fsSL https://raw.githubusercontent.com/netglass-io/NobleOne-Releases/main/install.sh | sudo bash -s -- --env prod
```

The script fetches Tailscale auth keys from Hub automatically. Configure keys in Hub under Device Activation > Tailscale.

## 📋 System Requirements

- **Hardware**: Nvidia Jetson (Nano, AGX Orin, Thor)
- **OS**: Ubuntu 22.04 LTS (ARM64)
- **Storage**: 8GB+ available space
- **Network**: Internet connection for installation
- **Permissions**: Root/sudo access

## 🏗️ What Gets Installed

- **CanBridge Service** - CAN bus data acquisition and SignalR server
- **Tailscale** - WireGuard mesh VPN for remote SSH access from anywhere
- **System Services** - Automatic startup and monitoring

Node WebApp container and other services are deployed remotely over Tailscale after initial bootstrap.

## 🌐 System Access

After installation:
- **Remote SSH**: `ssh nodemin@<tailscale-ip>` (from any machine on the tailnet)
- **Driver Interface**: http://your-device-ip:5233
- **System Status**: http://your-device-ip:5001/status

## 🐛 Report Issues or Request Features

Having problems or ideas for improvements?

**[👉 Create New Issue](https://github.com/netglass-io/NobleOne-Releases/issues/new/choose)**

Choose from:
- 🐛 **Bug Report** - System not working correctly
- ✨ **Feature Request** - Suggest improvements  
- 🔧 **Installation Support** - Need setup help

**[View All Issues](https://github.com/netglass-io/NobleOne-Releases/issues)**

## 📚 Documentation

### Installation & Setup
- **Prerequisites**: Ubuntu 22.04 LTS on supported Jetson hardware
- **Network**: Ensure internet connectivity during installation
- **Permissions**: Script requires sudo/root access

### Troubleshooting
- **Service Status**: `sudo systemctl status canbridge`
- **Logs**: `sudo journalctl -u canbridge -f`
- **Container Status**: `sudo docker ps`
- **Port Check**: `netstat -tlnp | grep :5233`

### Hardware Integration
- **CAN Interface**: Native SocketCAN via Jetson MTTCAN controller
- **Connection**: Direct CAN bus connection via CAN transceiver
- **Vehicle Integration**: Compatible with Curtis motor controllers

## 🔧 Support

### Before Reporting Issues
1. **Check system status**: Service and container health
2. **Review logs**: System and application logs for errors
3. **Verify hardware**: USB connections and CAN interface
4. **Network connectivity**: Internet access and port availability

### Getting Help
- **Installation Issues**: Use the Installation Support template
- **System Bugs**: Use the Bug Report template with logs
- **Feature Ideas**: Use the Feature Request template

### Contact
- **Issues & Bugs**: [GitHub Issues](https://github.com/netglass-io/NobleOne-Releases/issues)
- **Security Concerns**: security@noblelift.com

## 📦 Release Information

This repository contains:
- **Installation Scripts** - Automated setup and updates
- **Release Binaries** - Pre-compiled system packages
- **Issue Tracking** - Bug reports and feature requests
- **Documentation** - Setup guides and troubleshooting

For source code and development information, contact the development team.

---

**NobleOne** - Empowering intelligent fleet management through AI and real-time data integration.
