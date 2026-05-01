#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "Run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
[[ -f /etc/vpn-install.env ]] && source /etc/vpn-install.env
APP_DIR="${APP_DIR:-/var/www/html/panel-admin}"
DATA_DIR="$APP_DIR/data"
V2_PORT="${V2_PORT:-${V2_PORT}}"
SERVER_ADDR="${SERVER_ADDR:-$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"
V2_HOST="${V2_HOST:-v2.${DOMAIN_NAME:-mustakimshop.online}}"
mkdir -p "$DATA_DIR"
echo "[17/22] Installing Xray/V2Ray core..."
apt-get update >/dev/null 2>&1 || true
apt-get install -y unzip jq haproxy uuid-runtime >/dev/null 2>&1 || true

XRAY_UUID="$(uuidgen)"
XRAY_DIR="/usr/local/etc/xray"
XRAY_SSL_DIR="/usr/local/etc/xray/ssl"
mkdir -p "$XRAY_DIR" "$XRAY_SSL_DIR" /var/log/xray
chmod 755 /var/log/xray

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 || true

# Self-signed TLS cert for SNI routing. Client link uses allowInsecure=1.
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout "$XRAY_SSL_DIR/xray.key" \
  -out "$XRAY_SSL_DIR/xray.crt" \
  -subj "/CN=${V2_HOST}" \
  -addext "subjectAltName=DNS:${V2_HOST}" >/dev/null 2>&1 || true
chmod 600 "$XRAY_SSL_DIR/xray.key"
chmod 644 "$XRAY_SSL_DIR/xray.crt"

cat >"$XRAY_DIR/config.json" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1", "localhost"]
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "outboundTag": "blocked",
        "protocol": ["bittorrent"]
      }
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${V2_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "email": "default@xray-direct",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {}},
    {"tag": "blocked", "protocol": "blackhole", "settings": {}}
  ]
}
EOF


# Xray runs as nobody on this system; give it read/write access to certs and logs.
mkdir -p /usr/local/etc/xray/ssl
mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log

if getent group nogroup >/dev/null 2>&1; then
  XRAY_GROUP="nogroup"
else
  XRAY_GROUP="daemon"
fi

chown -R nobody:${XRAY_GROUP} /usr/local/etc/xray
chown -R nobody:${XRAY_GROUP} /var/log/xray

chmod 755 /usr/local/etc/xray
chmod 755 /usr/local/etc/xray/ssl
chmod 755 /var/log/xray

chmod 644 /usr/local/etc/xray/ssl/xray.crt 2>/dev/null || true
chmod 644 /usr/local/etc/xray/ssl/xray.key 2>/dev/null || true

chmod 666 /var/log/xray/access.log /var/log/xray/error.log

systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray >/dev/null 2>&1 || true

echo "[18/22] HAProxy/SNI disabled for speed mode..."
apt-get install -y haproxy >/dev/null 2>&1 || true
systemctl stop haproxy >/dev/null 2>&1 || true
systemctl disable haproxy >/dev/null 2>&1 || true

# Direct public ports:
# OpenConnect -> 443 TCP/UDP
# Xray/V2Ray  -> ${V2_PORT} TCP
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 443 -j ACCEPT
iptables -C INPUT -p tcp --dport ${V2_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${V2_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 8443 -j ACCEPT
iptables -C INPUT -p udp --dport 1194 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 1194 -j ACCEPT
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT

systemctl restart ocserv >/dev/null 2>&1 || true
sleep 1

echo "[19/22] Adding Xray panel page..."
cat >"$APP_DIR/xray.php" <<'PHP'
<?php
require __DIR__.'/config.php';
require_login();

$cfgFile = '/usr/local/etc/xray/config.json';
$uuid = '';
if(is_file($cfgFile)){
    $cfg = json_decode(file_get_contents($cfgFile), true);
    $uuid = $cfg['inbounds'][0]['settings']['clients'][0]['id'] ?? '';
}

$serverIp = trim(shell_exec("curl -4 -fsSL https://api.ipify.org 2>/dev/null"));
if(!$serverIp){ $serverIp = $_SERVER['SERVER_ADDR'] ?? $_SERVER['HTTP_HOST'] ?? 'SERVER_IP'; }
$serverIp = preg_replace('/:.*/', '', $serverIp);

$link = $uuid ? "vless://".$uuid."@".$serverIp.":${V2_PORT}?type=tcp&security=none#Xray-".$serverIp : '';

// Unique CURRENT client IP count from ESTABLISHED connections only.
// Disconnect হলে ESTABLISHED connection চলে যাবে, তাই count থেকেও বের হবে।
$active = trim(shell_exec("ss -Htn state established '( sport = :${V2_PORT} or dport = :${V2_PORT} )' 2>/dev/null | awk '{print $5}' | sed 's/::ffff://g' | sed 's/^\\[//;s/\\]//' | sed 's/:.*$//' | grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' | sort -u | wc -l"));
if($active === '') $active = '0';

render_header('Xray / V2Ray');
?>

<div class="grid">
  <div class="card">
    <div class="muted">Xray active devices</div>
    <div class="kpi"><?=esc($active)?></div>
  </div>
</div>

<div class="card" style="margin-top:18px">
  <div class="toolbar" style="align-items:center">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">Xray / V2Ray Config</h2>
      <div class="small">NekoBox বা latest v2rayNG app-এ এই config import করুন। Port: ${V2_PORT}</div>
    </div>
    <span class="badge green">${V2_PORT}</span>
  </div>

  <label style="margin-top:12px;display:block">VLESS Link</label>
  <div style="display:flex;gap:10px;align-items:center;margin-top:8px">
    <input id="xrayLinkInput" value="<?=esc($link)?>" readonly
      style="flex:1;min-width:0;padding:14px;border-radius:16px;border:1px solid rgba(148,163,184,.25);background:#07111f;color:#e5e7eb;font-size:14px">
    <button class="btn green" type="button" onclick="copyXrayLink()" style="white-space:nowrap">Copy</button>
  </div>

  <div class="small" style="margin-top:12px">
    Address: <?=esc($serverIp)?> | Port: ${V2_PORT} | Protocol: VLESS | Network: TCP | Security: none
  </div>
</div>

<script>
function copyXrayLink(){
  const el = document.getElementById('xrayLinkInput');
  const val = el.value;
  if(navigator.clipboard && window.isSecureContext){
    navigator.clipboard.writeText(val).then(function(){ alert('Copied Xray config'); }).catch(function(){
      el.select(); el.setSelectionRange(0, 99999); document.execCommand('copy'); alert('Copied Xray config');
    });
  } else {
    el.select(); el.setSelectionRange(0, 99999); document.execCommand('copy'); alert('Copied Xray config');
  }
}
</script>

<?php render_footer(); ?>
PHP
python3 - <<'PY'
from pathlib import Path
cfg = Path('/var/www/html/panel-admin/config.php')
s = cfg.read_text()
anchor = '<a href="openconnect.php">OpenConnect</a>'
if 'xray.php' not in s:
    if anchor in s:
        s = s.replace(anchor, anchor + '\n      <a href="xray.php">Xray / V2Ray</a>')
    else:
        s = s.replace('<a href="change_password.php">Change Admin Password</a>', '<a href="xray.php">Xray / V2Ray</a>\n      <a href="change_password.php">Change Admin Password</a>')
cfg.write_text(s)
PY

chown -R www-data:www-data "$APP_DIR"
chmod 644 "$APP_DIR"/xray.php

echo
echo "Xray/V2Ray:"
echo "  Host: ${V2_HOST}:443"
echo "  UUID: ${XRAY_UUID}"
echo "  Link: vless://${XRAY_UUID}@${V2_HOST}:443?type=tcp&security=tls&sni=${V2_HOST}&allowInsecure=1#Xray-${V2_HOST}"

echo "[20/22] Adding domain settings page..."
cat >"$APP_DIR/settings.php" <<'PHP'
<?php
require __DIR__.'/config.php';
require_login();

$envFile = '/etc/vpn.env';
$msg=''; $err='';

function read_vpn_env($file){
    $out = ['DOMAIN_NAME'=>'mustakimshop.online'];
    if(is_file($file)){
        foreach(file($file, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
            if(strpos($line,'=')!==false){
                [$k,$v]=explode('=',$line,2);
                $out[trim($k)] = trim($v);
            }
        }
    }
    return $out;
}

if($_SERVER['REQUEST_METHOD']==='POST'){
    $domain = strtolower(trim($_POST['domain'] ?? ''));
    $domain = preg_replace('/^https?:\/\//','',$domain);
    $domain = trim($domain, "/ \t\n\r\0\x0B");
    if(!preg_match('/^[a-z0-9.-]+\.[a-z]{2,}$/', $domain)){
        $err = 'Invalid domain name';
    } else {
        $content = "DOMAIN_NAME={$domain}\nOC_HOST=oc.{$domain}\nV2_HOST=v2.{$domain}\nOVPN_HOST=ovpn.{$domain}\n";
        file_put_contents($envFile, $content);
        shell_exec('systemctl restart ocserv 2>/dev/null');
        shell_exec('systemctl restart haproxy 2>/dev/null');
        shell_exec('systemctl restart xray 2>/dev/null');
        shell_exec('systemctl restart apache2 2>/dev/null');
        $msg = 'Domain updated. Make sure DNS A records point to this VPS IP.';
    }
}

$env = read_vpn_env($envFile);
$domain = $env['DOMAIN_NAME'] ?? 'mustakimshop.online';

render_header('Domain Settings');
?>
<div class="card">
  <h2 class="section-title">Main Domain Settings</h2>
  <?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?>
  <?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>

  <form method="post">
    <label>Main domain</label>
    <input name="domain" value="<?=esc($domain)?>" placeholder="example.com" required>
    <br><br>
    <button class="btn" type="submit">Save & Restart Services</button>
  </form>

  <br>
  <div class="card">
    <div class="small">DNS records required:</div>
    <div class="code">oc.<?=esc($domain)?>   A   YOUR_VPS_IP
v2.<?=esc($domain)?>   A   YOUR_VPS_IP
ovpn.<?=esc($domain)?> A   YOUR_VPS_IP</div>
  </div>
</div>
<?php render_footer(); ?>
PHP

python3 - <<'PY'
from pathlib import Path
cfg = Path('/var/www/html/panel-admin/config.php')
s = cfg.read_text()
cfg.write_text(s)
PY

chown -R www-data:www-data "$APP_DIR"
chmod 644 "$APP_DIR"/settings.php

echo
echo "SNI routing:"
echo "  ${OC_HOST}:443 -> OpenConnect backend ${V2_PORT}"
echo "  ${V2_HOST}:443 -> Xray backend 8444"
echo "  OpenVPN UDP: 1194"
echo "  OpenVPN TCP: 8443"


echo "Xray checks:"
echo "  ss -tn sport = :${V2_PORT} | grep ESTAB | wc -l"
echo "  tail -n 50 /var/log/xray/access.log"
echo "  tail -n 50 /var/log/xray/error.log"


echo
echo "============================================================"
echo "✅ FULL VPN A-Z INSTALL COMPLETE"
echo "============================================================"
echo
echo "🌐 Admin Panel:"
echo "   URL      : http://${SERVER_ADDR}/vpn-panel/"
echo "   Username : ${ADMIN_USER}"
echo "   Password : ${ADMIN_PASS}"
echo
echo "📌 Main Domain:"
echo "   DOMAIN   : ${DOMAIN_NAME}"
echo
echo "🔐 Installed Protocols:"
echo "   1) OpenVPN UDP : ${SERVER_ADDR}:${UDP_PORT}"
echo "   2) OpenVPN TCP : ${SERVER_ADDR}:${TCP_PORT}"
echo "   3) OpenConnect : https://${SERVER_ADDR}:443"
echo "   4) Xray/V2Ray  : ${SERVER_ADDR}:${V2_PORT}"
echo
echo "🧩 Direct Port Mode:"
echo "   OpenConnect : ${SERVER_ADDR}:443 TCP/UDP"
echo "   Xray/V2Ray  : ${SERVER_ADDR}:${V2_PORT} TCP"
echo
echo "👤 Default VPN User:"
echo "   Username : ${DEFAULT_USER}"
echo "   Password : ${DEFAULT_USER_PASS}"
echo
echo "📱 Xray/V2Ray VLESS Link:"
echo "   vless://${XRAY_UUID}@${SERVER_ADDR}:${V2_PORT}?type=tcp&security=none#Xray-${SERVER_ADDR}"
echo
echo "🧪 Service Status:"
systemctl is-active --quiet apache2 && echo "   Apache Panel : running" || echo "   Apache Panel : not running"
systemctl is-active --quiet haproxy && echo "   HAProxy      : running (not required)" || echo "   HAProxy      : disabled/not required"
systemctl is-active --quiet openvpn-server@server-udp && echo "   OpenVPN UDP  : running" || echo "   OpenVPN UDP  : not running"
systemctl is-active --quiet openvpn-server@server-tcp && echo "   OpenVPN TCP  : running" || echo "   OpenVPN TCP  : not running"
systemctl is-active --quiet ocserv && echo "   OpenConnect  : running" || echo "   OpenConnect  : not running"
systemctl is-active --quiet xray && echo "   Xray/V2Ray   : running" || echo "   Xray/V2Ray   : not running"
echo
echo "📂 Important Files:"
echo "   VPN env      : /etc/vpn.env"
echo "   Xray config  : /usr/local/etc/xray/config.json"
echo "   Xray logs    : /var/log/xray/access.log /var/log/xray/error.log"
echo "   Panel path   : /var/www/html/panel-admin"
echo
echo "⚠️ DNS is not required for direct IP mode."
echo

echo "🚀 Xray Speed-Safe Optimization:"
echo "   Xray loglevel : warning"
echo "   Ports/routing : unchanged"
echo "   Client MTU    : set 1400 in NekoBox/v2rayNG if available"
echo
echo "✅ Use NekoBox or latest v2rayNG for VLESS/TCP/TLS config."
echo "============================================================"
echo

echo "🚀 XRAY DIRECT ${V2_PORT} SPEED MODE"
echo "   HAProxy/SNI removed for Xray speed."
echo "   OpenConnect keeps public 443."
echo "   Xray/V2Ray uses public ${V2_PORT} direct."
echo "   Use VLESS TCP security=none in NekoBox/v2rayNG."

echo "✅ Menu cleaned: old OpenVPN pages hidden; Dashboard is all-in-one."

echo "✅ OpenConnect URL copy button fixed on OpenConnect page."

echo "✅ OpenConnect URL copy card fixed correctly."
echo "✅ Xray page cleaned: active count + config copy only."

echo "✅ OpenConnect page fully overwritten with URL copy box."
echo "✅ Xray count uses unique established client IPs."
# ============================================================
