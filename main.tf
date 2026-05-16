terraform {
  required_version = ">= 1.13.1"
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "~> 4.0"
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

# Resources: RG, VNet, Subnet, PIP, NSG, NIC, VM
resource "azurerm_resource_group" "demo" {
  name     = "DemoResourceGroup"
  location = "East US"
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
    destination_port_range     = "22"
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
  name                = "TLC_Primary_Interface"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.demo_ip.id
  }
}

resource "azurerm_network_interface_security_group_association" "sg_assoc" {
  network_interface_id      = azurerm_network_interface.eth0.id
  network_security_group_id = azurerm_network_security_group.public.id
}

# "azurerm_linux_virtual_machine" "tlc_vm" {
#  name                = "TLC"
#  location            = azurerm_resource_group.demo.location
#  resource_group_name = azurerm_resource_group.demo.name
#  size                = "Standard_DC1s_v3"
#  admin_username      = "adminuser"
#  network_interface_ids = [azurerm_network_interface.eth0.id]
#
#  os_disk {
#    name                 = "TLC-demo-hdd1"
#    caching              = "ReadWrite"
#    storage_account_type = "Standard_LRS"
#  }
#
#  source_image_reference {
#    publisher = "Canonical"
#    offer     = "0001-com-ubuntu-server-jammy"
#    sku       = "22_04-lts-gen2"
#    version   = "latest"
#  }
#}

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
#data "github_actions_registration_token" "dynamic_runner" {
#  repository = "${local.repo}"
#}

output "public_ip_address" {
  value = azurerm_public_ip.demo_ip.ip_address
}
