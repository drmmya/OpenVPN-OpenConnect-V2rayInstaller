#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
PROTO="${2:-}"
PORT1="${3:-}"
PORT2="${4:-}"
CONF="/etc/vpn-protocols.conf"
INSTALLER_DIR="${INSTALLER_DIR:-/root/vpn-installer}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main}"
PANEL_DIR="/var/www/html/panel-admin"

fail(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "$*"; }

is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
port_in_use(){ local port="$1"; ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$"; }

get_conf(){ local k="$1" d="${2:-}"; [[ -f "$CONF" ]] && grep -E "^${k}=" "$CONF" | tail -1 | cut -d= -f2- || printf '%s' "$d"; }
set_conf(){ local k="$1" v="$2"; touch "$CONF"; if grep -qE "^${k}=" "$CONF"; then sed -i "s|^${k}=.*|${k}=${v}|" "$CONF"; else echo "${k}=${v}" >> "$CONF"; fi; chmod 644 "$CONF"; }
allow_tcp(){ iptables -C INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$1" -j ACCEPT; }
allow_udp(){ iptables -C INPUT -p udp --dport "$1" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$1" -j ACCEPT; }

ensure_script(){
  local f="$1"
  mkdir -p "$INSTALLER_DIR"
  if [[ ! -f "$INSTALLER_DIR/$f" ]]; then
    curl -fsSL "$REPO_RAW/$f" -o "$INSTALLER_DIR/$f" || fail "$f not found locally and download failed"
    chmod +x "$INSTALLER_DIR/$f"
  fi
  bash -n "$INSTALLER_DIR/$f" || fail "$f has syntax error"
}

ensure_free(){
  local p="$1" current="${2:-}"
  is_port "$p" || fail "Invalid port: $p"
  if [[ "$p" != "$current" ]] && port_in_use "$p"; then
    fail "Port $p already used. Choose another port."
  fi
}

active_openvpn(){ systemctl is-active --quiet openvpn-server@server-udp || systemctl is-active --quiet openvpn-server@server-tcp; }
active_openconnect(){ systemctl is-active --quiet ocserv; }
active_v2ray(){ systemctl is-active --quiet xray; }

verify_state(){
  local proto="$1" want="$2"
  case "$proto:$want" in
    openvpn:active) active_openvpn || fail "OpenVPN did not start/restart" ;;
    openvpn:inactive) ! active_openvpn || fail "OpenVPN did not stop" ;;
    openconnect:active) active_openconnect || fail "OpenConnect did not start/restart" ;;
    openconnect:inactive) ! active_openconnect || fail "OpenConnect did not stop" ;;
    v2ray:active|xray:active) active_v2ray || fail "V2Ray/Xray did not start/restart" ;;
    v2ray:inactive|xray:inactive) ! active_v2ray || fail "V2Ray/Xray did not stop" ;;
  esac
}

svc_start(){
  case "$1" in
    openvpn) systemctl start openvpn-server@server-udp openvpn-server@server-tcp; verify_state openvpn active ;;
    openconnect) systemctl start ocserv; verify_state openconnect active ;;
    v2ray|xray) systemctl start xray; verify_state v2ray active ;;
    *) fail "Unknown protocol: $1" ;;
  esac
}
svc_stop(){
  case "$1" in
    openvpn) systemctl stop openvpn-server@server-udp openvpn-server@server-tcp 2>/dev/null || true; verify_state openvpn inactive ;;
    openconnect) systemctl stop ocserv; verify_state openconnect inactive ;;
    v2ray|xray) systemctl stop xray; verify_state v2ray inactive ;;
    *) fail "Unknown protocol: $1" ;;
  esac
}
svc_restart(){
  case "$1" in
    openvpn) systemctl restart openvpn-server@server-udp openvpn-server@server-tcp; verify_state openvpn active ;;
    openconnect) systemctl restart ocserv; verify_state openconnect active ;;
    v2ray|xray) systemctl restart xray; verify_state v2ray active ;;
    *) fail "Unknown protocol: $1" ;;
  esac
}

regen_ovpn_profiles(){
  local server
  server="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  if [[ -x /usr/local/bin/ovpn-user-manage.sh ]]; then
    sqlite3 "$PANEL_DIR/data/vpn.sqlite" "SELECT username FROM ovpn_users" 2>/dev/null | while read -r u; do
      [[ -n "$u" ]] && SERVER_ADDR_OVERRIDE="$server" /usr/local/bin/ovpn-user-manage.sh regen "$u" >/dev/null 2>&1 || true
    done
  fi
}

change_openvpn_ports(){
  local udp="$1" tcp="$2"
  local old_udp old_tcp
  old_udp="$(get_conf OVPN_UDP_PORT 1194)"; old_tcp="$(get_conf OVPN_TCP_PORT 8443)"
  ensure_free "$udp" "$old_udp"; ensure_free "$tcp" "$old_tcp"
  [[ -f /etc/openvpn/server/server-udp.conf ]] || fail "OpenVPN UDP config not found"
  [[ -f /etc/openvpn/server/server-tcp.conf ]] || fail "OpenVPN TCP config not found"
  sed -i "s/^port .*/port ${udp}/" /etc/openvpn/server/server-udp.conf
  sed -i "s/^port .*/port ${tcp}/" /etc/openvpn/server/server-tcp.conf
  if [[ -f /usr/local/bin/ovpn-make-profile.sh ]]; then
    sed -i -E "s/remote \\\${SERVER_ADDR} [0-9]+ udp/remote \\\${SERVER_ADDR} ${udp} udp/g" /usr/local/bin/ovpn-make-profile.sh || true
    sed -i -E "s/remote \\\${SERVER_ADDR} [0-9]+ tcp-client/remote \\\${SERVER_ADDR} ${tcp} tcp-client/g" /usr/local/bin/ovpn-make-profile.sh || true
  fi
  allow_udp "$udp"; allow_tcp "$tcp"
  set_conf OPENVPN 1; set_conf OVPN_UDP_PORT "$udp"; set_conf OVPN_TCP_PORT "$tcp"
  svc_restart openvpn
  regen_ovpn_profiles
  info "OpenVPN ports changed: UDP=$udp TCP=$tcp"
}

change_openconnect_port(){
  local port="$1" old
  old="$(get_conf OC_PORT 443)"
  ensure_free "$port" "$old"
  [[ -f /etc/ocserv/ocserv.conf ]] || fail "OpenConnect config not found"
  sed -i -E "s/^tcp-port = .*/tcp-port = ${port}/; s/^udp-port = .*/udp-port = ${port}/" /etc/ocserv/ocserv.conf
  allow_tcp "$port"; allow_udp "$port"
  set_conf OPENCONNECT 1; set_conf OC_PORT "$port"
  svc_restart openconnect
  info "OpenConnect port changed: $port"
}

change_v2ray_port(){
  local port="$1" old cfg
  old="$(get_conf V2_PORT 4443)"
  ensure_free "$port" "$old"
  if [[ -f /usr/local/etc/xray/config.json ]]; then cfg="/usr/local/etc/xray/config.json"; elif [[ -f /etc/xray/config.json ]]; then cfg="/etc/xray/config.json"; else fail "Xray config not found"; fi
  python3 - <<PY
import json
path = "${cfg}"
port = int("${port}")
with open(path) as f:
    data = json.load(f)
if data.get("inbounds"):
    data["inbounds"][0]["port"] = port
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
  allow_tcp "$port"
  set_conf V2RAY 1; set_conf V2_PORT "$port"
  [[ -f "$PANEL_DIR/data/v2ray.env" ]] && sed -i "s/^V2_PORT=.*/V2_PORT=${port}/" "$PANEL_DIR/data/v2ray.env" || true
  svc_restart v2ray
  info "V2Ray/Xray port changed: $port"
}

install_protocol(){
  local proto="$1"
  case "$proto" in
    openvpn)
      local udp="${2:-1194}" tcp="${3:-8443}"
      ensure_free "$udp" "$(get_conf OVPN_UDP_PORT '')"; ensure_free "$tcp" "$(get_conf OVPN_TCP_PORT '')"
      ensure_script install-openvpn.sh
      export PANEL_DIR OVPN_UDP_PORT="$udp" OVPN_TCP_PORT="$tcp"
      bash "$INSTALLER_DIR/install-openvpn.sh"
      set_conf OPENVPN 1; set_conf OVPN_UDP_PORT "$udp"; set_conf OVPN_TCP_PORT "$tcp"
      verify_state openvpn active
      ;;
    openconnect)
      local port="${2:-443}"
      ensure_free "$port" "$(get_conf OC_PORT '')"
      ensure_script install-openconnect.sh
      export PANEL_DIR OC_PORT="$port"
      bash "$INSTALLER_DIR/install-openconnect.sh"
      set_conf OPENCONNECT 1; set_conf OC_PORT "$port"
      verify_state openconnect active
      ;;
    v2ray|xray)
      local port="${2:-4443}"
      ensure_free "$port" "$(get_conf V2_PORT '')"
      ensure_script install-v2ray.sh
      export PANEL_DIR V2_PORT="$port"
      bash "$INSTALLER_DIR/install-v2ray.sh"
      set_conf V2RAY 1; set_conf V2_PORT "$port"
      verify_state v2ray active
      ;;
    *) fail "Unknown protocol: $proto" ;;
  esac
  info "$proto installed"
}

case "$ACTION" in
  start) svc_start "$PROTO"; info "Started $PROTO" ;;
  stop) svc_stop "$PROTO"; info "Stopped $PROTO" ;;
  restart) svc_restart "$PROTO"; info "Restarted $PROTO" ;;
  status)
    case "$PROTO" in
      openvpn) active_openvpn ;;
      openconnect) active_openconnect ;;
      v2ray|xray) active_v2ray ;;
      *) fail "Unknown protocol: $PROTO" ;;
    esac ;;
  port-check)
    is_port "$PROTO" || fail "Invalid port: $PROTO"
    if port_in_use "$PROTO"; then echo "USED"; exit 2; else echo "FREE"; fi ;;
  change-port)
    case "$PROTO" in
      openvpn) change_openvpn_ports "$PORT1" "$PORT2" ;;
      openconnect) change_openconnect_port "$PORT1" ;;
      v2ray|xray) change_v2ray_port "$PORT1" ;;
      *) fail "Unknown protocol: $PROTO" ;;
    esac ;;
  install) install_protocol "$PROTO" "$PORT1" "$PORT2" ;;
  *) echo "Usage: vpn-control.sh {install|change-port|start|stop|restart|status|port-check} ..."; exit 1 ;;
esac
