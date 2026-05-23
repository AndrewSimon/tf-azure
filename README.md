# TF-AZURE
> Stands up some Azure resources in it's own resource group

This plan will:
1. Create a resource group for your 'demo' virtual network
2. Create 'demo' virtual network and 2 subnets, 1 'public' and 1 'private'
3. Create 2 NSG for the two subnets to restrict traffic, accordingly
4. Create a VM instance and network interface in the public subnet
5. Assign a public IP to the VM instance
6. Output the public IP so you can connect to your instance
7. Creates a key vault, key policy, and password secret (for MSSQL)
8. Creates an Azure Function (you must request a VM quota manually)
9. Creates a Gitthub webhook

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

## Install Python
>https://www.python.org/downloads/
 
## Create/Configure the Python Virtual Environment for Azure Functions 
 
 1. cd tf-azure
 2. py -3.13 -m venv .venv (Windows) or python -m venv .venv (Linux) # As of writing, python3.14  remote build not supported yet

## Create Azure storage for Terraform backend via Portal UI
>Create a resource group and storage account to be used in Terraform configuration setup below

1. Resource group name --> terraform-state 
2. Storage account name --> your_unique_storage_account_name  (must be unique across all Azure)
3. Data Storage --> Containers --> + Add container --> demo-tf-state
 
## Request Azure App Function Quota for App Service in your Subscription
>Request 1 VM or more for App Service to use to run the python function

1. Quotas|My quotas --> Subscriptions --> Azure Subscription Name
2. Provider: App Service --> Region (select the region to deploy)
3. Select the VM type, the 'B1' is small and affordable. It only needs to run our small python script (which, when triggered by the Webhook, starts another VM that will be our GH Runner VM).


## Terraform configuration setup
>Update the main.tf azurerm backend with the newly created storage account name from above

1. After installing above requirements, clone this repo.
2. cd tf-azure, edit main.tf --> change 'storage_account_name = "your_unique_storage_account_name"
3. Edit variables.tf --> change values to match your conventions and environment 

## Log into Azure via AzureCli
> az login

## Pip installs on Windows, upgrade pip3 and install modules
1. python3.9.exe -m pip install --upgrade pip

## Terraform Usage example

1. terraform init  #Perform only once, after first git clone
2. touch function_app.py # Necessary for filemd5 to work 
3. export TF_VAR_token=<your_github_personal_access_token> # to skip, source from profile
4. terraform plan 
5. terraform apply
6. terraform destroy -target=terraform_data.upload_function #Do this before loading python function updates
7. terraform destroy -target=azurerm_key_vault_secret.adminpass #Do this before applying (MSSQL) admin password updates
8. terraform destroy #deletes ALL of the remaining resources created by this plan.  

Note: due to Azure vault design, destroying vault purges secrets, which awaits a 10 minute timeout. It will complete normally but if you do not want to wait, CTL+C to exit, then, re-run terraform destroy to remove remaining resources. The terraform backend storage account you created by hand will not be destroyed.
--> After a terraform apply, be sure to refresh Azure portal screens before viewing/using data fields.

## Trouble-shooting

<i>Error in function call on azure_function.tf, Call to function "filemd5" failed: <B>function returned an inconsistent result</B></i>:
    
   1. If 'no file exists at ./function_app.py' or 'fiile not found', instead of 'insconsistent result', run 'touch function_app.py' then re-run 'terraform apply/destroy'.
   2. Re-run 'terraform apply' as the md5 will now match the function_app.py file. 

## Meta

Andrew Simon – asimon@technology-leadership.com

Created 3-09-2026
Updated 3-10-2026

Distributed under the Apache 2.0 license.