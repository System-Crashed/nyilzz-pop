#!/bin/bash

set -e

# Variables
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/opt/pop"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_DIR="$CONFIG_DIR/logs"
USER_NAME="popcache"
SERVICE_NAME="popnode"

# Detect architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
  ARCHIVE_URL="https://download.pipe.network/static/pop-v0.3.0-linux-x64.tar.gz"
elif [[ "$ARCH" == "aarch64" ]]; then
  ARCHIVE_URL="https://download.pipe.network/static/pop-v0.3.0-linux-arm64.tar.gz"
else
  echo "❌ Unsupported architecture: $ARCH"
  exit 1
fi

ARCHIVE_NAME=$(basename "$ARCHIVE_URL")

# Create system user
echo "Creating user $USER_NAME..."
sudo useradd -m -s /bin/bash "$USER_NAME" || true
sudo usermod -aG sudo "$USER_NAME"

# Download and install binary
echo "Downloading binary for $ARCH..."
curl -LO "$ARCHIVE_URL"
sudo tar -xzf "$ARCHIVE_NAME" -C "$INSTALL_DIR"
sudo chmod +x "$INSTALL_DIR/pop"
rm -f "$ARCHIVE_NAME"

# Prompt user for configuration values
echo "🔧 Let's configure your POP Node."

read -p "POP Name: " POP_NAME
read -p "POP Location (City, Country): " POP_LOCATION

read -p "Invite Code: " INVITE_CODE
if [[ -z "$INVITE_CODE" ]]; then
  echo "❌ Invite Code is required. Exiting."
  exit 1
fi

read -p "HTTP Port [default is: 443]: " PORT
HTTP_PORT=${HTTP:-443}

read -p "HTTP Port [default is: 80]: " HTTP_PORT
HTTP_PORT=${HTTP_PORT:-80}

read -p "Used Workers [default is: 40]: " WORKERS
WORKERS=${WORKERS:-40}

read -p "Memory Cache Size (in MB) [default is: 4096]: " MEM_CACHE
MEM_CACHE=${MEM_CACHE:-4096}

read -p "Disk Cache Size (in GB) [default is: 100]: " DISK_CACHE
DISK_CACHE=${DISK_CACHE:-100}

read -p "Your Name: " YOUR_NAME
read -p "Email: " EMAIL
read -p "Website URL: " WEBSITE
read -p "Discord Username: " DISCORD
read -p "Telegram Handle: " TELEGRAM
read -p "Solana Wallet Address: " SOLANA_PUBKEY

# Create config and log directories
echo "Setting up configuration..."
sudo mkdir -p "$CONFIG_DIR/cache" "$LOG_DIR"
sudo chown -R "$USER_NAME:$USER_NAME" "$CONFIG_DIR"

# Build the config file
sudo -u "$USER_NAME" bash -c "cat > $CONFIG_FILE <<EOL
{
  \"pop_name\": \"${POP_NAME:-null}\",
  \"pop_location\": \"${POP_LOCATION:-null}\",
  \"invite_code\": $INVITE_CODE,
  \"server\": {
    \"host\": \"0.0.0.0\",
    \"port\": $PORT,
    \"http_port\": $HTTP_PORT,
    \"workers\": $WORKERS
  },
  \"cache_config\": {
    \"memory_cache_size_mb\": $MEM_CACHE,
    \"disk_cache_path\": \"$CONFIG_DIR/cache\",
    \"disk_cache_size_gb\": $DISK_CACHE,
    \"default_ttl_seconds\": 86400,
    \"respect_origin_headers\": true,
    \"max_cacheable_size_mb\": 1024
  },
  \"api_endpoints\": {
    \"base_url\": \"https://dataplane.pipenetwork.com\"
  },
  \"identity_config\": {
    \"node_name\": \"${POP_NAME:-null}\",
    \"name\": \"${YOUR_NAME:-null}\",
    \"email\": \"${EMAIL:-null}\",
    \"website\": \"${WEBSITE:-null}\",
    \"discord\": \"${DISCORD:-null}\",
    \"telegram\": \"${TELEGRAM:-null}\",
    \"solana_pubkey\": \"${SOLANA_PUBKEY:-null}\"
  }
}
EOL"

# System optimizations
echo "Applying system tunings..."
sudo tee /etc/sysctl.d/99-popcache.conf > /dev/null <<EOF
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.wmem_max = 16777216
net.core.rmem_max = 16777216
EOF
sudo sysctl --system

echo "* soft nofile 65535" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 65535" | sudo tee -a /etc/security/limits.conf

# Create systemd service
echo "Creating systemd service..."
sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null <<EOF
[Unit]
Description=Pipe Network Node
After=network.target

[Service]
User=$USER_NAME
ExecStart=$INSTALL_DIR/pop --config $CONFIG_FILE
Restart=always
RestartSec=5
LimitNOFILE=65535
WorkingDirectory=$CONFIG_DIR
StandardOutput=append:$LOG_DIR/stdout.log
StandardError=append:$LOG_DIR/stderr.log
ENVIRONMENT=POP_INVITE_CODE=$INVITE_CODE

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now $SERVICE_NAME

# Logrotate setup
echo "Creating logrotate configuration..."
sudo tee /etc/logrotate.d/popnode > /dev/null <<EOF
$LOG_DIR/*.log {
  daily
  missingok
  rotate 14
  compress
  delaycompress
  notifempty
  create 640 $USER_NAME $USER_NAME
  sharedscripts
  postrotate
    systemctl restart $SERVICE_NAME > /dev/null
  endscript
}
EOF

echo
echo "✅ Pipe Node service installed and running!"
echo "Use these commands to manage it:"
echo "  • Check status:    sudo systemctl status $SERVICE_NAME"
echo "  • View logs:       journalctl -u $SERVICE_NAME -f"
echo "  • Restart:         sudo systemctl restart $SERVICE_NAME"
