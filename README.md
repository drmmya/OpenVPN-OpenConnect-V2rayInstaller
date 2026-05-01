# VPN PRO Admin Installer

Run from GitHub raw:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main/main-installer.sh)
```

Required GitHub root structure:

```text
main-installer.sh
setup-panel-ui.sh
install-openvpn.sh
install-openconnect.sh
install-v2ray.sh
vpn-control.sh
panel-admin/
```

Panel URL after install:

```text
http://YOUR_VPS_IP/vpn-panel
```

Default admin:

```text
openvpn / Easin112233@
```

Important fixes in this version:

- `/root/vpn-installer/*.sh` is always created, so panel install buttons can find child installers.
- `vpn-control.sh` has syntax check before install.
- Start/Stop/Restart verifies real systemd state before showing success.
- Port change updates service config and `/etc/vpn-protocols.conf`.
- OpenVPN port change regenerates `.ovpn` profiles.
- V2Ray/Xray uses `/usr/local/etc/xray/config.json`.
