# TF-AZURE
> Stands up some Azure resources in it's own resource group

This plan will:
1. Create a resource group for your 'demo' virtual network
2. Create 'demo' virtual network and 2 subnets, 1 'public' and 1 'private'
3. Create 2 NSG for the two subnets to restrict traffic, accordingly
4. Create a storage account and blob container for the Funcion App
5. Assign a public IP to the VM instance
6. Output the public IP so you can connect to your instance
7. Creates a key vault, key policy, and password secret (MSSQL and/or VM login)
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

## Trouble-shooting

<i>Error in function call on azure_function.tf, Call to function "filemd5" failed: <B>function returned an inconsistent result</B></i>:
    
   1. If 'no file exists at ./function_app.py' or 'fiile not found': run 'touch function_app.py' then re-run 'terraform apply/destroy'.
   2. Function app is created but not the function: re-run terraform apply, ensure the terraform_data.upload_function runs.  The upload package is about 500Mb because dependency libraries are built and uploaded along with your function.
   3. Upload function did not run the first time:  Re-run terraform apply
   4. The upload function runs but there is still no function in the function app:  this is usually due to missing dependencies.  Try running 'pip install -r requirements.txt' then re-run terraform apply.  You will have syntax errors even if you did not modify the function when any variable values are empty/missing.  Ensure the python app itself has no obvious syntax problems, run python function_app.py on the command line and ensure it returns no errors or output.  If there are errors, try to determine which variable values are coming up empty and/or unset.
   5. If you successfully installed Function App Core Tools, you will be able to run <i>func start</i> in the tf-azure directory and start a local Function App! You can post data with curl, fiddler or other client to <i>http://localhost:7071/api/launch_vm</i> and output not directed to the client will come into the screen running <i>func start</i> as standard error and standard out.  While trouble-shooting, you update the function_app.py code in an editor window, and saved code changes will automatically reload into the <i>func start</i> run, you do not need to restart it.  You can then re-run the client, hit the localhost api endpoint, and see if your code edits changed/fixed things.  Repeat as needed.  When done editing function_app.py <b>remember to update function_app.tf</b> as all of your function_app.py updates will be overwritten next time you run terraform apply.

## Costs

A <i>terraform apply</i> usually triggers the webhook and function as it's (re)deployed, whether you git push to trigger the function or not, and will launch a virtual machine!  Mercifully, you must run the plan TWICE the first time because the function app is not existing yet during the first run and the func build and upload will not trigger. After the second apply, the build and upload runs and takes 10 minutes while the webhook is triggered in the first 10 seconds, so there is an error 404 webhook response as the app route is not up yet.  Note, in both terraform apply runs, no VM is launched, yet, but you will have created the public IP and there is a small hourly cost for it until you destroy (delete/remove) it. But, once the app route is up and running, with this webhook trigger configured to your own repo(s), you will launch every time you a) send an authorized payload (via git push) to any of those repos configured, b) manually trigger the webhook via 'Redelivery' option in the Github UI, or c) re-deploy a webhook via terraform apply. That could be quite a few launches if you are pushing back to your own git repo regularly and frequently, and/or updating or manually triggering the webhook(s), so beware! 

The AWS version of the webhook (dynamic) VM launch called <i>tf-files</i> has a working full life-cycle, meaning it successfully joins the GH server becoming a functional Github self-hosted actions runner, that also knows how and when to safely kill itself, and remove vm storage and public ip in all situations along with it (based mostly on job queue count).  As of this writing, the tf-azure plan is still very useful in bringing up a generic 'latest' ubutu (lts) via webhook trigger.  It's an easy and convenient way to instantly request and create, either via github push or webhook payload re-delivery via Github UI, an accessible vm in it's own resource group, virtual network, and so on, whether you need a github self-hosted actions runner, or not! 

I/we hope to have the Github self-hosted actions runner registration and full life-cycle automation completed for <i>tf-azure</i> in the coming months.  The functionality includes non-root automatic shutdown on a quiet GH job queue, using API, which I/we do not yet support in Azure just yet.  There may be some crude hard-codes to imitate full life-cycle behavior in limited situations as I/we develop the first release candidate, but it largely won't work.  Meaning nodes will come up fine! It's just that you need to 1. join them to your Github server manually (when not working) and 2. terminate/delete vms and related resources manually or via terraform destroy when the terminate/remove/delete portion of the life-cycle fails to do it!  To ensure no unwanted vms or ip addresses, always run terraform destroy. It prevents future unwanted runners and public ip addresses via repo trigger that this deploy enables, and will cost you money whether you use those resources or not; but potential costs are incurred <i>only if you do not</i> terraform destroy when done.  

## Meta

Andrew Simon – asimon@technology-leadership.com

Created 3-09-2026
Updated 5-10-2026

Distributed under the Apache 2.0 license.