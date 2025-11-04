#!/bin/bash
# Azure infrastructure setup script for QUIC Host deployment

set -e

# Configuration
RESOURCE_GROUP="quic-host-rg"
LOCATION="eastus"
REGISTRY_NAME="quichostacr"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
APP_NAME="quic-host-github-app"
CONTAINER_APP_ENV="quic-host-env"
CONTAINER_APP_NAME="quic-host"

echo "========================================="
echo "Azure Infrastructure Setup for QUIC Host"
echo "========================================="
echo ""

# Login check
echo "Checking Azure CLI login status..."
az account show > /dev/null 2>&1 || {
    echo "Please login to Azure CLI first:"
    echo "  az login"
    exit 1
}

# Set subscription
if [ -n "$SUBSCRIPTION_ID" ]; then
    echo "Setting subscription to: $SUBSCRIPTION_ID"
    az account set --subscription "$SUBSCRIPTION_ID"
fi

CURRENT_SUBSCRIPTION=$(az account show --query id -o tsv)
echo "Using subscription: $CURRENT_SUBSCRIPTION"
echo ""

# Create resource group
echo "Creating resource group: $RESOURCE_GROUP"
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output table

echo ""

# Create Azure Container Registry
echo "Creating Azure Container Registry: $REGISTRY_NAME"
az acr create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$REGISTRY_NAME" \
    --sku Basic \
    --admin-enabled false \
    --output table

echo ""

# Enable system-assigned managed identity for ACR
echo "Configuring managed identity for ACR..."
az acr update \
    --name "$REGISTRY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --anonymous-pull-enabled false

echo ""

# Create Azure AD App Registration for GitHub Actions
echo "Creating Azure AD App Registration for GitHub Actions OIDC..."
APP_ID=$(az ad app create \
    --display-name "$APP_NAME" \
    --query appId -o tsv)

echo "App ID (Client ID): $APP_ID"

# Create service principal
echo "Creating service principal..."
SP_ID=$(az ad sp create \
    --id "$APP_ID" \
    --query id -o tsv)

echo "Service Principal ID: $SP_ID"

# Add federated credential for GitHub Actions
echo "Adding federated credential for GitHub Actions..."
REPO_OWNER=$(git remote get-url origin | sed -n 's/.*github.com[:/]\([^/]*\)\/.*/\1/p')
REPO_NAME=$(git remote get-url origin | sed -n 's/.*\/\(.*\)\.git/\1/p' | sed 's/\.git$//')

if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    echo "Warning: Could not auto-detect GitHub repository."
    echo "Please manually configure federated credentials in Azure Portal."
    echo "Repository format: OWNER/REPO"
else
    echo "GitHub Repository: $REPO_OWNER/$REPO_NAME"
    
    cat > /tmp/federated-credential.json <<FEDCRED
{
    "name": "github-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:$REPO_OWNER/$REPO_NAME:ref:refs/heads/main",
    "audiences": [
        "api://AzureADTokenExchange"
    ]
}
FEDCRED

    az ad app federated-credential create \
        --id "$APP_ID" \
        --parameters /tmp/federated-credential.json
    
    rm /tmp/federated-credential.json
fi

echo ""

# Assign roles to service principal
echo "Assigning roles to service principal..."

# Contributor role for resource group
az role assignment create \
    --assignee "$SP_ID" \
    --role "Contributor" \
    --scope "/subscriptions/$CURRENT_SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP" \
    --output table

# AcrPush role for container registry
ACR_ID=$(az acr show --name "$REGISTRY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
az role assignment create \
    --assignee "$SP_ID" \
    --role "AcrPush" \
    --scope "$ACR_ID" \
    --output table

echo ""

# Create Container Apps Environment
echo "Creating Container Apps Environment: $CONTAINER_APP_ENV"
az containerapp env create \
    --name "$CONTAINER_APP_ENV" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output table

echo ""
echo "========================================="
echo "Setup Complete!"
echo "========================================="
echo ""
echo "Please configure the following GitHub Secrets:"
echo ""
echo "AZURE_CLIENT_ID:       $APP_ID"
echo "AZURE_TENANT_ID:       $(az account show --query tenantId -o tsv)"
echo "AZURE_SUBSCRIPTION_ID: $CURRENT_SUBSCRIPTION"
echo ""
echo "To set these secrets, go to:"
echo "GitHub Repository → Settings → Secrets and variables → Actions → New repository secret"
echo ""
echo "Azure Resources Created:"
echo "  - Resource Group: $RESOURCE_GROUP"
echo "  - Container Registry: $REGISTRY_NAME.azurecr.io"
echo "  - Container Apps Environment: $CONTAINER_APP_ENV"
echo "  - App Registration: $APP_NAME"
echo ""
echo "Container app will be deployed to:"
echo "  https://$CONTAINER_APP_NAME.${LOCATION}.azurecontainerapps.io"
echo ""
