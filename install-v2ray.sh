#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "Run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
APP_DIR="${PANEL_DIR:-/var/www/html/panel-admin}"
DATA_DIR="$APP_DIR/data"
V2_PORT="${V2_PORT:-4443}"
UUID="${V2_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
CONF_FILE="/etc/vpn-protocols.conf"
SERVER_ADDR="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
set_conf(){ local k="$1" v="$2"; touch "$CONF_FILE"; if grep -qE "^${k}=" "$CONF_FILE"; then sed -i "s|^${k}=.*|${k}=${v}|" "$CONF_FILE"; else echo "${k}=${v}" >> "$CONF_FILE"; fi; chmod 644 "$CONF_FILE"; }
port_used(){ local port="$1"; ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; }

is_port "$V2_PORT" || { echo "ERROR: Invalid V2Ray/Xray port: $V2_PORT" >&2; exit 1; }

echo "[V2Ray/Xray] Installing packages..."
apt-get update >/dev/null
apt-get install -y curl unzip apache2 php libapache2-mod-php php-cli php-sqlite3 sqlite3 iptables iproute2 python3 ca-certificates >/dev/null

systemctl stop xray 2>/dev/null || true
if port_used "$V2_PORT"; then
  echo "ERROR: V2Ray/Xray TCP port $V2_PORT is already in use. Choose another port." >&2
  exit 1
fi

if ! command -v xray >/dev/null 2>&1; then
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" install >/dev/null
fi
mkdir -p /usr/local/etc/xray "$DATA_DIR" "$APP_DIR"

cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${V2_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "email": "default@vpn-panel" } ],
        "decryption": "none"
      },
      "streamSettings": { "network": "tcp", "security": "none" }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

iptables -C INPUT -p tcp --dport "$V2_PORT" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$V2_PORT" -j ACCEPT
cat >"$DATA_DIR/v2ray.env" <<EOF
V2_PORT=${V2_PORT}
V2_UUID=${UUID}
SERVER_ADDR=${SERVER_ADDR}
EOF
chown www-data:www-data "$DATA_DIR/v2ray.env" 2>/dev/null || true
chmod 664 "$DATA_DIR/v2ray.env" 2>/dev/null || true

cat >"$APP_DIR/v2ray.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $env=[]; $f=DATA_DIR.'/v2ray.env'; if(is_file($f)){ foreach(file($f,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){ if(strpos($line,'=')!==false){[$k,$v]=explode('=',$line,2); $env[$k]=$v; } } } $port=(int)($env['V2_PORT']??cfgv('V2_PORT','4443')); $uuid=$env['V2_UUID']??''; $host=$env['SERVER_ADDR']??($_SERVER['SERVER_ADDR']??'SERVER_IP'); $link='vless://'.$uuid.'@'.$host.':'.$port.'?encryption=none&security=none&type=tcp#VPN-Panel-V2Ray'; $active=trim(shell_exec("ss -Htn state established '( sport = :$port )' 2>/dev/null | awk '{print \$5}' | cut -d: -f1 | sort -u | wc -l")); render_header('V2Ray Panel'); ?>
<div class="grid"><div class="card"><div class="muted">Port</div><div class="kpi"><?=esc($port)?></div></div><div class="card"><div class="muted">Active IPs</div><div class="kpi"><?=esc($active?:'0')?></div></div></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">V2Ray / Xray VLESS Link</h2><div class="code"><?=esc($link)?></div></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">Manual config</h2><div class="code">Address: <?=esc($host)?>
Port: <?=esc($port)?>
UUID: <?=esc($uuid)?>
Protocol: VLESS
Network: TCP
Security: None
Encryption: None</div></div><?php render_footer(); ?>
PHP

set_conf V2RAY 1
set_conf V2_PORT "$V2_PORT"
systemctl daemon-reload
systemctl enable xray apache2 >/dev/null 2>&1 || true
systemctl reload apache2 >/dev/null 2>&1 || systemctl restart apache2 || true
if [[ -x /usr/local/bin/vpn-control.sh ]]; then /usr/local/bin/vpn-control.sh refresh-firewall >/dev/null 2>&1 || true; fi
systemctl restart xray
chown -R root:www-data "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;
chown -R www-data:www-data "$DATA_DIR"
chmod -R 775 "$DATA_DIR"
echo "[V2Ray/Xray] Done on port ${V2_PORT}"
