# TF-AZURE
> Stands up some Azure resources in it's own resource group

This plan will:
1. Create a resource group for your 'demo' virtual network
2. Create 'demo' virtual network and 2 subnets, 1 'public' and 1 'private'
3. Create 2 NSG for the two subnets to restrict traffic, accordingly
4. Create a VM instance and network interface in the public subnet
5. Assign a public IP to the VM instance
6. Output the public IP so you can connect to your instance

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
 
## Terraform configuration setup
>Update the main.tf azurerm backend with the newly created storage account name from above

1. After installing above requirements, clone this repo.
2. cd tf-azure, edit main.tf --> change 'storage_account_name = "your_unique_storage_account_name"

## Log into Azure via AzureCli
> az login

## Terraform Usage example

1. terraform init  #perform only once, after first git clone
2. terraform plan  #see what will happen - aka preview
3. terraform apply #implement what will happen - aka deploy
4. terraform destroy #deletes ALL of the resources created by this plan.  The terraform backend storage account you created by hand will not be destroyed.


## Meta

Andrew Simon – asimon@technology-leadership.com

Created 3-9-2026

Distributed under the Apache 2.0 license.
