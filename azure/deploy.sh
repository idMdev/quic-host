#!/bin/bash
# Deployment script for QUIC Host on Azure VM
# This script is copied to the VM and executed locally during deployment

set -e

# Parameters (passed via environment or command line)
ACR_SERVER="${1:-$acrServer}"
IMAGE_NAME="${2:-$imageName}"
CONTAINER_NAME="${3:-$containerName}"
ACR_PASSWORD="${4:-$acrPassword}"

LOGFILE="/var/log/quic-host-deploy.log"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

echo "==========================================="
echo "$TIMESTAMP - Starting deployment"
echo "==========================================="
echo "" | sudo tee -a "$LOGFILE"

log_step() { echo "[$TIMESTAMP] $1" | sudo tee -a "$LOGFILE"; echo "$1"; }
log_error() { echo "[$TIMESTAMP] ERROR: $1" | sudo tee -a "$LOGFILE" >&2; echo "ERROR: $1" >&2; }

log_step "Ensuring Docker service is enabled on boot..."
sudo systemctl enable docker 2>&1 | sudo tee -a "$LOGFILE" || log_error "Failed to enable docker"
sudo systemctl start docker 2>&1 | sudo tee -a "$LOGFILE" || log_error "Failed to start docker"

log_step "Docker service status:"
sudo systemctl status docker --no-pager 2>&1 | sudo tee -a "$LOGFILE" || true

log_step "Logging into Azure Container Registry..."
echo "$ACR_PASSWORD" | docker login "$ACR_SERVER" --username 00000000-0000-0000-0000-000000000000 --password-stdin 2>&1 | sudo tee -a "$LOGFILE" || log_error "Failed to login to ACR"

log_step "Creating systemd service unit file..."
cat <<EOF | sudo tee /etc/systemd/system/quic-host.service > /dev/null
[Unit]
Description=QUIC Host Container Service
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=5
TimeoutStartSec=0
StandardOutput=journal
StandardError=journal
ExecStartPre=-/usr/bin/docker stop quic-host
ExecStartPre=-/usr/bin/docker rm quic-host
ExecStartPre=/usr/bin/docker pull $ACR_SERVER/quic-host:latest
ExecStart=/usr/bin/docker run --name quic-host -p 8443:8443/tcp -p 8443:8443/udp -e PORT=8443 $ACR_SERVER/quic-host:latest
ExecStop=/usr/bin/docker stop quic-host

[Install]
WantedBy=multi-user.target
EOF

log_step "Service file created. Contents:"
cat /etc/systemd/system/quic-host.service 2>&1 | sudo tee -a "$LOGFILE"

log_step "Reloading systemd daemon..."
sudo systemctl daemon-reload 2>&1 | sudo tee -a "$LOGFILE" || log_error "Failed to reload systemd"

log_step "Enabling quic-host service..."
sudo systemctl enable quic-host.service 2>&1 | sudo tee -a "$LOGFILE" || log_error "Failed to enable service"

log_step "Stopping old service if running..."
sudo systemctl stop quic-host.service 2>&1 | sudo tee -a "$LOGFILE" || true

log_step "Starting quic-host service..."
sudo systemctl start quic-host.service 2>&1 | sudo tee -a "$LOGFILE" || log_error "Failed to start service"

log_step "Waiting 15 seconds for service to fully start..."
sleep 15

log_step "Checking service status..."
sudo systemctl status quic-host.service --no-pager 2>&1 | sudo tee -a "$LOGFILE" || log_error "Service status check failed"

log_step "Checking if service is active..."
if sudo systemctl is-active quic-host.service 2>&1 | sudo tee -a "$LOGFILE"; then 
    log_step "Service is ACTIVE"
else 
    log_error "Service is NOT ACTIVE"
fi

log_step "Verifying Docker images..."
docker images | grep quic-host 2>&1 | sudo tee -a "$LOGFILE" || log_error "No quic-host images found"

log_step "Verifying container is running..."
docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 | sudo tee -a "$LOGFILE"

if docker ps --filter "name=$CONTAINER_NAME" --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then 
    log_step "Container IS RUNNING"
else 
    log_error "Container is NOT RUNNING"
fi

log_step "Checking ALL containers (including stopped)..."
docker ps -a --filter "name=$CONTAINER_NAME" 2>&1 | sudo tee -a "$LOGFILE"

log_step "Checking container logs..."
docker logs "$CONTAINER_NAME" --tail 50 2>&1 | sudo tee -a "$LOGFILE" || log_error "Failed to get container logs"

log_step "Checking if ports are listening..."
sudo netstat -tulpn | grep 8443 2>&1 | sudo tee -a "$LOGFILE" || log_error "Port 8443 not found in netstat"

log_step "Checking journalctl logs for service..."
sudo journalctl -u quic-host.service -n 50 --no-pager 2>&1 | sudo tee -a "$LOGFILE" || true

log_step "Setting up port forwarding from 443 to 8443..."
log_step "Installing iptables-persistent for rule persistence..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | sudo tee -a "$LOGFILE" && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent 2>&1 | sudo tee -a "$LOGFILE" || log_step "iptables-persistent already installed or failed to install"

log_step "Configuring iptables rules..."
sudo iptables -t nat -C PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443 2>&1 | sudo tee -a "$LOGFILE" || sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443 2>&1 | sudo tee -a "$LOGFILE"
sudo iptables -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-port 8443 2>&1 | sudo tee -a "$LOGFILE" || sudo iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-port 8443 2>&1 | sudo tee -a "$LOGFILE"

log_step "Saving iptables rules..."
sudo netfilter-persistent save 2>&1 | sudo tee -a "$LOGFILE" || sudo sh -c "mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4" 2>&1 | sudo tee -a "$LOGFILE"

log_step "Port forwarding configured: 443 -> 8443 (TCP and UDP)"

log_step "Verifying iptables rules..."
sudo iptables -t nat -L PREROUTING -n -v | grep -E "(443|8443)" 2>&1 | sudo tee -a "$LOGFILE" || log_step "No matching rules found"

log_step "Deployment complete! Service is managed by systemd and will auto-start on boot."
log_step "Full deployment log saved to: $LOGFILE"
