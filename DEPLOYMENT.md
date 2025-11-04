# Deployment Guide for quic-host on Shared Azure VM

This document explains how quic-host is deployed alongside dns-container on a shared Azure VM.

## Architecture Overview

```
Azure VM (dns-container-rg)
├── DNS Container (port 53)     - from idMdev/dns-container repo
└── QUIC Host Container (port 8443) - from idMdev/quic-host repo
```

Both containers run on the same Azure VM, each managed by its own GitHub Actions workflow.

## Why Shared VM?

- **UDP Support**: Azure Container Apps does not support UDP ingress
- **QUIC Protocol**: Requires UDP for HTTP/3 functionality
- **Cost Efficiency**: Share VM resources between services
- **Independent Deployment**: Each service can update without affecting the other

## Prerequisites

### Initial Setup (One-time)

1. **Azure VM with Docker** must exist in resource group `dns-container-rg`
   - Typically created by dns-container setup
   - Must have Docker installed
   - Must have Network Security Group configured

2. **Azure Container Registry** `quichostacr.azurecr.io`
   - Shared between both services
   - Stores container images

3. **GitHub Secrets** configured for OIDC authentication:
   - `AZURE_CLIENT_ID`
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`

### Running the Setup Script

```bash
cd azure
./setup.sh
```

The setup script:
- ✅ Checks if resource group exists (created by dns-container)
- ✅ Checks/creates Azure Container Registry
- ✅ Creates GitHub OIDC app registration
- ✅ Assigns necessary permissions
- ✅ Verifies VM exists and has Docker
- ✅ Creates/updates NSG rules for port 8443 (TCP+UDP)

## Deployment Process

### Automatic Deployment

Push to `main` branch triggers deployment:

```bash
git push origin main
```

GitHub Actions will:
1. Build Docker image
2. Push to Azure Container Registry
3. SSH into VM via `az vm run-command`
4. Pull latest image
5. Stop old quic-host container
6. Start new quic-host container with UDP+TCP ports

### Manual Deployment

Via GitHub UI:
1. Go to Actions tab
2. Select "Deploy to Azure VM" workflow
3. Click "Run workflow"
4. Select branch and run

### What Happens During Deployment

The deployment uses a systemd service unit to manage the container lifecycle:

```bash
# On the Azure VM, the workflow:
# 1. Creates/updates the systemd service unit file at /etc/systemd/system/quic-host.service
# 2. Reloads systemd daemon
# 3. Enables the service (auto-start on boot)
# 4. Restarts the service (pulls latest image and starts container)

# The systemd service handles:
# - Automatic container start on VM boot
# - Container restart on failure
# - Pulling latest image from ACR
# - Proper container lifecycle management
```

**Service Unit Configuration:**
- **Type**: simple (foreground process)
- **Restart**: always (auto-restart on failure)
- **Dependencies**: Requires and starts after Docker service
- **Ports**: 8443/tcp and 8443/udp
- **Image**: Automatically pulls latest from ACR on service start

## Port Allocation

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| dns-container | 53 | TCP/UDP | DNS queries |
| quic-host | 443 | TCP/UDP | HTTPS/QUIC (forwarded to 8443) |
| quic-host | 8443 | TCP | HTTP/2, HTTP/1.1 fallback |
| quic-host | 8443 | UDP | QUIC (HTTP/3) |

> **Note**: Port 443 is forwarded to port 8443 using iptables rules configured during deployment.

## Independence Between Services

✅ **Each service is independent:**
- Separate containers
- Separate GitHub repos
- Separate GitHub Actions workflows
- No shared dependencies
- Different ports (no conflicts)

✅ **Shared resources:**
- Same Azure VM
- Same Container Registry
- Same Resource Group
- Same Network Security Group

## Network Security Group Rules

The setup script creates the following NSG rules:

```
Name: AllowHTTPS
Priority: 300
Source: * (any)
Destination Port: 443
Protocol: * (both TCP and UDP)
Direction: Inbound

Name: AllowQUIC
Priority: 310
Source: * (any)
Destination Port: 8443
Protocol: * (both TCP and UDP)
Direction: Inbound
```

Both ports allow HTTP/3 (QUIC) over UDP and HTTPS over TCP. Port 443 is forwarded to port 8443 by iptables rules on the VM.

## Testing Deployment

### Check Service Status

```bash
# Via Azure CLI
VM_NAME=$(az vm list --resource-group dns-container-rg --query "[0].name" -o tsv)

# Check systemd service status
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "sudo systemctl status quic-host.service"
```

### Check Container Status

```bash
# Check if container is running
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker ps --filter name=quic-host"
```

### View Container Logs

```bash
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker logs quic-host --tail 50"
```

### Test Service Endpoint

```bash
# Get VM public IP
VM_IP=$(az vm list-ip-addresses --resource-group dns-container-rg --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)

# Test HTTPS endpoint on standard port
curl -k https://$VM_IP

# Test HTTPS endpoint on direct port
curl -k https://$VM_IP:8443

# Test with HTTP/3 support (if available)
curl --http3 -k https://$VM_IP
curl --http3 -k https://$VM_IP:8443
```

## Troubleshooting

For detailed troubleshooting steps, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### Service Not Starting

```bash
# Check systemd service status and logs
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "sudo systemctl status quic-host.service --no-pager; sudo journalctl -u quic-host.service -n 50 --no-pager"

# Manually restart the service
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "sudo systemctl restart quic-host.service"
```

### Container Not Starting

```bash
# Check if image was pulled successfully
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker images | grep quic-host"

# Check container logs for errors
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker logs quic-host"
```

### Port Already in Use

If port 8443 is already in use by another service:

```bash
# Check what's using port 8443
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "netstat -tulpn | grep 8443"
```

### UDP Not Working

```bash
# Verify NSG rule exists
az network nsg rule show \
  --resource-group dns-container-rg \
  --nsg-name <NSG_NAME> \
  --name AllowQUIC

# Test UDP port connectivity
nc -u -v $VM_IP 8443
```

### Workflow Fails to Find VM

Ensure the resource group name is correct:
```yaml
env:
  RESOURCE_GROUP: dns-container-rg  # Must match actual RG name
```

## Maintenance

### Viewing Both Containers

```bash
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker ps"
```

### Cleaning Up Old Images

```bash
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker image prune -a -f"
```

### Restarting Container

```bash
# Restart via systemd service (recommended)
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "sudo systemctl restart quic-host.service"

# Or restart container directly
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker restart quic-host"
```

### Viewing Service Logs

```bash
# View systemd service logs
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "sudo journalctl -u quic-host.service -n 100 --no-pager"
```

## Best Practices

1. **Always test locally first**: Use `docker-compose up` to test before deploying
2. **Monitor container logs**: Check logs after deployment to verify success
3. **Use workflow_dispatch**: For manual testing without pushing to main
4. **Keep containers small**: Minimize image size for faster deployments
5. **Version your images**: The workflow tags with both `latest` and commit SHA
6. **Use systemd for container management**: Provides automatic restart, boot persistence, and proper lifecycle management
7. **Check service status after deployment**: Verify systemd service is active and container is running

## Related Documentation

- [Main README](README.md) - Project overview and local development
- [Azure Setup Guide](azure/README.md) - Detailed Azure configuration
- [dns-container repo](https://github.com/idMdev/dns-container) - Companion service

## Support

For issues related to:
- **QUIC/HTTP/3 functionality**: See main README troubleshooting
- **Azure VM setup**: See dns-container repository
- **Deployment failures**: Check GitHub Actions logs
- **Network issues**: Verify NSG rules and VM networking
