# Azure Deployment Guide

This directory contains infrastructure setup and deployment automation for deploying the QUIC Host service to Azure Container Apps with managed identity integration.

## Architecture

- **Azure Container Registry (ACR)**: Stores Docker images
- **Azure Container Apps**: Runs the containerized service with auto-scaling and ingress
- **Container Apps Environment**: Managed Kubernetes environment for container apps
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
- Create a Container Apps Environment (`quic-host-env`)
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
5. Deploy to Azure Container Apps (create or update)

**Trigger deployment:**
- Push to `main` branch
- Or manually via Actions tab → "Deploy to Azure Container Apps" → "Run workflow"

## Configuration

### Environment Variables

The deployment can be customized by editing `.github/workflows/azure-deploy.yml`:

```yaml
env:
  CONTAINER_APP_NAME: quic-host         # Container app name
  CONTAINER_APP_ENV: quic-host-env      # Container Apps Environment
  RESOURCE_GROUP: quic-host-rg          # Azure resource group
  LOCATION: eastus                      # Azure region
  REGISTRY_NAME: quichostacr            # ACR name (must be globally unique)
  IMAGE_NAME: quic-host                 # Docker image name
```

### Container Configuration

The Container Apps deployment includes:
- **CPU**: 1.0 cores
- **Memory**: 2.0 GB
- **Port**: 8443 (HTTPS/QUIC)
- **Ingress**: External with HTTP/2 transport
- **Scaling**: 1-1 replicas (can be adjusted for auto-scaling)
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
https://quic-host.eastus.azurecontainerapps.io
```

Note: Container Apps provides automatic HTTPS on port 443. The internal container port (8443) is mapped to the standard HTTPS port by the ingress controller.

### Testing the Deployment

```bash
# Check deployment status
az containerapp show \
  --resource-group quic-host-rg \
  --name quic-host \
  --query "{FQDN:properties.configuration.ingress.fqdn,State:properties.provisioningState}" \
  --output table

# View logs
az containerapp logs show \
  --resource-group quic-host-rg \
  --name quic-host \
  --follow

# Test HTTPS endpoint
curl https://quic-host.eastus.azurecontainerapps.io
```

## Workflow Features

### Build Optimization
- Docker layer caching with GitHub Actions cache
- Multi-stage builds for minimal image size
- Vendored Go dependencies for faster builds

### Deployment Strategy
- Zero-downtime deployments with revision management
- Automatic health checks and self-healing
- Traffic splitting for blue-green deployments
- Built-in auto-scaling based on HTTP requests

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
# Check container app logs
az containerapp logs show \
  --resource-group quic-host-rg \
  --name quic-host \
  --follow

# Check revision status
az containerapp revision list \
  --resource-group quic-host-rg \
  --name quic-host \
  --output table

# Restart container app
az containerapp revision restart \
  --resource-group quic-host-rg \
  --name quic-host
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

Container Apps automatically provides managed certificates for custom domains. For the default domain, Azure-managed certificates are used automatically with proper TLS termination at the ingress.

To use a custom domain:

1. Add custom domain to Container App:
```bash
az containerapp hostname add \
  --resource-group quic-host-rg \
  --name quic-host \
  --hostname yourdomain.com
```

2. Configure DNS CNAME record to point to the Container App FQDN

3. Bind certificate (managed or bring your own):
```bash
az containerapp hostname bind \
  --resource-group quic-host-rg \
  --name quic-host \
  --hostname yourdomain.com \
  --environment quic-host-env \
  --validation-method CNAME
```

## Scaling and High Availability

Container Apps provides built-in features for production deployments:
- **Auto-scaling**: Based on HTTP requests, CPU, memory, or custom metrics
- **Multiple replicas**: Horizontal scaling with load balancing
- **Zero-downtime deployments**: Revision-based deployments
- **Health probes**: Automatic health monitoring and restart
- **Azure Monitor**: Built-in logging and metrics

Example: Enable auto-scaling based on HTTP requests:
```bash
az containerapp update \
  --name quic-host \
  --resource-group quic-host-rg \
  --min-replicas 1 \
  --max-replicas 10 \
  --scale-rule-name http-rule \
  --scale-rule-type http \
  --scale-rule-http-concurrency 10
```

## Cost Optimization

Current configuration costs approximately:
- ACR Basic: ~$5/month
- Container Apps: ~$50-70/month (with 1 vCPU, 2GB memory, running 24/7)
- Container Apps Environment: Included in consumption pricing

To reduce costs:
- Scale to zero when not in use (set `--min-replicas 0`)
- Use consumption-based pricing tier
- Schedule deployments with GitHub Actions schedules
- Monitor and optimize resource allocation

## Cleanup

To remove all Azure resources:

```bash
az group delete --name quic-host-rg --yes --no-wait
az ad app delete --id <CLIENT_ID>
```

## Additional Resources

- [Azure Container Apps Documentation](https://docs.microsoft.com/azure/container-apps/)
- [Azure Container Registry Documentation](https://docs.microsoft.com/azure/container-registry/)
- [GitHub Actions Azure Login](https://github.com/Azure/login)
- [Managed Identity Documentation](https://docs.microsoft.com/azure/active-directory/managed-identities-azure-resources/)
- [Container Apps Scaling](https://docs.microsoft.com/azure/container-apps/scale-app)
