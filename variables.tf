variable "msi_id" {
  type        = string
  description = "The Managed Service Identity ID. If this value isn't null (the default), 'data.azurerm_client_config.current.object_id' will be set to this value."
  default     = null
}
variable "adminpass" {
  type        = string
  description = "VM and DB admin password. Never commit real passwords to a repo"
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
description = "Github PAT - never commit tokens. Use cmd line option -var=token=mytoken"
  type        = string
  default     = ""
}
variable "storage_account" {
description = "Demo function storage accounts gets destroyed, thus terreform state storage account should differt"
  type        = string
  default     = "tlcdemostorageaccount"
}
variable "storage_container" {
description = "storage container that contains function code"
  type        = string
  default     = "function-code"
}
variable "location" {
description = "Location of the resources to deploy"
  type        = string
  default     = "eastus2"
}
variable "vm_size" {
description = "Size of the VM we will deploy dynamically"
  type        = string
  default     = "Standard_D2s_v3"
}
variable "sku_name" {
description = "Size of the DB compute"
  type        = string
#  default     = "GP_Standard_D2s_v3" # Good for prod - replica will be created too
  default     = "B_Standard_B1ms" # B_  prevents replicas, which is our default
}
variable "storage_mb" {
description = "Size of the DB storage"
  type        = string
  default     = "32768"
}
variable "mkt_opt" {
description = "Regular pricing unless you specify 'spot'"
  type        = string
  default     = "spot"
}
variable "function_code" {
description = "Name of the python function (code), not the app that runs it"
  type        = string
  default     = "launch_vm"
}
variable "bashpath" {
description = "This is necessary to run bash in Windows (i.e. /bin dirname is problematic)"
  type      = string
  default   = "bash"
}
variable "static_option" {
  type      = bool
  ## 1 = yes, I want static vm resources too, 0 = no, thank you
  default   = false
}
variable "db_name" {
  description = "PSQLDB name: terraform converts to pri and replica db names, or skips if blank"
  type      = string
  default   = "" # Or a unique string like "tlc-db" to create a db pri and replica
}