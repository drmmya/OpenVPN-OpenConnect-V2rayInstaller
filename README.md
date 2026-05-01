# OpenVPN + OpenConnect + V2Ray/Xray Installer

Run from root on Ubuntu/Debian VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main/main-installer.sh)
```

Features:
- Main installer with protocol selection
- Separate scripts for OpenVPN, OpenConnect, V2Ray/Xray, and panel UI
- Full old-install cleanup before fresh install
- Custom ports
- Dynamic `/vpn-panel` admin panel
- Modern colorful dashboard
- Total VPS bandwidth cards using `vnstat`
- Installed ports shown as separate vertical cards

After install:

```text
Admin URL: http://YOUR_VPS_IP/vpn-panel
Default admin user: openvpn
Default admin pass: Easin112233@
```

Bandwidth note: `vnstat` may need a few minutes after first install before usage data appears.
