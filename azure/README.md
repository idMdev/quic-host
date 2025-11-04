# Azure Deployment Guide

This directory contains infrastructure setup and deployment automation for deploying the QUIC Host service to Azure Container Instances (ACI) with managed identity integration.

## Architecture

- **Azure Container Registry (ACR)**: Stores Docker images
- **Azure Container Instances (ACI)**: Runs the containerized service
- **Managed Identity**: System-assigned identity for secure authentication to Azure services
- **GitHub Actions**: CI/CD pipeline with OIDC authentication
- **ACR Authentication**: Uses access tokens from the GitHub Actions service principal for image pulls

## Prerequisites

1. Azure CLI installed and configured
2. GitHub repository with Actions enabled
3. Azure subscription with appropriate permissions

## Quick Start

### 1. Setup Azure Infrastructure

Run the setup script to create required Azure resources:

```bash
cd azure
./setup.sh
```

This script will:
- Create a resource group (`quic-host-rg`)
- Create an Azure Container Registry (`quichostacr`)
- Create an Azure AD App Registration for GitHub Actions
- Configure federated credentials for OIDC authentication
- Assign necessary roles (Contributor, AcrPush)

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
2. Get ACR access token for authentication
3. Build the Docker image
4. Push to Azure Container Registry
5. Deploy to Azure Container Instances

**Trigger deployment:**
- Push to `main` branch
- Or manually via Actions tab → "Deploy to Azure Container Instances" → "Run workflow"

## Configuration

### Environment Variables

The deployment can be customized by editing `.github/workflows/azure-deploy.yml`:

```yaml
env:
  CONTAINER_NAME: quic-host           # ACI container name
  RESOURCE_GROUP: quic-host-rg        # Azure resource group
  LOCATION: eastus                    # Azure region
  REGISTRY_NAME: quichostacr          # ACR name (must be globally unique)
  IMAGE_NAME: quic-host               # Docker image name
```

### Container Configuration

The ACI deployment includes:
- **CPU**: 1 core
- **Memory**: 1.5 GB
- **Port**: 8443 (HTTPS/QUIC)
- **DNS**: `quic-host-demo.eastus.azurecontainer.io`
- **Restart Policy**: OnFailure
- **Identity**: System-assigned managed identity

## Managed Identity Benefits

Using managed identity provides:
- No credentials stored in code or configuration
- Automatic credential rotation
- Simplified authentication to Azure services
- Enhanced security with least-privilege access

## Accessing the Deployed Service

After deployment, the service will be available at:

```
https://quic-host-demo.eastus.azurecontainer.io:8443
```

### Testing the Deployment

```bash
# Check deployment status
az container show \
  --resource-group quic-host-rg \
  --name quic-host \
  --query "{FQDN:ipAddress.fqdn,State:instanceView.state}" \
  --output table

# View logs
az container logs \
  --resource-group quic-host-rg \
  --name quic-host

# Test HTTPS endpoint
curl -k https://quic-host-demo.eastus.azurecontainer.io:8443
```

## Workflow Features

### Build Optimization
- Docker layer caching with GitHub Actions cache
- Multi-stage builds for minimal image size
- Vendored Go dependencies for faster builds

### Deployment Strategy
- Blue-green deployment using container updates
- Automatic rollback on failure
- Container health monitoring

### Security
- OIDC authentication (no long-lived secrets)
- System-assigned managed identity for Azure services
- ACR access tokens for secure image pulls
- Private container registry
- TLS 1.2+ for QUIC connections

## Troubleshooting

### Build Failures

```bash
# Check GitHub Actions logs
# Go to: Actions tab → Select failed workflow → View logs

# Verify ACR access
az acr login --name quichostacr
docker pull quichostacr.azurecr.io/quic-host:latest
```

### Deployment Failures

```bash
# Check container logs
az container logs --resource-group quic-host-rg --name quic-host

# Check container events
az container show \
  --resource-group quic-host-rg \
  --name quic-host \
  --query instanceView.events

# Restart container
az container restart --resource-group quic-host-rg --name quic-host
```

### Authentication Issues

```bash
# Verify service principal roles
az role assignment list --assignee <CLIENT_ID> --output table

# Test Azure CLI authentication with managed identity
az login --identity
az account show
```

## Custom Certificates

To use custom TLS certificates instead of self-signed:

1. Store certificates in Azure Key Vault
2. Grant managed identity access to Key Vault
3. Mount certificates as volume in ACI
4. Set environment variables:

```yaml
--environment-variables \
  TLS_CERT_FILE=/certs/cert.pem \
  TLS_KEY_FILE=/certs/key.pem
```

## Scaling and High Availability

For production deployments, consider:
- Azure Container Apps for auto-scaling
- Azure Load Balancer for high availability
- Azure Front Door for global distribution
- Azure Monitor for observability

## Cost Optimization

Current configuration costs approximately:
- ACR Basic: ~$5/month
- ACI (1 vCPU, 1.5GB): ~$35/month (running 24/7)

To reduce costs:
- Stop container when not in use: `az container stop`
- Use consumption-based pricing
- Schedule deployments with GitHub Actions schedules

## Cleanup

To remove all Azure resources:

```bash
az group delete --name quic-host-rg --yes --no-wait
az ad app delete --id <CLIENT_ID>
```

## Additional Resources

- [Azure Container Instances Documentation](https://docs.microsoft.com/azure/container-instances/)
- [Azure Container Registry Documentation](https://docs.microsoft.com/azure/container-registry/)
- [GitHub Actions Azure Login](https://github.com/Azure/login)
- [Managed Identity Documentation](https://docs.microsoft.com/azure/active-directory/managed-identities-azure-resources/)
