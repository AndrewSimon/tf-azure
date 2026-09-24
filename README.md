# TF-AZURE
> This project works in 2 parts. The first part is the Infrastructure as Code provisioned vis Terraform, and the second part is the Github Actions Workflow contained within this project. The terraform plan must run on a local device first, and some manual setup, described later, is required for the first manual run of Terraform plan and apply to succeed.  The terraform plan will:

1.  Create a resource group for your 'demo' virtual network
2.  Create 'demo' virtual network and 2 subnets, 1 'public' and 1 'private'
3.  Create 2 NSG for the two subnets to restrict traffic, accordingly
4.  Create a storage account and blob container for the Function App
5.  Creates a static Virtual Machine with disk and os pre-configured, if enabled
6.  Assign a public IP for a VM instance (when enabled, defaults to disabled)
7.  Output the public IP so you can connect to your instance, if you enabled it
8.  Creates a key vault, key policy, and password secret (PostgreSQL and/or VM login)
9.  Creates a PostgreSQL Flexible server with IP f/w access rule, when db name set
10. Creates an Azure Function to launch VMs dynamically (request VM quotas manually)
11. Creates a Github webhook with secret (stored in vault) and Azure API endpoint url
12. Creates an analytics workspace and Insights components
13. Creates an IAM (RBAC) user-assigned identity and (admin) role for dynamic Self-Hosted runner VMs to use to self-delete
14. Creates an IAM (RBAC) user-assigned identity for Github Hosted Actions Runner OIDC clients with (admin) permission to use for terraform

>The second part of the project is the Github Actions Workflow, which consists of two configurable jobs, plus the job completion hook:.  

1. The first job is more-or-less OPTIONAL. It runs the exact same terraform plan you just ran by hand first 
2. The second job of the Github Actions workflow is the 'complete-lifecycle' job, where the running of arbitrary workflow steps, such as a docker-in-docker build server or a k8s server can be installed and added as jobs or new pipelines
3. The end of job 2 triggers the ACTIONS_RUNNER_HOOK_JOB_COMPLETED script installed by the Function App at VM launch

## Requirements
> Install the following:

1. AzureCli
2. Git client
3. Terraform
4. Python
5. Azure Functions Core Tools

## Git Client Install on your local device:
```
https://git-scm.com/book/en/v2/Getting-Started-Installing-Git
```

## tf-azure Install Instructions
1. Change directory to the location you want your terraform plan to be, usually your home directory     
2. Using the git command-line, clone and checkout the 'dynamic-ghr' branch, which is newest:

```
git clone -b dynamic-ghr https://github.com/AndrewSimon/tf-azure
```

## Install Azure Function Core Tools 
> https://learn.microsoft.com/en-us/azure/azure-functions/how-to-create-function-azure-cli

## Install Python and modules
>https://www.python.org/downloads/

1. py -m pip install signify # Windows example, repeat for all needed modules
2. py -m pip install -r requirements.txt # Do this after all modules needed are installed
 
## Create/Configure the Python Virtual Environment for Azure Functions 
 
 1. cd tf-azure
 2. py -3.13 -m venv .venv (Windows) or python -m venv .venv (Linux) # As of writing, python3.14  remote build not supported yet
 3. ./.venv/Scripts/activate (e.g. windows via git bash)
 

## Create Azure storage for Terraform backend via Portal UI
>Create a resource group and storage account to be used in Terraform configuration setup below

1. Resource group name --> terraform-state 
2. Storage account name --> your_unique_storage_account_name  (must be unique across all Azure)
3. Data Storage --> Containers --> + Add container --> demo-tf-state
 
## Request Azure App Function Quota for App Service in your Subscription

1. Request 1 VM or more for App Service to use to run the python function containers
2. Request 10 or more LowPriorityCores for spot VMs (az quota create --resource-name "LowPriorityCores" --scope ...)

1. Quotas|My quotas --> Subscriptions --> Azure Subscription Name
2. Provider: App Service --> Region (select the region to deploy)
3. Select the VM type, the 'B1' is small and affordable. It only needs to run our small python script (which, when triggered by the Webhook, starts another, bigger if need be, VM that will be our GH Runner VM).

## Terraform configuration setup
>Update the main.tf azurerm backend with the newly created storage account name from above

1. After installing above requirements, clone this repo.
2. cd tf-azure, edit main.tf --> change 'storage_account_name = "your_unique_storage_account_name"
3. Edit variables.tf --> change values such as database name, function name, and skus to match your conventions and environment 

## Log into Azure via AzureCli
> az login

## Pip installs on Windows, upgrade pip3 and install modules
1. python3.9.exe -m pip install --upgrade pip

## Terraform Usage example

1. terraform init --upgrade # Perform only once, after first git clone
2. touch function_app.py # Necessary first time for filemd5 to work 
3. export TF_VAR_token=<i>your_github_personal_access_token</i> # to skip, source from profile
4. export TF_VAR_adminpass=<i>your_strong_admin_password</i> # or source from profile
5. terraform plan 
6. terraform apply -auto-approve  # NOTE: Run TWICE if first run!  And, read COSTS below!
7. terraform destroy -target=terraform_data.upload_function #Do this before loading python function updates
8. terraform destroy -target=azurerm_key_vault_secret.adminpass #Do this before applying (MSSQL) admin password updates
9. terraform destroy #deletes ALL of the remaining resources created by this plan.  

Note: due to Azure vault design, destroying vault purges secrets, which awaits a 10 minute timeout. It will complete normally but if you do not want to wait, CTL+C to exit, then, re-run terraform destroy to remove remaining resources. The terraform backend storage account you created by hand will not be destroyed.
--> After a terraform apply, be sure to refresh Azure portal screens before viewing/using data fields.


## Run Terraform via TF-AZURE Github Actions Workflow
> As mentioned, the workflow is in two jobs.  The first job fails on the first run because none of the resources for job one to run properly have been created yet.  Once run successfully manually, the resource group, managed identities, the Function App Flex Plan SKU, Insights monitoring, and many other resources are created or configured; but the first job fails, this time due to vault data and role access denial. Vault key and secrets, and problem role can be deleted manually using your account, and the Github hosted runners can now recreate them. This turns manual terraform control over to Guthub Actions runners. Deleting the problematic configuration data is an easy manual step:

1. terraform destroy -auto-approve -target azurerm_key_vault_secret.adminpass -target azurerm_key_vault_secret.token -target azurerm_key_vault_secret.webhook -target azurerm_key_vault_key.key -target azurerm_role_assignment.rg_contributor



> A targeted manual terraform destroy can then act as the switch that turns control over to the first job of the Github Actions workflow.  Once the targeted manual terraform destroy is run, configuration to run terraform ONLY THROUGH GITHUB ACTIONS WEBHOOK TRIGGER has been enabled, and job one of the workflow begins to  work properly.  Simply push a repository update to trigger both terraform and runner jobs. Your command-line account will now fail a terraform plan!  Github runner's OIDC account owns vault key and the role assignment.  

>You need to run the same terraform destroy you ran manually within a runner job this time, to destroy  the Azure resources your account won't have access to.  You can then complete a destroy with terraform destroy on command-line using your own account, or delete anything through the portal UI.  

## Postgresql
>By default the public IP option is enabled, but only your PC (e.g. the PC running terraform) gets firewall access without additional coding.  Login example, enter password when prompted:

 psql -h tlc-db-primary.postgres.database.azure.com -U "psqladmin" -d postgres -W
 
 
## Post Python steps
>Once able to build python and run successfully in your Azure Core API Tools environment locally, give a detailed update to requirements.txt. Though not strictly necessary, Azure Functions can fail with module version mismatches.

1. pip freeze > requirements.txt
2. Edit requirements.txt and remove all local path requirements, leave only entries that have the module name and version (only), like <b>urllib3==1.26.20</b>

## Trouble-shooting
    
   1. If 'no file exists at ./function_app.py' or 'file not found': run 'touch function_app.py' then re-run 'terraform apply/destroy'.  
   2. File is 'inconsistent' or Function app is created but not the function: re-run terraform apply.
   3. The upload function runs but there is still no function in the function app:  check for missing dependencies.  Try running 'pip install -r requirements.txt' then re-run terraform apply.
   4. Still no Azure Function and/or upload fails even though there are no errors in the function when running locally: delete the Function App manually through UI, run number 7 from above, <i>terraform destroy -target=terraform_data.upload_function</i>, then re-run terraform apply.
   5. You manually deleted the webhook but terraform isn't recreating it: run terraform destroy -target=github_repository_webhook.tf_webhook
   6. If you successfully installed Function App Core Tools, you will be able to run <i>func start</i> in the tf-azure directory and start a local Function App. You can post data with curl, fiddler or other client to <i>http://localhost:7071/api/launch_vm</i> and output not directed to the client will come into the screen running <i>func start</i> as standard error and standard out.  Trouble-shoot locally, as able.
   7. Return 401 Requires authentication [] on one or more secrets. Run <i>terraform apply -var=token=your_token</i> as exporting gh token as environment variable does not always work.
   8. If your function uploads but gives error 500, it means your function ran (mostly) ok!  Likely a problem with the values python is getting from terraform, such as a password that does not meet minimum requirements, Azure quota limits on functions or VMs, capacity problems in your selected region, etc.  For osProfile.adminPassword error, you must reset password, and to do that, you must run terraform destroy -target=azurerm_key_vault_secret.adminpass first.
   9. VM is running but not registering as a github runner: anything to do with registering or de-registering azure resources to/for the VM is via the user-data section of the embedded python code. Delete the Function App and the function_app.py file and re-run terraform apply.  Ensure the function uploads again.
   10.  Return Code 429 from Github webhook response. This custom message: <b>UserData did not decode.  Azure needs a minute or two before providing another useful VM.</b> is provided via python definition to catch any user-data decode issue.  This is some sort of caching bug in Azure Function launch affecting decoding of the encoded VM user-data. It takes about 2 minutes for the Azure Function to be 'reset' on it's own sufficiently to be able to cleanly create a new VM. 
   11. Unable to log into, or apps unable to connect to PostgreSQL: the code attempts to get ONLY YOUR ip address and add it to the f/w rules. It does not add any other IP addresses.  All other connections are blocked by default.  You can/should update the azure postgresql flex server 'network' options to add whatever additional addresses you need.  To add them to terraform to be permanent, add them manually first, then run 'terraform plan' to see the entries that will be <b>removed</b>.  Add those 'to-be-removed' entries to the firewall section of the postgresql.tf and re-run.  Repeat until the new entries are NOT removed by plan, then run terraform apply.

## Costs

This plan defaults to using an 'Always On' policy, which for the 500Mb reserved will cost about 6 bucks a month to run 24/7 in a 30 day month.  This is <b>required</b> so the 10 second Github timeout is not (often) exceeded.  Without warm-up, your Github webhook will get timeout, with no response from Azure.  However, it is NOT required to have Always On enabled when you are not using it.  Unused and unneeded runners will delete, along with their NIC and storage, no need to run terraform destroy.  Though, you can use terraform destroy the other resources when you are done for the day, you can also target the function app solely with <i>terraform destroy -target=azurerm_function_app_flex_consumption.demo</i>, keeping most everything else (that is cost free) configured and stored. This saves the Always On costs until you re-run terraform apply.  It will also enable faster creation of the complete environment with next run of terraform apply, than when running a complete terraform destroy prior.  

Perhaps, the only reason not to destroy the function app is that that function app's name becomes a unique sub-domain in the azurewebsites.net domain. If you want to ensure you do not lose that sub-domain, you will need to avoid destroying the app. 

With this webhook trigger configured to your own repo(s), you will launch every time you a) send an authorized payload (via git push) to any of those repos configured b) manually trigger the webhook via 'Redelivery' option in the Github UI, or c) re-deploy a webhook via terraform apply. That could be quite a few launches if you are pushing back to your own git repo regularly and frequently, and/or updating or manually triggering the web hook(s), so beware! 

This plan <i>tf-azure</i> has a working full life-cycle, meaning it successfully joins the GH server becoming a functional Github self-hosted actions runner, that also knows how and when to safely kill itself, and remove vm storage.   As of this writing, the tf-azure plan brings up a generic 'latest' ubutu (lts) via webhook trigger and joins to your github server as a self-hosted actions runner!  

Most importantly, this plan is an easy and convenient way to deploy the infrastructure to run VM servers in their own resource group, dedicated virtual network, security group, RBAC role, and so on, whether you need to use them as a github self-hosted actions runner, or not!  

## Meta

Andrew Simon – asimon@technology-leadership.com

Created 3-09-2026

Updated 9-23-2026

Distributed under the Apache 2.0 license.