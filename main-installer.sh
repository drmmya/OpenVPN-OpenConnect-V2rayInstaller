#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main}"
REQUIRED_SCRIPTS=(install-openvpn.sh install-openconnect.sh install-v2ray.sh setup-panel-ui.sh)

resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  local dir
  dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd 2>/dev/null || true)"
  if [[ -n "$dir" && -f "$dir/install-openvpn.sh" && -f "$dir/setup-panel-ui.sh" ]]; then
    echo "$dir"
    return 0
  fi

  local tmp="/tmp/vpn-modular-installer-$$"
  mkdir -p "$tmp"
  echo "Running via curl/process substitution. Downloading installer modules..." >&2
  for f in "${REQUIRED_SCRIPTS[@]}"; do
    curl -fsSL "${REPO_RAW_URL}/${f}" -o "$tmp/$f"
    chmod +x "$tmp/$f"
  done
  echo "$tmp"
}

SCRIPT_DIR="$(resolve_script_dir)"

cleanup_tmp() {
  if [[ "$SCRIPT_DIR" == /tmp/vpn-modular-installer-* ]]; then
    rm -rf "$SCRIPT_DIR" 2>/dev/null || true
  fi
}
trap cleanup_tmp EXIT

get_public_ip(){
  local ip=""
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
    ip="$(curl -4 -fsSL "$url" 2>/dev/null | tr -d '\r\n' || true)"
    [[ -n "$ip" ]] && break
  done
  [[ -n "$ip" ]] || ip="$(hostname -I | awk '{print $1}')"
  echo "$ip"
}

SERVER_ADDR="$(get_public_ip)"
[[ -n "$SERVER_ADDR" ]] || { echo "Could not detect server IP"; exit 1; }

NET_IFACE="$(ip route get 1.1.1.1 | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
: "${NET_IFACE:=eth0}"

ADMIN_USER="${ADMIN_USER:-openvpn}"
ADMIN_PASS="${ADMIN_PASS:-Easin112233@}"
DEFAULT_USER="${DEFAULT_USER:-Easin}"
DEFAULT_USER_PASS="${DEFAULT_USER_PASS:-Easin112233@}"
DOMAIN_NAME="${DOMAIN_NAME:-mustakimshop.online}"
OC_HOST="${OC_HOST:-oc.${DOMAIN_NAME}}"
V2_HOST="${V2_HOST:-v2.${DOMAIN_NAME}}"
OVPN_HOST="${OVPN_HOST:-ovpn.${DOMAIN_NAME}}"
APP_DIR="/var/www/html/panel-admin"

echo "Select protocols to install:"
echo "  1 = OpenVPN"
echo "  2 = OpenConnect"
echo "  3 = V2Ray/Xray"
echo "  0 or Enter = All"
read -r -p "Choice [0/all, example 1,2 or 1,3]: " CHOICE
CHOICE="${CHOICE:-0}"

install_openvpn=0
install_oc=0
install_v2=0
if [[ "$CHOICE" == "0" ]]; then
  install_openvpn=1
  install_oc=1
  install_v2=1
else
  IFS=',' read -ra PARTS <<< "$CHOICE"
  for p in "${PARTS[@]}"; do
    p="$(echo "$p" | xargs)"
    [[ "$p" == "1" ]] && install_openvpn=1
    [[ "$p" == "2" ]] && install_oc=1
    [[ "$p" == "3" ]] && install_v2=1
  done
fi

if [[ "$install_openvpn" == "0" && "$install_oc" == "0" && "$install_v2" == "0" ]]; then
  echo "Invalid choice. Use 0, 1, 2, 3, 1,2, 1,3, or 2,3"
  exit 1
fi

UDP_PORT="1194"
TCP_PORT="8443"
OC_PORT="443"
V2_PORT="4443"

if [[ "$install_openvpn" == "1" ]]; then
  read -r -p "OpenVPN UDP port [1194]: " UDP_PORT_IN
  UDP_PORT="${UDP_PORT_IN:-1194}"
  read -r -p "OpenVPN TCP port [8443]: " TCP_PORT_IN
  TCP_PORT="${TCP_PORT_IN:-8443}"
fi
if [[ "$install_oc" == "1" ]]; then
  read -r -p "OpenConnect TCP/UDP port [443]: " OC_PORT_IN
  OC_PORT="${OC_PORT_IN:-443}"
fi
if [[ "$install_v2" == "1" ]]; then
  read -r -p "V2Ray/Xray port [4443]: " V2_PORT_IN
  V2_PORT="${V2_PORT_IN:-4443}"
fi

cat >/etc/vpn-install.env <<ENVEOF
SERVER_ADDR=${SERVER_ADDR}
NET_IFACE=${NET_IFACE}
APP_DIR=${APP_DIR}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
DEFAULT_USER=${DEFAULT_USER}
DEFAULT_USER_PASS=${DEFAULT_USER_PASS}
DOMAIN_NAME=${DOMAIN_NAME}
OC_HOST=${OC_HOST}
V2_HOST=${V2_HOST}
OVPN_HOST=${OVPN_HOST}
UDP_PORT=${UDP_PORT}
TCP_PORT=${TCP_PORT}
OC_PORT=${OC_PORT}
V2_PORT=${V2_PORT}
ENVEOF
chmod 644 /etc/vpn-install.env
cp /etc/vpn-install.env /etc/vpn.env

cat >/etc/vpn-protocols.conf <<PROTOEOF
OPENVPN=${install_openvpn}
OPENCONNECT=${install_oc}
V2RAY=${install_v2}
PROTOEOF
chmod 644 /etc/vpn-protocols.conf

[[ "$install_openvpn" == "1" ]] && bash "$SCRIPT_DIR/install-openvpn.sh"
[[ "$install_oc" == "1" ]] && bash "$SCRIPT_DIR/install-openconnect.sh"
[[ "$install_v2" == "1" ]] && bash "$SCRIPT_DIR/install-v2ray.sh"
bash "$SCRIPT_DIR/setup-panel-ui.sh"

echo
echo "============================================================"
echo "✅ VPN INSTALL COMPLETE"
echo "============================================================"
[[ "$install_openvpn" == "1" ]] && echo "OpenVPN UDP = ${UDP_PORT}" && echo "OpenVPN TCP = ${TCP_PORT}"
[[ "$install_oc" == "1" ]] && echo "OpenConnect = ${OC_PORT}"
[[ "$install_v2" == "1" ]] && echo "V2Ray/Xray = ${V2_PORT}"
echo "Admin URL = http://${SERVER_ADDR}/vpn-panel"
echo "Admin username = ${ADMIN_USER}"
echo "Admin password = ${ADMIN_PASS}"
echo "Panel folder = ${APP_DIR}"
echo "============================================================"
