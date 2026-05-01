# OpenVPN + OpenConnect + V2Ray/Xray Installer

Professional multi-protocol VPN installer with a single admin panel.

## Quick install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main/main-installer.sh)
```

## Files

- `main-installer.sh` — main menu, port prompts, downloads/runs child scripts
- `setup-panel-ui.sh` — creates `/var/www/html/panel-admin` and `/vpn-panel`
- `install-openvpn.sh` — OpenVPN install + users + active devices + `.ovpn` download
- `install-openconnect.sh` — OpenConnect/ocserv install + users + live sessions
- `install-v2ray.sh` — V2Ray/Xray VLESS TCP install + config page

## Menu selection

- `1` = OpenVPN
- `2` = OpenConnect
- `3` = V2Ray/Xray
- `1,2` = OpenVPN + OpenConnect
- `1,3` = OpenVPN + V2Ray/Xray
- `2,3` = OpenConnect + V2Ray/Xray
- `0` or Enter = all protocols

The panel menu shows only installed protocols.

## Default ports

- OpenVPN UDP: `1194`
- OpenVPN TCP: `8443`
- OpenConnect: `443`
- V2Ray/Xray: `4443`

The installer asks for ports only for selected protocols. If OpenConnect port `443` is already busy, the installer automatically uses `444` to avoid ocserv startup failure.

## Admin panel

After install:

```text
http://YOUR_SERVER_IP/vpn-panel
```

Default admin:

```text
Username: openvpn
Password: Easin112233@
```

Default VPN user:

```text
Username: Easin
Password: Easin112233@
```

## Notes

- OpenVPN active devices are read from live OpenVPN status files, not stale history logs.
- OpenConnect live sessions are read from `occtl` socket.
- Mobile menu uses a sidebar drawer instead of horizontal scrolling.
- Future protocol changes should be edited in that protocol's own installer script.
