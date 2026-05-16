data "azurerm_client_config" "current" {}

output "subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}
# App Service Plan
resource "azurerm_service_plan" "demo" {
name = "demo-plan"
location = azurerm_resource_group.demo.location
resource_group_name = azurerm_resource_group.demo.name
os_type = "Linux"
	sku_name = "FC1" # Consumption plan
}

# Linux Function App (best for Python) - name must be unique!
resource "azurerm_function_app_flex_consumption" "demo" {
  name                       = "tlc-function-app"
  resource_group_name        = azurerm_resource_group.demo.name
  location                   = azurerm_resource_group.demo.location
  service_plan_id            = azurerm_service_plan.demo.id
  storage_container_endpoint = "https://tlcdemostorageaccount.blob.core.windows.net/function-code"
  storage_container_type     = "blobContainer"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.demo.primary_access_key
  # Critical Flex Consumption Settings
  maximum_instance_count = 3
  instance_memory_in_mb  = 2048
  
  # Runtime specific configuration
  runtime_name        = "python"
  runtime_version     = "3.12"

  site_config {
    # CORS (Optional - example)
    cors {
      allowed_origins = ["https://azure.com","https://github.com","https://api.github.com"]  
    }

    # HTTP 2.0 (Optional)
    http2_enabled = true
  }
}

resource "local_file" "azure_function" {
  filename = "function.py"
  content  = <<-EOT

# This is a generated script by Terraform lambda_handler.tf

import sys
import logging
import urllib3
import hmac
import hashlib
import json
import secrets
from hmac import compare_digest
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.resource import ResourceManagementClient


# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

SUBSCRIPTION_ID = '{data.azurerm_client_config.current.subscription_id}'
# These are currently defined in main.tf, they are not variables, yet
GROUP_NAME = "DemoResourceGroup"
VM_NAME = "Dynamic GHR VM1"
NETWORK_NAME = "demo"
SUBNET_NAME = "Public"
INTERFACE_NAME = "TLC_Primary_Interface"

# Create clients
resource_client = ResourceManagementClient(credential=DefaultAzureCredential(), subscription_id=SUBSCRIPTION_ID)
network_client = NetworkManagementClient(credential=DefaultAzureCredential(), subscription_id=SUBSCRIPTION_ID)
compute_client = ComputeManagementClient(credential=DefaultAzureCredential(), subscription_id=SUBSCRIPTION_ID)

# Create resource group
resource_client.resource_groups.create_or_update(
    GROUP_NAME,
    {"location": "eastus"}
)

# Create virtual network and subnet
network_client.virtual_networks.begin_create_or_update(
    GROUP_NAME,
    NETWORK_NAME,
    {"location": "eastus", "address_space": {"address_prefixes": ["10.0.0.0/16"]}}
).result()

network_client.subnets.begin_create_or_update(
    GROUP_NAME,
    NETWORK_NAME,
    SUBNET_NAME,
    {"address_prefix": "10.0.0.0/24"}
).result()

# Create network interface
network_client.network_interfaces.begin_create_or_update(
    GROUP_NAME,
    INTERFACE_NAME,
    {"ip_configurations": [{"name": "ipconfig1", "subnet": {"id": f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{GROUP_NAME}/providers/Microsoft.Network/virtualNetworks/{NETWORK_NAME}/subnets/{SUBNET_NAME}"}]}
).result()

# Create VM
compute_client.virtual_machines.begin_create_or_update(
    GROUP_NAME,
    VM_NAME,
    {
        "location": "eastus",
        "properties": {
            "hardwareProfile": {"vmSize": "Standard_B1s"},
            "storageProfile": {
                "imageReference": {
                    "publisher": "MicrosoftWindowsServer",
                    "offer": "WindowsServer",
                    "sku": "2022-Datacenter",
                    "version": "latest"
                },
                "osDisk": {
                    "name": f"{VM_NAME}-osdisk",
                    "caching": "ReadWrite",
                    "createOption": "FromImage"
                }
            },
            "networkProfile": {
                "networkInterfaces": [{
                    "id": f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{GROUP_NAME}/providers/Microsoft.Network/networkInterfaces/{INTERFACE_NAME}"
                }]
            }
        }
    }
).result()

  EOT
  file_permission = "0755" # Optional: set appropriate file permissions
}

# Data source to create the deployment package (ZIP file)
data "archive_file" "function_zip" {
  type        = "zip"
  source_file = "function.py"
  output_path = "function.zip"
  depends_on = [
    local_file.azure_function
  ]
}

# upload the zipped file to the container
resource "azurerm_storage_blob" "storage_blob_function" {
  name                   = "function.zip" # name of the blob in the contianer
  source                 = "./function.zip" # path to the zip file
  content_md5            = filemd5("./function.zip") # check if the zip file has changed
  storage_account_name   = "${var.storage_account}"
  storage_container_name = "${var.storage_container}"
  type                   = "Block"
  depends_on = [
    azurerm_storage_account.demo,
    local_file.azure_function,
    data.archive_file.function_zip
  ]
}

# Register the webhook in GitHub
resource "github_repository_webhook" "tf_webhook" {
  #repository = "${var.repo_name}"
  repository = "tf-azure"
  configuration {
    url         = "https://tlc-function-app.azurewebsites.net/webhook"
    content_type = "json"
    # The secret is stored securely in vault and passed here
    secret       = data.azurerm_key_vault_secret.webhook.value
    insecure_ssl = false
  }
  active = true
  events = ["push"] # Choose the events you need
  
  depends_on = [
    github_actions_secret.webhook_secret
  ]
}
