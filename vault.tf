

data "azurerm_client_config" "current" {}

locals {
  current_user_id = coalesce(var.msi_id, data.azurerm_client_config.current.object_id)
}

resource "azurerm_key_vault" "vault" {
  name                       = "TLC-KeyVault"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
#  soft_delete_retention_days = 7

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = local.current_user_id

    key_permissions    = ["List", "Create", "Delete", "Get", "Purge", "Recover", "Update", "GetRotationPolicy", "SetRotationPolicy"]
    secret_permissions = ["Set"]
  }
}

resource "azurerm_key_vault_key" "key" {
  name = "key-vault-demo"

  key_vault_id = azurerm_key_vault.vault.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }
}

resource "azurerm_key_vault_secret" "adminpass" {
  name         = "admin-password"
  value        = var.adminpass
  key_vault_id = azurerm_key_vault.vault.id
  lifecycle {
    ignore_changes = [
      ## To change password, run terraform destroy azurerm_key_vault_secret.adminpass first
      value
    ]
  }
}

data "azurerm_key_vault" "vault" {
  name = "TLC-KeyVault"
  resource_group_name = azurerm_resource_group.demo.name
}

data "azurerm_key_vault_secret" "password" {
  name = "admin-password"
  key_vault_id = data.azurerm_key_vault.vault.id
}


