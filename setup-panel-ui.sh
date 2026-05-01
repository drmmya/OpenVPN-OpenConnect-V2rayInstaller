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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apt-get update >/dev/null
apt-get install -y apache2 php libapache2-mod-php php-sqlite3 php-cli sqlite3 curl sudo acl vnstat iproute2 iptables python3 ca-certificates >/dev/null
mkdir -p "$APP_DIR" "$DATA_DIR" "$DOWNLOAD_DIR"

if [[ -d "$SCRIPT_DIR/panel-admin" ]]; then
  cp -a "$SCRIPT_DIR/panel-admin/." "$APP_DIR/"
else
  echo "ERROR: panel-admin source folder missing in $SCRIPT_DIR" >&2
  exit 1
fi

sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS admins(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
SQL
ADMIN_HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$ADMIN_PASS")"
sql_escape(){ printf "%s" "$1" | sed "s/'/''/g"; }
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO admins(username,password_hash) VALUES('$(sql_escape "$ADMIN_USER")','$ADMIN_HASH');"

cat >/etc/apache2/conf-available/vpn-panel.conf <<EOF
Alias /vpn-panel $APP_DIR
<Directory $APP_DIR>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF
a2enconf vpn-panel >/dev/null || true
a2enmod rewrite >/dev/null || true

if [[ -f "$SCRIPT_DIR/vpn-control.sh" ]]; then
  cp "$SCRIPT_DIR/vpn-control.sh" /usr/local/bin/vpn-control.sh
  chmod +x /usr/local/bin/vpn-control.sh
else
  echo "ERROR: vpn-control.sh missing in $SCRIPT_DIR" >&2
  exit 1
fi
bash -n /usr/local/bin/vpn-control.sh

cat >/etc/sudoers.d/vpn-panel-control <<'SUDO'
www-data ALL=(root) NOPASSWD: /usr/local/bin/vpn-control.sh
SUDO
chmod 440 /etc/sudoers.d/vpn-panel-control
visudo -cf /etc/sudoers.d/vpn-panel-control >/dev/null

systemctl enable vnstat apache2 >/dev/null 2>&1 || true
systemctl restart vnstat >/dev/null 2>&1 || true

for log in /var/log/vpn-panel-install-openvpn.log /var/log/vpn-panel-install-openconnect.log /var/log/vpn-panel-install-v2ray.log; do
  touch "$log"
  chown www-data:www-data "$log" 2>/dev/null || true
  chmod 664 "$log" 2>/dev/null || true
done
chown -R root:www-data "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;
chown -R www-data:www-data "$DATA_DIR" "$DOWNLOAD_DIR"
chmod -R 775 "$DATA_DIR" "$DOWNLOAD_DIR"
chmod 664 "$DB_FILE"
systemctl reload apache2 >/dev/null 2>&1 || systemctl restart apache2

echo "[Panel] Done: /vpn-panel"
