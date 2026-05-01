# OpenVPN + OpenConnect + V2Ray/Xray PRO Installer

All-in-one modular VPN installer with a modern admin panel.

## Quick install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main/main-installer.sh)
```

## Features

- Main installer with protocol selection
- Separate scripts for OpenVPN, OpenConnect, V2Ray/Xray
- Enter `0` or press Enter to install all protocols
- Custom port prompts during install
- Full old install cleanup before fresh install
- Admin panel folder: `/var/www/html/panel-admin`
- Admin URL: `http://SERVER-IP/vpn-panel`
- Dynamic menu based on installed protocols
- Modern colorful mobile-friendly UI
- Total VPS bandwidth on dashboard using `vnstat`
- Installed ports shown as vertical cards
- Service status on dashboard: RUNNING / STOPPED
- Start / Stop / Restart from admin panel
- System Control page:
  - install missing protocols later from panel
  - change installed protocol ports
  - port-used check before install/change
  - restart services cleanly
- OpenVPN multi-device count and GUI info support retained
- OpenConnect user/live session panel support retained
- V2Ray/Xray config/link panel support retained

## Files

- `main-installer.sh`
- `setup-panel-ui.sh`
- `install-openvpn.sh`
- `install-openconnect.sh`
- `install-v2ray.sh`

## Install options

When installer asks:

- `1` = OpenVPN
- `2` = OpenConnect
- `3` = V2Ray/Xray
- `1,2` = OpenVPN + OpenConnect
- `1,3` = OpenVPN + V2Ray/Xray
- `2,3` = OpenConnect + V2Ray/Xray
- `0` or Enter = All protocols

## Default ports

- OpenVPN UDP: `1194`
- OpenVPN TCP: `8443`
- OpenConnect: `443`
- V2Ray/Xray: `4443`

## Admin panel

After install:

```text
http://SERVER-IP/vpn-panel
```

Default admin:

```text
Username: openvpn
Password: Easin112233@
```

## Panel system control

Admin panel includes a **System Control** page.

From there you can:

- install a missing protocol
- set or change ports
- start service
- stop service
- restart service
- check service status

The panel uses `/usr/local/bin/vpn-control.sh` with a sudo whitelist:

```text
www-data ALL=(root) NOPASSWD: /usr/local/bin/vpn-control.sh
```

## Notes

- Bandwidth data may need a few minutes after first install because `vnstat` starts collecting after installation.
- If a port is already used, the panel blocks the action and asks for a different port.
- Upload all files to GitHub root, then run the Quick install command.
