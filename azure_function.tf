# App Service Plan
resource "azurerm_service_plan" "demo" {
name = "demo-plan"
location = azurerm_resource_group.demo.location
resource_group_name = azurerm_resource_group.demo.name

os_type = "Linux"
	sku_name = "FC1" # Consumption plan
}

resource "azurerm_role_assignment" "kudu_role" {
  scope                = azurerm_function_app_flex_consumption.demo.id
  role_definition_name = "Website Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Generate SAS token for function code blob authorization
data "azurerm_storage_account_blob_container_sas" "sas" {
  connection_string = azurerm_storage_account.demo.primary_connection_string
  container_name    = azurerm_storage_container.function_code_container.name
  https_only        = true
  expiry            = timeadd(time_static.sas.rfc3339, "8760h")
  start             = time_static.sas.rfc3339
  permissions {
    read   = true
    add    = true
    create = false
    write  = false
    delete = true
    list   = true
  }

  cache_control       = "max-age=5"
  content_disposition = "inline"
  content_encoding    = "deflate"
  content_language    = "en-US"
  content_type        = "application/json"
}

# Linux Function App (best for Python) - name must be unique!
resource "azurerm_function_app_flex_consumption" "demo" {
  name                        = "tlc-function-app"
  resource_group_name         = azurerm_resource_group.demo.name
  location                    = azurerm_resource_group.demo.location
  service_plan_id             = azurerm_service_plan.demo.id
  storage_container_endpoint  = "https://${var.storage_account}.blob.core.windows.net/${var.storage_container}"#  storage_container_type     = "blobContainer"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.demo.primary_access_key
  storage_container_type      = "blobContainer"
  # Critical Flex Consumption Settings
  maximum_instance_count = 3
  instance_memory_in_mb  = 2048

  # The function.zip created later is deployed here 
#  zip_deploy_file = "${path.module}/function.zip"
  
  # Runtime specific configuration
  runtime_name        = "python"
  runtime_version     = "3.13"

#Necessary because the function upload and create can take a very long time
#  timeouts {
#    create = "90m"
#    update = "90m"
#    delete = "90m"
#  }

 # app_settings = {
    # Required for remote builds (Python/Node) -> conficts with WEBSITE_RUN_FROM_PACKAGE = 1
#    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
#    "ENABLE_ORYX_BUILD"              = "true"
#    "DEPLOYMENT_SOURCE_HASH" = filebase64sha256(data.archive_file.function_zip.output_path)
    # Standard setting for zip deployment - Consumption plan only accepts URL
    #"WEBSITE_RUN_FROM_PACKAGE" = "1"
#    "WEBSITE_RUN_FROM_PACKAGE" = "${azurerm_storage_blob.storage_blob_function.url}${data.azurerm_storage_account_blob_container_sas.sas.sas}"
#  }

  site_config {
    # CORS (Optional - example)
    cors {
      allowed_origins = ["https://azure.com","https://github.com","https://api.github.com"]  
    }

    # HTTP 2.0 (Optional)
    http2_enabled = true
  }
}

resource "terraform_data" "upload_function" {
  triggers_replace = {
    file_content_hash = filemd5("${path.module}/function_app.py")
  }
  provisioner "local-exec" {
    # Use bash to run the command and stream last line every second
    command = <<EOT
      set -euo pipefail
      TMPFILE=/tmp/func.out
      py -m venv .venv
      # Run the long-running command in the background, redirecting stdout to file
      ( func azure functionapp publish tlc-function-app --python > "$TMPFILE" 2>&1 ) &
      CMD_PID=$!

      # While the process is running, print the last line every second
      while kill -0 "$CMD_PID" 2>/dev/null; do
        tail -n 1 "$TMPFILE"
        sleep 10
      done
      
      tail -n 1 "$TMPFILE"

      rm -f "$TMPFILE"
    EOT

    interpreter = ["${var.bashpath}", "-c"]
  }
}

#resource "terraform_data" "bootstrap" {
##  triggers_replace = [azurerm_function_app_flex_consumption.demo]
#  provisioner "local-exec" {
#    command = ""
#  }
#}


resource "local_file" "azure_function" {
  filename = "function_app.py"
  content  = <<-EOT
# This is a generated script by Terraform azure_function.tf

import urllib3
import hmac
import hashlib
import json
import secrets
import functools
import jwt
import logging
import os
import time
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient

# Forces regeneration of the file
ts = time.time()

# Make all variables global so they are accessible within various definitions
global SUBSCRIPTION_ID, RESOURCE_GROUP, VM_NAME, JWT_SECRET 
SUBSCRIPTION_ID = "${data.azurerm_client_config.current.subscription_id}"
RESOURCE_GROUP = "${azurerm_resource_group.demo.name}"
VM_NAME = "Github-runner-1"
JWT_SECRET = "${data.azurerm_key_vault_secret.webhook.value}"
LOCATION = "${var.location}"
VM_SIZE = "${var.vm_size}"
ADMIN_PASS = "${var.adminpass}"

def verify_signature(body: bytes, header_signature: str) -> bool:
    secret = JWT_SECRET
    if not secret or not header_signature:
        return False
    
    # Compute the expected hash
    hash_object = hmac.new(secret.encode('utf-8'), msg=body, digestmod=hashlib.sha256)
    expected_signature = "sha256=" + hash_object.hexdigest()
    
    # Constant-time comparison to prevent timing attacks
    return hmac.compare_digest(expected_signature, header_signature)

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
@app.route(route="launch_vm", auth_level=func.AuthLevel.ANONYMOUS)

def launch_vm(req: func.HttpRequest) -> func.HttpResponse:
    """
        Validates the GH webhook secret via it's signature before anything else
    """
    
    body = req.get_body()
    signature = req.headers.get("X-Hub-Signature-256")

    if not verify_signature(body, signature):
      logging.warning("Invalid signature. Unauthorized, access denied, return code 401.")
      return func.HttpResponse("Unauthorized", status_code=401)

    """
        If we are here, the sha256 hash signature is good!
    """
    
    # Use DefaultAzureCredential to authenticate via Managed Identity
    credential = DefaultAzureCredential()
    
    # Initialize clients
    compute_client = ComputeManagementClient(credential, SUBSCRIPTION_ID)
    # Logic to provision VNet, Subnet, and NIC would go here...

    # Create the VM
    vm_parameters = {
        "location": LOCATION,
        "properties": {
        "storageProfile": {
            "imageReference": {
                "publisher": "Canonical",
                "offer": "0001-com-ubuntu-server-jammy",
                "sku": "22_04-lts-gen2",
                "version": "latest"
            }
        },
        "hardwareProfile": {"vmSize": VM_SIZE},
        "osProfile": {
            "computerName": VM_NAME,
            "adminUsername": "azureuser",
            "adminPassword": ADMIN_PASS
        },
        "networkProfile": {
            "networkInterfaces": [{"id": "/subscriptions/0ad4ae54-f248-4b6a-bbc7-aba5b7fb7a01/resourceGroups/DemoResourceGroup/providers/Microsoft.Network/networkInterfaces/TLC_Primary_Interface"}]
        }
     }
   }
    
    poller = compute_client.virtual_machines.begin_create_or_update(
        RESOURCE_GROUP, VM_NAME, vm_parameters
    )
    return func.HttpResponse(f"VM creation started: {poller.status()}")

  EOT
  file_permission = "0755" # Optional: set appropriate file permissions
}

# Data source to create the deployment package (ZIP file)
#data "archive_file" "function_zip" {
#  type        = "zip"
# List files individually
#  source {
#    content  = file("${path.module}/host.json")
#    filename = "host.json"
#  }
#  source {
#    content  = file("${path.module}/function_app.py")
#    filename = "function_app.py"
#  }
#  source {
#    content  = file("${path.module}/requirements.txt")
#    filename = "requirements.txt"
#  }
#  output_path = "function.zip"
#  depends_on = [
#    local_file.azure_function
#  ]
#}

# upload the zipped file to the container
#resource "azurerm_storage_blob" "storage_blob_function" {
#  name                   = "function.zip" # name of the blob in the contianer
#  source                 = "./function.zip" # path to the zip file
#  content_md5            = filemd5("./function.zip") # check if the zip file has changed
#  storage_account_name   = "${var.storage_account}"
#  storage_container_name = "${var.storage_container}"
#  type                   = "Block"
#  depends_on = [
#    azurerm_storage_account.demo,
#    local_file.azure_function,
#    data.archive_file.function_zip
#  ]
#}

# Register the webhook in GitHub
resource "github_repository_webhook" "tf_webhook" {
  #repository = "${var.repo_name}"
  repository = "tf-azure"
  configuration {
    url         = "https://tlc-function-app.azurewebsites.net/api/${var.function_code}"
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
