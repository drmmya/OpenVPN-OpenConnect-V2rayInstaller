#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "Run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive

APP_DIR="${PANEL_DIR:-/var/www/html/panel-admin}"
DATA_DIR="$APP_DIR/data"
DOWNLOAD_DIR="$APP_DIR/downloads"
DB_FILE="$DATA_DIR/vpn.sqlite"
ADMIN_USER="${ADMIN_USER:-openvpn}"
ADMIN_PASS="${ADMIN_PASS:-Easin112233@}"

apt-get update >/dev/null
apt-get install -y apache2 php libapache2-mod-php php-sqlite3 php-cli sqlite3 curl sudo acl vnstat >/dev/null
mkdir -p "$APP_DIR" "$DATA_DIR" "$DOWNLOAD_DIR"
systemctl enable vnstat >/dev/null 2>&1 || true
systemctl restart vnstat >/dev/null 2>&1 || true

sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS admins(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
SQL
ADMIN_HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$ADMIN_PASS")"
sql_escape(){ printf "%s" "$1" | sed "s/'/''/g"; }
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO admins(username,password_hash) VALUES('$(sql_escape "$ADMIN_USER")','$ADMIN_HASH');"

cat >"$APP_DIR/config.php" <<'PHP'
<?php
session_start();
date_default_timezone_set('UTC');
define('APP_DIR', __DIR__);
define('DATA_DIR', __DIR__.'/data');
define('DB_PATH', __DIR__.'/data/vpn.sqlite');
define('DOWNLOAD_DIR', __DIR__.'/downloads');
function db(){ static $db=null; if($db===null){ $db=new SQLite3(DB_PATH); $db->busyTimeout(5000); } return $db; }
function esc($v){ return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function require_login(){ if(empty($_SESSION['admin_user'])){ header('Location: login.php'); exit; } }
function admin_login($u,$p){ $st=db()->prepare('SELECT username,password_hash FROM admins WHERE username=:u LIMIT 1'); $st->bindValue(':u',$u,SQLITE3_TEXT); $r=$st->execute(); $row=$r?$r->fetchArray(SQLITE3_ASSOC):false; return $row && password_verify($p,$row['password_hash']); }
function cli($cmd){ exec($cmd.' 2>&1',$out,$code); return [$code, implode("\n",$out)]; }
function human_bytes($bytes){ $bytes=(float)$bytes; $units=['B','KB','MB','GB','TB']; $i=0; while($bytes>=1024 && $i<count($units)-1){$bytes/=1024;$i++;} return ($i===0?(string)(int)$bytes:number_format($bytes,2)).' '.$units[$i]; }
function bw_total($row){ return (int)($row['rx'] ?? 0) + (int)($row['tx'] ?? 0); }
function vps_bandwidth(){
    $out = shell_exec('vnstat --json 2>/dev/null');
    if(!$out) return ['today'=>0,'month'=>0,'total'=>0,'ready'=>false];
    $data = json_decode($out, true);
    $iface = $data['interfaces'][0] ?? null;
    if(!$iface) return ['today'=>0,'month'=>0,'total'=>0,'ready'=>false];
    $traffic = $iface['traffic'] ?? [];
    $days = $traffic['day'] ?? [];
    $months = $traffic['month'] ?? [];
    $today = $days ? bw_total(end($days)) : 0;
    $month = $months ? bw_total(end($months)) : 0;
    $total = bw_total($traffic['total'] ?? []);
    return ['today'=>$today,'month'=>$month,'total'=>$total,'ready'=>true];
}
function vpn_conf(){ $f='/etc/vpn-protocols.conf'; return is_file($f) ? parse_ini_file($f) : []; }
function proto_enabled($k){ $c=vpn_conf(); return !empty($c[$k]) && (string)$c[$k] !== '0'; }
function cfgv($k,$d=''){ $c=vpn_conf(); return isset($c[$k]) ? $c[$k] : $d; }
function render_header($title='VPN Panel'){
$brand=$title ?: 'VPN Panel';
?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=esc($brand)?></title><link rel="stylesheet" href="style.css"></head>
<body><div class="shell"><header class="site-header"><div class="brand-wrap"><button class="menu-btn" type="button" onclick="document.body.classList.toggle('menu-open')">☰</button><div><div class="brand"><?=esc($brand)?></div><div class="sub">Logged in as <?=esc($_SESSION['admin_user'] ?? '')?></div></div></div><a class="refresh-btn" href="<?=esc(basename($_SERVER['PHP_SELF']).(!empty($_SERVER['QUERY_STRING'])?'?'.$_SERVER['QUERY_STRING']:''))?>">Refresh</a></header><div class="layout"><aside class="sidebar"><nav class="menu">
<a href="index.php">Dashboard</a>
<?php if(proto_enabled('OPENVPN')): ?><a href="openvpn.php">OpenVPN Panel</a><?php endif; ?>
<?php if(proto_enabled('OPENCONNECT')): ?><a href="openconnect.php">OpenConnect Panel</a><?php endif; ?>
<?php if(proto_enabled('V2RAY')): ?><a href="v2ray.php">V2Ray Panel</a><?php endif; ?>
<a href="change_password.php">Change Admin Password</a><a href="logout.php">Logout</a>
</nav></aside><main class="content">
<?php }
function render_footer(){ ?>
</main></div></div><script>document.addEventListener('click',function(e){if(document.body.classList.contains('menu-open')&&!e.target.closest('.sidebar')&&!e.target.closest('.menu-btn'))document.body.classList.remove('menu-open')});</script></body></html>
<?php }
PHP

cat >"$APP_DIR/style.css" <<'CSS'
:root{--bg:#050b18;--bg2:#0b1730;--panel:#0e1b34;--line:#25406d;--text:#f4f8ff;--muted:#9cb2d8;--blue:#4f8cff;--cyan:#20d6ff;--green:#22c793;--purple:#8b5cf6;--red:#ff5f78;--yellow:#ffbf47;--shadow:0 16px 40px rgba(0,0,0,.30)}*{box-sizing:border-box}html,body{margin:0;padding:0}body{font-family:Inter,Segoe UI,Arial,sans-serif;color:var(--text);background:radial-gradient(900px 480px at 18% 0%,rgba(79,140,255,.25),transparent 60%),radial-gradient(850px 430px at 85% 10%,rgba(34,199,147,.16),transparent 58%),linear-gradient(180deg,var(--bg),var(--bg2))}a{text-decoration:none;color:inherit}.shell{min-height:100vh}.site-header{position:sticky;top:0;z-index:60;display:flex;align-items:center;justify-content:space-between;gap:16px;padding:22px 20px;background:rgba(5,11,24,.84);backdrop-filter:blur(16px);border-bottom:1px solid rgba(255,255,255,.07)}.brand-wrap{display:flex;align-items:center;gap:16px}.menu-btn,.refresh-btn{border:1px solid rgba(94,139,255,.35);background:linear-gradient(180deg,#162b57,#0d1a35);color:var(--text);border-radius:14px;padding:10px 14px;cursor:pointer;box-shadow:0 10px 24px rgba(0,0,0,.18)}.brand{font-size:clamp(28px,4vw,42px);font-weight:900;letter-spacing:-.04em}.sub,.muted{color:var(--muted)}.layout{display:flex;gap:20px;max-width:1480px;margin:0 auto;padding:20px}.sidebar{width:260px;flex:0 0 260px;background:linear-gradient(180deg,rgba(18,35,70,.82),rgba(10,22,45,.82));border:1px solid rgba(94,139,255,.28);border-radius:24px;padding:18px;box-shadow:var(--shadow);height:fit-content;position:sticky;top:106px}.menu{display:grid;gap:10px}.menu a{padding:15px 16px;border-radius:16px;background:rgba(255,255,255,.035);border:1px solid rgba(94,139,255,.22)}.menu a:hover{background:linear-gradient(135deg,rgba(79,140,255,.20),rgba(34,199,147,.10));border-color:rgba(96,165,250,.48)}.content{flex:1;min-width:0}.grid,.hero-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}.card{background:linear-gradient(180deg,rgba(17,31,58,.96),rgba(10,22,45,.96));border:1px solid rgba(94,139,255,.25);border-radius:24px;padding:20px;box-shadow:var(--shadow)}.gradient-card{position:relative;overflow:hidden}.gradient-card:before{content:"";position:absolute;inset:-70px auto auto -55px;width:175px;height:175px;border-radius:999px;background:rgba(79,140,255,.28);filter:blur(10px)}.gradient-card:nth-child(2):before{background:rgba(34,199,147,.24)}.gradient-card:nth-child(3):before{background:rgba(139,92,246,.25)}.gradient-card>*{position:relative}.section-title{font-size:19px;font-weight:800;margin:0 0 12px}.kpi{font-size:40px;font-weight:950;margin-top:10px;letter-spacing:-.04em}.kpi.small-kpi{font-size:30px}.status-on{color:#fff;text-shadow:2px 2px 0 rgba(32,214,255,.65),0 0 26px rgba(34,199,147,.35)}.status-off{color:#ffb0bf}.badge{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:7px 11px;font-size:12px;border:1px solid rgba(94,139,255,.3);background:#122342}.badge.green{background:rgba(34,199,147,.14);border-color:rgba(34,199,147,.35);color:#8fe7c7}.badge.red{background:rgba(255,95,120,.12);border-color:rgba(255,95,120,.3);color:#ffb0bf}.badge.yellow{background:rgba(255,191,71,.12);border-color:rgba(255,191,71,.3);color:#ffd78d}.toolbar{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:14px}input,textarea,button{font:inherit}input,textarea{width:100%;padding:13px 14px;color:var(--text);background:#071426;border:1px solid rgba(94,139,255,.28);border-radius:16px}textarea{min-height:180px}.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;border:none;border-radius:14px;padding:11px 16px;cursor:pointer;color:#fff;background:linear-gradient(135deg,var(--blue),var(--purple))}.btn.green{background:linear-gradient(135deg,#19b981,#22c793)}.btn.red{background:linear-gradient(135deg,#ff4d6d,#ff7b92)}.btn.gray{background:#23375e}.btn.yellow{background:var(--yellow);color:#1c2130}.flash{padding:13px 16px;border-radius:16px;margin-bottom:14px;background:#12332a;border:1px solid #1d5d4f}.flash.error{background:#3d1923;border-color:#7f3343}.table-wrap{overflow:auto;border:1px solid rgba(94,139,255,.25);border-radius:18px}table{width:100%;border-collapse:collapse;min-width:900px}th,td{padding:14px 12px;border-bottom:1px solid rgba(255,255,255,.06);text-align:left;vertical-align:top}th{color:#b7c8e6;font-size:13px}td{font-size:14px}.actions{display:flex;gap:8px;flex-wrap:wrap}.small{font-size:12px;color:var(--muted)}.code{white-space:pre-wrap;word-break:break-word;background:#071426;border:1px solid rgba(94,139,255,.26);padding:14px;border-radius:16px;overflow:auto}.empty{padding:30px 14px;color:var(--muted);text-align:center}.bandwidth-card{background:linear-gradient(135deg,rgba(79,140,255,.22),rgba(139,92,246,.16),rgba(34,199,147,.10));border-color:rgba(110,163,255,.45)}.port-list{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px}.port-item{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:17px 18px;border-radius:20px;border:1px solid rgba(86,142,255,.34);background:linear-gradient(135deg,rgba(79,140,255,.17),rgba(34,199,147,.08))}.port-item strong{font-size:15px}.port-value{font-size:24px;font-weight:950;color:#fff;text-shadow:0 0 18px rgba(79,140,255,.35)}@media (max-width:980px){.layout{padding:14px}.sidebar{position:fixed;left:14px;top:92px;bottom:14px;width:min(84vw,320px);transform:translateX(-120%);transition:transform .22s ease;z-index:80;overflow:auto}body.menu-open .sidebar{transform:translateX(0)}.content{width:100%}table{min-width:760px}.brand{font-size:26px}.port-list{grid-template-columns:1fr}}
CSS

cat >"$APP_DIR/login.php" <<'PHP'
<?php require __DIR__.'/config.php'; if(!empty($_SESSION['admin_user'])){ header('Location: index.php'); exit; } $err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ if(admin_login(trim($_POST['username'] ?? ''), $_POST['password'] ?? '')){ $_SESSION['admin_user']=trim($_POST['username']); header('Location: index.php'); exit; } $err='Invalid username or password'; } ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VPN Panel Login</title><link rel="stylesheet" href="style.css"></head><body><div class="layout" style="max-width:680px;min-height:100vh;align-items:center;justify-content:center"><div class="card" style="width:100%"><div class="brand">VPN Panel</div><div class="sub">Login with admin account</div><br><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?><form method="post"><label>Username</label><input name="username" value="openvpn" required><br><br><label>Password</label><input type="password" name="password" required><br><br><button class="btn" type="submit">Login</button></form></div></div></body></html>
PHP

cat >"$APP_DIR/index.php" <<'PHP'
<?php
require __DIR__.'/config.php';
require_login();
$bw = vps_bandwidth();
render_header('VPN Panel');
?>
<div class="hero-grid">
  <div class="card gradient-card"><div class="muted">OpenVPN</div><div class="kpi <?=proto_enabled('OPENVPN')?'status-on':'status-off'?>"><?=proto_enabled('OPENVPN')?'ON':'OFF'?></div></div>
  <div class="card gradient-card"><div class="muted">OpenConnect</div><div class="kpi <?=proto_enabled('OPENCONNECT')?'status-on':'status-off'?>"><?=proto_enabled('OPENCONNECT')?'ON':'OFF'?></div></div>
  <div class="card gradient-card"><div class="muted">V2Ray/Xray</div><div class="kpi <?=proto_enabled('V2RAY')?'status-on':'status-off'?>"><?=proto_enabled('V2RAY')?'ON':'OFF'?></div></div>
</div>

<div class="card bandwidth-card" style="margin-top:18px">
  <div class="toolbar">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">Total VPS Bandwidth</h2>
      <div class="small">System bandwidth from vnStat. New installs may need a few minutes before data appears.</div>
    </div>
    <span class="badge green"><?= $bw['ready'] ? 'Tracking ON' : 'Waiting for data' ?></span>
  </div>
  <div class="grid">
    <div class="card"><div class="muted">Today</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['today']))?></div></div>
    <div class="card"><div class="muted">This Month</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['month']))?></div></div>
    <div class="card"><div class="muted">All Time</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['total']))?></div></div>
  </div>
</div>

<div class="card" style="margin-top:18px">
  <div class="toolbar">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">Installed Ports</h2>
      <div class="small">Each service port is shown separately for cleaner mobile and desktop view.</div>
    </div>
  </div>
  <div class="port-list">
    <?php if(proto_enabled('OPENVPN')): ?>
      <div class="port-item"><strong>OpenVPN UDP</strong><span class="port-value"><?=esc(cfgv('OVPN_UDP_PORT','1194'))?></span></div>
      <div class="port-item"><strong>OpenVPN TCP</strong><span class="port-value"><?=esc(cfgv('OVPN_TCP_PORT','8443'))?></span></div>
    <?php endif; ?>
    <?php if(proto_enabled('OPENCONNECT')): ?>
      <div class="port-item"><strong>OpenConnect</strong><span class="port-value"><?=esc(cfgv('OC_PORT','443'))?></span></div>
    <?php endif; ?>
    <?php if(proto_enabled('V2RAY')): ?>
      <div class="port-item"><strong>V2Ray/Xray</strong><span class="port-value"><?=esc(cfgv('V2_PORT','4443'))?></span></div>
    <?php endif; ?>
  </div>
</div>
<?php render_footer(); ?>
PHP

cat >"$APP_DIR/change_password.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); $msg='';$err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $cur=$_POST['current_password']??''; $new=$_POST['new_password']??''; if(admin_login($_SESSION['admin_user'],$cur) && $new!==''){ $hash=password_hash($new,PASSWORD_DEFAULT); $st=db()->prepare('UPDATE admins SET password_hash=:h WHERE username=:u'); $st->bindValue(':h',$hash,SQLITE3_TEXT); $st->bindValue(':u',$_SESSION['admin_user'],SQLITE3_TEXT); $st->execute(); $msg='Admin password updated'; } else $err='Current password is incorrect'; } render_header('Change Admin Password'); ?>
<div class="card"><h2 class="section-title">Change admin password</h2><?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?><form method="post"><label>Current password</label><input type="password" name="current_password" required><br><br><label>New password</label><input type="password" name="new_password" required><br><br><button class="btn" type="submit">Update password</button></form></div><?php render_footer(); ?>
PHP
cat >"$APP_DIR/logout.php" <<'PHP'
<?php require __DIR__.'/config.php'; session_destroy(); header('Location: login.php');
PHP

cat >/etc/apache2/conf-available/vpn-panel.conf <<EOF
Alias /vpn-panel $APP_DIR
<Directory $APP_DIR>
  Options FollowSymLinks
  AllowOverride All
  Require all granted
</Directory>
EOF
a2enconf vpn-panel >/dev/null || true
a2enmod rewrite >/dev/null || true
chown -R www-data:www-data "$APP_DIR"
chmod -R 755 "$APP_DIR"
chmod -R 775 "$DATA_DIR" "$DOWNLOAD_DIR"
chmod 664 "$DB_FILE"
systemctl enable apache2 >/dev/null
systemctl restart apache2

# =========================
# PRO CONTROL PANEL ADD-ON
# =========================
cat >/usr/local/bin/vpn-control.sh <<'CTRL'
#!/usr/bin/env bash
set -euo pipefail
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main}"
CONF="/etc/vpn-protocols.conf"
PANEL_DIR="/var/www/html/panel-admin"
export PANEL_DIR PANEL_ALIAS="vpn-panel" ADMIN_USER="${ADMIN_USER:-openvpn}" ADMIN_PASS="${ADMIN_PASS:-Easin112233@}" DEFAULT_USER="${DEFAULT_USER:-Easin}" DEFAULT_USER_PASS="${DEFAULT_USER_PASS:-Easin112233@}"

get_conf(){ local k="$1" d="${2:-}"; [[ -f "$CONF" ]] && grep -E "^${k}=" "$CONF" | tail -1 | cut -d= -f2- || printf '%s' "$d"; }
set_conf(){ local k="$1" v="$2"; touch "$CONF"; if grep -qE "^${k}=" "$CONF"; then sed -i "s|^${k}=.*|${k}=${v}|" "$CONF"; else echo "${k}=${v}" >> "$CONF"; fi; chmod 644 "$CONF"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
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
        udp="${3:-1194}"; tcp="${4:-8443}"; ensure_free "$udp" "$(get_conf OVPN_UDP_PORT '')"; ensure_free "$tcp" "$(get_conf OVPN_TCP_PORT '')";
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
        udp="${3:-}"; tcp="${4:-}"; old_udp="$(get_conf OVPN_UDP_PORT 1194)"; old_tcp="$(get_conf OVPN_TCP_PORT 8443)"; ensure_free "$udp" "$old_udp"; ensure_free "$tcp" "$old_tcp";
        [[ -f /etc/openvpn/server/server-udp.conf ]] && sed -i "s/^port .*/port ${udp}/" /etc/openvpn/server/server-udp.conf
        [[ -f /etc/openvpn/server/server-tcp.conf ]] && sed -i "s/^port .*/port ${tcp}/" /etc/openvpn/server/server-tcp.conf
        [[ -f /usr/local/bin/ovpn-make-profile.sh ]] && sed -i -E "s/remote \\${SERVER_ADDR\} [0-9]+ udp/remote \\${SERVER_ADDR} ${udp} udp/; s/remote \\${SERVER_ADDR\} [0-9]+ tcp-client/remote \\${SERVER_ADDR} ${tcp} tcp-client/" /usr/local/bin/ovpn-make-profile.sh || true
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
CTRL
chmod +x /usr/local/bin/vpn-control.sh
cat >/etc/sudoers.d/vpn-panel-control <<'SUDO'
www-data ALL=(root) NOPASSWD: /usr/local/bin/vpn-control.sh
SUDO
chmod 440 /etc/sudoers.d/vpn-panel-control
visudo -cf /etc/sudoers.d/vpn-panel-control >/dev/null

cat >"$APP_DIR/system_control.php" <<'PHP'
<?php
require __DIR__.'/config.php'; require_login();
function run_control($args){ return cli('sudo /usr/local/bin/vpn-control.sh '.$args); }
function svc_on($p){ exec('sudo /usr/local/bin/vpn-control.sh status '.escapeshellarg($p).' >/dev/null 2>&1',$o,$c); return $c===0; }
function installed($key){ return proto_enabled($key); }
$msg=''; $err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
  $action=$_POST['action']??''; $proto=$_POST['proto']??'';
  if(in_array($proto,['openvpn','openconnect','v2ray'],true)){
    if(in_array($action,['start','stop','restart'],true)){ [$c,$o]=run_control($action.' '.escapeshellarg($proto)); $c===0?$msg=$o:$err=$o; }
    if($action==='install'){
      if($proto==='openvpn'){ $udp=(int)($_POST['udp_port']??1194); $tcp=(int)($_POST['tcp_port']??8443); [$c,$o]=run_control('install openvpn '.$udp.' '.$tcp); }
      elseif($proto==='openconnect'){ $port=(int)($_POST['port']??443); [$c,$o]=run_control('install openconnect '.$port); }
      else { $port=(int)($_POST['port']??4443); [$c,$o]=run_control('install v2ray '.$port); }
      $c===0?$msg=$o:$err=$o;
    }
    if($action==='change_port'){
      if($proto==='openvpn'){ $udp=(int)($_POST['udp_port']??cfgv('OVPN_UDP_PORT','1194')); $tcp=(int)($_POST['tcp_port']??cfgv('OVPN_TCP_PORT','8443')); [$c,$o]=run_control('change-port openvpn '.$udp.' '.$tcp); }
      elseif($proto==='openconnect'){ $port=(int)($_POST['port']??cfgv('OC_PORT','443')); [$c,$o]=run_control('change-port openconnect '.$port); }
      else { $port=(int)($_POST['port']??cfgv('V2_PORT','4443')); [$c,$o]=run_control('change-port v2ray '.$port); }
      $c===0?$msg=$o:$err=$o;
    }
  }
}
$items=[
 ['key'=>'OPENVPN','proto'=>'openvpn','name'=>'OpenVPN','ports'=>'UDP '.cfgv('OVPN_UDP_PORT','1194').' / TCP '.cfgv('OVPN_TCP_PORT','8443')],
 ['key'=>'OPENCONNECT','proto'=>'openconnect','name'=>'OpenConnect','ports'=>cfgv('OC_PORT','443')],
 ['key'=>'V2RAY','proto'=>'v2ray','name'=>'V2Ray/Xray','ports'=>cfgv('V2_PORT','4443')],
];
render_header('System Control'); ?>
<?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
<div class="grid">
<?php foreach($items as $it): $is=installed($it['key']); $running=svc_on($it['proto']); ?>
  <div class="card gradient-card">
    <div class="toolbar"><h2 class="section-title"><?=esc($it['name'])?></h2><span class="badge <?=$running?'green':'red'?>"><?=$running?'RUNNING':'STOPPED'?></span></div>
    <div class="small">Installed: <strong><?=$is?'YES':'NO'?></strong></div>
    <div class="small">Port: <strong><?=esc($it['ports'])?></strong></div><br>
    <form method="post" class="actions">
      <input type="hidden" name="proto" value="<?=esc($it['proto'])?>"><button class="btn green" name="action" value="start">Start</button><button class="btn yellow" name="action" value="restart">Restart</button><button class="btn red" name="action" value="stop">Stop</button>
    </form><br>
    <form method="post">
      <input type="hidden" name="proto" value="<?=esc($it['proto'])?>">
      <?php if($it['proto']==='openvpn'): ?>
        <label>UDP Port</label><input name="udp_port" value="<?=esc(cfgv('OVPN_UDP_PORT','1194'))?>"><br><br><label>TCP Port</label><input name="tcp_port" value="<?=esc(cfgv('OVPN_TCP_PORT','8443'))?>">
      <?php else: ?>
        <label>Port</label><input name="port" value="<?=esc($it['proto']==='openconnect'?cfgv('OC_PORT','443'):cfgv('V2_PORT','4443'))?>">
      <?php endif; ?><br><br>
      <?php if(!$is): ?><button class="btn green" name="action" value="install">Install <?=esc($it['name'])?></button><?php else: ?><button class="btn" name="action" value="change_port">Change Port</button><?php endif; ?>
    </form>
  </div>
<?php endforeach; ?>
</div>
<div class="card" style="margin-top:18px"><h2 class="section-title">Port check rule</h2><div class="small">Before install/change-port, system checks if the requested port is already used. If used, action is blocked and you must enter another port.</div></div>
<?php render_footer(); ?>
PHP

# Replace index.php with PRO dashboard including service controls and install shortcuts
cat >"$APP_DIR/index.php" <<'PHP'
<?php
require __DIR__.'/config.php'; require_login();
function svc_on($p){ exec('sudo /usr/local/bin/vpn-control.sh status '.escapeshellarg($p).' >/dev/null 2>&1',$o,$c); return $c===0; }
function run_control($args){ return cli('sudo /usr/local/bin/vpn-control.sh '.$args); }
$msg='';$err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
  $action=$_POST['action']??''; $proto=$_POST['proto']??'';
  if(in_array($action,['start','stop','restart'],true) && in_array($proto,['openvpn','openconnect','v2ray'],true)){ [$c,$o]=run_control($action.' '.escapeshellarg($proto)); $c===0?$msg=$o:$err=$o; }
  if($action==='quick_install' && in_array($proto,['openvpn','openconnect','v2ray'],true)){
    if($proto==='openvpn') [$c,$o]=run_control('install openvpn '.(int)($_POST['udp_port']??1194).' '.(int)($_POST['tcp_port']??8443));
    elseif($proto==='openconnect') [$c,$o]=run_control('install openconnect '.(int)($_POST['port']??443));
    else [$c,$o]=run_control('install v2ray '.(int)($_POST['port']??4443));
    $c===0?$msg=$o:$err=$o;
  }
}
$bw=vps_bandwidth();
$cards=[['OPENVPN','openvpn','OpenVPN'],['OPENCONNECT','openconnect','OpenConnect'],['V2RAY','v2ray','V2Ray/Xray']];
render_header('VPN Panel'); ?>
<?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
<div class="hero-grid">
<?php foreach($cards as $c): $installed=proto_enabled($c[0]); $running=svc_on($c[1]); ?>
  <div class="card gradient-card"><div class="toolbar"><div><div class="muted"><?=esc($c[2])?></div><div class="kpi <?=$installed?'status-on':'status-off'?>"><?=$installed?'ON':'OFF'?></div></div><span class="badge <?=$running?'green':'red'?>"><?=$running?'RUNNING':'STOPPED'?></span></div><form method="post" class="actions"><input type="hidden" name="proto" value="<?=esc($c[1])?>"><button class="btn green" name="action" value="start">Start</button><button class="btn yellow" name="action" value="restart">Restart</button><button class="btn red" name="action" value="stop">Stop</button></form><?php if(!$installed): ?><br><a class="btn" href="system_control.php">Install / Set Port</a><?php endif; ?></div>
<?php endforeach; ?>
</div>
<div class="card bandwidth-card" style="margin-top:18px"><div class="toolbar"><div><h2 class="section-title" style="margin-bottom:6px">Total VPS Bandwidth</h2><div class="small">System bandwidth from vnStat.</div></div><span class="badge green"><?= $bw['ready']?'Tracking ON':'Waiting for data'?></span></div><div class="grid"><div class="card"><div class="muted">Today</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['today']))?></div></div><div class="card"><div class="muted">This Month</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['month']))?></div></div><div class="card"><div class="muted">All Time</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['total']))?></div></div></div></div>
<div class="card" style="margin-top:18px"><div class="toolbar"><div><h2 class="section-title" style="margin-bottom:6px">Installed Ports</h2><div class="small">Vertical cards for clean pro view.</div></div><a class="btn" href="system_control.php">System Control</a></div><div class="port-list"><?php if(proto_enabled('OPENVPN')): ?><div class="port-item"><strong>OpenVPN UDP</strong><span class="port-value"><?=esc(cfgv('OVPN_UDP_PORT','1194'))?></span></div><div class="port-item"><strong>OpenVPN TCP</strong><span class="port-value"><?=esc(cfgv('OVPN_TCP_PORT','8443'))?></span></div><?php else: ?><div class="port-item"><strong>OpenVPN</strong><a class="btn green" href="system_control.php">Install</a></div><?php endif; ?><?php if(proto_enabled('OPENCONNECT')): ?><div class="port-item"><strong>OpenConnect</strong><span class="port-value"><?=esc(cfgv('OC_PORT','443'))?></span></div><?php else: ?><div class="port-item"><strong>OpenConnect</strong><a class="btn green" href="system_control.php">Install</a></div><?php endif; ?><?php if(proto_enabled('V2RAY')): ?><div class="port-item"><strong>V2Ray/Xray</strong><span class="port-value"><?=esc(cfgv('V2_PORT','4443'))?></span></div><?php else: ?><div class="port-item"><strong>V2Ray/Xray</strong><a class="btn green" href="system_control.php">Install</a></div><?php endif; ?></div></div>
<?php render_footer(); ?>
PHP

# Add System Control to menu
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/html/panel-admin/config.php')
s=p.read_text()
if 'system_control.php' not in s:
    s=s.replace('<a href="change_password.php">Change Admin Password</a>', '<a href="system_control.php">System Control</a>\n<a href="change_password.php">Change Admin Password</a>')
    p.write_text(s)
PY
chown -R www-data:www-data "$APP_DIR"
chmod -R 755 "$APP_DIR"
chmod -R 775 "$APP_DIR/data" "$APP_DIR/downloads"
systemctl restart apache2
