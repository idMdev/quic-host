#!/bin/bash
# Azure infrastructure setup script for QUIC Host VM deployment

set -e

# Configuration
RESOURCE_GROUP="dns-container-rg"
LOCATION="eastus"
REGISTRY_NAME="quichostacr1"
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
    
    # Configure VM with system-assigned managed identity
    echo ""
    echo "Configuring VM with system-assigned managed identity..."
    VM_IDENTITY=$(az vm identity show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query principalId -o tsv 2>/dev/null)
    
    if [ -z "$VM_IDENTITY" ]; then
        echo "Assigning system-assigned managed identity to VM..."
        VM_IDENTITY=$(az vm identity assign \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --query principalId -o tsv)
        echo "Managed identity assigned: $VM_IDENTITY"
        
        # Wait for identity to propagate
        echo "Waiting for identity to propagate (15 seconds)..."
        sleep 15
    else
        echo "VM already has managed identity: $VM_IDENTITY"
    fi
    
    # Assign AcrPull role to VM's managed identity
    echo ""
    echo "Assigning AcrPull role to VM's managed identity..."
    ACR_ID=$(az acr show --name "$REGISTRY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
    VM_ACR_PULL_ASSIGNED=$(az role assignment list --assignee "$VM_IDENTITY" --scope "$ACR_ID" --role "AcrPull" --query "[0].roleDefinitionName" -o tsv)
    
    if [ -z "$VM_ACR_PULL_ASSIGNED" ]; then
        az role assignment create \
            --assignee "$VM_IDENTITY" \
            --role "AcrPull" \
            --scope "$ACR_ID" \
            --output table
        echo "AcrPull role assigned to VM's managed identity"
        
        # Wait for role assignment to propagate
        echo "Waiting for role assignment to propagate (15 seconds)..."
        sleep 15
    else
        echo "AcrPull role already assigned to VM's managed identity"
    fi
    
    # Install Azure CLI on VM if not present
    echo ""
    echo "Ensuring Azure CLI is installed on VM..."
    AZ_CLI_CHECK=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "az version 2>/dev/null || echo 'not installed'" \
        --query "value[0].message" -o tsv | grep -o "azure-cli" || echo "")
    
    if [ -z "$AZ_CLI_CHECK" ]; then
        echo "Installing Azure CLI on VM (this may take a few minutes)..."
        echo "Note: Using Microsoft's official installation script from packages.microsoft.com"
        az vm run-command invoke \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --command-id RunShellScript \
            --scripts \
                "# Install Azure CLI using package manager (more secure than piped curl)" \
                "curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null" \
                "AZ_REPO=\$(lsb_release -cs)" \
                "echo \"deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ \$AZ_REPO main\" | sudo tee /etc/apt/sources.list.d/azure-cli.list" \
                "sudo apt-get update" \
                "sudo apt-get install -y azure-cli" \
            --query "value[0].message" -o tsv
        echo "Azure CLI installed on VM"
    else
        echo "Azure CLI is already installed on VM"
    fi
    
    # Check NSG rules for ports 443 and 8443
    echo ""
    echo "Checking Network Security Group rules for ports 443 and 8443..."
    NSG_NAME=$(az network nsg list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
    
    if [ -n "$NSG_NAME" ]; then
        # Check for port 443 rule
        HTTPS_RULE=$(az network nsg rule show \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "AllowHTTPS" \
            --query "name" -o tsv 2>/dev/null || echo "")
        
        if [ -z "$HTTPS_RULE" ]; then
            echo "Creating NSG rule for HTTPS (port 443 TCP+UDP)..."
            az network nsg rule create \
                --resource-group "$RESOURCE_GROUP" \
                --nsg-name "$NSG_NAME" \
                --name "AllowHTTPS" \
                --priority 300 \
                --source-address-prefixes '*' \
                --source-port-ranges '*' \
                --destination-address-prefixes '*' \
                --destination-port-ranges 443 \
                --access Allow \
                --protocol '*' \
                --direction Inbound \
                --description "Allow HTTPS traffic on port 443 (forwarded to 8443)" \
                --output table
            echo "NSG rule for port 443 created"
        else
            echo "NSG rule for port 443 already exists"
        fi
        
        # Check for port 8443 rule
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
            echo "NSG rule for port 8443 created"
        else
            echo "NSG rule for port 8443 already exists"
        fi
    else
        echo "WARNING: No NSG found. Please ensure ports 443 and 8443 (TCP+UDP) are open."
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
    echo "  - https://$VM_IP:443 (forwarded to container)"
    echo "  - https://$VM_IP:8443 (direct container access)"
fi

echo ""
