#!/usr/bin/env bash
set -euo pipefail

# Safe control wrapper for VPN Panel
# Allowed actions only. Designed to be called by www-data via sudo.

ACTION="${1:-}"
PROTO="${2:-}"
PORT1="${3:-}"
PORT2="${4:-}"

is_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

port_in_use() {
  local port="$1"
  ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

service_name() {
  case "$1" in
    openvpn-udp) echo "openvpn-server@server-udp" ;;
    openvpn-tcp) echo "openvpn-server@server-tcp" ;;
    openvpn) echo "openvpn" ;;
    openconnect) echo "ocserv" ;;
    v2ray|xray) echo "xray" ;;
    apache) echo "apache2" ;;
    *) fail "Unknown service/protocol: $1" ;;
  esac
}

svc_start() {
  local s
  case "$1" in
    openvpn)
      systemctl start openvpn-server@server-udp || true
      systemctl start openvpn-server@server-tcp || true
      ;;
    openconnect)
      systemctl start ocserv
      ;;
    v2ray|xray)
      systemctl start xray
      ;;
    *)
      s="$(service_name "$1")"
      systemctl start "$s"
      ;;
  esac
}

svc_stop() {
  local s
  case "$1" in
    openvpn)
      systemctl stop openvpn-server@server-udp || true
      systemctl stop openvpn-server@server-tcp || true
      ;;
    openconnect)
      systemctl stop ocserv
      ;;
    v2ray|xray)
      systemctl stop xray
      ;;
    *)
      s="$(service_name "$1")"
      systemctl stop "$s"
      ;;
  esac
}

svc_restart() {
  local s
  case "$1" in
    openvpn)
      systemctl restart openvpn-server@server-udp || true
      systemctl restart openvpn-server@server-tcp || true
      ;;
    openconnect)
      systemctl restart ocserv
      ;;
    v2ray|xray)
      systemctl restart xray
      ;;
    *)
      s="$(service_name "$1")"
      systemctl restart "$s"
      ;;
  esac
}

change_openvpn_ports() {
  local udp="$1" tcp="$2"
  is_port "$udp" || fail "Invalid OpenVPN UDP port: $udp"
  is_port "$tcp" || fail "Invalid OpenVPN TCP port: $tcp"

  # Allow current OpenVPN ports to be changed without false conflict.
  local current_udp current_tcp
  current_udp="$(awk '/^port /{print $2; exit}' /etc/openvpn/server/server-udp.conf 2>/dev/null || true)"
  current_tcp="$(awk '/^port /{print $2; exit}' /etc/openvpn/server/server-tcp.conf 2>/dev/null || true)"

  if [[ "$udp" != "$current_udp" ]] && port_in_use "$udp"; then fail "UDP port $udp already in use"; fi
  if [[ "$tcp" != "$current_tcp" ]] && port_in_use "$tcp"; then fail "TCP port $tcp already in use"; fi

  sed -i "s/^port .*/port ${udp}/" /etc/openvpn/server/server-udp.conf
  sed -i "s/^port .*/port ${tcp}/" /etc/openvpn/server/server-tcp.conf

  if [[ -f /usr/local/bin/ovpn-make-profile.sh ]]; then
    sed -i "s/remote \${SERVER_ADDR} [0-9]\+ udp/remote \${SERVER_ADDR} ${udp} udp/g" /usr/local/bin/ovpn-make-profile.sh || true
    sed -i "s/remote \${OVPN_HOST:-\$SERVER_ADDR} [0-9]\+ tcp-client/remote \${OVPN_HOST:-\$SERVER_ADDR} ${tcp} tcp-client/g" /usr/local/bin/ovpn-make-profile.sh || true
  fi

  iptables -C INPUT -p udp --dport "$udp" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$udp" -j ACCEPT
  iptables -C INPUT -p tcp --dport "$tcp" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$tcp" -j ACCEPT

  svc_restart openvpn
  echo "OpenVPN ports changed: UDP=$udp TCP=$tcp"
}

change_openconnect_port() {
  local port="$1"
  is_port "$port" || fail "Invalid OpenConnect port: $port"
  local current
  current="$(awk -F'= *' '/^tcp-port/{print $2; exit}' /etc/ocserv/ocserv.conf 2>/dev/null || true)"
  if [[ "$port" != "$current" ]] && port_in_use "$port"; then fail "Port $port already in use"; fi

  sed -i "s/^tcp-port = .*/tcp-port = ${port}/" /etc/ocserv/ocserv.conf
  sed -i "s/^udp-port = .*/udp-port = ${port}/" /etc/ocserv/ocserv.conf
  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
  iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$port" -j ACCEPT
  svc_restart openconnect
  echo "OpenConnect port changed: $port"
}

change_v2ray_port() {
  local port="$1"
  is_port "$port" || fail "Invalid V2Ray/Xray port: $port"
  local current=""
  if [[ -f /etc/xray/config.json ]]; then
    current="$(grep -m1 '"port"' /etc/xray/config.json | grep -oE '[0-9]+' | head -n1 || true)"
  fi
  if [[ "$port" != "$current" ]] && port_in_use "$port"; then fail "Port $port already in use"; fi

  if [[ -f /etc/xray/config.json ]]; then
    python3 - <<PY
import json
p='/etc/xray/config.json'
port=int('${port}')
with open(p) as f:
    data=json.load(f)
if 'inbounds' in data and data['inbounds']:
    data['inbounds'][0]['port']=port
with open(p,'w') as f:
    json.dump(data,f,indent=2)
PY
  else
    fail "/etc/xray/config.json not found"
  fi
  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
  svc_restart v2ray
  echo "V2Ray/Xray port changed: $port"
}

install_protocol() {
  local proto="$1"
  shift || true
  case "$proto" in
    openvpn)
      bash /root/vpn-installer/install-openvpn.sh "$@"
      ;;
    openconnect)
      bash /root/vpn-installer/install-openconnect.sh "$@"
      ;;
    v2ray|xray)
      bash /root/vpn-installer/install-v2ray.sh "$@"
      ;;
    *) fail "Unknown protocol: $proto" ;;
  esac
}

case "$ACTION" in
  start)
    svc_start "$PROTO"
    echo "Started $PROTO"
    ;;
  stop)
    svc_stop "$PROTO"
    echo "Stopped $PROTO"
    ;;
  restart)
    svc_restart "$PROTO"
    echo "Restarted $PROTO"
    ;;
  status)
    case "$PROTO" in
      openvpn)
        systemctl is-active openvpn-server@server-udp || true
        systemctl is-active openvpn-server@server-tcp || true
        ;;
      openconnect)
        systemctl is-active ocserv || true
        ;;
      v2ray|xray)
        systemctl is-active xray || true
        ;;
      *) fail "Unknown protocol: $PROTO" ;;
    esac
    ;;
  port-check)
    is_port "$PROTO" || fail "Invalid port: $PROTO"
    if port_in_use "$PROTO"; then echo "USED"; exit 2; else echo "FREE"; fi
    ;;
  change-port)
    case "$PROTO" in
      openvpn) change_openvpn_ports "$PORT1" "$PORT2" ;;
      openconnect) change_openconnect_port "$PORT1" ;;
      v2ray|xray) change_v2ray_port "$PORT1" ;;
      *) fail "Unknown protocol: $PROTO" ;;
    esac
    ;;
  install)
    install_protocol "$PROTO" "$PORT1" "$PORT2"
    ;;
  *)
    cat >&2 <<USAGE
Usage:
  vpn-control.sh start openvpn|openconnect|v2ray
  vpn-control.sh stop openvpn|openconnect|v2ray
  vpn-control.sh restart openvpn|openconnect|v2ray
  vpn-control.sh status openvpn|openconnect|v2ray
  vpn-control.sh port-check PORT
  vpn-control.sh change-port openvpn UDP_PORT TCP_PORT
  vpn-control.sh change-port openconnect PORT
  vpn-control.sh change-port v2ray PORT
  vpn-control.sh install openvpn UDP_PORT TCP_PORT
  vpn-control.sh install openconnect PORT
  vpn-control.sh install v2ray PORT
USAGE
    exit 1
    ;;
esac
