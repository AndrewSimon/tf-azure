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


## The azyre function python code is inline code within terraform
resource "local_file" "azure_function" {
  filename = "function_app.py"
  content  = <<-EOT
# This is a generated script by Terraform azure_function.tf

import base64
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
global SUBSCRIPTION_ID, RESOURCE_GROUP, VM_NAME, JWT_SECRET, USERDATA
SUBSCRIPTION_ID = "${data.azurerm_client_config.current.subscription_id}"
RESOURCE_GROUP = "${azurerm_resource_group.demo.name}"
NETWORK_INTERFACE = "${azurerm_network_interface.eth0.id}"
VM_NAME = "Github-runner-1"
JWT_SECRET = "${data.azurerm_key_vault_secret.webhook.value}"
LOCATION = "${var.location}"
VM_SIZE = "${var.vm_size}"
GH_PAT = '${var.token}'
REPO_NAME = '${var.repo_name}'
ADMIN_PASS = "${var.adminpass}"
MKT_OPT = "dynamic"
REGION = "${var.location}"

## While the function is inline python code sourced by terraform, this inline 
## cloud-init user-data, also in terraform, is sourced by the python function
USERDATA = f"""#!/bin/bash
# We can comment/remove install if GHR software is pre-installed on the vm image
RUNNER_VERSION=$(curl -s https://github.com/actions/runner/tags|grep releases/tag/v|head -n1|awk -F">v" '{{print $2}}'|awk -F"</" '{{print ""$1}}')
cd /home/azureuser
mkdir -p actions-runner 2>/dev/null
cd /home/azureuser/actions-runner
curl -o actions-runner-linux-x64-$RUNNER_VERSION.tar.gz -L https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz
tar xzf ./actions-runner-linux-x64-$RUNNER_VERSION.tar.gz && ./bin/installdependencies.sh

# Runner hook to complete dynamically provisioned instance lifecycle.
# Because there is a configurable maximum number of runners, first check
# the queue: if more jobs than runners, do not terminate
cat <<'EOF' > /home/azureuser/actions-runner/bin/complete_lifecycle.sh
trap 'exit 0' TERM
export QUEUED=$(curl -s -L   -H "Accept: application/vnd.github+json"   -H "Authorization: Bearer {GH_PAT}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/A{REPO_NAME}/actions/runs?sort=created&direction=desc&per_page=25"|grep  -E '"id": [0-9]{{10}}'| sort -r -u| awk '{{print $2}}'|sed -e  's/,//g' |while read x
do
curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer {GH_PAT}" -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/repos/{REPO_NAME}/actions/runs/$x/jobs
done | grep -e queued -e running |wc -l)
#export CNT=$(/home/azureuser/bin/aws ec2 describe-instance-status --instance-ids $(/home/azureuser/bin/aws ec2 describe-instances --filters "Name=tag:runner,Values=*" --query 'Reservations[].Instances[].InstanceId' --output text) --filters Name=instance-state-name,Values=running,pending --query "length(InstanceStatuses[?InstanceStatus.Status!='ok' || SystemStatus.Status!='ok'])")
CNT=1
if (( $CNT > $QUEUED )) || (( $QUEUED == 0 )) || (( $CNT >= 1 )) ; then
    echo "Server count $CNT is greater than jobs on the queue $QUEUED or QUEUED = 0 or CNT >= 1, shutting down now"
    #TOKEN=$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
    #INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" 169.254.169.254/latest/meta-data/instance-id)
    #REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" 169.254.169.254/latest/meta-data/placement/region)
    #/home/azureuser/bin/aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION
    shutdown -h now # perhaps install az cli and remove that way...
    exit 0
else
  echo "Keeping runners ($CNT) for jobs queued ($QUEUED). Not ending life-cycle, will let next job do it."
fi
EOF
# Comment out the below line to NOT terminate instance after running a job
echo ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/home/azureuser/actions-runner/bin/complete_lifecycle.sh >> /etc/environment
chmod +x /home/azureuser/actions-runner/bin/complete_lifecycle.sh
chown -R azureuser:azureuser /home/azureuser

# List workflow runs for a repo
RESPONSE=$(curl -s -H "Authorization: token {GH_PAT}" -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/{REPO_NAME}/actions/runs")

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
  shutdown -h now
fi
# Configure runner and connect to server
export DEFAULT_MAX=1
#TOKEN=$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
#export SUFFIX=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" 169.254.169.254/latest/meta-data/local-ipv4|awk -F. '{{print $4}}')
export SUFFIX=1
export RUNNER_TOKEN=$(curl -s -L -X POST -H "Accept: application/vnd.github+json" -H "Authorization: Bearer {GH_PAT}" -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/repos/{REPO_NAME}/actions/runners/registration-token| grep token|awk -F\\" '{{print $4}}')
sudo -u azureuser bash -c "cd /home/azureuser/actions-runner && ./config.sh remove --token $RUNNER_TOKEN"
sudo -u azureuser bash -c "cd /home/azureuser/actions-runner/ && ./config.sh --url https://github.com/{REPO_NAME} --token $RUNNER_TOKEN --unattended --replace --name tlc-{MKT_OPT}-runner-$SUFFIX"
nohup sudo -u azureuser bash -c 'cd /home/azureuser/actions-runner && ./run.sh' &
"""


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
    global USERDATA
    # encode user-data
    USERDATA = base64.b64encode(USERDATA.encode('utf-8')).decode('utf-8')
    
    # Use DefaultAzureCredential to authenticate via Managed Identity
    credential = DefaultAzureCredential()
    
    # Initialize clients
    compute_client = ComputeManagementClient(credential, SUBSCRIPTION_ID)
    # Logic to provision VNet, Subnet, and NIC would go here...

    # Create the VM
    vm_parameters = {
        "location": LOCATION,
        "properties": {
        "userData": USERDATA,
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
            "adminPassword": ADMIN_PASS,
        },
        "networkProfile": {
            "networkInterfaces": [{"id": NETWORK_INTERFACE}]
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
