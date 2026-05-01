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
apt-get install -y apache2 php libapache2-mod-php php-sqlite3 php-cli sqlite3 curl sudo acl >/dev/null
mkdir -p "$APP_DIR" "$DATA_DIR" "$DOWNLOAD_DIR"

sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS admins(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
SQL
ADMIN_HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$ADMIN_PASS")"
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO admins(username,password_hash) VALUES('$(printf "%s" "$ADMIN_USER" | sed "s/'/''/g")','$ADMIN_HASH');"

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
:root{--bg:#071120;--bg2:#0b1730;--panel:#0e1b34;--line:#223557;--text:#eef4ff;--muted:#9cb2d8;--blue:#4f8cff;--green:#22c793;--red:#ff5f78;--yellow:#ffbf47;--shadow:0 16px 40px rgba(0,0,0,.28)}*{box-sizing:border-box}html,body{margin:0;padding:0}body{font-family:Inter,Segoe UI,Arial,sans-serif;color:var(--text);background:radial-gradient(1200px 600px at 10% 0%,#0e2450 0%,transparent 60%),linear-gradient(180deg,var(--bg),var(--bg2))}a{text-decoration:none;color:inherit}.shell{min-height:100vh}.site-header{position:sticky;top:0;z-index:60;display:flex;align-items:center;justify-content:space-between;gap:16px;padding:18px 20px;background:rgba(7,17,32,.88);backdrop-filter:blur(14px);border-bottom:1px solid rgba(255,255,255,.06)}.brand-wrap{display:flex;align-items:center;gap:14px}.menu-btn,.refresh-btn{border:1px solid var(--line);background:linear-gradient(180deg,#112246,#0d1a35);color:var(--text);border-radius:14px;padding:10px 14px;cursor:pointer}.brand{font-size:clamp(26px,4vw,40px);font-weight:800;letter-spacing:-.02em}.sub,.muted{color:var(--muted)}.layout{display:flex;gap:20px;max-width:1400px;margin:0 auto;padding:20px}.sidebar{width:260px;flex:0 0 260px;background:rgba(14,27,52,.78);border:1px solid var(--line);border-radius:24px;padding:18px;box-shadow:var(--shadow);height:fit-content;position:sticky;top:96px}.menu{display:grid;gap:10px}.menu a{padding:14px 16px;border-radius:16px;background:rgba(255,255,255,.02);border:1px solid var(--line)}.menu a:hover{background:#132446}.content{flex:1;min-width:0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}.card{background:linear-gradient(180deg,rgba(17,31,58,.96),rgba(14,26,50,.96));border:1px solid var(--line);border-radius:24px;padding:20px;box-shadow:var(--shadow)}.section-title{font-size:18px;font-weight:700;margin:0 0 12px}.kpi{font-size:38px;font-weight:800;margin-top:10px}.badge{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:6px 10px;font-size:12px;border:1px solid var(--line);background:#122342}.badge.green{background:rgba(34,199,147,.12);border-color:rgba(34,199,147,.3);color:#8fe7c7}.badge.red{background:rgba(255,95,120,.12);border-color:rgba(255,95,120,.3);color:#ffb0bf}.badge.yellow{background:rgba(255,191,71,.12);border-color:rgba(255,191,71,.3);color:#ffd78d}.toolbar{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:14px}input,textarea,button{font:inherit}input,textarea{width:100%;padding:13px 14px;color:var(--text);background:#091425;border:1px solid var(--line);border-radius:16px}textarea{min-height:180px}.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;border:none;border-radius:14px;padding:11px 16px;cursor:pointer;color:#fff;background:var(--blue)}.btn.green{background:var(--green)}.btn.red{background:var(--red)}.btn.gray{background:#23375e}.btn.yellow{background:var(--yellow);color:#1c2130}.flash{padding:13px 16px;border-radius:16px;margin-bottom:14px;background:#12332a;border:1px solid #1d5d4f}.flash.error{background:#3d1923;border-color:#7f3343}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:18px}table{width:100%;border-collapse:collapse;min-width:900px}th,td{padding:14px 12px;border-bottom:1px solid rgba(255,255,255,.06);text-align:left;vertical-align:top}th{color:#b7c8e6;font-size:13px}td{font-size:14px}.actions{display:flex;gap:8px;flex-wrap:wrap}.small{font-size:12px;color:var(--muted)}.code{white-space:pre-wrap;word-break:break-word;background:#08111f;border:1px solid var(--line);padding:14px;border-radius:16px;overflow:auto}.empty{padding:30px 14px;color:var(--muted);text-align:center}@media (max-width:980px){.layout{padding:14px}.sidebar{position:fixed;left:14px;top:88px;bottom:14px;width:min(84vw,320px);transform:translateX(-120%);transition:transform .22s ease;z-index:80;overflow:auto}body.menu-open .sidebar{transform:translateX(0)}.content{width:100%}table{min-width:760px}.brand{font-size:24px}}
CSS

cat >"$APP_DIR/login.php" <<'PHP'
<?php require __DIR__.'/config.php'; if(!empty($_SESSION['admin_user'])){ header('Location: index.php'); exit; } $err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ if(admin_login(trim($_POST['username'] ?? ''), $_POST['password'] ?? '')){ $_SESSION['admin_user']=trim($_POST['username']); header('Location: index.php'); exit; } $err='Invalid username or password'; } ?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VPN Panel Login</title><link rel="stylesheet" href="style.css"></head><body><div class="layout" style="max-width:680px;min-height:100vh;align-items:center;justify-content:center"><div class="card" style="width:100%"><div class="brand">VPN Panel</div><div class="sub">Login with admin account</div><br><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?><form method="post"><label>Username</label><input name="username" value="openvpn" required><br><br><label>Password</label><input type="password" name="password" required><br><br><button class="btn" type="submit">Login</button></form></div></div></body></html>
PHP

cat >"$APP_DIR/index.php" <<'PHP'
<?php require __DIR__.'/config.php'; require_login(); render_header('VPN Panel'); $c=vpn_conf(); ?>
<div class="grid">
 <div class="card"><div class="muted">OpenVPN</div><div class="kpi"><?=proto_enabled('OPENVPN')?'ON':'OFF'?></div></div>
 <div class="card"><div class="muted">OpenConnect</div><div class="kpi"><?=proto_enabled('OPENCONNECT')?'ON':'OFF'?></div></div>
 <div class="card"><div class="muted">V2Ray/Xray</div><div class="kpi"><?=proto_enabled('V2RAY')?'ON':'OFF'?></div></div>
</div>
<div class="card" style="margin-top:18px"><h2 class="section-title">Installed ports</h2><div class="code">OpenVPN UDP: <?=esc(cfgv('OVPN_UDP_PORT','1194'))?>
OpenVPN TCP: <?=esc(cfgv('OVPN_TCP_PORT','8443'))?>
OpenConnect: <?=esc(cfgv('OC_PORT','443'))?>
V2Ray/Xray: <?=esc(cfgv('V2_PORT','4443'))?></div></div>
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
