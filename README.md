# VPN PRO Admin Installer — fixed version

Run from the extracted folder on a clean Ubuntu/Debian VPS:

```bash
sudo apt update && sudo apt install -y curl && sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main/main-installer.sh)'
```

Panel URL after install:

```text
http://YOUR_VPS_IP/vpn-panel
```

Default admin:

```text
openvpn / Easin112233@
```

Default VPN user:

```text
Easin / Easin112233@
```

## Panel install logs

When installing a protocol from the admin panel, the job runs in the background and writes logs here:

```bash
sudo tail -f /var/log/vpn-panel-install-openvpn.log
sudo tail -f /var/log/vpn-panel-install-openconnect.log
sudo tail -f /var/log/vpn-panel-install-v2ray.log
```

## Important fixes in this version

- Panel install buttons no longer break with `ERR_EMPTY_RESPONSE`.
- OpenVPN downloaded `.ovpn` files use the real selected/changed ports.
- OpenVPN profiles regenerate after port changes.
- Missing panel files are no longer ignored during install.
- Port validation and duplicate-port checks were added.
- OpenConnect no longer silently falls back to port `444`.
- Persistent firewall rules were added for OpenVPN, OpenConnect, and V2Ray/Xray via `vpn-iptables.service`.
- Required dependencies such as `iproute2`, `python3`, and `php-sqlite3` were added.
- Username validation was added for VPN users.
- OpenConnect passwords are no longer displayed or stored in plaintext CSV.
- Apache directory listing is disabled.
- Panel file permissions were hardened.

## Quick verification after install

```bash
sudo cat /etc/vpn-protocols.conf
sudo systemctl status openvpn-server@server-udp --no-pager
sudo systemctl status openvpn-server@server-tcp --no-pager
sudo systemctl status ocserv --no-pager
sudo systemctl status xray --no-pager
sudo systemctl status vpn-iptables --no-pager
sudo grep -R '^remote ' /var/www/html/panel-admin/downloads/*.ovpn
```

### Live install logs in Admin Panel
Go to **System Control** and use the **Live Install Console**. When you install OpenVPN, OpenConnect, or V2Ray/Xray from the panel, logs auto-refresh in the browser every 2 seconds like `tail -f` in PuTTY.

Direct log files:

```bash
sudo tail -f /var/log/vpn-panel-install-openvpn.log
sudo tail -f /var/log/vpn-panel-install-openconnect.log
sudo tail -f /var/log/vpn-panel-install-v2ray.log
```
