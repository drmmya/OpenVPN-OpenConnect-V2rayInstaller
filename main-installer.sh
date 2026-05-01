#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then echo "Run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main}"
WORK_DIR="/tmp/vpn-installer-$$"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

fetch_script(){
  local f="$1"
  if [[ -f "$(pwd)/$f" ]]; then return 0; fi
  if [[ -f "./$f" ]]; then return 0; fi
  if [[ -f "${LOCAL_DIR:-}/$f" ]]; then cp "${LOCAL_DIR}/$f" "$f"; return 0; fi
  curl -fsSL "$REPO_RAW/$f" -o "$f"
  chmod +x "$f"
}

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
LOCAL_DIR=""
[[ -f "$SCRIPT_PATH" ]] && LOCAL_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)" || true

for f in setup-panel-ui.sh install-openvpn.sh install-openconnect.sh install-v2ray.sh; do
  if [[ -n "$LOCAL_DIR" && -f "$LOCAL_DIR/$f" ]]; then cp "$LOCAL_DIR/$f" "$f"; chmod +x "$f"; else fetch_script "$f"; fi
done

read -r -p "Select protocols [0/all, 1=OpenVPN, 2=OpenConnect, 3=V2Ray, example 1,2]: " CHOICE || true
CHOICE="${CHOICE:-0}"
CHOICE="${CHOICE// /}"
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
if [[ "$ASK_OC" == "1" ]]; then
  read -r -p "OpenConnect TCP/UDP port [443]: " v || true; OC_PORT="${v:-443}"
fi
if [[ "$ASK_V2" == "1" ]]; then
  read -r -p "V2Ray/Xray port [4443]: " v || true; V2_PORT="${v:-4443}"
fi

export OVPN_UDP_PORT OVPN_TCP_PORT OC_PORT V2_PORT
export PANEL_DIR="/var/www/html/panel-admin"
export PANEL_ALIAS="vpn-panel"
export ADMIN_USER="${ADMIN_USER:-openvpn}"
export ADMIN_PASS="${ADMIN_PASS:-Easin112233@}"
export DEFAULT_USER="${DEFAULT_USER:-Easin}"
export DEFAULT_USER_PASS="${DEFAULT_USER_PASS:-Easin112233@}"

echo "[MAIN] Setting up base panel..."
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
[[ "$INSTALLED_OPENVPN" == "1" ]] && echo "OpenVPN UDP = $OVPN_UDP_PORT | TCP = $OVPN_TCP_PORT"
[[ "$INSTALLED_OPENCONNECT" == "1" ]] && echo "OpenConnect = $OC_PORT"
[[ "$INSTALLED_V2RAY" == "1" ]] && echo "V2Ray/Xray = $V2_PORT"
echo "Admin URL = http://${SERVER_ADDR}/vpn-panel"
echo "Admin user = ${ADMIN_USER}"
echo "Admin pass = ${ADMIN_PASS}"
echo "Default VPN user = ${DEFAULT_USER}"
echo "Default VPN pass = ${DEFAULT_USER_PASS}"
echo "=============================================="
