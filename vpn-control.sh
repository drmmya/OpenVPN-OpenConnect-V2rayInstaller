#!/usr/bin/env bash
set -euo pipefail
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main}"
CONF="/etc/vpn-protocols.conf"
PANEL_DIR="/var/www/html/panel-admin"
export PANEL_DIR PANEL_ALIAS="vpn-panel" ADMIN_USER="${ADMIN_USER:-openvpn}" ADMIN_PASS="${ADMIN_PASS:-Easin112233@}" DEFAULT_USER="${DEFAULT_USER:-Easin}" DEFAULT_USER_PASS="${DEFAULT_USER_PASS:-Easin112233@}"

get_conf(){ local k="$1" d="${2:-}"; [[ -f "$CONF" ]] && grep -E "^${k}=" "$CONF" | tail -1 | cut -d= -f2- || printf '%s' "$d"; }
set_conf(){ local k="$1" v="$2"; touch "$CONF"; if grep -qE "^${k}=" "$CONF"; then sed -i "s|^${k}=.*|${k}=${v}|" "$CONF"; else echo "${k}=${v}" >> "$CONF"; fi; chmod 644 "$CONF"; }
valid_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
port_used(){ local p="$1"; ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${p}$"; }
allow_tcp(){ iptables -C INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$1" -j ACCEPT; }
allow_udp(){ iptables -C INPUT -p udp --dport "$1" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$1" -j ACCEPT; }
fetch(){ local f="$1" d="/tmp/vpn-panel-control-$$"; mkdir -p "$d"; curl -fsSL "$REPO_RAW/$f" -o "$d/$f"; chmod +x "$d/$f"; echo "$d/$f"; }
ensure_free(){ local p="$1" current="${2:-}"; valid_port "$p" || { echo "Invalid port: $p"; exit 2; }; if [[ "$p" != "$current" ]] && port_used "$p"; then echo "Port $p already used. Choose another port."; exit 3; fi; }

case "${1:-}" in
  port-check)
    p="${2:-}"; valid_port "$p" || { echo "INVALID"; exit 2; }; if port_used "$p"; then echo "USED"; exit 1; else echo "FREE"; fi ;;
  status)
    case "${2:-}" in
      openvpn) systemctl is-active --quiet openvpn-server@server-udp || systemctl is-active --quiet openvpn-server@server-tcp ;;
      openconnect) systemctl is-active --quiet ocserv ;;
      v2ray) systemctl is-active --quiet xray ;;
      *) exit 2 ;;
    esac ;;
  start|stop|restart)
    act="$1"; proto="${2:-}"
    case "$proto" in
      openvpn) systemctl "$act" openvpn-server@server-udp 2>/dev/null || true; systemctl "$act" openvpn-server@server-tcp 2>/dev/null || true ;;
      openconnect) systemctl "$act" ocserv ;;
      v2ray) systemctl "$act" xray ;;
      *) echo "Invalid protocol"; exit 2 ;;
    esac
    echo "${proto} ${act} done" ;;
  install)
    proto="${2:-}"
    case "$proto" in
      openvpn)
        udp="${3:-1194}"; tcp="${4:-8443}"; ensure_free "$udp" "$(get_conf OVPN_UDP_PORT '')"; ensure_free "$tcp" "$(get_conf OVPN_TCP_PORT '')"
        export OVPN_UDP_PORT="$udp" OVPN_TCP_PORT="$tcp"; bash "$(fetch install-openvpn.sh)"; set_conf OPENVPN 1; set_conf OVPN_UDP_PORT "$udp"; set_conf OVPN_TCP_PORT "$tcp" ;;
      openconnect)
        port="${3:-443}"; ensure_free "$port" "$(get_conf OC_PORT '')"; export OC_PORT="$port"; bash "$(fetch install-openconnect.sh)"; set_conf OPENCONNECT 1; set_conf OC_PORT "$port" ;;
      v2ray)
        port="${3:-4443}"; ensure_free "$port" "$(get_conf V2_PORT '')"; export V2_PORT="$port"; bash "$(fetch install-v2ray.sh)"; set_conf V2RAY 1; set_conf V2_PORT "$port" ;;
      *) echo "Invalid protocol"; exit 2 ;;
    esac
    echo "$proto installed" ;;
  change-port)
    proto="${2:-}"
    case "$proto" in
      openvpn)
        udp="${3:-}"; tcp="${4:-}"; old_udp="$(get_conf OVPN_UDP_PORT 1194)"; old_tcp="$(get_conf OVPN_TCP_PORT 8443)"; ensure_free "$udp" "$old_udp"; ensure_free "$tcp" "$old_tcp"
        [[ -f /etc/openvpn/server/server-udp.conf ]] && sed -i "s/^port .*/port ${udp}/" /etc/openvpn/server/server-udp.conf
        [[ -f /etc/openvpn/server/server-tcp.conf ]] && sed -i "s/^port .*/port ${tcp}/" /etc/openvpn/server/server-tcp.conf
        if [[ -f /usr/local/bin/ovpn-make-profile.sh ]]; then
          sed -i -E "s#^remote .* [0-9]+ udp#remote \\${SERVER_ADDR} ${udp} udp#; s#^remote .* [0-9]+ tcp-client#remote \\${SERVER_ADDR} ${tcp} tcp-client#" /usr/local/bin/ovpn-make-profile.sh || true
        fi
        allow_udp "$udp"; allow_tcp "$tcp"; set_conf OVPN_UDP_PORT "$udp"; set_conf OVPN_TCP_PORT "$tcp"; systemctl restart openvpn-server@server-udp openvpn-server@server-tcp ;;
      openconnect)
        port="${3:-}"; old="$(get_conf OC_PORT 443)"; ensure_free "$port" "$old"; [[ -f /etc/ocserv/ocserv.conf ]] && sed -i -E "s/^tcp-port = .*/tcp-port = ${port}/; s/^udp-port = .*/udp-port = ${port}/" /etc/ocserv/ocserv.conf; allow_tcp "$port"; allow_udp "$port"; set_conf OC_PORT "$port"; systemctl restart ocserv ;;
      v2ray)
        port="${3:-}"; old="$(get_conf V2_PORT 4443)"; ensure_free "$port" "$old"; [[ -f /usr/local/etc/xray/config.json ]] && python3 - <<PY
import json
p=int('$port')
path='/usr/local/etc/xray/config.json'
with open(path) as f: data=json.load(f)
if data.get('inbounds'): data['inbounds'][0]['port']=p
with open(path,'w') as f: json.dump(data,f,indent=2)
PY
        allow_tcp "$port"; set_conf V2_PORT "$port"; [[ -f "$PANEL_DIR/data/v2ray.env" ]] && sed -i "s/^V2_PORT=.*/V2_PORT=${port}/" "$PANEL_DIR/data/v2ray.env" || true; systemctl restart xray ;;
      *) echo "Invalid protocol"; exit 2 ;;
    esac
    echo "$proto port changed" ;;
  *) echo "Usage: vpn-control.sh {install|change-port|start|stop|restart|status|port-check} ..."; exit 2 ;;
esac
