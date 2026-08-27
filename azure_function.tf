# App Service Plan
resource "azurerm_service_plan" "demo" {
name = "demo-plan"
location = azurerm_resource_group.demo.location
resource_group_name = azurerm_resource_group.demo.name

os_type = "Linux"
	sku_name = "FC1" # Consumption plan
}

# App registration with Entra ID and Password below it
resource "azuread_application" "function_auth" {
  display_name     = "tlc-function-app-auth"
  sign_in_audience = "AzureADMyOrg"
}
resource "azuread_application_password" "function_auth_secret" {
  application_id = azuread_application.function_auth.id
}

# Assign the Contributor role to the Function App's identity
resource "azurerm_role_assignment" "contributor" {
  scope                = azurerm_resource_group.demo.id # What access is to
  role_definition_name = "Contributor"
  principal_id         = azurerm_function_app_flex_consumption.demo.identity[0].principal_id # Who gets above access
  depends_on = [
    azurerm_function_app_flex_consumption.demo
  ]
}

# Place-holder for future dev
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
  maximum_instance_count = 2
  instance_memory_in_mb  = 512

  # Runtime specific configuration
  runtime_name        = "python"
  runtime_version     = "3.13"

  auth_settings_v2 {
    auth_enabled           = true
    unauthenticated_action = "AllowAnonymous" # Not as safe but we have web secret and CORS too
    default_provider       = "azureactivedirectory"
    active_directory_v2 {
      client_id                  = azuread_application.function_auth.client_id
      client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
      tenant_auth_endpoint   = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0/"
    }
    login {}
  }

  app_settings = {
    "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET" = azuread_application_password.function_auth_secret.value
#    "WEBSITE_LOCAL_CACHE_OPTION" = "Never"
#    "WEBSITE_FUNCTIONS_ARMCACHE_ENABLED" = "0"
  }
  
  always_ready {
    name  = "http" 
    instance_count = 1 # Set to 1 or higher to enable Always Ready
  }

  site_config {
    # CORS (CORS applies to browsers, mostly)
    cors {
      allowed_origins = ["https://portal.azure.com","https://azure.com","https://github.com","https://api.github.com"]
    }
    # HTTP 2.0 (Optional)
    http2_enabled = true
        # Native Application Insights Activation 
    application_insights_connection_string = azurerm_application_insights.demo.connection_string
    application_insights_key               = azurerm_application_insights.demo.instrumentation_key
  }
  
  # Activate the System Assigned Managed Identity so function has access to do stuff in Azure
  identity {
    type = "SystemAssigned"
  }
}

## This custom resource is a more reliable upload than via flex app resource above.
## Additionally, this custom resource can manage the function life-cycle 
## independently from the flex app resource
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
  depends_on = [
    azurerm_function_app_flex_consumption.demo
  ]
}

## The azyre function python code is inline code within terraform
resource "local_file" "azure_function" {
  filename = "function_app.py"
  content  = <<-EOT
# This is a generated script by Terraform azure_function.tf

import asyncio
import base64
import binascii
import urllib3
import hmac
import hashlib
import json
import secrets
import functools
import jwt
import logging
import os
import sys
import datetime
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.compute.models import VirtualMachinePriorityTypes, VirtualMachineEvictionPolicyTypes, BillingProfile

# Create suffix to use for device/resource names
SUFFIX = datetime.datetime.now().strftime("%H%M%S")
# Required for terraform-python compatibility
true = True
SUBSCRIPTION_ID = "${data.azurerm_client_config.current.subscription_id}"
RESOURCE_GROUP = "${azurerm_resource_group.demo.name}"
JWT_SECRET = "${data.azurerm_key_vault_secret.webhook.value}"
LOCATION = "${var.location}"
VM_SIZE = "${var.vm_size}"
GH_PAT = '${var.token}'
REPO_NAME = '${var.repo_name}'
ADMIN_PASS = "${var.adminpass}"
MKT_OPT = '${var.mkt_opt}'
REGION = "${var.location}"
NAME = "Github-runner-"
NIC_BNAME = "GH-runner-nic-"
IP_BNAME = "GH-runner-ip-"
DISK_BNAME = "GH-runner-disk-"
VM_NAME = NAME + SUFFIX
NIC_NAME = NIC_BNAME + SUFFIX
IP_NAME = IP_BNAME + SUFFIX
DISK_NAME = DISK_BNAME + SUFFIX
SUBNET_ID = "${azurerm_subnet.public.id}"
NSG_ID = "${azurerm_network_security_group.public.id}"
UAI_ID = "${azurerm_user_assigned_identity.vm_identity.id}"

## Define vm identity here so the value can be passed in via empty dict at vm creation
IDENTITY_RESOURCE_ID = (
    f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-vm-contributor"
)
## While the function is inline python code sourced by terraform, this inline 
## cloud-init user-data, also in terraform, is sourced by the python function

def is_valid_base64(encoded_str):
    """
    Checks if a string is a valid Base64 encoded string. If ok, then we can see if it decoded ok below
    """
    # Base64 strings must be a multiple of 4 in length
    # Add standard '=' padding if it's missing
    missing_padding = len(encoded_str) % 4
    if missing_padding:
        encoded_str += '=' * (4 - missing_padding)

    try:
        # Validate = True strictly checks for non-Base64 characters
        base64.b64decode(encoded_str, validate=True)
        return True
    except (binascii.Error, ValueError, TypeError):
        return False

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
        If we are here, the sha256 hash signature is good! Now check to see if userdata is good.
    """
    global USERDATA, NAME, SUFFIX, VM_NAME, NIC_NAME, IP_NAME, DISK_NAME
    SUFFIX = datetime.datetime.now().strftime("%H%M%S") # Recalculate SUFFIX each launch_vm run
    VM_NAME = NAME + SUFFIX
    NIC_NAME = NIC_BNAME + SUFFIX
    IP_NAME = IP_BNAME + SUFFIX
    DISK_NAME = DISK_BNAME + SUFFIX

    USERDATA = f"""#!/bin/bash
    apt-get install jq -y
    # We can comment/remove install if GHR software is pre-installed on the vm image
    RUNNER_VERSION=$(curl -s https://github.com/actions/runner/tags|grep releases/tag/v|head -n1|awk -F">v" '{{print $2}}'|awk -F"</" '{{print ""$1}}')
    cd /home/azureuser
    mkdir -p actions-runner 2>/dev/null
    cd /home/azureuser/actions-runner
    curl -o actions-runner-linux-x64-$RUNNER_VERSION.tar.gz -L https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz
    tar xzf ./actions-runner-linux-x64-$RUNNER_VERSION.tar.gz && ./bin/installdependencies.sh
    ln -s /usr/bin/python3 /usr/bin/python 2>/dev/null

    # Runner hook to complete dynamically provisioned instance lifecycle.
    # Because there is a configurable maximum number of runners, first check
    # the queue: if more jobs than runners, do not terminate
    cat <<'EOF' > /home/azureuser/actions-runner/bin/complete_lifecycle.sh
    trap 'exit 0' TERM
    RESPONSE=$(curl -s -H "Authorization: token {GH_PAT}" -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/{REPO_NAME}/actions/runs")
    PENDING_COUNT=$(echo "$RESPONSE" | awk -F'[,:"]' '
      /"status":/ {{
          if ($5 == "queued") {{
              count++
          }}
        }}
        END {{ print count+0 }}
      ')
    echo "Number of pending jobs: $PENDING_COUNT"
    if (( $PENDING_COUNT == 0 )) ; then
      echo "No jobs pending, this runner is not needed, terminating in 5 seconds!"
      sleep 5
      TOKEN=$(curl -s -G -H "Metadata: true" --noproxy "*" "http://169.254.169.254/metadata/identity/oauth2/token" --data-urlencode "api-version=2018-02-01" --data-urlencode "resource=https://management.azure.com/" | jq -r .access_token)
      curl -X DELETE -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/{VM_NAME}?api-version=2025-11-01"
      exit 0
    else
      echo "This runner just got another job assigned! Keeping runner! Not ending life-cycle, will let next job do it."
    fi
EOF
    # Comment out the below line to NOT terminate instance after running a job
    echo ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/home/azureuser/actions-runner/bin/complete_lifecycle.sh >> /etc/environment
    chmod +x /home/azureuser/actions-runner/bin/complete_lifecycle.sh
    chown -R azureuser:azureuser /home/azureuser

    # List workflow runs for a repo
    RESPONSE=$(curl -s -H "Authorization: token {GH_PAT}" -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/{REPO_NAME}/actions/runs")
    # Checking queue (only) as this VM definitely not 'busy' yet
    # Use awk to parse the json and count runs
    # It looks for "status" key and counts if it is "queued"
    PENDING_COUNT=$(echo "$RESPONSE" | awk -F'[,:"]' '
        /"status":/ {{
            if ($5 == "queued") {{
                count++
            }}
        }}
        END {{ print count+0 }}
    ')
    echo "Number of pending jobs: $PENDING_COUNT"
    if (( $PENDING_COUNT == 0 )) ; then
      echo "No jobs pending, this runner is not needed, terminating in 5 seconds!"
      sleep 5
      TOKEN=$(curl -s -G -H "Metadata: true" --noproxy "*" "http://169.254.169.254/metadata/identity/oauth2/token" --data-urlencode "api-version=2018-02-01" --data-urlencode "resource=https://management.azure.com/" | jq -r .access_token)
      curl -X DELETE -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/{VM_NAME}?api-version=2025-11-01"
      exit 0
    fi

    # Configure runner and connect to server
    export DEFAULT_MAX=1
    TOKEN=$(curl -s -G -H "Metadata: true" --noproxy "*" "http://169.254.169.254/metadata/identity/oauth2/token" --data-urlencode "api-version=2018-02-01" --data-urlencode "resource=https://management.azure.com/" | jq -r .access_token)
    export RUNNER_TOKEN=$(curl -s -L -X POST -H "Accept: application/vnd.github+json" -H "Authorization: Bearer {GH_PAT}" -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/repos/{REPO_NAME}/actions/runners/registration-token| grep token|awk -F\\" '{{print $4}}')
    sudo -u azureuser bash -c "cd /home/azureuser/actions-runner && ./config.sh remove --token $RUNNER_TOKEN"
    sudo -u azureuser bash -c "cd /home/azureuser/actions-runner/ && ./config.sh --url https://github.com/{REPO_NAME} --token $RUNNER_TOKEN --unattended --replace --name tlc-{MKT_OPT}-runner-{SUFFIX}"
    nohup sudo -u azureuser bash -c 'cd /home/azureuser/actions-runner && ./run.sh' &
    """

    # encode user-data - convert to utf-8 first then use b64encode
    encoded_user_data = base64.b64encode(USERDATA.encode('utf-8')).decode('utf-8')
    
    if is_valid_base64(encoded_user_data):
    # Decode and convert the bytes back to a UTF-8 string
      decoded_bytes = base64.b64decode(encoded_user_data)
      decoded_text = decoded_bytes.decode('utf-8')
    # This is hard-coded to ensure valid bash at beginning of file
      if decoded_text.startswith("#!/bin/bash"):
        print("File starts with #!/bin/bash!")
        print(f"Decoded successfully: {decoded_text}")
        USERDATA = encoded_user_data
      else:
        print(f"Decode failed: {decoded_text}")
        return func.HttpResponse("UserData did not decode and/or #!/bin/bash is missing from the first line. \nAzure may need a minute or two before providing another properly configured VM.", status_code=429)
    
    # Use DefaultAzureCredential to authenticate via Managed Identity
    credential = DefaultAzureCredential(additionally_allowed_tenants=["*"])
    
    # Initialize clients
    compute_client = ComputeManagementClient(credential, SUBSCRIPTION_ID)
    network_client = NetworkManagementClient(credential, SUBSCRIPTION_ID)
    
    # Create Public IP
#    print("Creating public IP address...")
#    ip_poller = network_client.public_ip_addresses.begin_create_or_update(
#      RESOURCE_GROUP,
#      IP_NAME,
#      {
#        "location": LOCATION,
#        "sku": {"name": "Standard"},
#        "public_ip_allocation_method": "Static",
#        "deleteOption": "Delete"
#      }
#    )
#    ip_result = ip_poller.result()
    
    # Create NIC
    print(f"Creating NIC without public IP: {NIC_NAME}")
    nic_poller = network_client.network_interfaces.begin_create_or_update(
      RESOURCE_GROUP,
      NIC_NAME,
      {
        "location": LOCATION,
        "properties": {
        "ipConfigurations": [{
            "name": "internal",
            "properties": {
              "subnet": {"id": SUBNET_ID},
            }
          }],
        "NetworkSecurityGroup": {"id": NSG_ID}
        }
      }
    )
## We don't need nic result as that value is derived below
##    nic_result = nic_poller.result()   

    # Create the VM
    vm_parameters = {
        "location": LOCATION,
        "identity": {
          "type": "UserAssigned",  # Use "SystemAssigned, UserAssigned" if enabling both
          "userAssignedIdentities": {
            IDENTITY_RESOURCE_ID: {}  # Must be an empty dictionary
        }
      },
        "properties": {
        "billingProfile": {
          "maxPrice": -1 # -1 indicates the VM will be billed at the current price of a Spot VM
        },
        "evictionPolicy": "Delete",
        "userData": USERDATA,
        "storageProfile": {
            "osDisk": {
              "name": DISK_NAME,
              "createOption": "FromImage",
              "deleteOption": "Delete"
              },
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
            "adminPassword": ADMIN_PASS,
        },
         "networkProfile": {
            "networkInterfaces": [{
              "id": f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/networkInterfaces/{NIC_NAME}",
              "properties": {
                "deleteOption": "Delete"
                }
              }]
        }
      }
   }
    if MKT_OPT.lower() == 'spot':
      vm_parameters['properties']['priority'] = VirtualMachinePriorityTypes.spot
      
    try:
      print(f"Creating VM with public IP: {VM_NAME}")
      poller = compute_client.virtual_machines.begin_create_or_update(
        RESOURCE_GROUP, VM_NAME, vm_parameters
      )
      return func.HttpResponse(f"VM creation started: {VM_NAME}")
    except Exception as e:
      print("Error creating VM:", e)  
      return func.HttpResponse(str(e), status_code=500)
  EOT
  file_permission = "0755" # Optional: set appropriate file permissions
}

# Create the Log Analytics Workspace
resource "azurerm_log_analytics_workspace" "demo" {
  name                = "lw-flex-consumption-demo"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# Create the Application Insights Component
resource "azurerm_application_insights" "demo" {
  name                = "ai-flex-consumption-prod"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  workspace_id        = azurerm_log_analytics_workspace.demo.id
  application_type    = "web"
}

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
