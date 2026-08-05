# Primary server (already exists or created here)
resource "azurerm_postgresql_flexible_server" "primary" {
name = "primary-psql-server"
resource_group_name = azurerm_resource_group.demo.name
location = azurerm_resource_group.demo.location
# location = "eastus2"
version                       = "18"
administrator_login           = "psqladmin"
administrator_password        = var.adminpass
auto_grow_enabled             = true
backup_retention_days         = 7 
geo_redundant_backup_enabled  = true
sku_name                      = var.sku_name
storage_mb                    = var.storage_mb
storage_tier                  = "P4"
# prevent silent deployment drops
public_network_access_enabled = true 
# prevent muti-region and tier limitations
zone                          = "3"
lifecycle {
  ignore_changes = [
    administrator_password,
    name
    ]
  }
}

# Replica server
resource "azurerm_postgresql_flexible_server" "replica" {
# If first byte of sku_name is 'B', it's burstable and doesn't support replicas
count = substr(var.sku_name, 0, 1) == "B" ? 0 : 1
name = "replica-psql-server"
resource_group_name = azurerm_resource_group.demo.name
location = azurerm_resource_group.demo.location
create_mode = "Replica"
source_server_id = azurerm_postgresql_flexible_server.primary.id
}

output "pri_db_fqdn" {
  value       = azurerm_postgresql_flexible_server.primary.fqdn
  description = "The FQDN of the PostgreSQL Flexible Server."
}
output "rep_db_fqdn" {
  value       = azurerm_postgresql_flexible_server.replica[*].fqdn
  description = "The FQDN of the PostgreSQL Flexible Server."
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "demo" {
  name             = "my-local-ip"
  start_ip_address = local.my_ip
  end_ip_address   = local.my_ip
  server_id        = azurerm_postgresql_flexible_server.primary.id
}