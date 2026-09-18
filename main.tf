terraform {
  required_version = ">= 1.13.1"
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "~> 4.5"
    }
    azuread = {
      source = "hashicorp/azuread"
      version = "~> 3.0"
     }
    github = {
      source  = "integrations/github"
      version = "~> 6.8.3"
    }
    azuresql = {
      source  = "jonascrevecoeur/azuresql"
    }
  }
  backend "azurerm" {
    resource_group_name = "terraform-state"
    storage_account_name = "tlcterraformstate" # You must hard-code a unique name here
    container_name = "demo-tf-state"
    key = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  } 
}

provider "github" {
  owner = "${local.owner}"  # The target GitHub organization or user account [7]
  token = "${var.token}"
}
# Get user and subscription information
data "azurerm_client_config" "current" {}

data "azuread_client_config" "current" {}

data "azurerm_location" "current" { location = var.location }

# We need to grant access to our manyally created terraform state storage
data "azurerm_resource_group" "terraform_state" {
  name = "terraform-state" # Replace with your Terraform State stroage RG name
}

# 1. Activate the Application Administrator role in the tenant (if not already active)
resource "azuread_directory_role" "app_admin" {
  display_name = "Application Administrator"
}

# 2. Assign the Application Administrator role to your GitHub OIDC Managed Identity
resource "azuread_directory_role_assignment" "github_oidc_ad_access" {
  role_id             = azuread_directory_role.app_admin.template_id
  principal_object_id = azurerm_user_assigned_identity.github_oidc.principal_id
}

# This was already active. Activation can be done, or use import, as needed
data "azurerm_role_definition" "vm_contributor" {
  name = "Virtual Machine Contributor"
}

data "http" "client_ip" { url = "https://ipv4.icanhazip.com" }

resource "time_static" "sas" {}

output "location" {
  value = data.azurerm_location.current.display_name 
}
output "subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}

# Resources: RG, VNet, Subnet, PIP, NSG, NIC, VM
resource "azurerm_resource_group" "demo" {
  name     = "DemoResourceGroup"
  location = data.azurerm_location.current.display_name
}

# Create a storage account for the apps, not terraform state
resource "azurerm_storage_account" "demo" {
  name                     = "${var.storage_account}"
  resource_group_name      = azurerm_resource_group.demo.name
  location                 = azurerm_resource_group.demo.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "function_code_container" {
  name                  = "${var.storage_container}"
  storage_account_id  = azurerm_storage_account.demo.id
  container_access_type = "blob"
}

resource "azurerm_virtual_network" "demo" {
  name                = "demo"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
}

resource "azurerm_subnet" "public" {
  name                 = "Public"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = ["10.0.1.0/24"]
  
}

resource "azurerm_subnet" "private" {
  name                 = "Private"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = ["10.0.2.0/24"]
  # Set to false to deny default outbound internet access
  default_outbound_access_enabled = false
}

resource "azurerm_public_ip" "demo_ip" {
  count = var.static_option ? 1 : 0
  name                = "DemoPublicIP"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Allow all port 22 traffic between the Internet and this NSG
resource "azurerm_network_security_group" "public" {
  name                = "Public"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22-8001"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Allow only traffic between 10.0.X.X subnets in your vnet
resource "azurerm_network_security_group" "private" {
  name                = "Private"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefixes    = ["10.0.1.0/24", "10.0.2.0/24"]
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "eth0" {
  count               = var.static_option ? 1 : 0
  name                = "TLC_Primary_Interface"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.demo_ip[0].id
  }
}

resource "azurerm_network_interface_security_group_association" "sg_assoc" {
  count                     = var.static_option ? 1 : 0
  network_interface_id      = azurerm_network_interface.eth0[0].id
  network_security_group_id = azurerm_network_security_group.public.id
}

# CREATE THE USER-ASSIGNED MANAGED IDENTITY (Executed Prior to Dynamic VMs)
resource "azurerm_user_assigned_identity" "vm_identity" {
  name                = "uami-vm-contributor"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
}

resource "azurerm_role_assignment" "vm_role" {
  scope                = azurerm_resource_group.demo.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.vm_identity.principal_id
}
## We launch dynamic VMs via Azure Function App similar to this static VM
resource "azurerm_linux_virtual_machine" "tlc_vm" {
  count = var.static_option ? 1 : 0
  name                = "TLC"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  size                = var.vm_size
  admin_username      = "adminuser" # Linux is azureuser - this is for MSSQL
  admin_password      = var.adminpass
  disable_password_authentication = false
  
  network_interface_ids = [azurerm_network_interface.eth0[0].id]

  os_disk {
    name                 = "TLC-demo-hdd1"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  
  }  
}

# Create random password to be stored
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Parse repo_name to get repo without account
locals { 
  repo  = basename(var.repo_name)
  owner = dirname(var.repo_name)
  my_ip = chomp(data.http.client_ip.response_body)
  pri_db = "${var.db_name}--primary"
  replica = "${var.db_name}-replica"
}

# Create a repository secret (aka webhook secret)
resource "github_actions_secret" "webhook_secret" {
  repository      = "${local.repo}"
  secret_name     = "WEBHOOK_SECRET_TOKEN"
  plaintext_value = "${random_password.password.result}"
  depends_on = [
    random_password.password
  ]
  lifecycle {
    ignore_changes = [
      ## To change password, run terraform destroy azurerm_key_vault_secret.adminpass first
      plaintext_value
    ]
  }
}

# 1. Create User Assigned Managed Identity for Github (non-self-hosted) Runners
resource "azurerm_user_assigned_identity" "github_oidc" {
  name                = "id-github-actions-runner"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
}


# 2. Assign other role (not Contributor) to identity outside of for loop below
#resource "azurerm_role_assignment" "tf_key_permissions" {
#  scope                = azurerm_key_vault.vault.id
#  role_definition_name = "Key Vault Crypto Officer"
#  principal_id         = azurerm_user_assigned_identity.github_oidc.principal_id
#}


# 3. Assign a role to the identity (i.e., Contributor) to access resources in each asigned rg
resource "azurerm_role_assignment" "rg_contributor" {
  for_each = {
    group_1 = data.azurerm_resource_group.terraform_state.id
    group_2 = azurerm_resource_group.demo.id
  }

  scope                = each.value
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.github_oidc.principal_id

  lifecycle {
    create_before_destroy = true
  }
}

# 5. Establish OIDC Trust via Federated Identity Credential
resource "azurerm_federated_identity_credential" "github_repo_trust" {
  name                = "fic-github-actions"
# Deprecated:  resource_group_name = azurerm_resource_group.demo.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  
  # Links the identity specifically to your repo's main branch environment
  subject             = "repo:${var.repo_name}:environment:public"
  parent_id           = azurerm_user_assigned_identity.github_oidc.id
}

# 6. Create Role Assignment to access tlc-function-app
resource "azurerm_role_assignment" "function_app_flex_access" {
  scope                = azurerm_function_app_flex_consumption.demo.id
  role_definition_name = "Website Contributor" # Change this based on the exact access level you need
  principal_id         = azurerm_user_assigned_identity.github_oidc.principal_id
  depends_on = [
    azurerm_user_assigned_identity.github_oidc,
    azurerm_function_app_flex_consumption.demo
  ]
}
# These next 5 secrets are used to permission gh-runners when using azure/login@v2
resource "github_actions_secret" "AZURE_SUBSCRIPTION_ID" {
  repository      = "${local.repo}"
  secret_name     = "AZURE_SUBSCRIPTION_ID"
  plaintext_value = data.azurerm_client_config.current.subscription_id
}

resource "github_actions_secret" "AZURE_TENANT_ID" {
  repository      = "${local.repo}"
  secret_name     = "AZURE_TENANT_ID"
  plaintext_value = data.azurerm_client_config.current.tenant_id
}

resource "github_actions_secret" "AZURE_CLIENT_ID" {
  repository      = "${local.repo}"
  secret_name     = "AZURE_CLIENT_ID"
  plaintext_value = azurerm_user_assigned_identity.github_oidc.client_id
}

resource "github_actions_secret" "GITHUB_PERSONAL_ACCESS_TOKEN" {
  repository      = "${local.repo}"
  secret_name     = "PERSONAL_ACCESS_TOKEN"
  plaintext_value = var.token
}

resource "github_actions_secret" "ADMIN_PASSWORD" {
  repository      = "${local.repo}"
  secret_name     = "ADMIN_PASSWORD"
  plaintext_value = var.adminpass
}

#data "github_actions_registration_token" "dynamic_runner" {
#  repository = "${local.repo}"
#}

output "public_ip_address" {
  value = one(azurerm_public_ip.demo_ip[*].ip_address)
}
#output "current_user_principal_name" {
#  value = data.azuread_user.current_user.user_principal_name
#}
