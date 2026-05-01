# OpenVPN + OpenConnect + V2Ray Installer

A modular all-in-one VPN installer for Ubuntu/Debian VPS. This project installs and manages **OpenVPN**, **OpenConnect**, and **V2Ray/Xray** from separate protocol scripts, with one main installer and a web-based admin panel.

GitHub main installer:

```bash
https://github.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/blob/main/main-installer.sh
```

---

## Features

- One main installer script
- Separate protocol scripts for easy future updates
- OpenVPN installer
- OpenConnect installer
- V2Ray/Xray installer
- Install one protocol, two protocols, or all protocols
- Custom port selection during installation
- Dynamic admin panel menu based on installed protocols
- Mobile-friendly admin panel menu
- Admin panel URL: `/vpn-panel`
- Admin panel folder: `/var/www/html/panel-admin`
- OpenVPN active connected device list
- OpenConnect user management panel
- V2Ray user management panel

---

## Supported OS

Recommended:

- Ubuntu 20.04+
- Ubuntu 22.04+
- Ubuntu 24.04+
- Debian 11+
- Debian 12+

Run as **root**.

---

## Quick Install from PuTTY

Login to your VPS as root, then run:

```bash
apt update -y && apt install -y curl && bash <(curl -fsSL https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main/main-installer.sh)
```

Alternative using `wget`:

```bash
apt update -y && apt install -y wget && bash <(wget -qO- https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main/main-installer.sh)
```

---

## Manual Install

```bash
git clone https://github.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller.git
cd OpenVPN-OpenConnect-V2rayInstaller
chmod +x *.sh
sudo bash main-installer.sh
```

---

## Protocol Selection

When the installer asks which protocol to install:

| Input | Result |
|---|---|
| `1` | Install OpenVPN only |
| `2` | Install OpenConnect only |
| `3` | Install V2Ray only |
| `1,2` | Install OpenVPN + OpenConnect |
| `1,3` | Install OpenVPN + V2Ray |
| `2,3` | Install OpenConnect + V2Ray |
| `0` or Enter | Install all protocols |

Example:

```text
Select protocols [0=All, 1=OpenVPN, 2=OpenConnect, 3=V2Ray]: 1,2
```

This installs only OpenVPN and OpenConnect.

---

## Default Ports

During installation, you can press Enter to use default ports, or type your custom port.

| Protocol | Default Port |
|---|---|
| OpenVPN UDP | `1194` |
| OpenVPN TCP | `8443` |
| OpenConnect TCP/UDP | `443` |
| V2Ray/Xray | `4443` |

Example custom port input:

```text
OpenVPN UDP port [1194]: 1195
OpenVPN TCP port [8443]: 8444
OpenConnect port [443]: 444
V2Ray port [4443]: 8443
```

The installer automatically applies the selected ports to:

- protocol config files
- firewall/iptables rules
- generated VPN profiles where needed
- admin panel summary

---

## Admin Panel

After installation, the installer shows the panel URL:

```text
Admin URL: http://YOUR_SERVER_IP/vpn-panel
```

Default admin login:

```text
Username: openvpn
Password: Easin112233@
```

Change the admin password after first login.

---

## Dynamic Admin Menu

The admin panel menu only shows installed protocols.

| Installed Protocols | Admin Menu |
|---|---|
| OpenVPN only | OpenVPN Panel |
| OpenConnect only | OpenConnect Panel |
| V2Ray only | V2Ray Panel |
| OpenVPN + OpenConnect | OpenVPN Panel + OpenConnect Panel |
| OpenVPN + V2Ray | OpenVPN Panel + V2Ray Panel |
| OpenConnect + V2Ray | OpenConnect Panel + V2Ray Panel |
| All protocols | OpenVPN Panel + OpenConnect Panel + V2Ray Panel |

Each page title changes based on the current protocol:

- OpenVPN page: `OpenVPN Panel`
- OpenConnect page: `OpenConnect Panel`
- V2Ray page: `V2Ray Panel`

---

## Project File Structure

```text
OpenVPN-OpenConnect-V2rayInstaller/
├── main-installer.sh
├── install-openvpn.sh
├── install-openconnect.sh
├── install-v2ray.sh
├── setup-panel-ui.sh
└── README.md
```

### `main-installer.sh`

Main entry point. It asks which protocols to install, asks ports, exports variables, and runs protocol scripts.

### `install-openvpn.sh`

Installs and configures OpenVPN, OpenVPN users, OpenVPN profile generation, OpenVPN service, status logs, and OpenVPN panel functions.

### `install-openconnect.sh`

Installs and configures OpenConnect/ocserv, OpenConnect users, service, firewall, and OpenConnect panel functions.

### `install-v2ray.sh`

Installs and configures V2Ray/Xray, V2Ray users, service, firewall, and V2Ray panel functions.

### `setup-panel-ui.sh`

Creates and updates the web admin panel UI, dynamic protocol menu, mobile menu, and protocol pages.

---

## Future Update System

This project is modular. If you want to update only one protocol later, edit only that protocol file.

Examples:

- OpenVPN function update: edit `install-openvpn.sh`
- OpenConnect function update: edit `install-openconnect.sh`
- V2Ray function update: edit `install-v2ray.sh`
- Admin panel UI update: edit `setup-panel-ui.sh`
- Installer selection logic update: edit `main-installer.sh`

You do not need to edit every file for a small protocol-specific update.

---

## Useful Commands

Check service status:

```bash
systemctl status apache2 --no-pager
systemctl status openvpn-server@server-udp --no-pager
systemctl status openvpn-server@server-tcp --no-pager
systemctl status ocserv --no-pager
systemctl status xray --no-pager
```

Restart services:

```bash
systemctl restart apache2
systemctl restart openvpn-server@server-udp
systemctl restart openvpn-server@server-tcp
systemctl restart ocserv
systemctl restart xray
```

View logs:

```bash
journalctl -u apache2 -n 100 --no-pager
journalctl -u openvpn-server@server-udp -n 100 --no-pager
journalctl -u openvpn-server@server-tcp -n 100 --no-pager
journalctl -u ocserv -n 100 --no-pager
journalctl -u xray -n 100 --no-pager
```

---

## Important Paths

```text
Admin panel: /var/www/html/panel-admin
Admin URL:   http://SERVER_IP/vpn-panel
OpenVPN:     /etc/openvpn/server
OpenConnect: /etc/ocserv
V2Ray/Xray:  /usr/local/etc/xray
Protocol config: /etc/vpn-protocols.conf
VPN env: /etc/vpn.env
```

---

## Troubleshooting

### Admin panel not opening

Check Apache:

```bash
systemctl status apache2 --no-pager
systemctl restart apache2
```

Make sure port 80 is allowed:

```bash
iptables -C INPUT -p tcp --dport 80 -j ACCEPT || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
```

### OpenVPN not connecting

Check OpenVPN services:

```bash
systemctl status openvpn-server@server-udp --no-pager
systemctl status openvpn-server@server-tcp --no-pager
```

Check OpenVPN logs:

```bash
tail -n 100 /var/log/openvpn/server-udp.log
tail -n 100 /var/log/openvpn/server-tcp.log
```

### OpenConnect not connecting

Check ocserv:

```bash
systemctl status ocserv --no-pager
journalctl -u ocserv -n 100 --no-pager
```

### V2Ray not connecting

Check Xray:

```bash
systemctl status xray --no-pager
journalctl -u xray -n 100 --no-pager
```

---

## Security Notes

- Change the default admin password after installation.
- Use strong VPN user passwords.
- Keep your VPS updated.
- Only open the ports you need.
- If you use a custom firewall provider, allow the selected ports there too.

---

## Final Install Summary

At the end of installation, the script shows:

```text
OpenVPN UDP = selected_port
OpenVPN TCP = selected_port
OpenConnect = selected_port
V2Ray = selected_port
Admin URL = http://SERVER_IP/vpn-panel
Admin username = openvpn
Admin password = Easin112233@
```

