variable "msi_id" {
  type        = string
  description = "The Managed Service Identity ID. If this value isn't null (the default), 'data.azurerm_client_config.current.object_id' will be set to this value."
  default     = null
}
variable "adminpass" {
  type        = string
  description = "Never commit real passwords to a repo"
  default     = ""
}