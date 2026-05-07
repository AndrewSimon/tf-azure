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
variable "webhook" {
  type        = string
  description = "Never commit real webhook secrets to a repo"
  default     = ""
}
# Use "accountname/repository" format
variable "repo_name" {
  default     = "AndrewSimon/tf-azure"
}
variable "max_instances" {
description = "Maximum number of running instances allowed by lambda_handler. Keep high if terminating instances at completion"
  type        = string
  default     = "10"
}
variable "min_instances" {
description = "Manimum number of running instances allowed by lambda_handler. Keep high if terminating instances at completion"
  type        = string
  default     = "1"
}