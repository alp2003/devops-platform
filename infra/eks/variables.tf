variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "platform"
}

variable "kubernetes_version" {
  type    = string
  default = "1.37"
}

variable "admin_cidr" {
  type        = string
  description = "Your public IP in CIDR form (x.x.x.x/32). Only this address can reach the EKS API."

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}
