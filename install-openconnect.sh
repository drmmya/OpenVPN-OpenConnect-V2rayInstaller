#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "Run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
APP_DIR="${PANEL_DIR:-/var/www/html/panel-admin}"; DATA_DIR="$APP_DIR/data"; BIN_DIR="/usr/local/bin"; OC_PORT="${OC_PORT:-443}"
SERVER_ADDR="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
NET_IFACE="$(ip route get 1.1.1.1 | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"; : "${NET_IFACE:=eth0}"

echo "[OpenConnect] Installing packages..."
apt-get update >/dev/null
apt-get install -y ocserv gnutls-bin apache2 php libapache2-mod-php php-cli sqlite3 curl openssl sudo iptables >/dev/null
mkdir -p /etc/ocserv/ssl "$DATA_DIR" "$BIN_DIR"
touch /etc/ocserv/ocpasswd; chmod 600 /etc/ocserv/ocpasswd; chown root:root /etc/ocserv/ocpasswd

# Avoid common port conflict. If requested port is busy by another service, fallback to 444.
if ss -tulnp 2>/dev/null | grep -qE ":${OC_PORT}[[:space:]]" && ! ss -tulnp 2>/dev/null | grep -E ":${OC_PORT}[[:space:]]" | grep -q ocserv; then
  echo "[OpenConnect] Port ${OC_PORT} is busy. Using 444 instead."
  OC_PORT=444
fi

openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout /etc/ocserv/ssl/server-key.pem -out /etc/ocserv/ssl/server-cert.pem -subj "/CN=${SERVER_ADDR}" -addext "subjectAltName=IP:${SERVER_ADDR}" >/dev/null 2>&1 || true
chmod 600 /etc/ocserv/ssl/server-key.pem; chmod 644 /etc/ocserv/ssl/server-cert.pem

cat >/etc/ocserv/ocserv.conf <<EOF
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
tcp-port = ${OC_PORT}
udp-port = ${OC_PORT}
run-as-user = nobody
run-as-group = daemon
use-occtl = true
socket-file = /run/occtl.socket
server-cert = /etc/ocserv/ssl/server-cert.pem
server-key = /etc/ocserv/ssl/server-key.pem
max-clients = 100000
max-same-clients = 0
default-domain = ${SERVER_ADDR}
ipv4-network = 10.20.30.0
ipv4-netmask = 255.255.255.0
dns = 1.1.1.1
dns = 8.8.8.8
tunnel-all-dns = true
route = default
keepalive = 32400
dpd = 90
mobile-dpd = 1800
switch-to-tcp-timeout = 25
try-mtu-discovery = false
compression = false
server-stats-reset-time = 604800
device = vpns
predictable-ips = true
cisco-client-compat = true
connect-script = /usr/local/bin/oc-event-log.sh
disconnect-script = /usr/local/bin/oc-event-log.sh
EOF

iptables -t nat -C POSTROUTING -s 10.20.30.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.20.30.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -C FORWARD -s 10.20.30.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.20.30.0/24 -j ACCEPT
iptables -C FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -C INPUT -p tcp --dport ${OC_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${OC_PORT} -j ACCEPT
iptables -C INPUT -p udp --dport ${OC_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport ${OC_PORT} -j ACCEPT

cat >"$BIN_DIR/oc-user-manage.sh" <<OCUSER
#!/usr/bin/env bash
set -euo pipefail
PASSFILE="/etc/ocserv/ocpasswd"; CSV="$DATA_DIR/oc_users.csv"; cmd="\${1:-}"; user="\${2:-}"; pass="\${3:-}"
mkdir -p "\$(dirname "\$CSV")"; touch "\$PASSFILE" "\$CSV"
chmod 600 "\$PASSFILE"; chmod 664 "\$CSV"; chown root:www-data "\$CSV" 2>/dev/null || true
upsert(){ local u="\$1" p="\$2" b="\${3:-0}"; grep -vF "\$u|" "\$CSV" > "\$CSV.tmp" 2>/dev/null || true; printf '%s|%s|%s\n' "\$u" "\$p" "\$b" >> "\$CSV.tmp"; mv "\$CSV.tmp" "\$CSV"; chmod 664 "\$CSV"; chown root:www-data "\$CSV" 2>/dev/null || true; }
delcsv(){ local u="\$1"; grep -vF "\$u|" "\$CSV" > "\$CSV.tmp" 2>/dev/null || true; mv "\$CSV.tmp" "\$CSV"; chmod 664 "\$CSV"; chown root:www-data "\$CSV" 2>/dev/null || true; }
getpass(){ awk -F'|' -v U="\$1" '\$1==U{print \$2; exit}' "\$CSV" 2>/dev/null || true; }
killu(){ command -v occtl >/dev/null 2>&1 && occtl -s /run/occtl.socket disconnect user "\$1" >/dev/null 2>&1 || true; }
case "\$cmd" in
 add|update) [[ -n "\$user" && -n "\$pass" ]] || exit 1; printf '%s\n%s\n' "\$pass" "\$pass" | ocpasswd -c "\$PASSFILE" "\$user" >/dev/null; upsert "\$user" "\$pass" 0; echo "User saved: \$user";;
 delete) [[ -n "\$user" ]] || exit 1; ocpasswd -c "\$PASSFILE" -d "\$user" >/dev/null 2>&1 || true; delcsv "\$user"; killu "\$user"; echo "User deleted: \$user";;
 block) [[ -n "\$user" ]] || exit 1; p="\$(getpass "\$user")"; [[ -n "\$p" ]] || p="blocked"; upsert "\$user" "\$p" 1; ocpasswd -c "\$PASSFILE" -d "\$user" >/dev/null 2>&1 || true; killu "\$user"; echo "User blocked: \$user";;
 unblock) [[ -n "\$user" ]] || exit 1; p="\$(getpass "\$user")"; [[ -n "\$p" ]] || { echo "No saved password"; exit 1; }; printf '%s\n%s\n' "\$p" "\$p" | ocpasswd -c "\$PASSFILE" "\$user" >/dev/null; upsert "\$user" "\$p" 0; echo "User unblocked: \$user";;
 *) echo "Usage: \$0 {add|update|delete|block|unblock} user [pass]"; exit 1;; esac
OCUSER
chmod +x "$BIN_DIR/oc-user-manage.sh"

cat >"$BIN_DIR/oc-event-log.sh" <<'OCEVENT'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/panel-admin/data/oc_events.sqlite"
TYPE="${REASON:-${script_type:-connect}}"; USER_NAME="${USERNAME:-${USER:-${username:-}}}"; REAL_IP="${IP_REAL:-${REMOTE_HOST:-${trusted_ip:-}}}"; VPN_IP="${IP_REMOTE:-${IP_LOCAL:-${ifconfig_pool_remote_ip:-}}}"; AGENT="${USER_AGENT:-${DEVICE_TYPE:-}}"; DUR="${STATS_DURATION:-${time_duration:-0}}"; BIN="${STATS_BYTES_IN:-${bytes_received:-0}}"; BOUT="${STATS_BYTES_OUT:-${bytes_sent:-0}}"
case "$(printf '%s' "$TYPE"|tr '[:upper:]' '[:lower:]')" in *disconnect*) EVENT_TYPE="disconnect";; *) EVENT_TYPE="connect";; esac
esc(){ printf "%s" "$1" | sed "s/'/''/g"; }
mkdir -p "$(dirname "$DB")"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS oc_events(id INTEGER PRIMARY KEY AUTOINCREMENT,event_time TEXT DEFAULT CURRENT_TIMESTAMP,event_type TEXT,username TEXT,real_ip TEXT,vpn_ip TEXT,user_agent TEXT,duration INTEGER DEFAULT 0,bytes_in INTEGER DEFAULT 0,bytes_out INTEGER DEFAULT 0); INSERT INTO oc_events(event_type,username,real_ip,vpn_ip,user_agent,duration,bytes_in,bytes_out) VALUES('$(esc "$EVENT_TYPE")','$(esc "$USER_NAME")','$(esc "$REAL_IP")','$(esc "$VPN_IP")','$(esc "$AGENT")',${DUR:-0},${BIN:-0},${BOUT:-0});"
OCEVENT
chmod +x "$BIN_DIR/oc-event-log.sh"

cat >"$BIN_DIR/oc-active-sessions.sh" <<'OCACT'
#!/usr/bin/env bash
set -euo pipefail
SOCK="/run/occtl.socket"
[[ -S "$SOCK" ]] || exit 0
occtl -s "$SOCK" show users 2>/dev/null || true
OCACT
chmod +x "$BIN_DIR/oc-active-sessions.sh"
cat >/etc/sudoers.d/vpn-panel-oc <<EOF
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-user-manage.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-active-sessions.sh
EOF
chmod 440 /etc/sudoers.d/vpn-panel-oc
visudo -cf /etc/sudoers.d/vpn-panel-oc >/dev/null

sqlite3 "$DATA_DIR/oc_events.sqlite" "CREATE TABLE IF NOT EXISTS oc_events(id INTEGER PRIMARY KEY AUTOINCREMENT,event_time TEXT DEFAULT CURRENT_TIMESTAMP,event_type TEXT,username TEXT,real_ip TEXT,vpn_ip TEXT,user_agent TEXT,duration INTEGER DEFAULT 0,bytes_in INTEGER DEFAULT 0,bytes_out INTEGER DEFAULT 0);" || true
chown www-data:www-data "$DATA_DIR/oc_events.sqlite" 2>/dev/null || true; chmod 664 "$DATA_DIR/oc_events.sqlite" 2>/dev/null || true

cat >"$APP_DIR/openconnect.php" <<'PHP'
<?php
require __DIR__.'/config.php'; require_login();
function oc_users(){ $f=DATA_DIR.'/oc_users.csv'; $rows=[]; if(!is_readable($f)) return $rows; foreach(file($f,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){ $p=explode('|',$line); if(trim($p[0]??'')!=='') $rows[]=['username'=>trim($p[0]),'password'=>$p[1]??'','blocked'=>(int)($p[2]??0)]; } return $rows; }
function oc_logs($limit=80){ $f=DATA_DIR.'/oc_events.sqlite'; if(!is_file($f)) return []; $db=new SQLite3($f); $res=$db->query('SELECT * FROM oc_events ORDER BY id DESC LIMIT '.(int)$limit); $rows=[]; while($res && $r=$res->fetchArray(SQLITE3_ASSOC)) $rows[]=$r; return $rows; }
function oc_sessions(){ $out=shell_exec('sudo /usr/local/bin/oc-active-sessions.sh 2>/dev/null'); $rows=[]; if(!$out) return $rows; foreach(explode("\n",trim($out)) as $line){ $line=trim($line); if($line===''||stripos($line,'id')===0||$line[0]=='('||strpos($line,'---')===0) continue; if(!preg_match('/^\d+\s+/',$line)) continue; $p=preg_split('/\s+/',$line); $rows[]=['id'=>$p[0]??'-','user'=>$p[1]??'unknown','real_ip'=>$p[3]??'-','vpn_ip'=>$p[4]??'-','device'=>$p[5]??'-','since'=>$p[6]??'live']; } return $rows; }
$msg='';$err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $u=trim($_POST['username']??''); $p=trim($_POST['password']??''); if($u&&$p){[$code,$out]=cli('sudo /usr/local/bin/oc-user-manage.sh add '.escapeshellarg($u).' '.escapeshellarg($p)); $code===0?$msg=$out:$err=$out;} }
foreach(['delete'=>'delete','block'=>'block','unblock'=>'unblock'] as $q=>$cmd){ if(isset($_GET[$q])){ cli('sudo /usr/local/bin/oc-user-manage.sh '.$cmd.' '.escapeshellarg(trim($_GET[$q]))); header('Location: openconnect.php'); exit; } }
$users=oc_users(); $sessions=oc_sessions(); $logs=oc_logs(); $server=$_SERVER['SERVER_ADDR']??$_SERVER['SERVER_NAME']??'SERVER_IP'; render_header('OpenConnect Panel'); ?>
<div class="grid"><div class="card"><div class="muted">Total users</div><div class="kpi"><?=count($users)?></div></div><div class="card"><div class="muted">Active sessions</div><div class="kpi"><?=count($sessions)?></div></div><div class="card"><div class="muted">Port</div><div class="kpi"><?=esc(cfgv('OC_PORT','443'))?></div></div></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">OpenConnect URL</h2><div class="code">https://<?=esc($server)?>:<?=esc(cfgv('OC_PORT','443'))?></div></div>
<?php if($msg): ?><div class="flash" style="margin-top:18px"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error" style="margin-top:18px"><?=esc($err)?></div><?php endif; ?>
<div class="card" style="margin-top:18px"><h2 class="section-title">OpenConnect users</h2><form method="post" class="actions" style="margin-bottom:14px"><input name="username" placeholder="Username" required><input name="password" placeholder="Password" required><button class="btn green">Add</button></form><div class="table-wrap"><table><tr><th>Username</th><th>Password</th><th>Status</th><th>Action</th></tr><?php if(!$users): ?><tr><td colspan="4" class="empty">No OpenConnect users.</td></tr><?php else: foreach($users as $u): ?><tr><td><strong><?=esc($u['username'])?></strong></td><td><?=esc($u['password'])?></td><td><?=((int)$u['blocked']===1)?'<span class="badge red">Blocked</span>':'<span class="badge green">Active</span>'?></td><td class="actions"><?php if((int)$u['blocked']===1): ?><a class="btn yellow" href="?unblock=<?=urlencode($u['username'])?>">Unblock</a><?php else: ?><a class="btn red" href="?block=<?=urlencode($u['username'])?>">Block</a><?php endif; ?><a class="btn red" href="?delete=<?=urlencode($u['username'])?>" onclick="return confirm('Delete this user?')">Delete</a></td></tr><?php endforeach; endif; ?></table></div></div>
<div class="card" style="margin-top:18px"><div class="toolbar"><h2 class="section-title">OpenConnect active sessions</h2><span class="badge green"><?=count($sessions)?> active</span></div><div class="table-wrap"><table><tr><th>User</th><th>ID</th><th>Real IP</th><th>VPN IP</th><th>Device</th><th>Since</th></tr><?php if(!$sessions): ?><tr><td colspan="6" class="empty">No active OpenConnect sessions.</td></tr><?php else: foreach($sessions as $s): ?><tr><td><?=esc($s['user'])?></td><td><?=esc($s['id'])?></td><td><?=esc($s['real_ip'])?></td><td><?=esc($s['vpn_ip'])?></td><td><?=esc($s['device'])?></td><td><?=esc($s['since'])?></td></tr><?php endforeach; endif; ?></table></div></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">OpenConnect logs</h2><div class="table-wrap"><table><tr><th>Time</th><th>Event</th><th>User</th><th>IP</th><th>VPN IP</th></tr><?php foreach($logs as $r): ?><tr><td><?=esc($r['event_time']??'')?></td><td><?=esc($r['event_type']??'')?></td><td><?=esc($r['username']??'')?></td><td><?=esc($r['real_ip']??'')?></td><td><?=esc($r['vpn_ip']??'')?></td></tr><?php endforeach; ?></table></div></div><?php render_footer(); ?>
PHP

# write corrected effective port back for summary/panel
if [[ -f /etc/vpn-protocols.conf ]]; then sed -i "s/^OC_PORT=.*/OC_PORT=${OC_PORT}/" /etc/vpn-protocols.conf || true; fi
systemctl daemon-reload
systemctl enable ocserv apache2 >/dev/null 2>&1 || true
if ! ocserv -c /etc/ocserv/ocserv.conf -t >/tmp/ocserv-test.log 2>&1; then
  echo "[OpenConnect] Config test warning:"; cat /tmp/ocserv-test.log; echo "[OpenConnect] Removing optional script hooks and retrying..."
  sed -i '/^connect-script/d;/^disconnect-script/d' /etc/ocserv/ocserv.conf
fi
rm -f /run/occtl.socket* /run/ocserv-socket* 2>/dev/null || true
if ! systemctl restart ocserv >/tmp/ocserv-restart.log 2>&1; then
  echo "[OpenConnect] ocserv restart failed. Details:"; cat /tmp/ocserv-restart.log; systemctl status ocserv --no-pager || true; exit 1
fi
systemctl restart apache2
chown -R www-data:www-data "$APP_DIR"; chmod -R 755 "$APP_DIR"; chmod -R 775 "$DATA_DIR"
echo "[OpenConnect] Done on port ${OC_PORT}"
