#!/usr/bin/env bash
set -e

echo "=== FULL VPN INSTALLER (FINAL FIXED VERSION) ==="

apt update
apt install -y openvpn easy-rsa apache2 php sqlite3 curl ocserv sudo

# -------- OPENVPN --------
echo "[OpenVPN Setup]"

mkdir -p /etc/openvpn/server

cat >/etc/openvpn/server/server.conf <<EOF
port 1194
proto udp
dev tun
server 10.8.0.0 255.255.255.0

duplicate-cn

status /var/log/openvpn-status.log
verb 3
EOF

systemctl enable openvpn-server@server || true
systemctl restart openvpn-server@server || true

# -------- OPENCONNECT --------
echo "[OpenConnect Setup FIXED]"

OC_DIR="/etc/ocserv"
OC_SSL_DIR="$OC_DIR/ssl"

mkdir -p "$OC_SSL_DIR"

openssl req -x509 -nodes -newkey rsa:2048 -days 3650   -keyout "$OC_SSL_DIR/server-key.pem"   -out "$OC_SSL_DIR/server-cert.pem"   -subj "/CN=$(hostname -I | awk '{print $1}')" >/dev/null 2>&1

cat >/etc/ocserv/ocserv.conf <<EOF
auth = "plain[passwd=/etc/ocserv/ocpasswd]"

tcp-port = 443
udp-port = 443

run-as-user = nobody
run-as-group = daemon

use-occtl = true
socket-file = /run/occtl.socket
isolate-workers = false
duplicate-users = true

server-cert = $OC_SSL_DIR/server-cert.pem
server-key = $OC_SSL_DIR/server-key.pem

max-clients = 100000
max-same-clients = 0

ipv4-network = 10.20.30.0
ipv4-netmask = 255.255.255.0

dns = 1.1.1.1
dns = 8.8.8.8
EOF

rm -f /run/ocserv-socket* /run/occtl.socket*
systemctl enable ocserv
systemctl restart ocserv

# -------- HELPER --------
cat >/usr/local/bin/oc-active-sessions.sh <<'EOF'
#!/usr/bin/env bash
SOCK="/run/occtl.socket"
[ -S "$SOCK" ] || exit 0
occtl -s "$SOCK" show users 2>/dev/null || true
EOF

chmod +x /usr/local/bin/oc-active-sessions.sh

# -------- PERMISSION --------
cat >/etc/sudoers.d/ocserv-panel <<EOF
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-active-sessions.sh
EOF

chmod 440 /etc/sudoers.d/ocserv-panel

# -------- APACHE --------
systemctl enable apache2
systemctl restart apache2

echo "================================="
echo "INSTALL COMPLETE"
echo "OpenVPN + OpenConnect FULL FIXED"
echo "================================="
