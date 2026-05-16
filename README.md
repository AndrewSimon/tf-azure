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

## Log into Azure via AzureCli
> az login

## Pip installs on Windows, upgrade pip3 and install modules
1. python3.9.exe -m pip install --upgrade pip

## Terraform Usage example

1. terraform init  #Perform only once, after first git clone
2. terraform plan  #Plan does not require a password
3. terraform apply -var="token=my_gh_pat" -var="adminpass=my_strong_pass" #First time apply must include a github token and (SQL) admin password 
4. terraform apply #Subsequent values of password var ignored until deleted first
5. terraform destroy -target=azurerm_key_vault_secret.adminpass #Do this before applying (MSSQL) admin password updates
6. terraform destroy #deletes ALL of the remaining resources created by this plan.  

Note: due to Azure vault design, destroying vault purges secrets, which awaits a 10 minute timeout. It will complete normally but if you do not want to wait, CTL+C to exit, then, re-run terraform destroy to remove remaining resources. The terraform backend storage account you created by hand will not be destroyed.
--> After a terraform apply, be sure to refresh Azure portal screens before viewing/using data fields.

## Trouble-shooting

<i>Error: Error in function call
   on azure_function.tf, Call to function "filemd5" failed: function returned an inconsistent result</i>: Re-run 'terraform apply' as the md5 will now match the function.py file.  If 'file not found' instead of 'insconsistent result', run 'touch function.py' then re-run 'terraform apply'.

## Meta

Andrew Simon – asimon@technology-leadership.com

Created 3-09-2026
Updated 3-10-2026

Distributed under the Apache 2.0 license.