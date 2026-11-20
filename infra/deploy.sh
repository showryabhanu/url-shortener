#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${ROOT_DIR}/.env" ]; then
  set -a
  source "${ROOT_DIR}/.env"
  set +a
fi

if [ -f "${ROOT_DIR}/.infra_state" ]; then
  set -a
  source "${ROOT_DIR}/.infra_state"
  set +a
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
TABLE_NAME="${TABLE_NAME:-short_links}"
SHORT_DOMAIN="${SHORT_DOMAIN:-cc7.duckdns.org}"
PORT="${PORT:-3000}"
REDIRECT_STATUS="${REDIRECT_STATUS:-302}"
KEY_PATH="${KEY_PATH:-${HOME}/.ssh/${KEY_NAME:-url-shortener-key}.pem}"

if [ -z "${ELASTIC_IP:-}" ]; then
  echo "Error: ELASTIC_IP is not set. Run launch-ec2.sh first."
  exit 1
fi

echo "=============================================="
echo "Deploying App to EC2 (${ELASTIC_IP})"
echo "Domain: ${SHORT_DOMAIN}"
echo "=============================================="

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i ${KEY_PATH}"

echo "Waiting for EC2 SSH to become ready..."
RETRY=0
MAX_RETRIES=30
while [ $RETRY -lt $MAX_RETRIES ]; do
  if ssh ${SSH_OPTS} ec2-user@"${ELASTIC_IP}" "echo ready" >/dev/null 2>&1; then
    echo "SSH connection established!"
    break
  fi
  echo "Waiting for instance to accept SSH... ($((RETRY + 1))/${MAX_RETRIES})"
  sleep 5
  RETRY=$((RETRY + 1))
done

if [ $RETRY -ge $MAX_RETRIES ]; then
  echo "Error: Timed out waiting for SSH."
  exit 1
fi

echo "Preparing remote server environment..."
ssh ${SSH_OPTS} ec2-user@"${ELASTIC_IP}" << 'EOF'
sudo dnf update -y --releasever=latest
sudo dnf install -y --allowerasing nodejs20 nodejs20-npm tar gzip
sudo alternatives --set node /usr/bin/node-20 2>/dev/null || true

# Install Caddy web server
if ! command -v caddy &> /dev/null; then
  echo "Installing Caddy binary..."
  curl -sSLo /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_amd64.tar.gz" || \
  curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /tmp/caddy_bin
  
  if [ -f /tmp/caddy.tar.gz ]; then
    tar -xzf /tmp/caddy.tar.gz -C /tmp caddy
    sudo mv /tmp/caddy /usr/bin/caddy
    rm -f /tmp/caddy.tar.gz
  elif [ -f /tmp/caddy_bin ]; then
    sudo mv /tmp/caddy_bin /usr/bin/caddy
  fi
  sudo chmod +x /usr/bin/caddy
fi

# Create caddy user and config directories if needed
if ! id -u caddy &>/dev/null; then
  sudo useradd -r -s /sbin/nologin -d /var/lib/caddy caddy || true
fi
sudo mkdir -p /etc/caddy /var/lib/caddy /opt/url-shortener
sudo chown -R ec2-user:ec2-user /opt/url-shortener
EOF

echo "Packaging and uploading application bundle..."
tar -czf /tmp/app-bundle.tar.gz -C "${ROOT_DIR}/app" .
scp ${SSH_OPTS} /tmp/app-bundle.tar.gz ec2-user@"${ELASTIC_IP}":/tmp/app-bundle.tar.gz
rm -f /tmp/app-bundle.tar.gz

echo "Setting up application, systemd service, and Caddyfile on EC2..."
ssh ${SSH_OPTS} ec2-user@"${ELASTIC_IP}" bash -s -- "${SHORT_DOMAIN}" "${TABLE_NAME}" "${AWS_REGION}" "${PORT}" "${REDIRECT_STATUS}" << 'EOF'
SHORT_DOMAIN="$1"
TABLE_NAME="$2"
AWS_REGION="$3"
PORT="$4"
REDIRECT_STATUS="$5"

# Extract app
tar -xzf /tmp/app-bundle.tar.gz -C /opt/url-shortener
rm -f /tmp/app-bundle.tar.gz
cd /opt/url-shortener
npm install --omit=dev

# Write Environment file
cat <<EOT | sudo tee /etc/url-shortener.env >/dev/null
PORT=${PORT}
AWS_REGION=${AWS_REGION}
TABLE_NAME=${TABLE_NAME}
SHORT_DOMAIN=${SHORT_DOMAIN}
REDIRECT_STATUS=${REDIRECT_STATUS}
EOT
sudo chmod 600 /etc/url-shortener.env

# Write systemd service for url-shortener
cat <<EOT | sudo tee /etc/systemd/system/url-shortener.service >/dev/null
[Unit]
Description=Bitly URL Shortener Service
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/url-shortener
EnvironmentFile=/etc/url-shortener.env
ExecStart=/usr/bin/node /opt/url-shortener/server.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOT

# Write Caddyfile
cat <<EOT | sudo tee /etc/caddy/Caddyfile >/dev/null
${SHORT_DOMAIN} {
    reverse_proxy 127.0.0.1:${PORT}
}
EOT

# Write systemd service for Caddy
cat <<EOT | sudo tee /etc/systemd/system/caddy.service >/dev/null
[Unit]
Description=Caddy Reverse Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOT

# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable --now url-shortener
sudo systemctl restart url-shortener

sudo systemctl enable --now caddy
sudo systemctl restart caddy

sleep 3

# Verify services
echo "Service status check:"
systemctl is-active url-shortener
systemctl is-active caddy
EOF

echo "=========================================================================="
echo " Deployment successful!"
echo " Caddy is running and requesting Let's Encrypt TLS for: ${SHORT_DOMAIN}"
echo " Local health endpoint test:"
ssh ${SSH_OPTS} ec2-user@"${ELASTIC_IP}" "curl -s http://127.0.0.1:${PORT}/health"
echo ""
echo "=========================================================================="
