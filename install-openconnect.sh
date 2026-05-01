#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo "Run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
[[ -f /etc/vpn-install.env ]] && source /etc/vpn-install.env
APP_DIR="${APP_DIR:-/var/www/html/panel-admin}"
DATA_DIR="$APP_DIR/data"
BIN_DIR="/usr/local/bin"
OC_PORT="${OC_PORT:-443}"
SERVER_ADDR="${SERVER_ADDR:-$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"
NET_IFACE="${NET_IFACE:-$(ip route get 1.1.1.1 | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
: "${NET_IFACE:=eth0}"
mkdir -p "$DATA_DIR" "$BIN_DIR"
echo "[13/16] Installing OpenConnect..."
apt-get update >/dev/null 2>&1 || true
apt-get install -y ocserv gnutls-bin python3 sudo >/dev/null 2>&1 || true

OC_DIR="/etc/ocserv"
OC_SSL_DIR="$OC_DIR/ssl"
OC_PASSFILE="$OC_DIR/ocpasswd"
OC_USERS_CSV="/var/www/html/panel-admin/data/oc_users.csv"

mkdir -p "$OC_DIR" "$OC_SSL_DIR"
touch "$OC_PASSFILE"
chmod 600 "$OC_PASSFILE"
chown root:root "$OC_PASSFILE"

openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout "$OC_SSL_DIR/server-key.pem" \
  -out "$OC_SSL_DIR/server-cert.pem" \
  -subj "/CN=${SERVER_ADDR}" \
  -addext "subjectAltName=IP:${SERVER_ADDR}" >/dev/null 2>&1 || true
chmod 600 "$OC_SSL_DIR/server-key.pem"
chmod 644 "$OC_SSL_DIR/server-cert.pem"

cat >/etc/ocserv/ocserv.conf <<EOF
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
tcp-port = ${OC_PORT}
udp-port = ${OC_PORT}
run-as-user = nobody
run-as-group = daemon

# FINAL FIX: OpenConnect live control socket for panel
use-occtl = true
socket-file = /run/occtl.socket
isolate-workers = false
duplicate-users = true

server-cert = ${OC_SSL_DIR}/server-cert.pem
server-key = ${OC_SSL_DIR}/server-key.pem
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
dtls-legacy = true
EOF

# ensure firewall/NAT rules for OpenConnect
iptables -t nat -C POSTROUTING -s 10.20.30.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.20.30.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -C FORWARD -s 10.20.30.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.20.30.0/24 -j ACCEPT
iptables -C FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -C INPUT -p tcp --dport ${OC_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${OC_PORT} -j ACCEPT
iptables -C INPUT -p udp --dport ${OC_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport ${OC_PORT} -j ACCEPT

# separate OpenConnect users store (plaintext for panel display, hashed in ocpasswd)
cat >/usr/local/bin/oc-user-manage.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
PASSFILE="/etc/ocserv/ocpasswd"
CSV="/var/www/html/panel-admin/data/oc_users.csv"

mkdir -p /etc/ocserv
touch "$PASSFILE"
touch "$CSV"

cmd="${1:-}"
user="${2:-}"
pass="${3:-}"

init_csv() {
  touch "$CSV"
  chmod 664 "$CSV"
  chown root:www-data "$CSV" 2>/dev/null || true
}
ensure_no_header() {
  init_csv
}
upsert_csv() {
  local u="$1" p="$2" blocked="${3:-0}"
  ensure_no_header
  grep -vE "^${u//\./\\.}\|" "$CSV" > "${CSV}.tmp" 2>/dev/null || true
  printf '%s|%s|%s\n' "$u" "$p" "$blocked" >> "${CSV}.tmp"
  mv "${CSV}.tmp" "$CSV"
  chmod 664 "$CSV"
  chown root:www-data "$CSV" 2>/dev/null || true
}
delete_csv() {
  local u="$1"
  ensure_no_header
  grep -vE "^${u//\./\\.}\|" "$CSV" > "${CSV}.tmp" 2>/dev/null || true
  mv "${CSV}.tmp" "$CSV"
  chmod 664 "$CSV"
  chown root:www-data "$CSV" 2>/dev/null || true
}
get_csv_pass() {
  local u="$1"
  awk -F'|' -v U="$u" '$1==U{print $2; exit}' "$CSV" 2>/dev/null || true
}
kill_user() {
  local u="$1"
  if command -v occtl >/dev/null 2>&1; then
    occtl disconnect user "$u" >/dev/null 2>&1 || true
    occtl disconnect id "$u" >/dev/null 2>&1 || true
  fi
}
case "$cmd" in
  add)
    [[ -n "$user" && -n "$pass" ]] || exit 1
    printf '%s\n%s\n' "$pass" "$pass" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    upsert_csv "$user" "$pass" "0"
    echo "User added: $user"
    ;;
  update)
    [[ -n "$user" && -n "$pass" ]] || exit 1
    printf '%s\n%s\n' "$pass" "$pass" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    upsert_csv "$user" "$pass" "0"
    echo "User updated: $user"
    ;;
  delete)
    [[ -n "$user" ]] || exit 1
    ocpasswd -c "$PASSFILE" -d "$user" >/dev/null 2>&1 || true
    delete_csv "$user"
    kill_user "$user"
    echo "User deleted: $user"
    ;;
  block)
    [[ -n "$user" ]] || exit 1
    p="$(get_csv_pass "$user")"
    [[ -n "$p" ]] || p="blocked"
    upsert_csv "$user" "$p" "1"
    ocpasswd -c "$PASSFILE" -d "$user" >/dev/null 2>&1 || true
    kill_user "$user"
    echo "User blocked: $user"
    ;;
  unblock)
    [[ -n "$user" ]] || exit 1
    p="$(get_csv_pass "$user")"
    [[ -n "$p" ]] || exit 1
    printf '%s\n%s\n' "$p" "$p" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    upsert_csv "$user" "$p" "0"
    echo "User unblocked: $user"
    ;;
  *)
    echo "Usage: $0 {add|update|delete|block|unblock} USER [PASS]"
    exit 1
    ;;
esac
EOF
chmod 755 /usr/local/bin/oc-user-manage.sh
chown root:root /usr/local/bin/oc-user-manage.sh

cat >/usr/local/bin/oc-sessions.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SOCK="/run/occtl.socket"
if command -v occtl >/dev/null 2>&1 && [[ -S "$SOCK" ]]; then
  PAGER=cat occtl -s "$SOCK" show users 2>/dev/null | cat || true
fi
EOF
chmod 755 /usr/local/bin/oc-sessions.sh
chown root:root /usr/local/bin/oc-sessions.sh

cat >/etc/sudoers.d/ovpn-oc-users <<'EOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-user-manage.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-sessions.sh
EOF
chmod 440 /etc/sudoers.d/ovpn-oc-users
visudo -cf /etc/sudoers.d/ovpn-oc-users >/dev/null

# seed default OpenConnect user
/usr/local/bin/oc-user-manage.sh add "${DEFAULT_USER}" "${DEFAULT_USER_PASS}" >/dev/null 2>&1 || true
chown root:www-data "$OC_USERS_CSV" 2>/dev/null || true
chmod 664 "$OC_USERS_CSV" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
cfg = Path('/var/www/html/panel-admin/config.php')
s = cfg.read_text()
anchor = '<a href="change_password.php">Change Admin Password</a>'
if 'openconnect.php' not in s:
    s = s.replace(anchor, '<a href="openconnect.php">OpenConnect</a>\n      '+anchor)
cfg.write_text(s)
PY

cat >"$APP_DIR/openconnect.php" <<'PHP'
<?php
require __DIR__.'/config.php';
require_login();

/* Get Server IP */
$serverIp = trim(shell_exec("curl -4 -fsSL https://api.ipify.org 2>/dev/null"));
if(!$serverIp){
    $serverIp = $_SERVER['SERVER_ADDR'] ?? $_SERVER['HTTP_HOST'] ?? 'SERVER_IP';
}
$serverIp = preg_replace('/:.*/', '', $serverIp);
$ocUrl = "https://".$serverIp.":${OC_PORT}";

function oc_users(){
    $file='/etc/ocserv/ocpasswd';
    $rows=[];
    if(is_file($file)){
        foreach(file($file, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
            if(strpos($line,':')!==false){
                $parts=explode(':',$line);
                $rows[]=['username'=>$parts[0] ?? '', 'password'=>''];
            }
        }
    }
    return $rows;
}

function oc_cmd($cmd){
    $out=[]; $code=0;
    exec($cmd.' 2>&1', $out, $code);
    return [$code, implode("\n",$out)];
}

$msg=''; $err='';

if($_SERVER['REQUEST_METHOD']==='POST'){
    $action=$_POST['action'] ?? '';
    $u=trim($_POST['username'] ?? '');
    $p=$_POST['password'] ?? '';

    if($action==='add' && $u!=='' && $p!==''){
        [$code,$out]=oc_cmd('printf %s '.escapeshellarg($p).' | ocpasswd -c /etc/ocserv/ocpasswd '.escapeshellarg($u));
        $code===0 ? $msg='OpenConnect user added/updated' : $err=$out;
    }
}

if(isset($_GET['delete'])){
    $u=trim($_GET['delete']);
    if($u!==''){
        oc_cmd('ocpasswd -d /etc/ocserv/ocpasswd '.escapeshellarg($u));
    }
    header('Location: openconnect.php');
    exit;
}

$users=oc_users();

$raw = trim(shell_exec('occtl -s /run/occtl.socket show users 2>/dev/null'));
$activeRows=[];
if($raw){
    foreach(explode("\n",$raw) as $line){
        $line=trim($line);
        if($line==='' || stripos($line,'user')!==false || stripos($line,'id')===0) continue;
        $parts=preg_split('/\s+/', $line);
        if(count($parts)>=4){
            $activeRows[]=[
                'user'=>$parts[1] ?? '',
                'ip'=>$parts[3] ?? '',
                'vpn_ip'=>$parts[4] ?? ''
            ];
        }
    }
}

$activeCount=count($activeRows);

$today=trim(shell_exec("journalctl -u ocserv --since today --no-pager 2>/dev/null | grep -E 'connected' | wc -l"));
if($today==='') $today='0';

$logsRaw=shell_exec("journalctl -u ocserv -n 80 --no-pager 2>/dev/null");
$logs=[];
if($logsRaw){
    foreach(explode("\n",$logsRaw) as $line){
        if(stripos($line,'connected')!==false || stripos($line,'disconnected')!==false){
            $logs[]=$line;
        }
    }
}

render_header('OpenConnect');
?>

<style>
.oc-premium-url-card{
  margin-top:18px;
  position:relative;
  overflow:hidden;
  border:1px solid rgba(255,255,255,.14) !important;
  background:
    radial-gradient(circle at top left, rgba(34,197,94,.35), transparent 35%),
    radial-gradient(circle at bottom right, rgba(59,130,246,.30), transparent 35%),
    linear-gradient(135deg,#020617,#0f172a 55%,#111827) !important;
  box-shadow:0 18px 45px rgba(2,6,23,.28);
}

.oc-premium-url-card:before{
  content:"";
  position:absolute;
  inset:0;
  background:linear-gradient(120deg, transparent, rgba(255,255,255,.08), transparent);
  transform:translateX(-100%);
  animation:ocShine 4s infinite;
}

@keyframes ocShine{
  0%{transform:translateX(-100%)}
  55%{transform:translateX(100%)}
  100%{transform:translateX(100%)}
}

.oc-url-content{
  position:relative;
  z-index:2;
}

.oc-url-title{
  margin-bottom:6px;
  color:#ffffff !important;
  font-weight:900;
}

.oc-url-subtitle{
  color:#cbd5e1;
  font-size:13px;
}

.oc-url-row{
  display:flex;
  gap:10px;
  align-items:center;
  margin-top:14px;
}

#ocUrlInput{
  flex:1;
  min-width:0;
  padding:15px 16px;
  border-radius:16px;
  border:1px solid rgba(255,255,255,.18);
  background:rgba(2,6,23,.78);
  color:#ffffff;
  font-size:16px;
  font-weight:900;
  letter-spacing:.3px;
  outline:none;
  box-shadow:inset 0 0 0 1px rgba(255,255,255,.04);
}

.oc-copy-btn{
  width:48px;
  height:48px;
  border:0;
  border-radius:16px;
  cursor:pointer;
  background:linear-gradient(135deg,#22c55e,#16a34a);
  color:white;
  font-size:22px;
  display:flex;
  align-items:center;
  justify-content:center;
  box-shadow:0 12px 28px rgba(34,197,94,.30);
  transition:.2s;
}

.oc-copy-btn:hover{
  transform:translateY(-2px);
  box-shadow:0 16px 34px rgba(34,197,94,.42);
}

.oc-copy-msg{
  display:none;
  margin-top:10px;
  color:#bbf7d0;
  font-size:13px;
  font-weight:800;
}

@media(max-width:600px){
  .oc-url-row{
    gap:8px;
  }

  #ocUrlInput{
    font-size:14px;
    padding:14px;
  }

  .oc-copy-btn{
    width:44px;
    height:44px;
    border-radius:14px;
    font-size:20px;
  }
}
</style>

<div class="grid">
  <div class="card"><div class="muted">OpenConnect max capacity</div><div class="kpi">100000</div></div>
  <div class="card"><div class="muted">Active now</div><div class="kpi"><?=esc($activeCount)?></div></div>
  <div class="card"><div class="muted">Total users</div><div class="kpi"><?=esc(count($users))?></div></div>
  <div class="card"><div class="muted">Today connected</div><div class="kpi"><?=esc($today)?></div></div>
</div>

<div class="card oc-premium-url-card">
  <div class="oc-url-content">
    <div class="toolbar" style="align-items:center">
      <div>
        <h2 class="section-title oc-url-title">OpenConnect URL</h2>
        <div class="oc-url-subtitle">এই URL app-এ add করুন, তারপর username/password দিয়ে connect করুন।</div>
      </div>
      <span class="badge green">443</span>
    </div>

    <div class="oc-url-row">
      <input id="ocUrlInput" value="<?=esc($ocUrl)?>" readonly>
      <button class="oc-copy-btn" type="button" onclick="copyOpenConnectUrl()" title="Copy this URL">📋</button>
    </div>

    <div id="copyMsg" class="oc-copy-msg">✅ URL copied successfully!</div>
  </div>
</div>

<script>
function copyOpenConnectUrl(){
  const el = document.getElementById('ocUrlInput');
  const val = el.value;

  if(navigator.clipboard && window.isSecureContext){
    navigator.clipboard.writeText(val).then(function(){
      showCopyMsg();
    }).catch(function(){
      fallbackCopyUrl(el);
    });
  } else {
    fallbackCopyUrl(el);
  }
}

function fallbackCopyUrl(el){
  el.select();
  el.setSelectionRange(0, 99999);
  document.execCommand('copy');
  showCopyMsg();
}

function showCopyMsg(){
  const msg = document.getElementById('copyMsg');
  msg.style.display = 'block';
  setTimeout(function(){
    msg.style.display = 'none';
  }, 1600);
}
</script>

<?php if($msg): ?><div class="flash" style="margin-top:18px"><?=esc($msg)?></div><?php endif; ?>
<?php if($err): ?><div class="flash error" style="margin-top:18px"><?=esc($err)?></div><?php endif; ?>

<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect users</h2>
  <div class="small">এই page-এর username/password দিয়েই OpenConnect login হবে।</div>

  <form method="post" style="margin-top:14px">
    <input type="hidden" name="action" value="add">
    <label>Username</label>
    <input name="username" placeholder="Username" required>
    <label>Password</label>
    <input name="password" placeholder="Password" required>
    <br><br>
    <button class="btn green" type="submit">Add</button>
  </form>

  <div class="table-wrap" style="margin-top:18px">
    <table style="min-width:650px">
      <tr><th>Username</th><th>Password</th><th>Action</th></tr>
      <?php if(!$users): ?>
        <tr><td colspan="3" class="empty">No OpenConnect users found.</td></tr>
      <?php else: foreach($users as $u): ?>
        <tr>
          <td><strong><?=esc($u['username'])?></strong></td>
          <td>Hidden</td>
          <td><a class="btn red" href="openconnect.php?delete=<?=urlencode($u['username'])?>" onclick="return confirm('Delete this user?')">Delete</a></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>

<div class="card" style="margin-top:18px">
  <div class="toolbar">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">OpenConnect active sessions</h2>
      <div class="small">Connected OpenConnect users are shown here.</div>
    </div>
    <span class="badge green"><?=esc($activeCount)?> active</span>
  </div>

  <div class="table-wrap">
    <table style="min-width:720px">
      <tr><th>User</th><th>IP</th><th>VPN IP</th></tr>
      <?php if(!$activeRows): ?>
        <tr><td colspan="3" class="empty">No active OpenConnect users.</td></tr>
      <?php else: foreach($activeRows as $r): ?>
        <tr>
          <td><?=esc($r['user'])?></td>
          <td><?=esc($r['ip'])?></td>
          <td><?=esc($r['vpn_ip'])?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>

<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect logs</h2>
  <div class="table-wrap">
    <table style="min-width:760px">
      <tr><th>Log</th></tr>
      <?php if(!$logs): ?>
        <tr><td class="empty">No OpenConnect logs found.</td></tr>
      <?php else: foreach(array_slice($logs, -25) as $line): ?>
        <tr><td class="small"><?=esc($line)?></td></tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>

<?php render_footer(); ?>
PHP

echo "[14/16] Enabling OpenConnect..."
systemctl enable ocserv >/dev/null 2>&1 || true
systemctl restart ocserv || true

echo "[15/16] Restarting web panel..."
systemctl restart apache2 || true

echo "[16/16] Finalizing..."

echo
echo "CLI commands:"
echo "  /usr/local/bin/ovpn-user-manage.sh add USER PASS"
echo "  /usr/local/bin/ovpn-user-manage.sh update USER PASS"
echo "  /usr/local/bin/ovpn-user-manage.sh block USER"
echo "  /usr/local/bin/ovpn-user-manage.sh unblock USER"
echo "  /usr/local/bin/ovpn-user-manage.sh delete USER"
echo
echo "OpenConnect separate users:"
echo "  sudo /usr/local/bin/oc-user-manage.sh add USER PASS"
echo "  sudo /usr/local/bin/oc-user-manage.sh update USER PASS"
echo "  sudo /usr/local/bin/oc-user-manage.sh block USER"
echo "  sudo /usr/local/bin/oc-user-manage.sh unblock USER"
echo "  sudo /usr/local/bin/oc-user-manage.sh delete USER"


# ===== OpenConnect active sessions final patch =====
APP_DIR="/var/www/html/panel-admin"
DATA_DIR="$APP_DIR/data"
PHP_PAGE="$APP_DIR/openconnect.php"
OC_SOCKET="/run/ocserv-socket"
OC_HELPER="/usr/local/bin/oc-sessions.sh"
SUDOERS="/etc/sudoers.d/ovpn-occtl"
OC_LOG_DB="$DATA_DIR/oc_events.sqlite"

mkdir -p "$DATA_DIR"

cat >"$OC_HELPER" <<'EOH'
#!/usr/bin/env bash
set -euo pipefail
SOCK="/run/ocserv-socket"

if [[ ! -S "$SOCK" ]]; then
  echo '{"sessions":[],"active":0,"error":"socket not found"}'
  exit 0
fi

if occtl -n --json show users >/tmp/occtl.json 2>/dev/null; then
  cat /tmp/occtl.json
  rm -f /tmp/occtl.json
  exit 0
fi

if occtl -n -s "$SOCK" --json show users >/tmp/occtl.json 2>/dev/null; then
  cat /tmp/occtl.json
  rm -f /tmp/occtl.json
  exit 0
fi

OUT="$(occtl -n show users 2>/dev/null || occtl -n -s "$SOCK" show users 2>/dev/null || true)"
OUT="$OUT" python3 - <<'PY'
import json, os, re
text = os.environ.get("OUT","")
sessions = []
cur = None
for raw in text.splitlines():
    line = raw.strip()
    if not line:
        continue
    m = re.match(r'^id:\s*(.+)$', line, re.I)
    if m:
        if cur:
            sessions.append(cur)
        cur = {"id": m.group(1)}
        continue
    m = re.match(r'^([A-Za-z0-9 _/-]+):\s*(.*)$', line)
    if m and cur is not None:
        key = m.group(1).strip().lower().replace(' ', '_').replace('-', '_').replace('/', '_')
        cur[key] = m.group(2).strip()
if cur:
    sessions.append(cur)
print(json.dumps({"sessions": sessions, "active": len(sessions)}, ensure_ascii=False))
PY
EOH
chmod 755 "$OC_HELPER"
chown root:root "$OC_HELPER"

cat >"$SUDOERS" <<EOF2
www-data ALL=(root) NOPASSWD: $OC_HELPER
EOF2
chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null

sqlite3 "$OC_LOG_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS oc_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_time TEXT DEFAULT CURRENT_TIMESTAMP,
  event_type TEXT,
  username TEXT,
  real_ip TEXT,
  vpn_ip TEXT,
  user_agent TEXT,
  duration INTEGER DEFAULT 0,
  bytes_in INTEGER DEFAULT 0,
  bytes_out INTEGER DEFAULT 0
);
SQL
chown www-data:www-data "$OC_LOG_DB"
chmod 664 "$OC_LOG_DB"

cat >/usr/local/bin/oc-event-log.sh <<'EOE'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/panel-admin/data/oc_events.sqlite"
TYPE="${REASON:-connect}"
USER="${USERNAME:-${USER:-}}"
REAL_IP="${IP_REAL:-}"
VPN_IP="${IP_REMOTE:-}"
AGENT="${USER_AGENT:-${DEVICE_TYPE:-}}"
DUR="${STATS_DURATION:-0}"
BIN="${STATS_BYTES_IN:-0}"
BOUT="${STATS_BYTES_OUT:-0}"

sqlite3 "$DB" <<SQL
INSERT INTO oc_events(event_type,username,real_ip,vpn_ip,user_agent,duration,bytes_in,bytes_out)
VALUES('$TYPE','${USER//\'/''}','${REAL_IP//\'/''}','${VPN_IP//\'/''}','${AGENT//\'/''}',${DUR:-0},${BIN:-0},${BOUT:-0});
SQL
EOE
chmod 755 /usr/local/bin/oc-event-log.sh
chown root:root /usr/local/bin/oc-event-log.sh

if [[ -f /etc/ocserv/ocserv.conf ]]; then
  grep -q '^socket-file' /etc/ocserv/ocserv.conf || echo "socket-file = /run/ocserv-socket" >> /etc/ocserv/ocserv.conf
  grep -q '^connect-script' /etc/ocserv/ocserv.conf || echo "connect-script = /usr/local/bin/oc-event-log.sh" >> /etc/ocserv/ocserv.conf
  grep -q '^disconnect-script' /etc/ocserv/ocserv.conf || echo "disconnect-script = /usr/local/bin/oc-event-log.sh" >> /etc/ocserv/ocserv.conf
fi

cat >"$PHP_PAGE" <<'EOP'
<?php
require __DIR__.'/config.php';
require_login();

function oc_users_csv_path(){ return __DIR__ . '/data/oc_users.csv'; }

function oc_read_users(){
    $f = oc_users_csv_path();
    $rows = [];
    if (!is_file($f) || !is_readable($f)) return $rows;
    $lines = file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach($lines as $line){
        $parts = str_getcsv($line);
        if(count($parts) >= 2){
            $rows[] = ['username'=>$parts[0], 'password'=>$parts[1]];
        }
    }
    return $rows;
}

function oc_sessions_payload(){
    $raw = shell_exec('sudo /usr/local/bin/oc-sessions.sh 2>/dev/null');
    $arr = json_decode((string)$raw, true);
    if (!is_array($arr)) return ['active'=>0,'sessions'=>[],'error'=>'invalid json'];
    if (isset($arr['sessions']) && is_array($arr['sessions'])) return $arr;
    if (array_keys($arr) === range(0, count($arr)-1)) return ['active'=>count($arr),'sessions'=>$arr];
    return ['active'=>0,'sessions'=>[],'error'=>'unexpected payload'];
}

function oc_logs($limit=100){
    $db = new SQLite3(__DIR__.'/data/oc_events.sqlite');
    $db->busyTimeout(3000);
    $res = $db->query('SELECT * FROM oc_events ORDER BY id DESC LIMIT '.(int)$limit);
    $rows = [];
    while($row = $res->fetchArray(SQLITE3_ASSOC)) $rows[] = $row;
    return $rows;
}

$msg=''; $err='';

if ($_SERVER['REQUEST_METHOD']==='POST' && isset($_POST['add_user'])) {
    $u = trim($_POST['username'] ?? '');
    $p = trim($_POST['password'] ?? '');
    if ($u === '' || $p === '') {
        $err = 'Username and password required';
    } else {
        $cmd = 'sudo /usr/local/bin/oc-user-manage.sh add '.escapeshellarg($u).' '.escapeshellarg($p).' 2>&1';
        exec($cmd, $out, $code);
        if ($code === 0) {
            $msg = 'User added';
        } else {
            $err = trim(implode("\n",$out)) ?: 'Failed';
        }
    }
}

if (isset($_GET['delete']) && $_GET['delete'] !== '') {
    $u = trim($_GET['delete']);
    exec('sudo /usr/local/bin/oc-user-manage.sh delete '.escapeshellarg($u).' 2>&1', $out, $code);
    header('Location: openconnect.php');
    exit;
}

$users = oc_read_users();
$payload = oc_sessions_payload();
$sessions = $payload['sessions'] ?? [];
$active = (int)($payload['active'] ?? count($sessions));
$logs = oc_logs(50);

render_header('OpenConnect');
?>
<div class="grid">
  <div class="card"><div class="muted">OpenConnect max capacity</div><div class="kpi">100000</div></div>
  <div class="card"><div class="muted">OpenConnect active now</div><div class="kpi"><?=esc($active)?></div></div>
  <div class="card"><div class="muted">OpenConnect total users</div><div class="kpi"><?=esc(count($users))?></div></div>
</div>

<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect users</h2>
  <div class="small">এই page-এর username/password দিয়েই OpenConnect login হবে।</div>
  <br>
  <?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?>
  <?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>

  <form method="post" class="actions" style="margin-bottom:14px">
    <input name="username" placeholder="Username" required>
    <input name="password" placeholder="Password" required>
    <button class="btn" name="add_user" value="1" type="submit">Add</button>
  </form>

  <div class="table-wrap">
    <table style="min-width:700px">
      <tr><th>Username</th><th>Password</th><th>Action</th></tr>
      <?php if(!$users): ?>
        <tr><td colspan="3" class="empty">No OpenConnect users yet.</td></tr>
      <?php else: foreach($users as $u): ?>
        <tr>
          <td><strong><?=esc($u['username'])?></strong></td>
          <td><?=esc($u['password'])?></td>
          <td><a class="btn red" href="?delete=<?=urlencode($u['username'])?>" onclick="return confirm('Delete this user?')">Delete</a></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>

<div class="card" style="margin-top:18px">
  <div class="toolbar">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">OpenConnect active sessions</h2>
      <div class="small">Connected OpenConnect users are shown here.</div>
    </div>
    <span class="badge green"><?=esc($active)?> active</span>
  </div>
  <div class="table-wrap">
    <table style="min-width:900px">
      <tr><th>User</th><th>IP</th><th>VPN IP</th><th>Connected</th><th>Agent</th></tr>
      <?php if(!$sessions): ?>
        <tr><td colspan="5" class="empty">No active OpenConnect sessions.</td></tr>
      <?php else: foreach($sessions as $s):
        $user = $s['username'] ?? $s['user'] ?? $s['name'] ?? '-';
        $ip = $s['ip'] ?? $s['remote_ip'] ?? $s['ip_real'] ?? '-';
        $vpn = $s['device_ip'] ?? $s['vpn_ip'] ?? $s['ip_remote'] ?? '-';
        $conn = $s['conn_time'] ?? $s['connected_at'] ?? $s['since'] ?? '-';
        $agent = $s['user_agent'] ?? $s['device'] ?? $s['agent'] ?? '-';
      ?>
        <tr>
          <td><?=esc($user)?></td>
          <td><?=esc($ip)?></td>
          <td><?=esc($vpn)?></td>
          <td><?=esc($conn)?></td>
          <td class="small"><?=esc($agent)?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
  <div class="small" style="margin-top:12px">OpenConnect URL: https://<?=esc($_SERVER['SERVER_ADDR'] ?: $_SERVER['SERVER_NAME'])?>:${OC_PORT}</div>
</div>

<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect logs</h2>
  <div class="table-wrap">
    <table style="min-width:900px">
      <tr><th>Time</th><th>Event</th><th>User</th><th>IP</th><th>VPN IP</th><th>Agent</th></tr>
      <?php if(!$logs): ?>
        <tr><td colspan="6" class="empty">No OpenConnect logs yet.</td></tr>
      <?php else: foreach($logs as $r): ?>
        <tr>
          <td><?=esc($r['event_time'])?></td>
          <td><?=esc($r['event_type'])?></td>
          <td><?=esc($r['username'])?></td>
          <td><?=esc($r['real_ip'])?></td>
          <td><?=esc($r['vpn_ip'])?></td>
          <td class="small"><?=esc($r['user_agent'])?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>
<?php render_footer(); ?>
EOP

systemctl restart ocserv || true
systemctl restart apache2 || true

echo "Patched OpenConnect sessions page."
echo "Now refresh: http://YOUR-IP/vpn-panel/openconnect.php"

# ===== v7 integrated patch =====
APP_DIR="/var/www/html/panel-admin"
DATA_DIR="$APP_DIR/data"
mkdir -p "$DATA_DIR"

apt-get update -y >/dev/null 2>&1 || true
apt-get install -y sqlite3 python3 sudo >/dev/null 2>&1 || true

echo "[2/6] Fixing OpenConnect separate users storage..."
touch "$DATA_DIR/oc_users.csv"
chmod 664 "$DATA_DIR/oc_users.csv"
chown root:www-data "$DATA_DIR/oc_users.csv" || true
if ! grep -q '^Easin,' "$DATA_DIR/oc_users.csv" 2>/dev/null; then
  printf 'Easin,Easin112233@\n' >> "$DATA_DIR/oc_users.csv"
fi

cat >/usr/local/bin/oc-user-manage.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PASSFILE="/etc/ocserv/ocpasswd"
CSV="/var/www/html/panel-admin/data/oc_users.csv"
mkdir -p "$(dirname "$CSV")"
touch "$CSV"
chmod 664 "$CSV"
chown root:www-data "$CSV" 2>/dev/null || true
cmd="${1:-}"
user="${2:-}"
pass="${3:-}"
case "$cmd" in
  add)
    [[ -n "$user" && -n "$pass" ]] || exit 1
    printf '%s\n%s\n' "$pass" "$pass" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    grep -v "^${user}," "$CSV" > "${CSV}.tmp" 2>/dev/null || true
    mv "${CSV}.tmp" "$CSV" 2>/dev/null || true
    printf '%s,%s\n' "$user" "$pass" >> "$CSV"
    ;;
  update)
    [[ -n "$user" && -n "$pass" ]] || exit 1
    printf '%s\n%s\n' "$pass" "$pass" | ocpasswd -c "$PASSFILE" "$user" >/dev/null
    grep -v "^${user}," "$CSV" > "${CSV}.tmp" 2>/dev/null || true
    mv "${CSV}.tmp" "$CSV" 2>/dev/null || true
    printf '%s,%s\n' "$user" "$pass" >> "$CSV"
    ;;
  delete)
    [[ -n "$user" ]] || exit 1
    ocpasswd -c "$PASSFILE" -d "$user" >/dev/null || true
    grep -v "^${user}," "$CSV" > "${CSV}.tmp" 2>/dev/null || true
    mv "${CSV}.tmp" "$CSV" 2>/dev/null || true
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod 755 /usr/local/bin/oc-user-manage.sh
chown root:root /usr/local/bin/oc-user-manage.sh

cat >/etc/sudoers.d/ovpn-oc-users <<'SH'
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-user-manage.sh
SH
chmod 440 /etc/sudoers.d/ovpn-oc-users
visudo -cf /etc/sudoers.d/ovpn-oc-users >/dev/null

echo "[3/6] Preparing OpenConnect event database..."
sqlite3 "$DATA_DIR/oc_events.sqlite" <<'SQL'
CREATE TABLE IF NOT EXISTS oc_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_time TEXT DEFAULT CURRENT_TIMESTAMP,
  event_type TEXT,
  username TEXT,
  real_ip TEXT,
  vpn_ip TEXT,
  user_agent TEXT,
  duration INTEGER DEFAULT 0,
  bytes_in INTEGER DEFAULT 0,
  bytes_out INTEGER DEFAULT 0
);
SQL
chown www-data:www-data "$DATA_DIR/oc_events.sqlite" || true
chmod 664 "$DATA_DIR/oc_events.sqlite" || true

cat >/usr/local/bin/oc-event-log.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/panel-admin/data/oc_events.sqlite"
TYPE="${REASON:-connect}"
USER="${USERNAME:-${USER:-}}"
REAL_IP="${IP_REAL:-}"
VPN_IP="${IP_REMOTE:-}"
AGENT="${DEVICE:-${USER_AGENT:-}}"
DUR="${STATS_DURATION:-0}"
BIN="${STATS_BYTES_IN:-0}"
BOUT="${STATS_BYTES_OUT:-0}"
sqlite3 "$DB" <<SQL
INSERT INTO oc_events(event_type,username,real_ip,vpn_ip,user_agent,duration,bytes_in,bytes_out)
VALUES('$TYPE','${USER//\'/''}','${REAL_IP//\'/''}','${VPN_IP//\'/''}','${AGENT//\'/''}',${DUR:-0},${BIN:-0},${BOUT:-0});
SQL
SH
chmod 755 /usr/local/bin/oc-event-log.sh
chown root:root /usr/local/bin/oc-event-log.sh

if [[ -f /etc/ocserv/ocserv.conf ]]; then
  grep -q '^connect-script = /usr/local/bin/oc-event-log.sh' /etc/ocserv/ocserv.conf || echo 'connect-script = /usr/local/bin/oc-event-log.sh' >> /etc/ocserv/ocserv.conf
  grep -q '^disconnect-script = /usr/local/bin/oc-event-log.sh' /etc/ocserv/ocserv.conf || echo 'disconnect-script = /usr/local/bin/oc-event-log.sh' >> /etc/ocserv/ocserv.conf
fi

echo "[4/6] Rebuilding OpenConnect page with verified counters..."
cat > "$APP_DIR/openconnect.php" <<'PHP'
<?php
require __DIR__.'/config.php';
require_login();

function oc_users_csv_path(){ return __DIR__ . '/data/oc_users.csv'; }
function oc_read_users(){
    $f = oc_users_csv_path();
    $rows = [];
    if (!is_file($f) || !is_readable($f)) return $rows;
    $lines = file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach($lines as $line){
        $parts = str_getcsv($line);
        if(count($parts) >= 2){
            $rows[] = ['username'=>$parts[0], 'password'=>$parts[1]];
        }
    }
    return $rows;
}
function oc_logs($limit=100){
    $db = new SQLite3(__DIR__.'/data/oc_events.sqlite');
    $db->busyTimeout(3000);
    $res = $db->query('SELECT * FROM oc_events ORDER BY id DESC LIMIT '.(int)$limit);
    $rows = [];
    while($row = $res->fetchArray(SQLITE3_ASSOC)) $rows[] = $row;
    return $rows;
}
function oc_active_sessions(){
    $db = new SQLite3(__DIR__.'/data/oc_events.sqlite');
    $db->busyTimeout(3000);
    $sql = "SELECT e1.* FROM oc_events e1 INNER JOIN (SELECT username, MAX(id) AS max_id FROM oc_events WHERE COALESCE(username,'')<>'' GROUP BY username) latest ON latest.max_id=e1.id WHERE e1.event_type='connect' ORDER BY e1.id DESC";
    $res = $db->query($sql);
    $rows = [];
    while($row = $res->fetchArray(SQLITE3_ASSOC)) $rows[] = $row;
    return $rows;
}
$msg=''; $err='';
if ($_SERVER['REQUEST_METHOD']==='POST' && isset($_POST['add_user'])) {
    $u = trim($_POST['username'] ?? '');
    $p = trim($_POST['password'] ?? '');
    if ($u === '' || $p === '') {
        $err = 'Username and password required';
    } else {
        exec('sudo /usr/local/bin/oc-user-manage.sh add '.escapeshellarg($u).' '.escapeshellarg($p).' 2>&1', $out, $code);
        if ($code === 0) $msg = 'User added';
        else $err = trim(implode("\n", $out)) ?: 'Failed';
    }
}
if (isset($_GET['delete']) && $_GET['delete'] !== '') {
    $u = trim($_GET['delete']);
    exec('sudo /usr/local/bin/oc-user-manage.sh delete '.escapeshellarg($u).' 2>&1', $out, $code);
    header('Location: openconnect.php');
    exit;
}
$users = oc_read_users();
$logs = oc_logs(50);
$sessions = oc_active_sessions();
$active = count($sessions);
$todayConnects = 0;
foreach($logs as $r){ if(($r['event_type'] ?? '') === 'connect' && substr($r['event_time'],0,10) === gmdate('Y-m-d')) $todayConnects++; }
render_header('OpenConnect');
?>
<div class="grid">
  <div class="card"><div class="muted">OpenConnect max capacity</div><div class="kpi">100000</div></div>
  <div class="card"><div class="muted">OpenConnect active now</div><div class="kpi"><?=esc($active)?></div></div>
  <div class="card"><div class="muted">OpenConnect total users</div><div class="kpi"><?=esc(count($users))?></div></div>
  <div class="card"><div class="muted">Today connected</div><div class="kpi"><?=esc($todayConnects)?></div></div>
</div>

<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect users</h2>
  <div class="small">এই page-এর username/password দিয়েই OpenConnect login হবে।</div>
  <br>
  <?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?>
  <?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
  <form method="post" class="actions" style="margin-bottom:14px">
    <input name="username" placeholder="Username" required>
    <input name="password" placeholder="Password" required>
    <button class="btn" name="add_user" value="1" type="submit">Add</button>
  </form>
  <div class="table-wrap">
    <table style="min-width:700px">
      <tr><th>Username</th><th>Password</th><th>Action</th></tr>
      <?php if(!$users): ?>
        <tr><td colspan="3" class="empty">No OpenConnect users yet.</td></tr>
      <?php else: foreach($users as $u): ?>
        <tr>
          <td><strong><?=esc($u['username'])?></strong></td>
          <td><?=esc($u['password'])?></td>
          <td><a class="btn red" href="?delete=<?=urlencode($u['username'])?>" onclick="return confirm('Delete this user?')">Delete</a></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>

<div class="card" style="margin-top:18px">
  <div class="toolbar">
    <div>
      <h2 class="section-title" style="margin-bottom:6px">OpenConnect active sessions</h2>
      <div class="small">Connected OpenConnect users are shown here.</div>
    </div>
    <span class="badge green"><?=esc($active)?> active</span>
  </div>
  <div class="table-wrap">
    <table style="min-width:900px">
      <tr><th>User</th><th>IP</th><th>VPN IP</th><th>Connected</th></tr>
      <?php if(!$sessions): ?>
        <tr><td colspan="4" class="empty">No active OpenConnect sessions.</td></tr>
      <?php else: foreach($sessions as $s): ?>
        <tr>
          <td><?=esc($s['username'])?></td>
          <td><?=esc($s['real_ip'])?></td>
          <td><?=esc($s['vpn_ip'])?></td>
          <td><?=esc($s['event_time'])?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
  <div class="small" style="margin-top:12px">OpenConnect URL: https://<?=esc($_SERVER['SERVER_ADDR'] ?: $_SERVER['SERVER_NAME'])?>:${OC_PORT}</div>
</div>

<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect logs</h2>
  <div class="table-wrap">
    <table style="min-width:900px">
      <tr><th>Time</th><th>Event</th><th>User</th><th>IP</th><th>VPN IP</th></tr>
      <?php if(!$logs): ?>
        <tr><td colspan="5" class="empty">No OpenConnect logs yet.</td></tr>
      <?php else: foreach($logs as $r): ?>
        <tr>
          <td><?=esc($r['event_time'])?></td>
          <td><?=esc($r['event_type'])?></td>
          <td><?=esc($r['username'])?></td>
          <td><?=esc($r['real_ip'])?></td>
          <td><?=esc($r['vpn_ip'])?></td>
        </tr>
      <?php endforeach; endif; ?>
    </table>
  </div>
</div>
<?php render_footer(); ?>
PHP

echo "[5/6] Restarting services..."
systemctl restart ocserv || true
systemctl restart apache2 || true

echo "[6/6] Done."
echo "OpenConnect page now uses log-based active sessions and counters."
echo "Refresh: http://YOUR-IP/vpn-panel/openconnect.php"



# ---- Final OpenConnect/panel live fixes from original script ----
# FINAL OPENCONNECT FIX OVERRIDE - ChatGPT patched
# Keeps all previous OpenVPN / Xray / Panel code, fixes only OpenConnect.
# ============================================================
echo "[FINAL FIX] Applying OpenConnect live count + multi-device + panel fix..."

APP_DIR="/var/www/html/panel-admin"
DATA_DIR="$APP_DIR/data"
mkdir -p "$DATA_DIR"

if [[ -f /etc/ocserv/ocserv.conf ]]; then
  cp /etc/ocserv/ocserv.conf /etc/ocserv/ocserv.conf.bak.$(date +%s) || true
  sed -i '/^use-occtl[[:space:]]*=.*/d' /etc/ocserv/ocserv.conf
  sed -i '/^socket-file[[:space:]]*=.*/d' /etc/ocserv/ocserv.conf
  sed -i '/^occtl-socket-file[[:space:]]*=.*/d' /etc/ocserv/ocserv.conf
  sed -i '/^isolate-workers[[:space:]]*=.*/d' /etc/ocserv/ocserv.conf
  sed -i '/^duplicate-users[[:space:]]*=.*/d' /etc/ocserv/ocserv.conf
  sed -i '/^connect-script[[:space:]]*=.*/d' /etc/ocserv/ocserv.conf
  sed -i '/^disconnect-script[[:space:]]*=.*/d' /etc/ocserv/ocserv.conf
  cat >> /etc/ocserv/ocserv.conf <<'EOF_OCSERV_FIX'

# Final panel/live-session fix
use-occtl = true
socket-file = /run/occtl.socket
isolate-workers = false
max-same-clients = 0
duplicate-users = true
connect-script = /usr/local/bin/oc-event-log.sh
disconnect-script = /usr/local/bin/oc-event-log.sh
EOF_OCSERV_FIX
fi

sqlite3 "$DATA_DIR/oc_events.sqlite" <<'SQL'
CREATE TABLE IF NOT EXISTS oc_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_time TEXT DEFAULT CURRENT_TIMESTAMP,
  event_type TEXT,
  username TEXT,
  real_ip TEXT,
  vpn_ip TEXT,
  user_agent TEXT,
  duration INTEGER DEFAULT 0,
  bytes_in INTEGER DEFAULT 0,
  bytes_out INTEGER DEFAULT 0
);
SQL
chown www-data:www-data "$DATA_DIR/oc_events.sqlite" 2>/dev/null || true
chmod 664 "$DATA_DIR/oc_events.sqlite" 2>/dev/null || true

cat >/usr/local/bin/oc-event-log.sh <<'EOF_OC_EVENT'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/panel-admin/data/oc_events.sqlite"
TYPE="${REASON:-${script_type:-connect}}"
USER_NAME="${USERNAME:-${USER:-${username:-}}}"
REAL_IP="${IP_REAL:-${REMOTE_HOST:-${trusted_ip:-}}}"
VPN_IP="${IP_REMOTE:-${IP_LOCAL:-${ifconfig_pool_remote_ip:-}}}"
AGENT="${USER_AGENT:-${DEVICE_TYPE:-}}"
DUR="${STATS_DURATION:-${time_duration:-0}}"
BIN="${STATS_BYTES_IN:-${bytes_received:-0}}"
BOUT="${STATS_BYTES_OUT:-${bytes_sent:-0}}"
TYPE_L="$(printf '%s' "$TYPE" | tr '[:upper:]' '[:lower:]')"
case "$TYPE_L" in
  *disconnect*) EVENT_TYPE="disconnect" ;;
  *) EVENT_TYPE="connect" ;;
esac
esc(){ printf "%s" "$1" | sed "s/'/''/g"; }
mkdir -p "$(dirname "$DB")"
sqlite3 "$DB" <<SQL
INSERT INTO oc_events(event_type,username,real_ip,vpn_ip,user_agent,duration,bytes_in,bytes_out)
VALUES('$(esc "$EVENT_TYPE")','$(esc "$USER_NAME")','$(esc "$REAL_IP")','$(esc "$VPN_IP")','$(esc "$AGENT")',${DUR:-0},${BIN:-0},${BOUT:-0});
SQL
EOF_OC_EVENT
chmod 755 /usr/local/bin/oc-event-log.sh
chown root:root /usr/local/bin/oc-event-log.sh

cat >/usr/local/bin/oc-active-sessions.sh <<'EOF_OC_ACTIVE'
#!/usr/bin/env bash
set -euo pipefail
export PAGER=cat
SOCK="/run/occtl.socket"
if [[ -S "$SOCK" ]]; then
  occtl -s "$SOCK" show users 2>/dev/null || true
  exit 0
fi
for s in /run/occtl.socket.* /run/ocserv-socket.* /var/run/occtl.socket.* /var/run/ocserv-socket.*; do
  [[ -S "$s" ]] || continue
  occtl -s "$s" show users 2>/dev/null && exit 0 || true
done
exit 0
EOF_OC_ACTIVE
chmod 755 /usr/local/bin/oc-active-sessions.sh
chown root:root /usr/local/bin/oc-active-sessions.sh

cat >/usr/local/bin/oc-sessions.sh <<'EOF_OC_SESSIONS'
#!/usr/bin/env bash
exec /usr/local/bin/oc-active-sessions.sh
EOF_OC_SESSIONS
chmod 755 /usr/local/bin/oc-sessions.sh
chown root:root /usr/local/bin/oc-sessions.sh

cat >/etc/sudoers.d/ovpn-oc-fixed <<'EOF_SUDO_OC'
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-user-manage.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-active-sessions.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-sessions.sh
EOF_SUDO_OC
chmod 440 /etc/sudoers.d/ovpn-oc-fixed
visudo -cf /etc/sudoers.d/ovpn-oc-fixed >/dev/null

python3 - <<'PY'
from pathlib import Path
cfg = Path('/var/www/html/panel-admin/config.php')
if cfg.exists():
    s = cfg.read_text()
    anchor = '<a href="change_password.php">Change Admin Password</a>'
    link = '<a href="openconnect.php">OpenConnect</a>'
    if link not in s and anchor in s:
        s = s.replace(anchor, link + '\n      ' + anchor)
    cfg.write_text(s)
PY

cat >"$APP_DIR/openconnect.php" <<'PHP_OC_PAGE'
<?php
require __DIR__.'/config.php';
require_login();

function oc_users_path(){ return __DIR__ . '/data/oc_users.csv'; }
function oc_read_users(){
    $f = oc_users_path();
    $rows = [];
    if (!is_file($f) || !is_readable($f)) return $rows;
    foreach(file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line){
        $line = trim($line);
        if($line === '') continue;
        $p = (strpos($line, '|') !== false) ? explode('|', $line) : str_getcsv($line);
        if(count($p) >= 1 && trim($p[0]) !== ''){
            $rows[] = ['username'=>trim($p[0]), 'password'=>$p[1] ?? '', 'blocked'=>(int)($p[2] ?? 0)];
        }
    }
    return $rows;
}
function oc_logs($limit=80){
    $dbFile = __DIR__.'/data/oc_events.sqlite';
    if(!is_file($dbFile)) return [];
    $db = new SQLite3($dbFile); $db->busyTimeout(3000);
    $res = $db->query('SELECT * FROM oc_events ORDER BY id DESC LIMIT '.(int)$limit);
    $rows = [];
    if($res){ while($row = $res->fetchArray(SQLITE3_ASSOC)) $rows[] = $row; }
    return $rows;
}
function oc_active_sessions(){
    $out = shell_exec('sudo /usr/local/bin/oc-active-sessions.sh 2>/dev/null');
    $rows = [];
    if(!$out) return $rows;
    foreach(explode("\n", trim($out)) as $line){
        $line = trim($line);
        if($line === '') continue;
        if(stripos($line, 'id') === 0 || stripos($line, '---') === 0 || $line[0] === '(') continue;
        if(!preg_match('/^\d+\s+/', $line)) continue;
        $p = preg_split('/\s+/', $line);
        $rows[] = [
            'session_id'=>$p[0] ?? '-', 'username'=>$p[1] ?? 'unknown', 'vhost'=>$p[2] ?? '-',
            'real_ip'=>$p[3] ?? '-', 'vpn_ip'=>$p[4] ?? '-', 'device'=>$p[5] ?? '-',
            'connected_since'=>$p[6] ?? 'live', 'dtls'=>$p[7] ?? '-'
        ];
    }
    return $rows;
}

$msg=''; $err='';
if ($_SERVER['REQUEST_METHOD']==='POST' && isset($_POST['add_user'])) {
    $u = trim($_POST['username'] ?? ''); $p = trim($_POST['password'] ?? '');
    if ($u === '' || $p === '') $err = 'Username and password required';
    else { exec('sudo /usr/local/bin/oc-user-manage.sh add '.escapeshellarg($u).' '.escapeshellarg($p).' 2>&1', $out, $code); if ($code === 0) $msg = 'User added'; else $err = trim(implode("\n", $out)) ?: 'Failed'; }
}
if (isset($_GET['delete']) && $_GET['delete'] !== '') { exec('sudo /usr/local/bin/oc-user-manage.sh delete '.escapeshellarg(trim($_GET['delete'])).' 2>&1'); header('Location: openconnect.php'); exit; }
if (isset($_GET['block']) && $_GET['block'] !== '') { exec('sudo /usr/local/bin/oc-user-manage.sh block '.escapeshellarg(trim($_GET['block'])).' 2>&1'); header('Location: openconnect.php'); exit; }
if (isset($_GET['unblock']) && $_GET['unblock'] !== '') { exec('sudo /usr/local/bin/oc-user-manage.sh unblock '.escapeshellarg(trim($_GET['unblock'])).' 2>&1'); header('Location: openconnect.php'); exit; }

$users = oc_read_users(); $logs = oc_logs(80); $sessions = oc_active_sessions(); $active = count($sessions);
$todayConnects = 0; foreach($logs as $r){ if(($r['event_type'] ?? '') === 'connect' && substr((string)($r['event_time'] ?? ''),0,10) === gmdate('Y-m-d')) $todayConnects++; }
$server = $_SERVER['SERVER_ADDR'] ?? $_SERVER['SERVER_NAME'] ?? 'SERVER_IP';
render_header('OpenConnect');
?>
<div class="grid">
  <div class="card"><div class="muted">OpenConnect max capacity</div><div class="kpi">100000</div></div>
  <div class="card"><div class="muted">OpenConnect active now</div><div class="kpi"><?=esc($active)?></div></div>
  <div class="card"><div class="muted">OpenConnect total users</div><div class="kpi"><?=esc(count($users))?></div></div>
  <div class="card"><div class="muted">Today connected</div><div class="kpi"><?=esc($todayConnects)?></div></div>
</div>
<div class="card" style="margin-top:18px"><h2 class="section-title">OpenConnect URL</h2><div class="code">https://<?=esc($server)?>:${OC_PORT}</div></div>
<div class="card" style="margin-top:18px">
  <h2 class="section-title">OpenConnect users</h2><div class="small">এই page-এর username/password দিয়েই OpenConnect login হবে।</div><br>
  <?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
  <form method="post" class="actions" style="margin-bottom:14px"><input name="username" placeholder="Username" required><input name="password" placeholder="Password" required><button class="btn" name="add_user" value="1" type="submit">Add</button></form>
  <div class="table-wrap"><table style="min-width:800px"><tr><th>Username</th><th>Password</th><th>Status</th><th>Action</th></tr>
  <?php if(!$users): ?><tr><td colspan="4" class="empty">No OpenConnect users yet.</td></tr><?php else: foreach($users as $u): ?><tr><td><strong><?=esc($u['username'])?></strong></td><td><?=esc($u['password'])?></td><td><?=((int)$u['blocked']===1) ? '<span class="badge red">Blocked</span>' : '<span class="badge green">Active</span>'?></td><td class="actions"><?php if((int)$u['blocked']===1): ?><a class="btn yellow" href="?unblock=<?=urlencode($u['username'])?>">Unblock</a><?php else: ?><a class="btn red" href="?block=<?=urlencode($u['username'])?>" onclick="return confirm('Block this user?')">Block</a><?php endif; ?><a class="btn red" href="?delete=<?=urlencode($u['username'])?>" onclick="return confirm('Delete this user?')">Delete</a></td></tr><?php endforeach; endif; ?></table></div>
</div>
<div class="card" style="margin-top:18px"><div class="toolbar"><div><h2 class="section-title" style="margin-bottom:6px">OpenConnect active sessions</h2><div class="small">Live occtl socket থেকে active sessions দেখায়। Same user multiple device হলে আলাদা count হবে।</div></div><span class="badge green"><?=esc($active)?> active</span></div>
  <div class="table-wrap"><table style="min-width:1000px"><tr><th>User</th><th>Session ID</th><th>Real IP</th><th>VPN IP</th><th>Device</th><th>Since</th><th>DTLS</th></tr>
  <?php if(!$sessions): ?><tr><td colspan="7" class="empty">No active OpenConnect sessions.</td></tr><?php else: foreach($sessions as $s): ?><tr><td><?=esc($s['username'])?></td><td><?=esc($s['session_id'])?></td><td><?=esc($s['real_ip'])?></td><td><?=esc($s['vpn_ip'])?></td><td><?=esc($s['device'])?></td><td><?=esc($s['connected_since'])?></td><td><?=esc($s['dtls'])?></td></tr><?php endforeach; endif; ?></table></div>
</div>
<div class="card" style="margin-top:18px"><h2 class="section-title">OpenConnect logs</h2><div class="small" style="margin-bottom:12px">History logs. Active count logs থেকে নেওয়া হয় না; live occtl থেকে নেওয়া হয়।</div><div class="table-wrap"><table style="min-width:900px"><tr><th>Time</th><th>Event</th><th>User</th><th>IP</th><th>VPN IP</th></tr><?php if(!$logs): ?><tr><td colspan="5" class="empty">No OpenConnect logs yet.</td></tr><?php else: foreach($logs as $r): ?><tr><td><?=esc($r['event_time'] ?? '')?></td><td><?=esc($r['event_type'] ?? '')?></td><td><?=esc($r['username'] ?? '')?></td><td><?=esc($r['real_ip'] ?? '')?></td><td><?=esc($r['vpn_ip'] ?? '')?></td></tr><?php endforeach; endif; ?></table></div></div>
<?php render_footer(); ?>
PHP_OC_PAGE

chown -R www-data:www-data "$APP_DIR" 2>/dev/null || true
chmod -R 755 "$APP_DIR" 2>/dev/null || true
chmod -R 777 "$DATA_DIR" 2>/dev/null || true
rm -f /run/ocserv-socket* /run/occtl.socket* 2>/dev/null || true
systemctl daemon-reload || true
systemctl enable ocserv >/dev/null 2>&1 || true
systemctl restart ocserv || true
systemctl restart apache2 || true
sleep 2

echo "✅ FINAL OpenConnect fix applied. Test: occtl -s /run/occtl.socket show users"

###############################
# FINAL OPENVPN + OPENCONNECT COUNT FIX PATCH
###############################
echo "[FINAL FIX] Re-applying OpenVPN status permissions + OpenConnect live socket fix..."

# OpenVPN status files must be readable by Apache/PHP for live multi-device count
chmod 644 /var/log/openvpn/openvpn-status-udp.log /var/log/openvpn/openvpn-status-tcp.log 2>/dev/null || true
setfacl -m u:www-data:r /var/log/openvpn/openvpn-status-udp.log /var/log/openvpn/openvpn-status-tcp.log 2>/dev/null || true

# OpenConnect final fixed occtl config
if [ -d /etc/ocserv ]; then
cat >/etc/ocserv/ocserv.conf <<EOF
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
tcp-port = ${OC_PORT}
udp-port = ${OC_PORT}
run-as-user = nobody
run-as-group = daemon
use-occtl = true
socket-file = /run/occtl.socket
isolate-workers = false
duplicate-users = true
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
dtls-legacy = true
EOF
rm -f /run/ocserv-socket* /run/occtl.socket* 2>/dev/null || true
systemctl restart ocserv || true
fi

cat >/usr/local/bin/oc-active-sessions.sh <<'EOF'
#!/usr/bin/env bash
SOCK="/run/occtl.socket"
[ -S "$SOCK" ] || exit 0
occtl -s "$SOCK" show users 2>/dev/null || true
EOF
chmod +x /usr/local/bin/oc-active-sessions.sh
cat >/etc/sudoers.d/ocserv-panel <<EOF
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-active-sessions.sh
EOF
chmod 440 /etc/sudoers.d/ocserv-panel
systemctl restart apache2 || true

echo "✅ FINAL OpenVPN multi-device count + OpenConnect count fix applied."


# =========================================================
# FINAL LIVE PANEL FIXES: OpenVPN/OpenConnect/AJAX
# =========================================================
echo "[FINAL] Applying live panel fixes..."

# OpenVPN status file permissions for Apache panel
chmod 644 /var/log/openvpn/openvpn-status-udp.log /var/log/openvpn/openvpn-status-tcp.log 2>/dev/null || true
setfacl -m u:www-data:r /var/log/openvpn/openvpn-status-udp.log /var/log/openvpn/openvpn-status-tcp.log 2>/dev/null || true

# OpenConnect socket and helper
rm -f /run/ocserv-socket* /run/occtl.socket* 2>/dev/null || true
systemctl restart ocserv || true
sleep 2

cat >/usr/local/bin/oc-active-sessions.sh <<'EOF'
#!/usr/bin/env bash
SOCK="/run/occtl.socket"
[ -S "$SOCK" ] || exit 0
occtl -s "$SOCK" show users 2>/dev/null || true
EOF
chmod +x /usr/local/bin/oc-active-sessions.sh

cat >/etc/sudoers.d/ocserv-panel <<'EOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-active-sessions.sh
EOF
chmod 440 /etc/sudoers.d/ocserv-panel

# Add live AJAX CSS
cat >>/var/www/html/panel-admin/style.css <<'CSS'

.live-flash {
  animation: liveFlash .75s ease;
}
@keyframes liveFlash {
  0% { box-shadow: 0 0 0 0 rgba(34,199,147,.70); transform: scale(1.01); }
  100% { box-shadow: 0 0 0 14px rgba(34,199,147,0); transform: scale(1); }
}
CSS

# Dashboard AJAX auto refresh every 3s
if ! grep -q "VPN_AJAX_REFRESH_FINAL" /var/www/html/panel-admin/index.php 2>/dev/null; then
  sed -i '/<?php render_footer(); ?>/i \
<script id="VPN_AJAX_REFRESH_FINAL">\
let __lastGridText = "";\
async function vpnLiveRefresh(){\
  try{\
    const res = await fetch(window.location.href, {cache:"no-store"});\
    const html = await res.text();\
    const doc = new DOMParser().parseFromString(html, "text/html");\
    const oldGrid = document.querySelector(".grid");\
    const newGrid = doc.querySelector(".grid");\
    if(oldGrid && newGrid){\
      const t = newGrid.innerText.trim();\
      if(__lastGridText && __lastGridText !== t){ oldGrid.classList.add("live-flash"); setTimeout(()=>oldGrid.classList.remove("live-flash"), 800); }\
      __lastGridText = t;\
      oldGrid.innerHTML = newGrid.innerHTML;\
    }\
    const oldTables = document.querySelectorAll(".table-wrap");\
    const newTables = doc.querySelectorAll(".table-wrap");\
    newTables.forEach((el,i)=>{ if(oldTables[i]) oldTables[i].innerHTML = el.innerHTML; });\
    const oldToolbar = document.querySelectorAll(".toolbar");\
    const newToolbar = doc.querySelectorAll(".toolbar");\
    newToolbar.forEach((el,i)=>{ if(oldToolbar[i]) oldToolbar[i].innerHTML = el.innerHTML; });\
  }catch(e){ console.log("VPN live refresh error", e); }\
}\
setInterval(vpnLiveRefresh, 3000);\
vpnLiveRefresh();\
</script>' /var/www/html/panel-admin/index.php
fi

# OpenConnect page AJAX auto refresh every 3s if page exists
if [ -f /var/www/html/panel-admin/openconnect.php ] && ! grep -q "OC_AJAX_REFRESH_FINAL" /var/www/html/panel-admin/openconnect.php 2>/dev/null; then
  sed -i '/<?php render_footer(); ?>/i \
<script id="OC_AJAX_REFRESH_FINAL">\
let __lastOCText = "";\
async function ocLiveRefresh(){\
  try{\
    const res = await fetch(window.location.href, {cache:"no-store"});\
    const html = await res.text();\
    const doc = new DOMParser().parseFromString(html, "text/html");\
    const oldGrid = document.querySelector(".grid");\
    const newGrid = doc.querySelector(".grid");\
    if(oldGrid && newGrid){\
      const t = newGrid.innerText.trim();\
      if(__lastOCText && __lastOCText !== t){ oldGrid.classList.add("live-flash"); setTimeout(()=>oldGrid.classList.remove("live-flash"), 800); }\
      __lastOCText = t;\
      oldGrid.innerHTML = newGrid.innerHTML;\
    }\
    const oldTables = document.querySelectorAll(".table-wrap");\
    const newTables = doc.querySelectorAll(".table-wrap");\
    newTables.forEach((el,i)=>{ if(oldTables[i]) oldTables[i].innerHTML = el.innerHTML; });\
    const oldToolbar = document.querySelectorAll(".toolbar");\
    const newToolbar = doc.querySelectorAll(".toolbar");\
    newToolbar.forEach((el,i)=>{ if(oldToolbar[i]) oldToolbar[i].innerHTML = el.innerHTML; });\
  }catch(e){ console.log("OC live refresh error", e); }\
}\
setInterval(ocLiveRefresh, 3000);\
ocLiveRefresh();\
</script>' /var/www/html/panel-admin/openconnect.php
fi

# Faster stale cleanup behavior: restart OpenVPN if status files become older than 90s.
# This is a safety fallback only; normal live count still comes from status files.
cat >/usr/local/bin/ovpn-status-watchdog.sh <<'EOF'
#!/usr/bin/env bash
now=$(date +%s)
changed=0
for f in /var/log/openvpn/openvpn-status-udp.log /var/log/openvpn/openvpn-status-tcp.log; do
  [ -f "$f" ] || continue
  mt=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
  age=$((now-mt))
  if [ "$age" -gt 90 ]; then
    changed=1
  fi
done
if [ "$changed" = "1" ]; then
  systemctl restart openvpn-server@server-udp 2>/dev/null || true
  systemctl restart openvpn-server@server-tcp 2>/dev/null || true
fi
EOF
chmod +x /usr/local/bin/ovpn-status-watchdog.sh
(crontab -l 2>/dev/null | grep -v 'ovpn-status-watchdog.sh'; echo '* * * * * /usr/local/bin/ovpn-status-watchdog.sh >/dev/null 2>&1') | crontab -

systemctl restart apache2 || true
echo "[FINAL] Live panel fixes applied."

