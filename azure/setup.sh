#!/bin/bash
# Azure infrastructure setup script for QUIC Host VM deployment

set -e

# Configuration
RESOURCE_GROUP="dns-container-rg"
LOCATION="eastus"
REGISTRY_NAME="quichostacr"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
APP_NAME="quic-host-github-app"

echo "========================================="
echo "Azure Infrastructure Setup for QUIC Host"
echo "VM Deployment Configuration"
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

# Check if resource group exists (shared with dns-container)
echo "Checking resource group: $RESOURCE_GROUP"
if az group show --name "$RESOURCE_GROUP" > /dev/null 2>&1; then
    echo "Resource group $RESOURCE_GROUP already exists (shared with dns-container)"
else
    echo "Creating resource group: $RESOURCE_GROUP"
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output table
fi

echo ""

# Check if Azure Container Registry exists
echo "Checking Azure Container Registry: $REGISTRY_NAME"
if az acr show --name "$REGISTRY_NAME" --resource-group "$RESOURCE_GROUP" > /dev/null 2>&1; then
    echo "Azure Container Registry $REGISTRY_NAME already exists"
else
    echo "Creating Azure Container Registry: $REGISTRY_NAME"
    az acr create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$REGISTRY_NAME" \
        --sku Basic \
        --admin-enabled false \
        --output table
    
    echo ""
    
    # Configure managed identity for ACR
    echo "Configuring managed identity for ACR..."
    az acr update \
        --name "$REGISTRY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --anonymous-pull-enabled false
fi

echo ""

# Create Azure AD App Registration for GitHub Actions
echo "Creating Azure AD App Registration for GitHub Actions OIDC..."
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)

if [ -z "$APP_ID" ]; then
    APP_ID=$(az ad app create \
        --display-name "$APP_NAME" \
        --query appId -o tsv)
    echo "Created new App ID (Client ID): $APP_ID"
    
    # Create service principal
    echo "Creating service principal..."
    SP_ID=$(az ad sp create \
        --id "$APP_ID" \
        --query id -o tsv)
    echo "Service Principal ID: $SP_ID"
else
    echo "App Registration already exists: $APP_ID"
    SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)
    echo "Service Principal ID: $SP_ID"
fi

# Add federated credential for GitHub Actions
echo "Configuring federated credential for GitHub Actions..."
REPO_OWNER=$(git remote get-url origin | sed -n 's/.*github.com[:/]\([^/]*\)\/.*/\1/p')
REPO_NAME=$(git remote get-url origin | sed -n 's/.*\/\(.*\)\.git/\1/p' | sed 's/\.git$//')

if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
    echo "Warning: Could not auto-detect GitHub repository."
    echo "Please manually configure federated credentials in Azure Portal."
    echo "Repository format: OWNER/REPO"
else
    echo "GitHub Repository: $REPO_OWNER/$REPO_NAME"
    
    # Check if federated credential already exists
    EXISTING_CRED=$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='github-actions-main'].name" -o tsv)
    
    if [ -z "$EXISTING_CRED" ]; then
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
        echo "Federated credential created"
    else
        echo "Federated credential already exists"
    fi
fi

echo ""

# Assign roles to service principal
echo "Assigning roles to service principal..."

# Contributor role for resource group
CONTRIBUTOR_ASSIGNED=$(az role assignment list --assignee "$SP_ID" --scope "/subscriptions/$CURRENT_SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP" --role "Contributor" --query "[0].roleDefinitionName" -o tsv)

if [ -z "$CONTRIBUTOR_ASSIGNED" ]; then
    az role assignment create \
        --assignee "$SP_ID" \
        --role "Contributor" \
        --scope "/subscriptions/$CURRENT_SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP" \
        --output table
    echo "Contributor role assigned"
else
    echo "Contributor role already assigned"
fi

# AcrPush role for container registry
ACR_ID=$(az acr show --name "$REGISTRY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
ACR_PUSH_ASSIGNED=$(az role assignment list --assignee "$SP_ID" --scope "$ACR_ID" --role "AcrPush" --query "[0].roleDefinitionName" -o tsv)

if [ -z "$ACR_PUSH_ASSIGNED" ]; then
    az role assignment create \
        --assignee "$SP_ID" \
        --role "AcrPush" \
        --scope "$ACR_ID" \
        --output table
    echo "AcrPush role assigned"
else
    echo "AcrPush role already assigned"
fi

echo ""

# Check VM setup
echo "Checking Azure VM configuration..."
VM_NAME=$(az vm list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)

if [ -z "$VM_NAME" ]; then
    echo ""
    echo "WARNING: No VM found in resource group $RESOURCE_GROUP"
    echo ""
    echo "This deployment assumes you have a VM set up (shared with dns-container)."
    echo "If you need to create a VM, please refer to the dns-container repository setup."
    echo ""
else
    VM_IP=$(az vm list-ip-addresses --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
    echo "Found VM: $VM_NAME"
    echo "Public IP: $VM_IP"
    
    # Check if Docker is installed on VM
    echo ""
    echo "Verifying Docker installation on VM..."
    DOCKER_CHECK=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "docker --version" \
        --query "value[0].message" -o tsv 2>/dev/null | grep -o "Docker version" || echo "")
    
    if [ -n "$DOCKER_CHECK" ]; then
        echo "Docker is installed on VM"
    else
        echo "WARNING: Docker may not be installed on VM. Please ensure Docker is installed."
    fi
    
    # Check NSG rules for port 8443
    echo ""
    echo "Checking Network Security Group rules for port 8443..."
    NSG_NAME=$(az network nsg list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
    
    if [ -n "$NSG_NAME" ]; then
        QUIC_RULE=$(az network nsg rule show \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "AllowQUIC" \
            --query "name" -o tsv 2>/dev/null || echo "")
        
        if [ -z "$QUIC_RULE" ]; then
            echo "Creating NSG rule for QUIC (port 8443 UDP+TCP)..."
            az network nsg rule create \
                --resource-group "$RESOURCE_GROUP" \
                --nsg-name "$NSG_NAME" \
                --name "AllowQUIC" \
                --priority 310 \
                --source-address-prefixes '*' \
                --source-port-ranges '*' \
                --destination-address-prefixes '*' \
                --destination-port-ranges 8443 \
                --access Allow \
                --protocol '*' \
                --direction Inbound \
                --description "Allow QUIC traffic on port 8443" \
                --output table
            echo "NSG rule created"
        else
            echo "NSG rule for QUIC already exists"
        fi
    else
        echo "WARNING: No NSG found. Please ensure port 8443 (TCP+UDP) is open."
    fi
fi

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
echo "Azure Resources:"
echo "  - Resource Group: $RESOURCE_GROUP (shared with dns-container)"
echo "  - Container Registry: $REGISTRY_NAME.azurecr.io"
echo "  - App Registration: $APP_NAME"

if [ -n "$VM_NAME" ]; then
    echo "  - VM: $VM_NAME"
    echo "  - Public IP: $VM_IP"
    echo ""
    echo "Service will be accessible at:"
    echo "  https://$VM_IP:8443"
fi

echo ""
