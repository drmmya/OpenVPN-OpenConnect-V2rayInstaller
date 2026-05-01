#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then echo "Run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main}"
INSTALLER_DIR="/root/vpn-installer"
mkdir -p "$INSTALLER_DIR/panel-admin"

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
LOCAL_DIR=""
if [[ -f "$SCRIPT_PATH" ]]; then LOCAL_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"; fi

fetch_file(){
  local remote="$1" dest="$2"
  if [[ -n "$LOCAL_DIR" && -f "$LOCAL_DIR/$remote" ]]; then
    mkdir -p "$(dirname "$dest")"; cp "$LOCAL_DIR/$remote" "$dest"
  else
    mkdir -p "$(dirname "$dest")"; curl -fsSL "$REPO_RAW/$remote" -o "$dest"
  fi
}

ROOT_FILES=(setup-panel-ui.sh install-openvpn.sh install-openconnect.sh install-v2ray.sh vpn-control.sh)
PANEL_FILES=(config.php style.css login.php index.php change_password.php logout.php system_control.php system-control.php openvpn.php openconnect.php v2ray.php README.md)

for f in "${ROOT_FILES[@]}"; do fetch_file "$f" "$INSTALLER_DIR/$f"; chmod +x "$INSTALLER_DIR/$f"; done
for f in "${PANEL_FILES[@]}"; do fetch_file "panel-admin/$f" "$INSTALLER_DIR/panel-admin/$f" || true; done

cd "$INSTALLER_DIR"

read -r -p "Select protocols [0/all, 1=OpenVPN, 2=OpenConnect, 3=V2Ray, example 1,2]: " CHOICE || true
CHOICE="${CHOICE:-0}"; CHOICE="${CHOICE// /}"
want(){ [[ "$CHOICE" == "0" || "$CHOICE" == "all" || ",$CHOICE," == *",$1,"* ]]; }

ASK_OVPN=0; ASK_OC=0; ASK_V2=0
want 1 && ASK_OVPN=1
want 2 && ASK_OC=1
want 3 && ASK_V2=1

OVPN_UDP_PORT="1194"; OVPN_TCP_PORT="8443"; OC_PORT="443"; V2_PORT="4443"
if [[ "$ASK_OVPN" == "1" ]]; then
  read -r -p "OpenVPN UDP port [1194]: " v || true; OVPN_UDP_PORT="${v:-1194}"
  read -r -p "OpenVPN TCP port [8443]: " v || true; OVPN_TCP_PORT="${v:-8443}"
fi
if [[ "$ASK_OC" == "1" ]]; then read -r -p "OpenConnect TCP/UDP port [443]: " v || true; OC_PORT="${v:-443}"; fi
if [[ "$ASK_V2" == "1" ]]; then read -r -p "V2Ray/Xray port [4443]: " v || true; V2_PORT="${v:-4443}"; fi

export OVPN_UDP_PORT OVPN_TCP_PORT OC_PORT V2_PORT
export PANEL_DIR="/var/www/html/panel-admin"
export PANEL_ALIAS="vpn-panel"
export ADMIN_USER="${ADMIN_USER:-openvpn}"
export ADMIN_PASS="${ADMIN_PASS:-Easin112233@}"
export DEFAULT_USER="${DEFAULT_USER:-Easin}"
export DEFAULT_USER_PASS="${DEFAULT_USER_PASS:-Easin112233@}"

cleanup_old_install(){
  echo "[MAIN] Cleaning old VPN install if present..."
  OLD_OVPN_UDP_PORT="1194"; OLD_OVPN_TCP_PORT="8443"; OLD_OC_PORT="443"; OLD_V2_PORT="4443"
  if [[ -f /etc/vpn-protocols.conf ]]; then
    OLD_OVPN_UDP_PORT="$(grep -E '^OVPN_UDP_PORT=' /etc/vpn-protocols.conf | tail -1 | cut -d= -f2 || true)"; OLD_OVPN_UDP_PORT="${OLD_OVPN_UDP_PORT:-1194}"
    OLD_OVPN_TCP_PORT="$(grep -E '^OVPN_TCP_PORT=' /etc/vpn-protocols.conf | tail -1 | cut -d= -f2 || true)"; OLD_OVPN_TCP_PORT="${OLD_OVPN_TCP_PORT:-8443}"
    OLD_OC_PORT="$(grep -E '^OC_PORT=' /etc/vpn-protocols.conf | tail -1 | cut -d= -f2 || true)"; OLD_OC_PORT="${OLD_OC_PORT:-443}"
    OLD_V2_PORT="$(grep -E '^V2_PORT=' /etc/vpn-protocols.conf | tail -1 | cut -d= -f2 || true)"; OLD_V2_PORT="${OLD_V2_PORT:-4443}"
  fi
  systemctl stop openvpn-server@server-udp openvpn-server@server-tcp ovpn-iptables.service ocserv xray apache2 2>/dev/null || true
  systemctl disable openvpn-server@server-udp openvpn-server@server-tcp ovpn-iptables.service ocserv xray 2>/dev/null || true
  rm -rf /var/www/html/ovpn-admin /var/www/html/panel-admin /etc/openvpn/pki-webadmin /root/easy-rsa
  rm -f /etc/openvpn/server/server-udp.conf /etc/openvpn/server/server-tcp.conf
  rm -f /etc/ocserv/ocserv.conf /etc/ocserv/ocpasswd; rm -rf /etc/ocserv/ssl
  rm -f /usr/local/etc/xray/config.json /etc/xray/config.json
  rm -f /etc/systemd/system/ovpn-iptables.service
  rm -f /usr/local/bin/ovpn-auth.php /usr/local/bin/ovpn-log-event.php /usr/local/bin/ovpn-make-profile.sh /usr/local/bin/ovpn-user-manage.sh /usr/local/bin/ovpn-kill-user.sh /usr/local/bin/ovpn-iptables-apply.sh
  rm -f /usr/local/bin/oc-user-manage.sh /usr/local/bin/oc-event-log.sh /usr/local/bin/oc-active-sessions.sh
  rm -f /etc/vpn-protocols.conf
  rm -f /var/log/openvpn/server-udp.log /var/log/openvpn/server-tcp.log /var/log/openvpn/openvpn-status-udp.log /var/log/openvpn/openvpn-status-tcp.log /var/log/openvpn/ipp-udp.txt /var/log/openvpn/ipp-tcp.txt
  for p in "$OLD_OVPN_UDP_PORT" 1194; do while iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; done
  for p in "$OLD_OVPN_TCP_PORT" 8443; do while iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; done
  for p in "$OLD_OC_PORT" 443 444; do while iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; while iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; done
  for p in "$OLD_V2_PORT" 4443; do while iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; done
  systemctl daemon-reload || true
}

cleanup_old_install

echo "[MAIN] Setting up panel..."
bash ./setup-panel-ui.sh

INSTALLED_OPENVPN=0; INSTALLED_OPENCONNECT=0; INSTALLED_V2RAY=0
if [[ "$ASK_OVPN" == "1" ]]; then bash ./install-openvpn.sh; INSTALLED_OPENVPN=1; fi
if [[ "$ASK_OC" == "1" ]]; then bash ./install-openconnect.sh; INSTALLED_OPENCONNECT=1; fi
if [[ "$ASK_V2" == "1" ]]; then bash ./install-v2ray.sh; INSTALLED_V2RAY=1; fi

cat >/etc/vpn-protocols.conf <<EOF
OPENVPN=$INSTALLED_OPENVPN
OPENCONNECT=$INSTALLED_OPENCONNECT
V2RAY=$INSTALLED_V2RAY
OVPN_UDP_PORT=$OVPN_UDP_PORT
OVPN_TCP_PORT=$OVPN_TCP_PORT
OC_PORT=$OC_PORT
V2_PORT=$V2_PORT
EOF
chmod 644 /etc/vpn-protocols.conf

SERVER_ADDR="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
echo
echo "=============================================="
echo "Installation completed"
echo "=============================================="
[[ "$INSTALLED_OPENVPN" == "1" ]] && echo "OpenVPN UDP = $OVPN_UDP_PORT" && echo "OpenVPN TCP = $OVPN_TCP_PORT"
[[ "$INSTALLED_OPENCONNECT" == "1" ]] && echo "OpenConnect = $OC_PORT"
[[ "$INSTALLED_V2RAY" == "1" ]] && echo "V2Ray/Xray = $V2_PORT"
echo "Admin URL = http://${SERVER_ADDR}/vpn-panel"
echo "Admin user = ${ADMIN_USER}"
echo "Admin pass = ${ADMIN_PASS}"
echo "Default VPN user = ${DEFAULT_USER}"
echo "Default VPN pass = ${DEFAULT_USER_PASS}"
echo "=============================================="
