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
  description = "Use 'account/repo' portion of github url, tf will parse, as needed"
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
variable "token" {
description = "Github PAT - never commit tokens. Use cmd line option -var=gh_token=mytoken"
  type        = string
  default     = ""
}
variable "storage_account" {
description = "Demo function storage accounts gets destroyed, thus terreform state storage account should differt"
  type        = string
  default     = "tlcdemostorageaccount"
}
variable "storage_container" {
description = "Function itself can be the same as the storage container that contains it"
  type        = string
  default     = "function-code"
}
variable "bashpath" {
description = "This necessary to run bash in Windows, eg Cygwin or equivalent"
  type      = string
  default   = "bash"
}