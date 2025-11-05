# Azure Deployment Guide

This directory contains infrastructure setup and deployment automation for deploying the QUIC Host service to Azure VM with managed identity integration.

## Architecture

- **Azure Container Registry (ACR)**: Stores Docker images
- **Azure VM**: Runs Docker containers (shared with dns-container)
- **VM Managed Identity**: System-assigned identity for secure ACR authentication (no passwords/tokens stored on VM)
- **GitHub Actions**: CI/CD pipeline with OIDC authentication
- **ACR Authentication**: 
  - GitHub Actions uses OIDC tokens for building and pushing images
  - VM uses its managed identity for pulling images (passwordless authentication)

## Why Azure VM Instead of Container Apps?

Azure Container Apps does not support UDP ingress, which is required for QUIC (HTTP/3) protocol. Therefore, this service is deployed to an Azure VM that supports both TCP and UDP traffic, allowing proper QUIC functionality.

## Prerequisites

1. Azure CLI installed and configured
2. GitHub repository with Actions enabled
3. Azure subscription with appropriate permissions
4. Azure VM with Docker installed (shared with dns-container repo)

## Quick Start

### Files in this Directory

- **setup.sh**: Infrastructure setup script for creating Azure resources and configuring VM managed identity
- **deploy.sh**: Deployment script that runs on the VM to deploy the container using managed identity
- **README.md**: This guide

### 1. Setup Azure Infrastructure

Run the setup script to create/verify required Azure resources:

```bash
cd azure
./setup.sh
```

This script will:
- Check/create resource group (`dns-container-rg`, shared with dns-container)
- Check/create Azure Container Registry (`quichostacr`)
- Create an Azure AD App Registration for GitHub Actions
- Configure federated credentials for OIDC authentication
- Assign necessary roles (Contributor, AcrPush to service principal)
- **Configure VM with system-assigned managed identity**
- **Assign AcrPull role to VM's managed identity**
- **Install Azure CLI on the VM if not present**
- Verify VM exists and Docker is installed
- Create Network Security Group rules for port 8443 (TCP+UDP)

### 2. Configure GitHub Secrets

After running the setup script, add the following secrets to your GitHub repository:

**Settings → Secrets and variables → Actions → New repository secret**

Required secrets:
- `AZURE_CLIENT_ID`: Application (client) ID from setup output
- `AZURE_TENANT_ID`: Azure AD tenant ID from setup output
- `AZURE_SUBSCRIPTION_ID`: Azure subscription ID from setup output

### 3. Deploy via GitHub Actions

The deployment workflow (`.github/workflows/azure-deploy.yml`) will automatically:
1. Authenticate to Azure using OIDC
2. Get ACR access token for authentication (GitHub Actions only)
3. Build the Docker image
4. Push to Azure Container Registry
5. Copy the deployment script (`azure/deploy.sh`) to the VM
6. Execute the deployment script which:
   - **Authenticates to ACR using VM's managed identity (passwordless)**
   - Pulls the latest image from ACR
   - Creates/updates systemd service for container lifecycle management
   - Creates ACR login helper script for future service restarts
   - Starts the container with UDP+TCP port bindings
   - Sets up port forwarding from 443 to 8443
   - **Logs all deployment steps to multiple log files:**
     - `/var/log/quic-host-deploy.log` (main log)
     - `/var/log/quic-host-deploy-detailed.log` (detailed log)
     - `/var/log/quic-host-acr-login.log` (ACR authentication log)

**Trigger deployment:**
- Push to `main` branch
- Or manually via Actions tab → "Deploy to Azure VM" → "Run workflow"

## Configuration

### Environment Variables

The deployment can be customized by editing `.github/workflows/azure-deploy.yml`:

```yaml
env:
  REGISTRY_NAME: quichostacr            # ACR name (must be globally unique)
  IMAGE_NAME: quic-host                 # Docker image name
  CONTAINER_NAME: quic-host             # Container name on VM
  RESOURCE_GROUP: dns-container-rg      # Azure resource group (shared)
```

### Container Configuration

The container deployment includes:
- **Port**: 8443 (TCP+UDP for HTTPS/HTTP2 and QUIC/HTTP3)
- **Restart Policy**: always (via systemd)
- **Environment**: PORT=8443
- **ACR Authentication**: Managed identity (no passwords/credentials stored)

## Shared VM with dns-container

This deployment shares an Azure VM with the `dns-container` repository. Both containers run on the same VM:
- **dns-container**: Manages DNS services on port 53
- **quic-host**: Provides QUIC/HTTP3 service on port 8443

Each repository has its own GitHub Actions workflow that can independently update its respective container without affecting the other.

## Managed Identity Benefits

Using VM's managed identity for ACR authentication provides:
- **No credentials stored on VM**: No passwords, tokens, or secrets
- **Automatic credential management**: Azure handles token lifecycle
- **Enhanced security**: Least-privilege access with role-based permissions
- **Simplified operations**: No manual credential rotation needed
- **Better audit trail**: All authentication attempts logged
- **Reduced attack surface**: No secrets to leak or steal

## Accessing the Deployed Service

After deployment, the service will be available at:

```
https://VM_PUBLIC_IP:8443
```

The VM public IP is displayed in the GitHub Actions workflow output.

### Testing the Deployment

```bash
# Get VM public IP
az vm list-ip-addresses \
  --resource-group dns-container-rg \
  --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" \
  --output tsv

# Test HTTPS endpoint
curl -k https://VM_IP:8443

# View container logs on VM
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "docker logs quic-host --tail 50"

# View deployment logs
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "cat /var/log/quic-host-deploy.log"

# View detailed deployment logs (more verbose)
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "tail -100 /var/log/quic-host-deploy-detailed.log"

# Check ACR authentication logs
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "cat /var/log/quic-host-acr-login.log"

# Check container status
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "docker ps --filter name=quic-host"
```

## Workflow Features

### Build Optimization
- Docker layer caching with GitHub Actions cache
- Multi-stage builds for minimal image size
- Vendored Go dependencies for faster builds

### Deployment Strategy
- Zero-downtime deployments (stop old, start new container)
- Automatic restart on failure with systemd service management
- **Managed identity for ACR authentication (passwordless)**
- Container registry pull from ACR using VM's identity
- VM command execution via Azure CLI
- **Comprehensive logging at multiple levels for easy troubleshooting**

### Security
- OIDC authentication (no long-lived secrets)
- **VM managed identity for ACR access (no credentials on VM)**
- System-assigned managed identity for Azure services
- **No passwords or tokens stored on VM**
- Private container registry
- TLS 1.2+ for QUIC connections
- Network Security Groups for port access control

## Troubleshooting

### Deployment Log Files

The deployment creates multiple log files on the VM for troubleshooting:

1. **Main Deployment Log**: `/var/log/quic-host-deploy.log`
   - High-level deployment progress and status
   - Quick overview of what happened during deployment

2. **Detailed Deployment Log**: `/var/log/quic-host-deploy-detailed.log`
   - Verbose output of all commands
   - Full command outputs and error messages
   - Best for debugging deployment issues

3. **ACR Login Log**: `/var/log/quic-host-acr-login.log`
   - ACR authentication attempts using managed identity
   - Useful for diagnosing ACR access issues

4. **Systemd Service Logs**: Available via `journalctl -u quic-host.service`
   - Container lifecycle events
   - Start/stop/restart operations
   - Managed by systemd

**Viewing logs:**
```bash
# Quick check - view main log
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "cat /var/log/quic-host-deploy.log"

# Detailed troubleshooting - view detailed log
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "cat /var/log/quic-host-deploy-detailed.log"

# Check ACR authentication
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "cat /var/log/quic-host-acr-login.log"
```

### Build Failures

```bash
# Check GitHub Actions logs
# Go to: Actions tab → Select failed workflow → View logs

# Verify ACR access
az acr login --name quichostacr
docker pull quichostacr.azurecr.io/quic-host:latest
```

### Managed Identity Issues

If deployment fails with ACR authentication errors:

```bash
# 1. Verify VM has managed identity assigned
az vm identity show \
  --resource-group dns-container-rg \
  --name <VM_NAME>

# Should show a principalId (if empty, managed identity is not assigned)

# 2. Check if VM's identity has AcrPull role
VM_IDENTITY=$(az vm identity show --resource-group dns-container-rg --name <VM_NAME> --query principalId -o tsv)
ACR_ID=$(az acr show --name quichostacr --resource-group dns-container-rg --query id -o tsv)

az role assignment list \
  --assignee $VM_IDENTITY \
  --scope $ACR_ID

# Should show AcrPull role assignment

# 3. If missing, re-run setup script
cd azure
./setup.sh

# 4. Test ACR login from VM
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "az acr login --name quichostacr"

# 5. Check Azure CLI is installed on VM
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name <VM_NAME> \
  --command-id RunShellScript \
  --scripts "az version"
```

**Common managed identity issues:**
- **"az: command not found"**: Azure CLI not installed on VM → Run `setup.sh`
- **"Failed to connect to MSI"**: VM doesn't have managed identity → Run `setup.sh`
- **"Authorization failed"**: Missing AcrPull role → Run `setup.sh`
- **"Token expired"**: Normal - `az acr login` automatically refreshes tokens

### Deployment Failures

```bash
# Check deployment logs on VM
VM_NAME=$(az vm list --resource-group dns-container-rg --query "[0].name" -o tsv)

# Main deployment log
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "cat /var/log/quic-host-deploy.log"

# Detailed deployment log
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "tail -200 /var/log/quic-host-deploy-detailed.log"

# Container logs
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker logs quic-host --tail 100"

# Check if container is running
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker ps -a --filter name=quic-host"

# Restart service manually
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "sudo systemctl restart quic-host.service"
```

### Network Issues

```bash
# Verify NSG rules
NSG_NAME=$(az network nsg list --resource-group dns-container-rg --query "[0].name" -o tsv)
az network nsg rule list \
  --resource-group dns-container-rg \
  --nsg-name $NSG_NAME \
  --output table

# Check if port 8443 is open
az network nsg rule show \
  --resource-group dns-container-rg \
  --nsg-name $NSG_NAME \
  --name AllowQUIC

# Test connectivity
VM_IP=$(az vm list-ip-addresses --resource-group dns-container-rg --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
curl -k https://$VM_IP:8443
```

### Authentication Issues

```bash
# Verify service principal roles
az role assignment list --assignee <CLIENT_ID> --output table

# Test ACR access
az acr login --name quichostacr
```

## Custom Certificates

By default, the application generates self-signed certificates. For production use:

1. Mount certificates into the container on the VM
2. Update the container run command in `.github/workflows/azure-deploy.yml`:

```bash
docker run -d --name quic-host \
  --restart unless-stopped \
  -p 8443:8443/tcp -p 8443:8443/udp \
  -v /path/to/certs:/certs \
  -e PORT=8443 \
  -e TLS_CERT_FILE=/certs/cert.pem \
  -e TLS_KEY_FILE=/certs/key.pem \
  $ACR_LOGIN_SERVER/quic-host:latest
```

## VM Requirements

The Azure VM should have:
- **Docker installed**: Required to run containers
- **Sufficient resources**: At least 1 vCPU and 2GB RAM recommended
- **Network Security Group**: Port 8443 (TCP+UDP) open for QUIC
- **Managed identity** (optional): For enhanced security

The VM is shared with dns-container, so ensure sufficient resources for both services.

## Cost Optimization

Since this uses a shared VM with dns-container:
- VM costs are shared between both services
- ACR Basic: ~$5/month
- Total cost depends on VM size (typically $20-100/month for small VMs)

To reduce costs:
- Use smaller VM sizes when possible
- Stop VM when not needed (development environments)
- Use Azure Reserved Instances for production

## Cleanup

To remove quic-host (but keep VM and other resources for dns-container):

```bash
# Stop and remove container from VM
VM_NAME=$(az vm list --resource-group dns-container-rg --query "[0].name" -o tsv)
az vm run-command invoke \
  --resource-group dns-container-rg \
  --name $VM_NAME \
  --command-id RunShellScript \
  --scripts "docker stop quic-host && docker rm quic-host"

# Delete images from ACR (optional)
az acr repository delete \
  --name quichostacr \
  --repository quic-host \
  --yes

# To remove app registration (if not shared)
az ad app delete --id <CLIENT_ID>
```

**Warning**: Do not delete the resource group or VM as they are shared with dns-container!

## Additional Resources

- [Azure VM Documentation](https://docs.microsoft.com/azure/virtual-machines/)
- [Azure Container Registry Documentation](https://docs.microsoft.com/azure/container-registry/)
- [GitHub Actions Azure Login](https://github.com/Azure/login)
- [Managed Identity Documentation](https://docs.microsoft.com/azure/active-directory/managed-identities-azure-resources/)
- [QUIC Protocol](https://quicwg.org/)
