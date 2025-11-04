# Troubleshooting Guide

This document provides solutions to common issues when deploying and running quic-host.

## Table of Contents
- [GitHub Actions Deployment Failures](#github-actions-deployment-failures)
- [Container Not Starting](#container-not-starting)
- [ERR_CONNECTION_REFUSED](#err_connection_refused)
- [SSL_ERROR_SYSCALL](#ssl_error_syscall)
- [Port Forwarding Issues](#port-forwarding-issues)
- [QUIC/UDP Not Working](#quicudp-not-working)

## GitHub Actions Deployment Failures

### Symptoms
- GitHub Actions workflow completes but container is not running on VM
- Error messages in Azure VM run-command output like:
  - `[Unit]: not found`
  - `[Service]: not found`
  - `Host: not found`
- Container never gets deployed despite successful build

### Root Cause

This issue occurred when the systemd service file content was being passed as a parameter to `az vm run-command invoke`. The multi-line content was not properly handled, causing bash to interpret the service file lines (like `[Unit]`, `[Service]`) as bash commands instead of file content.

### Solution Applied (Fixed in Latest Version)

The workflow now writes the systemd service file line-by-line using individual `echo` commands instead of passing multi-line content as a parameter. This ensures proper handling by the Azure VM run-command.

**Before (Broken):**
```yaml
SERVICE_CONTENT=$(cat quic-host.service | sed "s|\${ACR_LOGIN_SERVER}|$ACR_LOGIN_SERVER|g")
# ... pass as parameter
"serviceContent=$SERVICE_CONTENT"
# ... then try to echo it
'echo "$serviceContent" | sudo tee /etc/systemd/system/quic-host.service > /dev/null'
```

**After (Fixed):**
```yaml
# Write file line by line with explicit echo commands
'echo "[Unit]" | sudo tee /etc/systemd/system/quic-host.service > /dev/null'
'echo "Description=QUIC Host Container Service" | sudo tee -a /etc/systemd/system/quic-host.service > /dev/null'
# ... continues for each line
```

### Manual Fix for Existing Deployments

If you need to manually fix a VM that has this issue:

```bash
# SSH to the VM
ssh user@VM_PUBLIC_IP

# Create the systemd service file manually
sudo tee /etc/systemd/system/quic-host.service > /dev/null <<EOF
[Unit]
Description=QUIC Host Container Service
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=5
TimeoutStartSec=0
ExecStartPre=-/usr/bin/docker stop quic-host
ExecStartPre=-/usr/bin/docker rm quic-host
ExecStartPre=/usr/bin/docker pull quichostacr.azurecr.io/quic-host:latest
ExecStart=/usr/bin/docker run --name quic-host -p 8443:8443/tcp -p 8443:8443/udp -e PORT=8443 quichostacr.azurecr.io/quic-host:latest
ExecStop=/usr/bin/docker stop quic-host

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
sudo systemctl daemon-reload

# Enable and start the service
sudo systemctl enable quic-host.service
sudo systemctl start quic-host.service

# Verify it's running
sudo systemctl status quic-host.service
docker ps --filter "name=quic-host"
```

### Prevention

This issue is now fixed in the GitHub Actions workflow. To ensure you're using the fixed version:

1. Pull the latest changes from the main branch
2. Re-run the GitHub Actions workflow
3. The deployment should now succeed and the container will be deployed properly

## Container Not Starting

### Symptoms
- Container doesn't appear in `docker ps` output
- `docker logs quic-host` shows errors or no output
- Service not accessible on port 8443

### Diagnostic Commands

Run these commands on the VM to diagnose:

```bash
# Check systemd service status
sudo systemctl status quic-host.service

# Check if service is enabled (auto-start on boot)
sudo systemctl is-enabled quic-host.service

# View service logs
sudo journalctl -u quic-host.service -n 50 --no-pager

# Check if container is running
docker ps -a --filter "name=quic-host"

# Check container logs
docker logs quic-host --tail 50

# Check Docker service status
sudo systemctl status docker

# Check if Docker starts on boot
sudo systemctl is-enabled docker
```

### Solution: Ensure Services Start on Boot

```bash
# Enable Docker service
sudo systemctl enable docker
sudo systemctl start docker

# Enable quic-host service
sudo systemctl enable quic-host.service
sudo systemctl start quic-host.service

# Verify both are enabled
sudo systemctl is-enabled docker
sudo systemctl is-enabled quic-host.service
```

### Solution: Restart the Service

If the service failed to start, restart it:

```bash
# Restart the systemd service (will pull latest image and start container)
sudo systemctl restart quic-host.service

# Check status
sudo systemctl status quic-host.service

# View recent logs
sudo journalctl -u quic-host.service -n 50 --no-pager
```

### Solution: Manual Container Start (Legacy)

If systemd service is not set up, you can start the container manually (not recommended):

```bash
# Stop and remove existing container
docker stop quic-host 2>/dev/null || true
docker rm quic-host 2>/dev/null || true

# Start container with proper restart policy
docker run -d \
  --name quic-host \
  --restart unless-stopped \
  -p 8443:8443/tcp \
  -p 8443:8443/udp \
  -e PORT=8443 \
  quichostacr.azurecr.io/quic-host:latest
```

**Note**: Using systemd service is the recommended approach as it provides better lifecycle management.

## ERR_CONNECTION_REFUSED

### Symptoms
- Browser shows `ERR_CONNECTION_REFUSED` when accessing `https://VM_IP:8443` or `https://VM_IP:443`
- Connection times out or fails immediately

### Diagnostic Commands

```bash
# Check if container is running
docker ps --filter "name=quic-host"

# Check what's listening on ports
sudo netstat -tulpn | grep -E "(443|8443)"

# Check container logs for errors
docker logs quic-host --tail 50

# Check if ports are exposed
docker port quic-host

# Test connection from VM itself
curl -k -v https://localhost:8443

# Check firewall rules
sudo iptables -L -n -v | grep -E "(443|8443)"
```

### Common Causes and Solutions

#### 1. Container Not Running
```bash
# Check container status
docker ps -a --filter "name=quic-host"

# If stopped, check why
docker logs quic-host

# Restart container
docker restart quic-host
```

#### 2. Port Not Exposed
```bash
# Check if ports are exposed
docker port quic-host

# Expected output:
# 8443/tcp -> 0.0.0.0:8443
# 8443/udp -> 0.0.0.0:8443

# If not exposed, recreate container with correct ports
```

#### 3. Azure NSG Rules Missing
```bash
# Check NSG rules (run locally with Azure CLI)
az network nsg rule list \
  --resource-group dns-container-rg \
  --nsg-name <NSG_NAME> \
  --query "[?destinationPortRange=='443' || destinationPortRange=='8443']" \
  --output table
```

If rules are missing, run the setup script again:
```bash
cd azure
./setup.sh
```

#### 4. VM Firewall Blocking Traffic
```bash
# Check if UFW is active
sudo ufw status

# If active, allow ports
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 8443/tcp
sudo ufw allow 8443/udp
```

## SSL_ERROR_SYSCALL

### Symptoms
- `curl` returns: `(35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to 0.0.0.0:8443`
- Connection starts but fails during TLS handshake
- Browser shows security or connection error

### What This Error Means

`SSL_ERROR_SYSCALL` indicates the TLS handshake failed because:
1. The server closed the connection unexpectedly
2. The server isn't properly listening on the port
3. There's a network issue between client and server
4. The TLS certificate or configuration has issues

### Diagnostic Commands

```bash
# Test connection with verbose output
curl -k -v --max-time 10 https://localhost:8443 2>&1

# Check if container is actually listening
sudo netstat -tulpn | grep 8443

# Check container logs for TLS errors
docker logs quic-host --tail 50 | grep -i "tls\|error\|fatal"

# Test TCP connection separately
nc -zv localhost 8443

# Check if the process is listening inside container
docker exec quic-host netstat -tulpn 2>/dev/null || docker exec quic-host ss -tulpn

# Test from within container
docker exec quic-host wget -O- --no-check-certificate https://localhost:8443 2>&1
```

### Common Causes and Solutions

#### 1. Container Not Fully Started
```bash
# Wait longer for container to start
sleep 10

# Check logs to see if servers are running
docker logs quic-host --tail 20

# Expected log output:
# "Starting HTTP/3 (QUIC) server on port 8443"
# "Starting HTTP/2 and HTTP/1.1 fallback server on port 8443"
```

#### 2. Application Crashed After Start
```bash
# Check if container is still running
docker ps --filter "name=quic-host"

# If exited, check logs for crash
docker logs quic-host

# Common issues:
# - Port already in use
# - Permission denied
# - Missing dependencies
```

#### 3. Port Already in Use
```bash
# Check what's using port 8443
sudo lsof -i :8443
# or
sudo ss -tulpn | grep 8443

# If another process is using it, stop that process or change port
```

#### 4. Container Network Issues
```bash
# Check container network settings
docker inspect quic-host --format '{{.NetworkSettings.IPAddress}}'
docker inspect quic-host --format '{{.NetworkSettings.Ports}}'

# Try accessing via container IP
CONTAINER_IP=$(docker inspect quic-host --format '{{.NetworkSettings.IPAddress}}')
curl -k -v https://$CONTAINER_IP:8443
```

#### 5. Application-Level Issue
```bash
# Check if the Go application is running inside the container
docker exec quic-host ps aux | grep quic-host

# Check what ports the application is binding to
docker exec quic-host netstat -tulpn | grep LISTEN

# Expected: should show listening on :8443 or 0.0.0.0:8443
```

### Solution: Test TLS Handshake

Use `openssl` for detailed TLS diagnostics:

```bash
# Test TLS handshake with detailed output
openssl s_client -connect localhost:8443 -servername localhost -debug

# Check supported protocols
openssl s_client -connect localhost:8443 -servername localhost -tls1_2

# If this hangs or fails immediately, the TLS server isn't responding
```

### Solution: Rebuild and Redeploy

If the issue persists:

```bash
# Pull latest image
docker pull quichostacr.azurecr.io/quic-host:latest

# Stop and remove old container
docker stop quic-host
docker rm quic-host

# Run with proper settings
docker run -d \
  --name quic-host \
  --restart unless-stopped \
  -p 8443:8443/tcp \
  -p 8443:8443/udp \
  -e PORT=8443 \
  quichostacr.azurecr.io/quic-host:latest

# Wait and check logs
sleep 5
docker logs quic-host
```

## Port Forwarding Issues

### Symptoms
- Port 8443 works but port 443 doesn't
- `iptables` rules not persisting across reboots

### Diagnostic Commands

```bash
# Check current iptables rules
sudo iptables -t nat -L PREROUTING -n -v

# Check if rules file exists
ls -la /etc/iptables/rules.v4

# Check if iptables-persistent is installed
dpkg -l | grep iptables-persistent
```

### Solution: Verify Port Forwarding Rules

```bash
# Add port forwarding rules
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
sudo iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-port 8443

# Save rules
sudo mkdir -p /etc/iptables
sudo iptables-save | sudo tee /etc/iptables/rules.v4

# Install iptables-persistent to load rules on boot
sudo apt-get update
sudo apt-get install -y iptables-persistent

# During installation, select "Yes" to save current rules
```

### Solution: Test Port Forwarding

```bash
# From VM, test port 443
curl -k -v https://localhost:443

# From external machine, test both ports
curl -k https://VM_PUBLIC_IP:443
curl -k https://VM_PUBLIC_IP:8443
```

## QUIC/UDP Not Working

### Symptoms
- Browser falls back to HTTP/2 instead of HTTP/3
- UDP port not accessible
- `curl --http3` fails

### Diagnostic Commands

```bash
# Check if UDP port is listening
sudo netstat -ulpn | grep 8443

# Test UDP connectivity (from another machine)
nc -u -v VM_PUBLIC_IP 8443

# Check container UDP port mapping
docker port quic-host 8443/udp
```

### Solution: Verify UDP Ports

```bash
# Ensure container exposes UDP
docker inspect quic-host --format '{{.HostConfig.PortBindings}}'

# Should show both TCP and UDP for port 8443

# If missing, recreate container:
docker stop quic-host
docker rm quic-host
docker run -d \
  --name quic-host \
  --restart unless-stopped \
  -p 8443:8443/tcp \
  -p 8443:8443/udp \
  -e PORT=8443 \
  quichostacr.azurecr.io/quic-host:latest
```

### Solution: Check NSG Rules Allow UDP

```bash
# Run locally with Azure CLI
az network nsg rule show \
  --resource-group dns-container-rg \
  --nsg-name <NSG_NAME> \
  --name AllowQUIC

# Verify protocol is '*' (both TCP and UDP) or 'UDP'
```

## Quick Diagnostic Script

Save this as `diagnose.sh` and run on the VM:

```bash
#!/bin/bash
echo "=== Container Status ==="
docker ps --filter "name=quic-host"
echo ""

echo "=== Container Logs (last 20 lines) ==="
docker logs quic-host --tail 20
echo ""

echo "=== Listening Ports ==="
sudo netstat -tulpn | grep -E "(443|8443)"
echo ""

echo "=== Container Port Mappings ==="
docker port quic-host
echo ""

echo "=== iptables NAT Rules ==="
sudo iptables -t nat -L PREROUTING -n -v | grep -E "(443|8443)"
echo ""

echo "=== Docker Service Status ==="
sudo systemctl status docker --no-pager
echo ""

echo "=== Test Local Connection ==="
curl -k -v --max-time 5 https://localhost:8443 2>&1 | head -30
echo ""

echo "=== Test Local Connection Port 443 ==="
curl -k -v --max-time 5 https://localhost:443 2>&1 | head -30
```

Make it executable and run:
```bash
chmod +x diagnose.sh
./diagnose.sh
```

## Getting Help

If you're still experiencing issues after trying these solutions:

1. Run the diagnostic script above and save the output
2. Check GitHub Actions logs for deployment errors
3. Review Azure NSG rules in Azure Portal
4. Check VM system logs: `sudo journalctl -u docker --since "1 hour ago"`

## Related Documentation

- [DEPLOYMENT.md](DEPLOYMENT.md) - Deployment guide
- [README.md](README.md) - Project overview
- [Azure Setup](azure/README.md) - Azure infrastructure setup
