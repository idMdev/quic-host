#!/bin/bash
# Deployment script for QUIC Host on Azure VM
# This script is copied to the VM and executed locally during deployment
# Uses VM managed identity for ACR authentication

set -e

# Parameters (passed via environment or command line)
ACR_SERVER="${1:-$acrServer}"
IMAGE_NAME="${2:-$imageName}"
CONTAINER_NAME="${3:-$containerName}"

LOGFILE="/var/log/quic-host-deploy.log"
DETAILED_LOGFILE="/var/log/quic-host-deploy-detailed.log"

echo "==========================================="
echo "$(date "+%Y-%m-%d %H:%M:%S") - Starting deployment"
echo "==========================================="
echo "" | sudo tee -a "$LOGFILE"
echo "Detailed logs will be saved to: $DETAILED_LOGFILE" | sudo tee -a "$LOGFILE"

log_step() { 
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" | sudo tee -a "$LOGFILE" | sudo tee -a "$DETAILED_LOGFILE"
    echo "$1"
}

log_detail() {
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DETAIL] $1" | sudo tee -a "$DETAILED_LOGFILE"
}

log_error() { 
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] ERROR: $1" | sudo tee -a "$LOGFILE" | sudo tee -a "$DETAILED_LOGFILE" >&2
    echo "ERROR: $1" >&2
}

log_step "=========================================="
log_step "Deployment Configuration"
log_step "=========================================="
log_step "ACR Server: $ACR_SERVER"
log_step "Image Name: $IMAGE_NAME"
log_step "Container Name: $CONTAINER_NAME"
log_step "Log File: $LOGFILE"
log_step "Detailed Log File: $DETAILED_LOGFILE"
log_step "=========================================="

log_step "Ensuring Docker service is enabled on boot..."
if sudo systemctl enable docker 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "Docker service enabled successfully"
else
    log_error "Failed to enable docker service"
fi

if sudo systemctl start docker 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "Docker service started successfully"
else
    log_error "Failed to start docker service"
fi

log_step "Checking Docker service status..."
sudo systemctl status docker --no-pager 2>&1 | sudo tee -a "$DETAILED_LOGFILE" || true
DOCKER_STATUS=$(sudo systemctl is-active docker || echo "inactive")
log_step "Docker service status: $DOCKER_STATUS"

if [ "$DOCKER_STATUS" != "active" ]; then
    log_error "Docker service is not active. Deployment cannot continue."
    exit 1
fi

log_step "Logging into Azure Container Registry using managed identity..."
log_detail "Checking Azure CLI installation..."
if ! command -v az &> /dev/null; then
    log_error "Azure CLI is not installed on this VM. Please run setup.sh to install it."
    exit 1
fi

log_detail "Azure CLI version:"
az version 2>&1 | sudo tee -a "$DETAILED_LOGFILE" || true

log_detail "Attempting to login to ACR using managed identity..."
if az acr login --name "${ACR_SERVER%%.*}" 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_step "Successfully logged into ACR using managed identity"
else
    log_error "Failed to login to ACR using managed identity"
    log_detail "Checking if VM has managed identity assigned..."
    IDENTITY_CHECK=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2021-02-01&resource=https://management.azure.com/" 2>&1 || echo "FAILED")
    if echo "$IDENTITY_CHECK" | grep -q "access_token"; then
        log_detail "VM has managed identity but ACR login failed. Check role assignments."
    else
        log_error "VM does not have managed identity configured. Please run setup.sh to configure it."
    fi
    exit 1
fi

log_step "Creating ACR login helper script for systemd service..."
cat <<'HELPER_EOF' | sudo tee /usr/local/bin/acr-login-helper.sh > /dev/null
#!/bin/bash
# Helper script to login to ACR using managed identity
# Called by systemd service before pulling images

LOGFILE="/var/log/quic-host-acr-login.log"

echo "[$(date "+%Y-%m-%d %H:%M:%S")] Starting ACR login with managed identity..." | sudo tee -a "$LOGFILE"

# Get ACR name from parameter
ACR_NAME="$1"

if [ -z "$ACR_NAME" ]; then
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] ERROR: ACR name not provided" | sudo tee -a "$LOGFILE"
    exit 1
fi

# Login to ACR using managed identity
if az acr login --name "$ACR_NAME" 2>&1 | sudo tee -a "$LOGFILE"; then
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] Successfully logged into ACR: $ACR_NAME" | sudo tee -a "$LOGFILE"
    exit 0
else
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] ERROR: Failed to login to ACR: $ACR_NAME" | sudo tee -a "$LOGFILE"
    exit 1
fi
HELPER_EOF

sudo chmod +x /usr/local/bin/acr-login-helper.sh
log_step "ACR login helper script created at /usr/local/bin/acr-login-helper.sh"
log_detail "Helper script will be called by systemd before pulling images"

# Extract ACR name from server URL (e.g., quichostacr.azurecr.io -> quichostacr)
ACR_NAME="${ACR_SERVER%%.*}"
log_detail "Extracted ACR name: $ACR_NAME"

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
# Login to ACR using managed identity before pulling
ExecStartPre=/usr/local/bin/acr-login-helper.sh $ACR_NAME
# Stop and remove old container
ExecStartPre=-/usr/bin/docker stop quic-host
ExecStartPre=-/usr/bin/docker rm quic-host
# Pull latest image from ACR
ExecStartPre=/usr/bin/docker pull $ACR_SERVER/quic-host:latest
# Start the container
ExecStart=/usr/bin/docker run --name quic-host -p 8443:8443/tcp -p 8443:8443/udp -e PORT=8443 $ACR_SERVER/quic-host:latest
ExecStop=/usr/bin/docker stop quic-host

[Install]
WantedBy=multi-user.target
EOF

log_step "Service file created. Contents:"
cat /etc/systemd/system/quic-host.service 2>&1 | sudo tee -a "$DETAILED_LOGFILE"

log_step "Reloading systemd daemon..."
if sudo systemctl daemon-reload 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "Systemd daemon reloaded successfully"
else
    log_error "Failed to reload systemd daemon"
fi

log_step "Enabling quic-host service..."
if sudo systemctl enable quic-host.service 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "quic-host service enabled successfully (will start on boot)"
else
    log_error "Failed to enable quic-host service"
fi

log_step "Stopping old service if running..."
if sudo systemctl stop quic-host.service 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "Old service stopped successfully"
else
    log_detail "No old service was running (this is normal for first deployment)"
fi

log_step "Starting quic-host service..."
if sudo systemctl start quic-host.service 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "quic-host service started successfully"
else
    log_error "Failed to start quic-host service"
    log_step "Checking journalctl for error details..."
    sudo journalctl -u quic-host.service -n 50 --no-pager 2>&1 | sudo tee -a "$DETAILED_LOGFILE"
    exit 1
fi

log_step "Waiting 20 seconds for service to fully start and pull image..."
for i in {1..20}; do
    echo -n "."
    sleep 1
done
echo ""

log_step "Checking service status..."
if sudo systemctl status quic-host.service --no-pager 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "Service status check completed successfully"
else
    log_error "Service status check failed"
fi

log_step "Checking if service is active..."
if sudo systemctl is-active quic-host.service 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then 
    log_step "✓ Service is ACTIVE"
else 
    log_error "✗ Service is NOT ACTIVE"
    log_step "Fetching service logs for diagnosis..."
    sudo journalctl -u quic-host.service -n 100 --no-pager 2>&1 | sudo tee -a "$DETAILED_LOGFILE"
fi

log_step "Verifying Docker images..."
if docker images | grep quic-host 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "Docker images found"
    IMAGE_COUNT=$(docker images --filter "reference=*quic-host*" --format "{{.Repository}}" | wc -l)
    log_detail "Number of quic-host images: $IMAGE_COUNT"
else
    log_error "No quic-host images found - this is unexpected after pulling"
    log_detail "This may indicate a problem with the image pull step"
fi

log_step "Verifying container is running..."
docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>&1 | sudo tee -a "$DETAILED_LOGFILE"

if docker ps --filter "name=$CONTAINER_NAME" --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then 
    log_step "✓ Container IS RUNNING"
    log_detail "Container details:"
    docker inspect "$CONTAINER_NAME" --format "State: {{.State.Status}}, StartedAt: {{.State.StartedAt}}" 2>&1 | sudo tee -a "$DETAILED_LOGFILE"
else 
    log_error "✗ Container is NOT RUNNING"
fi

log_step "Checking ALL containers (including stopped)..."
docker ps -a --filter "name=$CONTAINER_NAME" 2>&1 | sudo tee -a "$DETAILED_LOGFILE"

log_step "Checking container logs (last 50 lines)..."
if docker logs "$CONTAINER_NAME" --tail 50 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "Container logs retrieved successfully"
else
    log_error "Failed to get container logs - container may not exist yet"
fi

log_step "Checking if ports are listening..."
log_detail "Checking netstat for port 8443..."
if sudo netstat -tulpn | grep 8443 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_step "✓ Port 8443 is LISTENING"
else
    log_error "✗ Port 8443 is NOT LISTENING"
fi

log_step "Checking journalctl logs for service (last 50 lines)..."
sudo journalctl -u quic-host.service -n 50 --no-pager 2>&1 | sudo tee -a "$DETAILED_LOGFILE" || true

log_step "Checking ACR login helper logs..."
if [ -f /var/log/quic-host-acr-login.log ]; then
    log_detail "ACR login helper log contents:"
    cat /var/log/quic-host-acr-login.log 2>&1 | sudo tee -a "$DETAILED_LOGFILE" || true
else
    log_detail "No ACR login helper log found yet (will be created on next service start)"
fi

log_step "Setting up port forwarding from 443 to 8443..."
log_detail "Installing iptables-persistent for rule persistence..."
if sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | sudo tee -a "$DETAILED_LOGFILE" && \
   sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "iptables-persistent installed successfully"
else
    log_detail "iptables-persistent already installed or installation skipped"
fi

log_step "Configuring iptables rules for TCP..."
if sudo iptables -t nat -C PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "TCP rule already exists"
else
    if sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
        log_detail "TCP rule added successfully"
    else
        log_error "Failed to add TCP iptables rule"
    fi
fi

log_step "Configuring iptables rules for UDP..."
if sudo iptables -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-port 8443 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "UDP rule already exists"
else
    if sudo iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-port 8443 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
        log_detail "UDP rule added successfully"
    else
        log_error "Failed to add UDP iptables rule"
    fi
fi

log_step "Saving iptables rules..."
if sudo netfilter-persistent save 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "iptables rules saved with netfilter-persistent"
elif sudo sh -c "mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4" 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "iptables rules saved to /etc/iptables/rules.v4"
else
    log_error "Failed to save iptables rules"
fi

log_step "✓ Port forwarding configured: 443 -> 8443 (TCP and UDP)"

log_step "Verifying iptables rules..."
if sudo iptables -t nat -L PREROUTING -n -v | grep -E "(443|8443)" 2>&1 | sudo tee -a "$DETAILED_LOGFILE"; then
    log_detail "iptables rules verified"
else
    log_detail "No matching iptables rules found"
fi

log_step "=========================================="
log_step "✓ Deployment Complete!"
log_step "=========================================="
log_step "Service is managed by systemd and will auto-start on boot."
log_step "Log files:"
log_step "  - Main log:     $LOGFILE"
log_step "  - Detailed log: $DETAILED_LOGFILE"
log_step "  - ACR login:    /var/log/quic-host-acr-login.log"
log_step "  - Service logs: sudo journalctl -u quic-host.service"
log_step "  - Container:    docker logs $CONTAINER_NAME"
log_step "=========================================="
log_step "Useful commands:"
log_step "  - View status:  sudo systemctl status quic-host.service"
log_step "  - Restart:      sudo systemctl restart quic-host.service"
log_step "  - Stop:         sudo systemctl stop quic-host.service"
log_step "  - Logs:         sudo journalctl -u quic-host.service -f"
log_step "=========================================="
